"""Thu process output của đúng child auth lab và giữ credential canary chỉ trong RAM."""

from contextlib import contextmanager
import json
import re
import threading

MAX_OUTPUT_BYTES = 1_048_576
READ_CHUNK_BYTES = 8192
READ_JOIN_SECONDS = 10
MAX_CANARIES = 512
MAX_CANARY_BYTES = 65_536
READY_MARKER = b'AUTH_LAB_READY\n'
SENSITIVE_NAMES = {'email', 'password', 'currentpassword', 'newpassword',
                   'confirmpassword', 'token', 'accesstoken', 'refreshtoken'}
SENSITIVE_HEADERS = {'authorization', 'cookie', 'set-cookie', 'x-csrf-token'}


class CredentialCanaries:
    """Giữ bounded canary từ đúng request/response HTTP của child fixture trong bộ nhớ.

    Input
    Param: ports — hai listener loopback của primary và peer do launcher sở hữu.
    Param: values — credential/email tổng hợp đã biết trước lúc phát request.
    Output: context manager đăng ký observer trên request helper và values() trả snapshot bất biến.
    Errors: port/capacity/input không hợp lệ làm dừng kiểm thử, không bỏ canary để tạo PASS giả.
    Side effects: giữ giá trị nhạy cảm trong RAM tới hết scan; không ghi file hoặc log.
    """

    def __init__(self, ports, values):
        """Chốt hai cổng backend và canary ban đầu trước khi bắt đầu phát request.

        Input
        Param: ports — tuple đúng hai listener primary/peer do launcher chọn.
        Param: values — password/email fixture cần dò ngay cả khi response không phản chiếu lại.
        Errors: cổng hoặc canary vượt cận làm dừng trước khi có thể báo scan sạch.
        Side effects: khởi tạo registry RAM có khóa cho request đồng thời.
        """
        if (type(ports) is not tuple or len(ports) != 2
                or any(type(port) is not int or not 1024 <= port <= 65535 for port in ports)
                or len(set(ports)) != 2):
            raise RuntimeError('Credential observer ports invalid')
        self._ports = frozenset(ports)
        self._values = []
        self._total_bytes = 0
        self._lock = threading.Lock()
        for value in values:
            self._add(value)

    def _add(self, value):
        """Thêm giá trị canary duy nhất khi giới hạn số lượng và byte của toàn fixture còn hợp lệ.

        Input
        Param: value — chuỗi credential/email quan sát trực tiếp, chỉ dùng để dò bytes.
        Errors: giá trị rỗng/quá dài hoặc vượt cận làm fail closed trước scan.
        Side effects: cập nhật registry RAM có khóa vì nhiều HTTP worker có thể hoàn tất đồng thời.
        """
        if type(value) is not str:
            raise RuntimeError('Credential canary value invalid')
        if len(value.encode('utf-8')) < 8:
            return
        if len(value.encode('utf-8')) > 4096:
            raise RuntimeError('Credential canary value invalid')
        with self._lock:
            if value in self._values:
                return
            size = len(value.encode('utf-8'))
            if len(self._values) >= MAX_CANARIES or self._total_bytes + size > MAX_CANARY_BYTES:
                raise RuntimeError('Credential canary budget exceeded')
            self._values.append(value)
            self._total_bytes += size

    def _collect_json(self, value, key=''):
        """Thu value dưới field nhạy cảm đã allowlist và token/email response mà không giữ toàn body.

        Input
        Param: value — JSON decoded hoặc node lồng trong payload đang xử lý trong RAM.
        Param: key — tên thuộc tính hiện hành để chỉ thu trường credential đã định trước.
        """
        if isinstance(value, dict):
            for name, child in value.items():
                normalized = re.sub(r'[^a-z]', '', str(name).lower())
                if normalized in SENSITIVE_NAMES and isinstance(child, str):
                    self._add(child)
                elif isinstance(child, (dict, list)):
                    self._collect_json(child, normalized)
        elif isinstance(value, list):
            for child in value:
                if isinstance(child, (dict, list)):
                    self._collect_json(child, key)

    def observe(self, port, body, request_headers, response_headers, response_body):
        """Nhận credential hai chiều đúng listener; port lạ hoặc JSON/headers hỏng không được âm thầm bỏ qua.

        Input
        Param: port — cổng loopback lấy từ request helper đang phát, không từ dữ liệu body.
        Param: body — JSON request đã parse bởi helper, không được serialize vào report.
        Param: request_headers — header request đang ở RAM, gồm bearer/cookie/CSRF nếu có.
        Param: response_headers — cặp header trả về từ server trước khi đóng response.
        Param: response_body — bytes response đã giới hạn bởi request helper.
        Side effects: bổ sung canary field trong registry RAM để scan output sau khi child dừng.
        """
        if type(port) is not int or port not in self._ports or type(response_body) is not bytes:
            raise RuntimeError('Credential observer port mismatch')
        self._collect_json(body)
        for headers in (request_headers, response_headers):
            if headers is None:
                continue
            items = headers.items() if isinstance(headers, dict) else headers
            for name, value in items:
                header_name = str(name).lower()
                if header_name not in SENSITIVE_HEADERS:
                    continue
                values = value if isinstance(value, (tuple, list)) else (value,)
                for item in values:
                    if not isinstance(item, str):
                        continue
                    # Giữ header auth nguyên văn để bắt cả log đã đổi thứ tự field, rồi lấy token riêng khi có cấu trúc chuẩn.
                    self._add(item)
                    if header_name == 'authorization' and item.lower().startswith('bearer '):
                        self._add(item[7:])
                    elif header_name in ('cookie', 'set-cookie'):
                        parts = item.split(';') if header_name == 'cookie' else item.split(';', 1)[:1]
                        for part in parts:
                            if '=' in part:
                                self._add(part.split('=', 1)[1].strip())
        if response_body:
            try:
                self._collect_json(json.loads(response_body))
            except (ValueError, UnicodeDecodeError):
                # Body lỗi không phải JSON vẫn được scan nguyên dạng bytes trong hai pipe backend.
                pass

    @contextmanager
    def observe_requests(self):
        """Đăng ký observer cho request helper trong suốt lượt verify và khôi phục observer trước đó.

        Side effects: chỉ thay observer module-local; helper không log body/header và worker dùng cùng lock.
        """
        import verify_provider

        previous = verify_provider.credential_observer
        verify_provider.credential_observer = self
        try:
            yield
        finally:
            verify_provider.credential_observer = previous

    def values(self):
        """Trả snapshot tuple nhất quán cho scanner, không xuất nội dung hoặc mutable registry.

        Output
        Tuple canary giữ trong RAM; caller không được serialize giá trị trả về.
        """
        with self._lock:
            return tuple(self._values)

    def clear(self):
        """Bỏ mọi tham chiếu canary sau khi scan xong để thu hẹp thời gian tồn tại trong RAM.

        Side effects: xóa danh sách và bộ đếm dưới cùng khóa dùng bởi observer.
        """
        with self._lock:
            self._values.clear()
            self._total_bytes = 0


class BackendOutputCapture:
    """Drain stdout/stderr từ lúc khởi chạy để giữ readiness và log muộn của cùng process.

    Input
    Param: process — handle Popen chính xác của child backend, không nhận PID hoặc stream ngoài.
    Param: sink — literal primary/peer để report không chứa đường dẫn process.
    Output: ready Event và finish() trả scan enum/count sau EOF thật.
    Errors: capture trống, overflow, reader lỗi, process còn sống hoặc owner sai đều fail closed.
    Side effects: đọc cả hai pipe liên tục; giữ tối đa1MiB mỗi stream, tiếp tục drain khi vượt cận.
    """

    def __init__(self, process, sink):
        """Gắn duy nhất hai output pipe vào handle child và nhãn primary/peer cố định.

        Input
        Param: process — handle Popen duy nhất có cả stdout/stderr được launcher sở hữu.
        Param: sink — nhãn tĩnh primary hoặc peer để evidence không lộ đường dẫn.
        Errors: thiếu pipe hoặc nhãn khác allowlist bị từ chối trước khi tạo reader.
        """
        if (sink not in ('primary', 'peer') or process is None
                or not hasattr(process, 'stdout') or not hasattr(process, 'stderr')
                or process.stdout is None or process.stderr is None):
            raise RuntimeError('Backend output owner invalid')
        self.process = process
        self.sink = sink
        self.ready = threading.Event()
        self._lock = threading.Lock()
        self._buffers = {'backend_stdout': bytearray(), 'backend_stderr': bytearray()}
        self._sizes = {'backend_stdout': 0, 'backend_stderr': 0}
        self._eof = {'backend_stdout': threading.Event(), 'backend_stderr': threading.Event()}
        self._overflow = False
        self._read_error = False
        self._threads = []
        self._started = False
        self._ready_tail = b''

    def start(self):
        """Khởi động hai reader ngay sau Popen để child không kẹt pipe và không mất dòng READY.

        Errors: gọi nhiều lần bị từ chối để giữ một owner cho mỗi stream.
        """
        if self._started:
            raise RuntimeError('Backend output capture already started')
        self._started = True
        for name, stream in (('backend_stdout', self.process.stdout), ('backend_stderr', self.process.stderr)):
            thread = threading.Thread(target=self._drain, args=(name, stream), daemon=True)
            thread.start()
            self._threads.append(thread)

    def _drain(self, name, stream):
        """Đọc bounded chunks tới EOF; khi buffer đầy vẫn drain để backend có thể kết thúc bình thường.

        Input
        Param: name — chỉ backend_stdout hoặc backend_stderr do constructor cấp.
        Param: stream — đúng pipe thuộc Popen handle đã kiểm tra ở constructor.
        Side effects: chỉ giữ prefix trong RAM, đánh dấu overflow/error và giải phóng EOF event.
        """
        try:
            # BufferedReader.read1 trả bytes đang có ngay; TextIOWrapper.read có thể chờ đủ cả chunk.
            source = getattr(stream, 'buffer', stream)
            read_chunk = getattr(source, 'read1', source.read)
            while True:
                chunk = read_chunk(READ_CHUNK_BYTES)
                if not chunk:
                    break
                data = chunk.encode('utf-8') if isinstance(chunk, str) else bytes(chunk)
                with self._lock:
                    self._sizes[name] += len(data)
                    remaining = MAX_OUTPUT_BYTES - len(self._buffers[name])
                    if len(data) > remaining:
                        self._overflow = True
                    if remaining > 0:
                        self._buffers[name].extend(data[:remaining])
                    if name == 'backend_stdout':
                        probe = self._ready_tail + data
                        if READY_MARKER in probe or b'AUTH_LAB_READY\r\n' in probe:
                            self.ready.set()
                        self._ready_tail = probe[-len(READY_MARKER):]
        except Exception:
            with self._lock:
                self._read_error = True
        finally:
            self._eof[name].set()

    def finish(self, process, canaries):
        """Scan exact process pipes only after process terminal and both original readers observed EOF.

        Input
        Param: process — cùng object Popen đã gắn khi tạo capture.
        Param: canaries — tuple credential/email quan sát từ chính request helper của run.
        Output: hai stream scan và structured event chỉ PASS khi event xuất hiện trên stream sạch.
        Errors: process/EOF/capacity/stream thiếu không thể được báo là PASS.
        Side effects: chuyển buffer scan thành bytes trong RAM rồi xóa buffer sau khi có verdict.
        """
        if process is not self.process:
            raise RuntimeError('Backend output owner mismatch')
        if process.poll() is None:
            raise RuntimeError('Backend output process still active')
        if not self._started:
            raise RuntimeError('Backend output capture not started')
        for thread in self._threads:
            thread.join(READ_JOIN_SECONDS)
        if (any(thread.is_alive() for thread in self._threads)
                or not all(event.is_set() for event in self._eof.values())):
            raise RuntimeError('Backend output capture incomplete')
        for stream in (process.stdout, process.stderr):
            stream.close()
        from verify_security_evidence import scan_sink

        with self._lock:
            if self._overflow or self._read_error:
                raise RuntimeError('Backend output capture incomplete')
            data = {name: bytes(value) for name, value in self._buffers.items()}
            sizes = dict(self._sizes)
        scans = []
        for name in ('backend_stdout', 'backend_stderr'):
            stream_scans = [scan_sink(name, data[name], tuple(canaries[index:index + 64]))
                            for index in range(0, len(canaries), 64)]
            if not stream_scans:
                stream_scans = [scan_sink(name, data[name], ())]
            canary_matches = sum(item['canaryMatches'] for item in stream_scans)
            named_matches = stream_scans[0]['namedFieldMatches']
            scans.append({'sink': name, 'status': ('FAIL' if canary_matches or named_matches else
                                                    'PASS' if data[name] else 'NOT_RUN'),
                          'byteCount': sizes[name], 'canaryCount': len(canaries),
                          'canaryMatches': canary_matches, 'namedFieldMatches': named_matches})
        event_count = self._structured_event_count(data.values())
        structured_status = ('FAIL' if any(item['status'] == 'FAIL' for item in scans) else
                             'PASS' if event_count else 'NOT_RUN')
        with self._lock:
            for value in self._buffers.values():
                value.clear()
        return {'process': self.sink, 'streams': scans,
                'structuredLog': {'status': structured_status, 'eventCount': event_count}}

    @staticmethod
    def _structured_event_count(streams):
        """Đếm event JSON có tên sự kiện/correlation/outcome, không coi marker plain READY là structured log.

        Input
        Param: streams — bytes của stdout/stderr đã giới hạn trong RAM.
        Output: số event hợp schema tối thiểu, không giữ message hoặc field value.
        """
        count = 0
        for payload in streams:
            for line in payload.splitlines():
                try:
                    value = json.loads(line)
                except (ValueError, UnicodeDecodeError):
                    continue
                if (type(value) is dict and isinstance(value.get('event'), str)
                        and isinstance(value.get('correlationId'), str)
                        and isinstance(value.get('outcome'), str)):
                    count += 1
        return count
