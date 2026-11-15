"""Proxy ACK chỉ cho lab loopback: không ghi packet/query/credential và không sửa core auth."""

import struct
import threading
import select
import socket
import socketserver
import time

# Cận riêng fault harness, không là SLA: frame1MiB; completion5s và arm15s nằm trong HTTP20s.
MAX_FRAME_BYTES = 1_048_576
FRAME_TIMEOUT = 5
ARM_TIMEOUT = 15
STARTUP_TIMEOUT = 10
SHUTDOWN_TIMEOUT = 5


class FrameReader:
    """Ghép typed message PG theo length, độc lập cách TCP phân mảnh hoặc gộp dữ liệu."""

    def __init__(self):
        """Chỉ giữ buffer RAM và deadline partial frame, không giữ lịch sử payload."""
        self.buffer = bytearray()
        self.deadline = None

    def feed(self, chunk, now):
        """Ghép chunk có cận thành frame đầy đủ, không log hoặc diễn giải bind/query.

        Input
        Param: chunk — byte vừa nhận, chỉ giữ đến khi frame đủ.
        Param: now — monotonic timestamp để peer nhỏ giọt không reset deadline.
        Output: danh sách frame đầy đủ; Errors: length sai hoặc completion timeout.
        """
        if self.deadline is not None and now >= self.deadline:
            raise TimeoutError('PG frame completion expired')
        if chunk and not self.buffer:
            self.deadline = now + FRAME_TIMEOUT
        self.buffer.extend(chunk)
        frames = []
        while len(self.buffer) >= 5:
            length = struct.unpack('!I', self.buffer[1:5])[0]
            if not 4 <= length <= MAX_FRAME_BYTES:
                raise ValueError('PG frame length outside lab budget')
            if len(self.buffer) < length + 1:
                break
            frames.append(bytes(self.buffer[:length + 1]))
            del self.buffer[:length + 1]
            # Frame cũ đã xong; phần dư thuộc frame kế tiếp bắt đầu trong chunk hiện tại.
            self.deadline = now + FRAME_TIMEOUT if self.buffer else None
        return frames


class CommitGate:
    """Một arm generation cô lập; metadata chỉ đếm BEGIN/COMMIT, không lưu SQL hoặc connection ra report."""

    def __init__(self):
        """Dựng lock và trạng thái inactive để startup/seed/baseline được relay bình thường."""
        self.lock = threading.RLock()
        self.generation = 0
        self.active = False
        self.selected = None
        self.phase = 'IDLE'

    def arm(self, now):
        """Mở đúng một window sau seed/checks, từ chối arm lồng để không mất ownership.

        Input
        Param: now — monotonic timestamp bắt đầu deadline cố định của window.
        Output: generation opaque dùng finish; Errors: window trước chưa kết thúc.
        """
        with self.lock:
            if self.active:
                raise RuntimeError('Commit ACK arm already active')
            self.generation += 1
            self.active = True
            self.phase = 'ARMED'
            self.selected = None
            self.begun_connection = None
            self.begins = self.commits = 0
            self.commit_tag = False
            self.deadline = now + ARM_TIMEOUT
            return self.generation

    def frontend(self, connection, frame, ready_state, now):
        """Đặt suppression gate trước send COMMIT, chỉ claim transaction đã quan sát Z=T.

        Input
        Param: connection — identity riêng của worker, không PID hoặc dữ liệu DB.
        Param: frame — message RAM; chỉ so khớp exact BEGIN/COMMIT, không lưu query khác.
        Param: ready_state — trạng thái Z cuối cùng từ đúng connection đó.
        Param: now — monotonic timestamp kiểm arm deadline trước claim.
        Output: True khi worker vừa claim COMMIT và phải suppress downstream trước forward.
        """
        with self.lock:
            self.expire(now)
            if not self.active or frame[:1] != b'Q':
                return False
            if frame[5:] == b'BEGIN\0':
                self.begins += 1
                self.begun_connection = connection if self.begins == 1 else None
            if frame[5:] != b'COMMIT\0':
                return False
            self.commits += 1
            if self.phase != 'ARMED' or self.begins != 1 or connection != self.begun_connection or ready_state != b'T':
                self.phase = 'FAILED'
                return False
            self.selected = connection
            self.phase = 'CAPTURING'
            return True

    def suppresses(self, connection):
        """Kiểm gate dưới cùng lock trước forward response, không mở lại khi capture lỗi.

        Input
        Param: connection — identity worker đang định gửi bytes về SQLx.
        Output: True chỉ cho connection target trong window còn active.
        """
        with self.lock:
            return self.active and self.selected == connection

    def backend(self, connection, frame, now):
        """Chỉ C(COMMIT) rồi Z(I) của target mới xác nhận; caller phải đóng socket ngay.

        Input
        Param: connection — worker đã claim, ID mới không tái dùng giữa các arm.
        Param: frame — typed message từ PostgreSQL, không log payload.
        Param: now — monotonic timestamp tại lúc xử lý frame, không dùng thời gian poll cũ.
        Output: True khi phải đóng cả2socket; confirmed và failed vẫn phân biệt qua finish.
        """
        with self.lock:
            if not self.active or self.selected != connection:
                return False
            if self.expire(now):
                return True
            if frame[:1] == b'E':
                self.phase = 'FAILED'
                return True
            if frame[:1] == b'C':
                if frame[5:] != b'COMMIT\0' or self.commit_tag:
                    self.phase = 'FAILED'
                    return True
                self.commit_tag = True
            if frame[:1] == b'Z':
                self.phase = 'CONFIRMED' if self.commit_tag and frame[5:] == b'I' and self.phase == 'CAPTURING' else 'FAILED'
                return True
            return False

    def expire(self, now):
        """Deadline chỉ làm FAIL, không biến thiếu ACK thành bằng chứng COMMIT đã áp.

        Input
        Param: now — monotonic timestamp hiện tại của worker.
        Output: True nếu arm pending đã hết thời gian, worker phải đóng socket sở hữu.
        """
        with self.lock:
            if self.active and self.phase == 'FAILED':
                return True  # Mọi worker còn lại cũng phải đóng, không để target treo sau worker khác báo timeout.
            if self.active and self.phase in ('ARMED', 'CAPTURING') and now >= self.deadline:
                self.phase = 'FAILED'
                return True
            return False

    def cancel(self):
        """Hủy arm khi request/shutdown lỗi; không chuyển trạng thái FAILED thành success."""
        with self.lock:
            if self.active:
                self.phase = 'FAILED'

    def connection_closed(self, connection):
        """EOF trước đủ ACK là failure; close sau confirmed không được xóa evidence thành công.

        Input
        Param: connection — worker đang thu hồi socket riêng, ID không tái dùng.
        """
        with self.lock:
            if self.active and self.selected == connection and self.phase == 'CAPTURING':
                self.phase = 'FAILED'

    def finish(self, generation):
        """Đóng window và xuất metadata nếu đã cắt ACK xác nhận đúng một transaction.

        Input
        Param: generation — generation caller đã nhận từ arm, không chấp nhận callback cũ.
        Output: confirmed/begins/commits không có identity hoặc credential.
        Errors: no-fire/error/timeout/replay đều fail fixed diagnostic, không in payload.
        """
        with self.lock:
            if generation != self.generation or not self.active:
                raise RuntimeError('Commit ACK generation mismatch')
            valid = self.phase == 'CONFIRMED' and self.begins == self.commits == 1
            result = {'confirmed': valid, 'begins': self.begins, 'commits': self.commits}
            self.active = False
            self.selected = None
            if not valid:
                raise RuntimeError('Commit ACK injection not confirmed')
            return result


def close_socket(connection):
    """Đóng socket sở hữu để unblock recv/select khi hủy hoặc shutdown, không kill process/PG backend.

    Input
    Param: connection — socket thuộc proxy, có thể đã đóng bởi worker khác.
    """
    try:
        connection.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass  # Socket đã đóng là trạng thái bình thường khi worker và coordinator cùng thu hồi.
    connection.close()


def receive_exact(connection, size, deadline):
    """Đọc startup có completion deadline tuyệt đối, không cho byte nhỏ giọt kéo dài thời gian.

    Input
    Param: connection — socket loopback thuộc proxy, không đọc file/pipe hoặc environment.
    Param: size — số byte startup đã kiểm có cận10000.
    Param: deadline — monotonic hạn chung cho toàn negotiation/startup.
    Output: đủ byte hoặc lỗi cố định khi EOF/timeout, không in packet.
    """
    result = bytearray()
    while len(result) < size:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('PG startup completion expired')
        connection.settimeout(remaining)
        chunk = connection.recv(size - len(result))
        if not chunk:
            raise ConnectionError('PG startup incomplete')
        result.extend(chunk)
    return bytes(result)


def send_before_deadline(connection, data, deadline):
    """Giới hạn cả send startup bằng cùng completion deadline, không chỉ giới hạn recv.

    Input
    Param: connection — socket sở hữu trong negotiation loopback.
    Param: data — packet RAM đã kiểm size, không log hoặc lưu.
    Param: deadline — monotonic hạn chung, không gia hạn sau mỗi bước.
    """
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError('PG startup completion expired')
    connection.settimeout(remaining)
    connection.sendall(data)


def relay_startup(client, upstream):
    """Giữ SCRAM và exact role/DB của InspectionServer, chỉ relay negotiation bị từ chối TLS/GSS.

    Input
    Param: client — SQLx socket tới proxy lab.
    Param: upstream — socket tới InspectionServer do cùng launcher tạo, không target ngoài.
    Errors: principal/options/size/negotiation lạ hoặc timeout đóng kết nối, không fallback trust.
    """
    from local_db_bridge import validated_startup
    deadline = time.monotonic() + STARTUP_TIMEOUT
    for _ in range(3):
        length_bytes = receive_exact(client, 4, deadline)
        length = struct.unpack('!I', length_bytes)[0]
        if not 8 <= length <= 10000:
            raise ValueError('Invalid lab startup length')
        packet = length_bytes + receive_exact(client, length - 4, deadline)
        protocol = struct.unpack('!I', packet[4:8])[0]
        if length == 8 and protocol in (80877103, 80877104):
            send_before_deadline(upstream, packet, deadline)
            answer = receive_exact(upstream, 1, deadline)
            if answer != b'N':
                raise ValueError('Unexpected lab encryption response')
            send_before_deadline(client, answer, deadline)
            continue
        validated_startup(packet, user='iot_repository_probe', read_only=False)
        send_before_deadline(upstream, packet, deadline)
        client.settimeout(FRAME_TIMEOUT)
        upstream.settimeout(FRAME_TIMEOUT)
        return
    raise ValueError('Repeated lab encryption negotiation')


class CommitAckServer(socketserver.TCPServer):
    """Proxy verify-only, mỗi connection một event loop; gate luôn đặt trước send trong cùng worker."""

    allow_reuse_address = False

    def __init__(self, upstream_port):
        """Chỉ bind loopback ephemeral tới gateway của launcher, không có API arm từ HTTP.

        Input
        Param: upstream_port — cổng InspectionServer cùng run, không nhận hostname hoặc URL ngoài.
        """
        super().__init__(('127.0.0.1', 0), None)
        self.upstream_port = upstream_port
        self.gate = CommitGate()
        self.registry_lock = threading.Lock()
        self.sockets = set()
        self.workers = []
        self.stopping = threading.Event()
        self.next_connection = 0
        self.thread = None

    def start(self):
        """Chạy accept loop sở hữu; stop luôn join loop và workers trước DB cleanup."""
        self.thread = threading.Thread(target=self.serve_forever, kwargs={'poll_interval': .1}, daemon=True)
        self.thread.start()

    def process_request(self, request, client_address):
        """Đăng ký socket/worker trước start để shutdown không bỏ sót thread vừa accept.

        Input
        Param: request — socket đã accept từ SQLx loopback.
        Param: client_address — metadata bắt buộc của TCPServer, không log hoặc dùng cấp quyền.
        """
        with self.registry_lock:
            self.next_connection += 1
            identity = self.next_connection
            self.sockets.add(request)
            worker = threading.Thread(target=self.relay, args=(identity, request), daemon=True)
            self.workers.append(worker)
            worker.start()

    def relay(self, identity, client):
        """Relay typed frame bằng select trên socket; không có downstream thread chạy vượt gate.

        Input
        Param: identity — số worker tăng đơn điệu trong run, không tái dùng giữa arm.
        Param: client — SQLx socket đã được đăng ký ownership trước thread start.
        Side effects: đóng target ngay sau C(COMMIT)+Z(I), không phát ACK bị suppress.
        """
        upstream = None
        try:
            upstream = socket.create_connection(('127.0.0.1', self.upstream_port), timeout=2)
            with self.registry_lock:
                self.sockets.add(upstream)
            relay_startup(client, upstream)
            readers = {client: FrameReader(), upstream: FrameReader()}
            ready_state = None
            while not self.stopping.is_set():
                now = time.monotonic()
                if self.gate.expire(now):
                    return
                for reader in readers.values():
                    reader.feed(b'', now)
                readable, _, _ = select.select([client, upstream], [], [], .1)
                for source in readable:
                    chunk = source.recv(65536)
                    if not chunk:
                        return
                    for frame in readers[source].feed(chunk, time.monotonic()):
                        if source is client:
                            # Cùng event loop: không xử lý downstream giữa claim/gate và send COMMIT.
                            self.gate.frontend(identity, frame, ready_state, time.monotonic())
                            upstream.sendall(frame)
                        else:
                            if self.gate.suppresses(identity):
                                if self.gate.backend(identity, frame, time.monotonic()):
                                    return  # finally đóng cả2socket ngay, successful path không đợi timeout.
                            else:
                                if frame[:1] == b'Z':
                                    ready_state = frame[5:]
                                client.sendall(frame)
        except (OSError, ValueError, ConnectionError, TimeoutError):
            pass  # Không phản chiếu exception có thể chứa packet; caller kiểm marker/count hoặc fixed failure.
        finally:
            self.gate.connection_closed(identity)
            for connection in (client, upstream):
                if connection is not None:
                    close_socket(connection)
                    with self.registry_lock:
                        self.sockets.discard(connection)

    def stop(self):
        """Thu hồi active sockets và join từng worker có deadline, không dựa daemon hoặc listener close.

        Errors: worker/accept loop còn sống thì giữ journal, không cho fixture cleanup dưới connection sống.
        """
        self.stopping.set()
        self.gate.cancel()
        if self.thread is not None:
            self.shutdown()
        self.server_close()
        with self.registry_lock:
            connections = list(self.sockets)
            workers = list(self.workers)
        for connection in connections:
            close_socket(connection)
        deadline = time.monotonic() + SHUTDOWN_TIMEOUT
        for worker in workers:
            worker.join(max(0, deadline - time.monotonic()))
        if self.thread is not None:
            self.thread.join(max(0, deadline - time.monotonic()))
        if any(worker.is_alive() for worker in workers) or (self.thread is not None and self.thread.is_alive()):
            raise RuntimeError('Commit ACK proxy shutdown unverified')
