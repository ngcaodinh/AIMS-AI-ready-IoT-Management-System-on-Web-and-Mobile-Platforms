"""Kiểm startup boundary của endpoint DBeaver, không mở Docker hoặc đọc environment."""

import socket
import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[3]/"ops/database"))
import local_db_bridge as bridge


# Builder chỉ tạo packet tổng hợp để kiểm protocol, không chứa password hoặc query thật.
def startup(fields):
    """Input
    Param: fields — danh sách cặp key/value PostgreSQL startup của fixture.
    Output: packet protocol3, cho phép giữ duplicate để kiểm negative boundary.
    """
    body=struct.pack('!I',196608)+b''.join(key.encode()+b'\0'+value.encode()+b'\0' for key,value in fields)+b'\0'
    return struct.pack('!I',len(body)+4)+body


class LocalBridgeTests(unittest.TestCase):
    """Không biến Unix socket trusted thành endpoint owner hoặc generic PostgreSQL proxy."""

    # Writer/DB hệ thống đều phải bị chặn trước khi docker-exec được tạo.
    def test_rejects_owner_runtime_and_other_database(self):
        """Output: ValueError cho principal/database ngoài đúng allowlist inspection."""
        for user,database in (('iot_migrator',bridge.DATABASE),('iot_runtime',bridge.DATABASE),(bridge.USER,'postgres')):
            with self.subTest(user=user,database=database),self.assertRaises(ValueError):
                bridge.validated_startup(startup([('user',user),('database',database)]))

    # Không nhận options từ client để đổi role/search_path hoặc vô hiệu hóa budget lúc khởi tạo.
    def test_rejects_duplicate_principal_and_unapproved_options(self):
        """Output: duplicate key và startup parameter không duyệt bị fail closed."""
        base=[('user',bridge.USER),('database',bridge.DATABASE)]
        for extra in ([('user',bridge.USER)],[('options','-c role=iot_migrator')],[('replication','database')]):
            with self.subTest(extra=extra),self.assertRaises(ValueError):
                bridge.validated_startup(startup(base+extra))

    # Reader hợp lệ phải giữ PG framing và được ép read-only/timeouts phía server.
    def test_valid_reader_gets_readonly_budget(self):
        """Output: packet chỉ cho DB canonical, có readonly/statement/lock timeout cố định."""
        packet=bridge.validated_startup(startup([('user',bridge.USER),('database',bridge.DATABASE),('application_name','DBeaver')]))
        self.assertEqual(struct.unpack('!I',packet[:4])[0],len(packet))
        self.assertIn(b'default_transaction_read_only=on',packet)
        self.assertIn(b'statement_timeout=30000',packet)

    def test_probe_writer_cannot_enable_reader_or_owner_mutation(self):
        """Probe phải được launcher chọn tường minh; không thể mở writer cho owner hoặc DBeaver reader."""
        packet=startup([('user','iot_repository_probe'),('database',bridge.DATABASE)])
        with self.assertRaises(ValueError):
            bridge.validated_startup(packet)
        self.assertIn(b'default_transaction_read_only=off',bridge.validated_startup(packet,user='iot_repository_probe',read_only=False))
        reader=startup([('user',bridge.USER),('database',bridge.DATABASE)])
        with self.assertRaises(ValueError):
            bridge.validated_startup(reader,read_only=False)
        owner=startup([('user','iot_migrator'),('database',bridge.DATABASE)])
        with self.assertRaises(ValueError):
            bridge.validated_startup(owner,user='iot_migrator',read_only=False)

    # TCP không bảo đảm một recv nhận đủ dữ liệu; không coi packet thiếu là startup hợp lệ.
    def test_partial_packet_and_closed_peer_are_handled(self):
        """Output: nhận đủ byte khi chia chunk; peer đóng sớm tạo ConnectionError."""
        first,second=socket.socketpair()
        try:
            first.sendall(b'ab')
            first.sendall(b'cd')
            self.assertEqual(bridge.receive_exact(second,4),b'abcd')
            first.close()
            with self.assertRaises(ConnectionError):
                bridge.receive_exact(second,1)
        finally:
            first.close()
            second.close()
