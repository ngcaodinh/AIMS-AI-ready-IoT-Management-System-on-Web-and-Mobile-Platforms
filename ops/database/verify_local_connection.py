"""Kiểm endpoint DBeaver bằng SCRAM và SQL metadata; không đọc env, không lưu password hoặc verifier."""

import base64
import getpass
import hashlib
import hmac
import json
import secrets
import socket
import struct
from datetime import datetime,timezone
from pathlib import Path

import local_db_bridge as bridge
import verify_platform as platform


# Chỉ đọc frame protocol trong giới hạn, không in payload auth/SQL hoặc nội dung hàng ứng dụng.
def read_message(connection):
    """Input
    Param: connection — socket loopback đã được tạo cho probe hiện hành.
    Output: message tag/body; Errors: RuntimeError nếu kích thước vượt giới hạn an toàn.
    """
    tag=bridge.receive_exact(connection,1)
    size=struct.unpack('!I',bridge.receive_exact(connection,4))[0]
    if not 4<=size<=1000000:
        raise RuntimeError('Unexpected PostgreSQL message size')
    return tag,bridge.receive_exact(connection,size-4)


# Gửi đúng framing của PostgreSQL; password chỉ tồn tại trong thuật toán proof, không gửi plaintext.
def send_message(connection,tag,body):
    """Input
    Param: connection — socket của session probe.
    Param: tag — một byte message type đã xác định nội bộ.
    Param: body — payload nhị phân được framing, không được log.
    Side effects: ghi message vào endpoint local.
    """
    connection.sendall(tag+struct.pack('!I',len(body)+4)+body)


# Probe SCRAM-SHA-256 có nonce và kiểm server signature, không chấp nhận trust thay cho password.
def authenticate(connection,password):
    """Xác thực password trên endpoint thật bằng SCRAM-SHA-256 theo protocol PostgreSQL.
    Input
    Param: connection — socket loopback tới bridge đã khóa role/database.
    Param: password — mật khẩu người vận hành cung cấp, không lấy từ file/environment.
    Output: SQLSTATE nếu auth bị từ chối, None nếu SCRAM proof và server signature hợp lệ.
    Errors: RuntimeError nếu server không dùng SCRAM, nonce/iteration/signature sai.
    """
    body=struct.pack('!I',196608)+b'user\0'+bridge.USER.encode()+b'\0database\0'+bridge.DATABASE.encode()+b'\0application_name\0IoT-Bridge-Probe\0\0'
    connection.sendall(struct.pack('!I',len(body)+4)+body)
    nonce=secrets.token_urlsafe(24)
    client_first='n='+bridge.USER+',r='+nonce
    expected_signature=None
    verified=False
    for _ in range(50):
        tag,body=read_message(connection)
        if tag==b'E':
            return next((field[1:].decode('ascii') for field in body.split(b'\0') if field.startswith(b'C')), 'UNKNOWN')
        if tag==b'R':
            code=struct.unpack('!I',body[:4])[0]
            if code==10:
                if b'SCRAM-SHA-256\0' not in body[4:]:
                    raise RuntimeError('Expected SCRAM-SHA-256')
                initial=('n,,'+client_first).encode()
                send_message(connection,b'p',b'SCRAM-SHA-256\0'+struct.pack('!I',len(initial))+initial)
            elif code==11:
                server_first=body[4:].decode('ascii')
                fields=dict(item.split('=',1) for item in server_first.split(','))
                iterations=int(fields['i'])
                if not fields['r'].startswith(nonce) or not 4096<=iterations<=1000000:
                    raise RuntimeError('Invalid SCRAM nonce or iteration budget')
                salt=base64.b64decode(fields['s'],validate=True)
                # Password local hiện hành là ASCII; không áp dụng normalization suy đoán lên secret.
                salted=hashlib.pbkdf2_hmac('sha256',password.encode('utf-8'),salt,iterations)
                client_key=hmac.digest(salted,b'Client Key','sha256')
                stored_key=hashlib.sha256(client_key).digest()
                final='c=biws,r='+fields['r']
                auth_message=(client_first+','+server_first+','+final).encode()
                signature=hmac.digest(stored_key,auth_message,'sha256')
                proof=bytes(first^second for first,second in zip(client_key,signature))
                expected_signature=hmac.digest(hmac.digest(salted,b'Server Key','sha256'),auth_message,'sha256')
                send_message(connection,b'p',(final+',p='+base64.b64encode(proof).decode()).encode())
            elif code==12:
                final_fields=dict(item.split('=',1) for item in body[4:].decode('ascii').split(','))
                if expected_signature is None or 'v' not in final_fields or not hmac.compare_digest(expected_signature,base64.b64decode(final_fields['v'],validate=True)):
                    raise RuntimeError('Invalid SCRAM server signature')
                verified=True
            elif code==0 and not verified:
                raise RuntimeError('Server accepted trust instead of SCRAM password authentication')
            elif code!=0:
                raise RuntimeError('Unexpected PostgreSQL authentication mechanism')
        if tag==b'Z':
            if not verified:
                raise RuntimeError('SCRAM authentication was not completed')
            return None
    raise RuntimeError('Too many authentication messages')


# Query chỉ metadata hoặc negative LIMIT0; không đọc giá trị password/hash/token kể cả khi privilege sai.
def query(connection,statement):
    """Input
    Param: connection — session probe đã xác thực.
    Param: statement — SQL fixture nội bộ, không nhận input tùy ý từ người dùng.
    Output: (các scalar row dạng text, SQLSTATE lỗi hoặc None), không log payload.
    """
    send_message(connection,b'Q',statement.encode()+b'\0')
    rows=[]
    error=None
    while True:
        tag,body=read_message(connection)
        if tag==b'D':
            length=struct.unpack('!i',body[2:6])[0]
            rows.append(body[6:6+length].decode('utf-8'))
        elif tag==b'E':
            error=next((field[1:].decode('ascii') for field in body.split(b'\0') if field.startswith(b'C')), 'UNKNOWN')
        elif tag==b'Z':
            return rows,error


# Cả password đúng/sai đều kiểm trên server thật; report không chứa salt, verifier, nonce, proof hoặc password.
def verify(password):
    """Input
    Param: password — password local chỉ dùng trong RAM cho probe này.
    Output: metadata endpoint và các PASS; Side effects: ghi JSON evidence không secret.
    Errors: RuntimeError nếu identity/quyền/SCRAM không khớp; không đổi dữ liệu hoặc quyền.
    """
    checks=[]
    with socket.create_connection((bridge.HOST,bridge.PORT),timeout=10) as rejected:
        rejected.settimeout(10)
        if authenticate(rejected,secrets.token_urlsafe(32))!='28P01':
            raise RuntimeError('Wrong password was not rejected with 28P01')
    checks.append('PASS:wrong_password_rejected_by_scram')
    with socket.create_connection((bridge.HOST,bridge.PORT),timeout=10) as connection:
        connection.settimeout(10)
        if authenticate(connection,password) is not None:
            raise RuntimeError('Provided password was rejected')
        checks.append('PASS:provided_password_verified_with_scram')
        rows,error=query(connection,"SELECT jsonb_build_object('database',current_database(),'role',current_user,'read_only',current_setting('transaction_read_only'),'table_count',(SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'))::text;")
        if error:
            raise RuntimeError('Metadata query was rejected')
        metadata=json.loads(rows[0])
        if metadata!={'database':bridge.DATABASE,'role':bridge.USER,'read_only':'on','table_count':89}:
            raise RuntimeError('Unexpected endpoint identity')
        for name,statement,expected in (
            ('reader_cannot_read_password','SELECT password_hash FROM public.users LIMIT 0;','42501'),
            ('reader_cannot_read_session_verifier','SELECT token_digest FROM public.sessions LIMIT 0;','42501'),
            ('reader_cannot_update_audit','UPDATE public.audit_events SET outcome=outcome;','25006'),
            ('reader_cannot_create_table','CREATE TABLE public.forbidden_reader_probe(marker integer);','25006'),
            ('reader_cannot_call_worker',"SELECT * FROM public.claim_outbox('TEST',30,1);",'42501'),
            ('reader_cannot_become_owner','SET ROLE iot_migrator;','42501'),
        ):
            if query(connection,statement)[1]!=expected:
                raise RuntimeError('Inspection permission boundary failed: '+name)
            checks.append('PASS:'+name)
        send_message(connection,b'X',b'')
    platform.lab.inspect_lab()
    sessions=json.loads(platform.sql("SELECT coalesce(jsonb_agg(jsonb_build_object('application',application_name,'role',usename,'database',datname)),'[]') FROM pg_stat_activity WHERE datname='iot_platform_lab' AND usename='iot_dbeaver_reader' AND application_name LIKE 'DBeaver%';").stdout)
    if sessions:
        checks.append('PASS:dbeaver_jdbc_sessions_confirmed_on_server')
    report={'timestamp_utc':datetime.now(timezone.utc).isoformat(),'connection':metadata,'host':bridge.HOST,'port':bridge.PORT,
            'authentication':'SCRAM-SHA-256','checks':checks,'dbeaver_active_session_count':len(sessions),'dbeaver_sessions':sessions}
    path=Path(__file__).resolve().parents[2]/'ops/database/evidence/dbeaver-local.json'
    path.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    return report


# Mật khẩu nhập kín ở terminal do người vận hành chạy, không lấy từ env hay lưu vào argument list.
def main():
    """Output: report không secret sau probe thật; Side effects: chỉ metadata và negative checks."""
    print(json.dumps(verify(getpass.getpass('Local inspection password: ')),indent=2))


if __name__=='__main__':
    main()
