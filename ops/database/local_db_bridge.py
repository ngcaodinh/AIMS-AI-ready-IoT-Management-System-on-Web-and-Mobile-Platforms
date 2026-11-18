"""Endpoint PostgreSQL loopback dành riêng cho DBeaver reader, không thay container hoặc mở owner TCP."""

import argparse
import getpass
import json
import socket
import socketserver
import struct
import subprocess
import threading
from pathlib import Path

import verify_database as lab


HOST = "127.0.0.1"
PORT = 15432
DATABASE = "iot_platform_lab"
USER = "iot_dbeaver_reader"
MAX_STARTUP_BYTES = 10000

# Perl có sẵn trong image; Unix socket -> stdio nhị phân, không shell, không credential/environment.
SOCKET_RELAY = r'''
use strict; use warnings; use IO::Socket::UNIX; use IO::Select;
binmode STDIN; binmode STDOUT;
my $socket=IO::Socket::UNIX->new(Type=>SOCK_STREAM,Peer=>'/tmp/.s.PGSQL.5432') or die "socket unavailable";
my $selector=IO::Select->new(\*STDIN,$socket);
while(my @ready=$selector->can_read()) {
 for my $input (@ready) {
  my $count=sysread($input,my $buffer,65536);
  exit 0 unless defined($count) && $count>0;
  my $output=fileno($input)==fileno(STDIN)?$socket:\*STDOUT;
  my $offset=0;
  while($offset<$count) { my $written=syswrite($output,$buffer,$count-$offset,$offset); exit 1 unless $written; $offset+=$written; }
 }
}
'''


# Startup có thể bị chia nhiều TCP packet; không parse body chưa nhận đủ hoặc cấp phát vô hạn.
def receive_exact(connection, size):
    """Input
    Param: connection — socket client đã accept trên loopback.
    Param: size — số byte có giới hạn từ protocol parser.
    Output: đúng số byte; Errors: ConnectionError khi peer đóng sớm.
    """
    result = bytearray()
    while len(result) < size:
        chunk = connection.recv(size-len(result))
        if not chunk:
            raise ConnectionError("Incomplete PostgreSQL startup")
        result.extend(chunk)
    return bytes(result)


# Khóa principal/database trước khi Docker nhận kết nối; không chuyển Unix trust thành quyền owner trên TCP.
def validated_startup(packet, *, user=USER, read_only=True):
    """Input
    Param: packet — StartupMessage PostgreSQL protocol3, không gồm password.
    Param: user — principal được launcher định danh; mặc định chỉ reader DBeaver.
    Param: read_only — giữ read-only mặc định; runner probe tạm có SCRAM riêng mới tắt.
    Output: startup đã chuẩn hóa và ép budget; Errors: ValueError nếu khác user/DB hoặc options lạ.
    """
    if len(packet) < 9 or struct.unpack("!II",packet[:8]) != (len(packet),196608) or packet[-1:] != b"\0":
        raise ValueError("Invalid PostgreSQL startup")
    values = packet[8:-1].split(b"\0")
    if values and values[-1] == b"":
        values.pop()
    if len(values) % 2:
        raise ValueError("Invalid startup fields")
    fields = {}
    allowed = {"user","database","application_name","client_encoding","DateStyle","TimeZone","extra_float_digits"}
    for index in range(0,len(values),2):
        key = values[index].decode("ascii")
        value = values[index+1].decode("utf-8")
        if key not in allowed or key in fields:
            raise ValueError("Unapproved PostgreSQL startup field")
        fields[key] = value
    if user not in (USER,"iot_repository_probe") or fields.get("user") != user or fields.get("database") != DATABASE:
        raise ValueError("Only canonical inspection role and database are permitted")
    if not read_only and user != "iot_repository_probe":
        raise ValueError("Only the temporary repository probe may request writer mode")
    mode = "on" if read_only else "off"
    fields["options"] = f"-c default_transaction_read_only={mode} -c statement_timeout=30000 -c lock_timeout=5000 -c idle_in_transaction_session_timeout=15000"
    body = struct.pack("!I",196608) + b"".join(key.encode()+b"\0"+value.encode()+b"\0" for key,value in fields.items()) + b"\0"
    return struct.pack("!I",len(body)+4)+body


class InspectionHandler(socketserver.BaseRequestHandler):
    """Mỗi client có một docker-exec relay; role PostgreSQL giới hạn quyền sau startup."""

    # Chỉ nhận protocol startup đúng namespace; không log packet, câu query hoặc error chứa input.
    def handle(self):
        """Side effects: relay đúng một session tới Unix socket; đóng process khi client disconnect.
        Errors: connection/protocol errors chỉ đóng kết nối, không ghi dữ liệu nhạy cảm vào log.
        """
        relay = None
        try:
            self.request.settimeout(10)
            for _ in range(3):
                length = struct.unpack("!I",receive_exact(self.request,4))[0]
                if not 8 <= length <= MAX_STARTUP_BYTES:
                    raise ValueError("Invalid startup size")
                packet = struct.pack("!I",length) + receive_exact(self.request,length-4)
                protocol = struct.unpack("!I",packet[4:8])[0]
                if length == 8 and protocol in (80877103,80877104):
                    # Chỉ loopback trên cùng máy; từ chối SSL/GSS negotiation, không giả TLS thành công.
                    self.request.sendall(b"N")
                    continue
                startup = validated_startup(packet,user=self.server.allowed_user,read_only=self.server.read_only)
                break
            else:
                raise ValueError("Repeated encryption negotiation")
            # Dùng config CLI rỗng của Auth Lab để Docker không mở credential mặc định của người chạy.
            relay = subprocess.Popen(lab.docker_argv("exec","-i",lab.CONTAINER,"perl","-e",SOCKET_RELAY),
                                     stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
            relay.stdin.write(startup)
            relay.stdin.flush()
            self.request.settimeout(None)
            # Windows select chỉ hỗ trợ socket; thread riêng chuyển stdout pipe mà không busy polling.
            downstream = threading.Thread(target=self.copy_to_client,args=(relay,),daemon=True)
            downstream.start()
            while True:
                chunk = self.request.recv(65536)
                if not chunk:
                    break
                relay.stdin.write(chunk)
                relay.stdin.flush()
        except (OSError,ConnectionError,ValueError,UnicodeError):
            pass
        finally:
            if relay is not None:
                relay.terminate()
                relay.wait(timeout=5)
                relay.stdin.close()
                relay.stdout.close()

    # Đọc pipe nhị phân với read1 để không chờ đủ buffer khi PostgreSQL chỉ gửi ít byte.
    def copy_to_client(self, relay):
        """Input
        Param: relay — process docker-exec thuộc đúng session đang xử lý.
        Side effects: chuyển response PostgreSQL về socket client, không đọc/log nội dung.
        """
        try:
            while True:
                chunk = relay.stdout.read1(65536)
                if not chunk:
                    break
                self.request.sendall(chunk)
        except (OSError,ValueError):
            pass
        finally:
            try:
                self.request.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


class InspectionServer(socketserver.ThreadingTCPServer):
    """Chỉ listen loopback cố định; không cho tham số mở ra LAN hoặc đổi principal."""
    daemon_threads = True
    allow_reuse_address = True
    allowed_user = USER
    read_only = True


# SCRAM áp ngay trên Unix socket riêng của reader; không mở TCP trong container hoặc đổi trust của migrator.
def configure_password(password):
    """Cấu hình password verifier và HBA đúng role/database, không lưu plaintext vào source hoặc file cấu hình.
    Input
    Param: password — mật khẩu do người vận hành cung cấp qua giao diện kín; không lấy từ environment.
    Side effects: cập nhật verifier SCRAM trong PostgreSQL, thêm HBA local hẹp và reload; không restart engine.
    Errors: ValueError nếu rỗng; lỗi Docker/SQL được truyền lên, không in password hoặc verifier.
    """
    if not password or '\x00' in password:
        raise ValueError("A nonempty local password is required")
    lab.inspect_lab()
    identity=lab.sql("""SELECT coalesce(bool_and(NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication AND NOT rolbypassrls
      AND shobj_description(oid,'pg_authid')='IoT canonical local inspection role; no writer authority'),false)
      FROM pg_roles WHERE rolname='iot_dbeaver_reader';""",database=DATABASE).stdout.strip()
    if identity!="t":
        raise RuntimeError("Inspection role is absent or has unexpected provenance")
    quoted=password.replace("'","''")
    # Password chỉ qua stdin psql, không nằm trong argv Docker, log output hoặc file mẫu.
    lab.sql("SET standard_conforming_strings=on; SET password_encryption='scram-sha-256'; ALTER ROLE iot_dbeaver_reader PASSWORD '"+quoted+"';",role=lab.ADMIN,database=DATABASE)
    # HBA không chứa password: prepend exact local scope trước dòng trust hiện hữu, ghi backup một lần.
    hba_editor=r'''
use strict; use warnings;
my $path='/tmp/iot-postgres17-data/pg_hba.conf';
open my $input,'<',$path or die 'cannot open HBA'; local $/; my $content=<$input>; close $input;
my $rule="local iot_platform_lab iot_dbeaver_reader scram-sha-256\n";
if(index($content,$rule)!=0) {
 if(!-e "$path.before-iot-reader") { open my $backup,'>',"$path.before-iot-reader" or die 'cannot back up HBA'; print $backup $content; close $backup; }
 open my $output,'>',"$path.iot-reader-tmp" or die 'cannot write HBA'; print $output $rule.$content; close $output;
 chmod 0600,"$path.iot-reader-tmp" or die 'cannot protect HBA';
 rename "$path.iot-reader-tmp",$path or die 'cannot replace HBA';
}
'''
    lab.docker("exec",lab.CONTAINER,"perl","-e",hba_editor)
    if lab.sql("SELECT pg_reload_conf();",role=lab.ADMIN,database=DATABASE).stdout.strip()!="t":
        raise RuntimeError("PostgreSQL did not reload the scoped authentication rule")


# Bootstrap role từ SQL có version control, chỉ khi caller giao hành động setup.
def setup_reader():
    """Side effects: tạo/cấp role inspection đã giới hạn, không đọc/ghi password hoặc env thật."""
    lab.inspect_lab()
    path = Path(__file__).resolve().parents[2]/"backend/migrations/lab/dbeaver_reader.sql"
    lab.sql(path.read_text(encoding="utf-8"),role=lab.ADMIN,database=DATABASE)
    policy=path.with_name("dbeaver_permissions.sql").read_text(encoding="utf-8")
    lab.sql(policy,database=DATABASE)


# Endpoint không phục vụ owner/runtime; config xuất ra chỉ chứa metadata không secret.
def main():
    """Điều phối setup hoặc bridge local; không tự thay đổi role khi chỉ chạy serve.
    Output: metadata endpoint; Side effects: mở loopback cho inspection role tới DB canonical.
    """
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action",choices=("setup","serve","set-password"))
    action=parser.parse_args().action
    if action=="setup":
        setup_reader()
        print("Inspection role ready")
        return
    if action=="set-password":
        configure_password(getpass.getpass("Local inspection password: "))
        print("Local inspection SCRAM authentication configured")
        return
    lab.inspect_lab()
    with InspectionServer((HOST,PORT),InspectionHandler) as server:
        print(json.dumps({"host":HOST,"port":PORT,"database":DATABASE,"user":USER,"mode":"LOCAL_INSPECTION_ONLY"}),flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
