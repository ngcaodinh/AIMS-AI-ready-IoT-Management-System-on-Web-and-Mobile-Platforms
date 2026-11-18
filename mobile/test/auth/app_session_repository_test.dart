import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../../lib/features/auth/data/app_auth_api.dart';
import '../../lib/features/auth/data/app_auth_failure.dart';
import '../../lib/features/auth/data/app_login_response.dart';
import '../../lib/features/auth/data/app_session_repository.dart';
import '../../lib/features/auth/data/app_session_state.dart';
import '../../lib/features/auth/data/full_session_profile.dart';
import '../../lib/features/auth/data/session_token_store.dart';

const sessionToken = 'synthetic_session_A';
const alternateToken = 'synthetic_session_B';
const sessionEmail = 'first@example.invalid';
const alternateEmail = 'second@example.invalid';
const sessionIdentity = '11111111-1111-4111-8111-111111111111';
const alternateIdentity = '22222222-2222-4222-8222-222222222222';
const privatePassword = 'synthetic-private-password';
final initialTime = DateTime.utc(2026, 10, 26);

/// Tạo DTO login đã qua parser; test repository không thay provider/network hoặc storage thật.
/// Input
/// Param: limited — scope password-only của candidate.
/// Param: email — identity email cần đối chiếu với input theo ASCII normalization.
/// Param: expiry — thời điểm hết hạn có thể trôi qua khi chờ storage ACK.
/// Output: candidate token tổng hợp chỉ nằm trong RAM fake API/store.
AppLoginResponse issuedSession({
  bool limited = false,
  String email = sessionEmail,
  DateTime? expiry,
}) => AppLoginResponse.fromJson({
  'me': {'id': sessionIdentity, 'email': email, 'mustChangePassword': limited},
  'limited': limited,
  'token': sessionToken,
  'expiresAt': (expiry ?? initialTime.add(const Duration(hours: 1)))
      .toIso8601String(),
});

/// Tạo profile full scalar, cho phép mismatch độc lập id/email để kiểm admission.
/// Input
/// Param: id — identity server trả về để kiểm binding với DTO cùng intent.
/// Param: email — email server trả về; không dùng sửa input hoặc credential.
/// Output: DTO profile không chứa bearer/password.
FullSessionProfile serverProfile({
  String id = sessionIdentity,
  String email = sessionEmail,
}) => FullSessionProfile.fromJson({
  'id': id,
  'email': email,
  'mustChangePassword': false,
  'displayTimezone': 'UTC',
  'preferencesRevision': 1,
});

/// API fake giữ source Future thật để suspend/dispose không được giả đã hủy I/O cũ.
final class SessionApiFake implements AppAuthApi {
  /// Dùng chung event ledger với store để chứng minh ACK và network order.
  /// Input
  /// Param: events — ledger riêng fixture để kiểm thứ tự side effect giữa hai boundary.
  SessionApiFake(this.events);
  final List<String> events;
  AppLoginResponse result = issuedSession();
  FullSessionProfile profileResult = serverProfile();
  AppAuthFailure? loginFailure;
  AppAuthFailure? profileFailure;
  AppAuthFailure? logoutFailure;
  Completer<AppLoginResponse>? loginGate;
  Completer<FullSessionProfile>? profileGate;
  Completer<void>? logoutGate;
  final loginInputs = <(String, String)>[];
  final profileTokens = <String>[];
  final logoutTokens = <String>[];

  /// Ghi đúng một input gốc, không normalize hoặc replay ở fake.
  /// Input
  /// Param: email — input nguyên bản cần được giữ khi gửi một login intent.
  /// Param: password — credential tổng hợp, chỉ ghi trong fake để phát hiện queue/replay.
  /// Output: candidate DTO hoặc source Future đang chờ; lỗi typed do test chọn.
  @override
  Future<AppLoginResponse> login(String email, String password) async {
    loginInputs.add((email, password));
    events.add('api.login');
    if (loginGate != null) return loginGate!.future;
    if (loginFailure != null) throw loginFailure!;
    return result;
  }

  /// Chỉ profile của bearer được truyền, không tự đổi sang account khác từ store.
  /// Input
  /// Param: token — bearer cụ thể repository đang sở hữu cho lần kiểm server.
  /// Output: profile DTO hoặc source Future chưa ACK; có thể phát lỗi typed đã định.
  @override
  Future<FullSessionProfile> getProfile(String token) async {
    profileTokens.add(token);
    events.add('api.profile');
    if (profileGate != null) return profileGate!.future;
    if (profileFailure != null) throw profileFailure!;
    return profileResult;
  }

  /// Revoke chỉ token cụ thể trong RAM; gate không tự complete khi repository dispose.
  /// Input
  /// Param: token — candidate/stable bearer được revoke, không đọc thay bằng key trong store.
  /// Side effects: ledger ghi một lần gọi; completion chỉ sau gate và lỗi typed của test.
  @override
  Future<void> logout(String token) async {
    logoutTokens.add(token);
    events.add('api.logout');
    await logoutGate?.future;
    if (logoutFailure != null) throw logoutFailure!;
  }
}

/// Store fake tách side effect khỏi ACK để lost write/delete không bị giả thành rollback.
final class SessionStoreFake implements SessionTokenStore {
  /// Nhận event ledger của chính repository fixture, không truy cập plugin/channel.
  /// Input
  /// Param: events — ledger in-memory dùng chứng minh clear/write/delete ACK order.
  SessionStoreFake(this.events);
  final List<String> events;
  StoredSessionCredential? storedSession;
  PendingLogoutIntent? logoutIntent;

  /// Đọc active token trong fake fixture để assertion không lộ vào repository API.
  String? get value => storedSession?.token;

  /// Gán fixture phiên giả với expiry đã biết, tránh metadata tùy ý trong test.
  /// Input
  /// Param: token — bearer tổng hợp hoặc null để giả lập active key vắng.
  set value(String? token) {
    storedSession = token == null
        ? null
        : StoredSessionCredential(
            token: token,
            expiresAt: initialTime.add(const Duration(hours: 1)),
          );
  }

  bool failRead = false;
  bool failWrite = false;
  bool failDelete = false;
  bool failOutboxWrite = false;
  int? failOutboxWriteAtCall;
  bool writeOutboxBeforeFailure = false;
  bool failOutboxDelete = false;
  bool deleteOutboxBeforeFailure = false;
  bool writeBeforeAck = false;
  Completer<void>? writeGate;
  Completer<void>? deleteGate;
  Completer<void>? outboxWriteGate;
  int reads = 0;
  int deletes = 0;
  int outboxWrites = 0;
  int outboxDeletes = 0;
  final writtenTokens = <String>[];

  /// Read error khác null thật; value không là bằng chứng session đã được admission.
  /// Output: key trong RAM hoặc null thật; lỗi read vẫn được phát riêng.
  @override
  Future<StoredSessionCredential?> readSession() async {
    reads++;
    events.add('store.read');
    if (failRead)
      throw const SessionStorageException(SessionStorageOperation.read);
    return storedSession;
  }

  /// Side effect phiên có thể xảy ra trước gate/error; repository giữ ownership tới ACK.
  /// Input
  /// Param: session — candidate bearer và expiry của intent hiện tại.
  /// Errors: lỗi write có thể phát sau khi value đã đổi; không rollback giả trong fake.
  @override
  Future<void> writeSession(StoredSessionCredential session) async {
    writtenTokens.add(session.token);
    events.add('store.write.begin');
    if (writeBeforeAck) storedSession = session;
    await writeGate?.future;
    if (failWrite)
      throw const SessionStorageException(SessionStorageOperation.write);
    storedSession = session;
    events.add('store.write.ack');
  }

  /// Chỉ ACK mới chứng minh own auth key đã clear; failure giữ nguyên value để bắt quarantine bypass.
  /// Errors: lỗi delete giữ key và không ghi ACK; gate cho phép kiểm ownership khi chờ.
  @override
  Future<void> deleteSession() async {
    deletes++;
    events.add('store.delete.begin');
    await deleteGate?.future;
    if (failDelete)
      throw const SessionStorageException(SessionStorageOperation.delete);
    storedSession = null;
    events.add('store.delete.ack');
  }

  /// Đọc tombstone riêng để test startup luôn ưu tiên phiên đang được thu hồi.
  /// Output: intent fake hiện hành; lỗi đọc dùng chung boundary storage.
  @override
  Future<PendingLogoutIntent?> readLogoutIntent() async {
    events.add('store.outbox.read');
    if (failRead) {
      throw const SessionStorageException(SessionStorageOperation.read);
    }
    return logoutIntent;
  }

  /// Ghi revoke record với ACK riêng, cho phép test chứng minh thứ tự trước active delete.
  /// Input
  /// Param: intent — bearer/expiry/retry state synthetic của một session cụ thể.
  @override
  Future<void> writeLogoutIntent(PendingLogoutIntent intent) async {
    outboxWrites++;
    events.add('store.outbox.write.begin');
    await outboxWriteGate?.future;
    // Có thể nhắm lỗi vào lần ghi quota/deadline để test ACK trước POST.
    final shouldFail =
        failOutboxWrite &&
        (failOutboxWriteAtCall == null ||
            outboxWrites == failOutboxWriteAtCall);
    if (shouldFail && writeOutboxBeforeFailure) logoutIntent = intent;
    if (shouldFail) {
      throw const SessionStorageException(SessionStorageOperation.write);
    }
    logoutIntent = intent;
    events.add('store.outbox.write.ack');
  }

  /// Xóa tombstone chỉ khi repository đã nhận terminal response và cleanup ACK.
  /// Errors: fake failure giữ record để startup có thể retry.
  @override
  Future<void> deleteLogoutIntent() async {
    outboxDeletes++;
    events.add('store.outbox.delete.begin');
    if (deleteOutboxBeforeFailure) logoutIntent = null;
    if (failOutboxDelete) {
      throw const SessionStorageException(SessionStorageOperation.delete);
    }
    logoutIntent = null;
    events.add('store.outbox.delete.ack');
  }
}

/// Fixture sở hữu clock/API/store/repository riêng, không dependency injection toàn cục.
final class SessionHarness {
  /// Dựng một repository duy nhất cho một store trong suốt lifetime của mỗi test.
  SessionHarness() {
    api = SessionApiFake(events);
    store = SessionStoreFake(events);
    timers = SessionTimerScheduler(now);
    repository = AppSessionRepository(
      api: api,
      tokenStore: store,
      now: now,
      retryTimerFactory: timers.create,
    );
  }
  final events = <String>[];
  DateTime clock = initialTime;
  late final SessionApiFake api;
  late final SessionStoreFake store;
  late final SessionTimerScheduler timers;
  late final AppSessionRepository repository;

  /// Cấp thời gian UTC điều khiển được để expiry không phụ thuộc đồng hồ máy.
  /// Output: thời gian UTC hiện tại riêng fixture, có thể tiến trong khi Future pending.
  DateTime now() => clock;

  /// Chỉ login sau restore null đã xác nhận signedOut, đúng public API contract.
  Future<void> ready() async {
    await repository.restore();
    expect(repository.state.phase, AppSessionPhase.signedOut);
  }
}

/// Drain microtask/event callbacks mà không dùng sleep dài hoặc timeout để thả ownership giả.
Future<void> settleSession() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

/// Timer giả chỉ chạy khi test tiến clock tới deadline, không chờ wall-clock hoặc native event loop.
final class SessionTimerFake implements Timer {
  /// Gắn deadline và callback retry của một lần hẹn duy nhất.
  /// Input
  /// Param: dueAt — thời điểm UTC scheduler cho phép callback chạy.
  /// Param: callback — worker repository đã sở hữu retry hiện hành.
  SessionTimerFake(this.dueAt, this._callback);

  final DateTime dueAt;
  final void Function() _callback;
  bool _active = true;

  /// Output: true khi timer chưa bị hủy hoặc kích hoạt.
  @override
  bool get isActive => _active;

  /// Output: tick không dùng trong test; deadline được kiểm qua clock fixture.
  @override
  int get tick => 0;

  /// Hủy timer giống lifecycle suspend/dispose của Timer nền tảng.
  @override
  void cancel() {
    _active = false;
  }

  /// Kích hoạt một lần để callback repository nạp lại outbox bền vững.
  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }
}

/// Scheduler deterministic cho retry jitter và quota; không khởi chạy timer thật trong test.
final class SessionTimerScheduler {
  /// Nhận clock của fixture để deadline không phụ thuộc đồng hồ host.
  /// Input
  /// Param: now — giờ UTC do test điều khiển.
  SessionTimerScheduler(this.now);
  final DateTime Function() now;
  final timers = <SessionTimerFake>[];

  /// Tạo timer có deadline xác định từ delay mà repository đã persist.
  /// Input
  /// Param: duration — khoảng chờ backoff/Retry-After.
  /// Param: callback — worker retry cần chạy khi clock đến hạn.
  /// Output: timer có thể cancel như Timer thật.
  Timer create(Duration duration, void Function() callback) {
    final timer = SessionTimerFake(now().add(duration), callback);
    timers.add(timer);
    return timer;
  }

  /// Chạy mọi callback đã đến hạn, giữ nguyên các timer tương lai hoặc đã hủy.
  void fireDue() {
    for (final timer in timers.toList()) {
      if (timer.isActive && !timer.dueAt.isAfter(now())) timer.fire();
    }
  }

  /// Output: số timer còn active để kiểm quota dừng retry tự động.
  int get activeCount {
    var count = 0;
    for (final timer in timers) {
      if (timer.isActive) count++;
    }
    return count;
  }
}

/// Các phase locked không được mang full profile hoặc lộ candidate/password qua state.
/// Input
/// Param: repository — instance đang kiểm admission; chỉ quan sát public state.
void expectLocked(AppSessionRepository repository) {
  expect(
    repository.state.phase,
    isNot(anyOf(AppSessionPhase.full, AppSessionPhase.limited)),
  );
  expect(repository.state.profile, isNull);
  expect(repository.state.toString().contains(sessionToken), isFalse);
  expect(repository.state.toString().contains(privatePassword), isFalse);
}

/// Initial checking chỉ sang signedOut khi null thật; stream broadcast không tự gọi API.
Future<void> checkInitialRestore() async {
  final harness = SessionHarness();
  expect(harness.repository.state.phase, AppSessionPhase.checking);
  expect(harness.repository.changes.isBroadcast, isTrue);
  await harness.ready();
  expect(harness.store.reads, 1);
  expect(harness.api.profileTokens, isEmpty);
  expect(harness.repository.busy, isFalse);
  await harness.repository.dispose();
}

/// Full admission phải chờ clear ACK, write ACK rồi profile identity khớp; input/password giữ nguyên.
Future<void> checkFullAdmissionOrder() async {
  final harness = SessionHarness();
  await harness.ready();
  final clear = Completer<void>();
  final write = Completer<void>();
  harness.store.deleteGate = clear;
  harness.store.writeGate = write;
  final intent = harness.repository.login(
    ' \t\fFIRST@EXAMPLE.INVALID\r\n',
    privatePassword,
  );
  await settleSession();
  expect(harness.repository.busy, isTrue);
  expectLocked(harness.repository);
  expect(harness.api.loginInputs, isEmpty);
  clear.complete();
  await settleSession();
  expect(harness.api.loginInputs.length, 1);
  expect(
    harness.api.loginInputs.single ==
        (' \t\fFIRST@EXAMPLE.INVALID\r\n', privatePassword),
    isTrue,
  );
  expect(harness.api.profileTokens, isEmpty);
  expectLocked(harness.repository);
  write.complete();
  await intent;
  expect(harness.repository.state.phase, AppSessionPhase.full);
  expect(harness.repository.state.profile?.userId, sessionIdentity);
  expect(harness.api.profileTokens.single == sessionToken, isTrue);
  expect(
    harness.events.indexOf('store.delete.ack'),
    lessThan(harness.events.indexOf('api.login')),
  );
  expect(
    harness.events.indexOf('store.write.ack'),
    lessThan(harness.events.indexOf('api.profile')),
  );
  expect(harness.repository.busy, isFalse);
  await harness.repository.dispose();
}

/// Limited login chỉ admission sau write ACK và không probe full profile để nâng scope.
Future<void> checkLimitedAdmission() async {
  final harness = SessionHarness();
  harness.api.result = issuedSession(limited: true);
  await harness.ready();
  final gate = Completer<void>();
  harness.store.writeGate = gate;
  final intent = harness.repository.login(sessionEmail, privatePassword);
  await settleSession();
  expectLocked(harness.repository);
  expect(harness.repository.busy, isTrue);
  gate.complete();
  await intent;
  expect(harness.repository.state.phase, AppSessionPhase.limited);
  expect(harness.repository.state.profile, isNull);
  expect(harness.api.profileTokens, isEmpty);
  expect(harness.store.value == sessionToken, isTrue);
  await harness.repository.dispose();
}

/// Restore phân biệt full/limited/offline/session-invalid, không dùng profile cache thay server.
Future<void> checkRestoreBoundaries() async {
  for (final kind in ['full', 'limited', 'offline', 'expired']) {
    final harness = SessionHarness();
    harness.store.value = sessionToken;
    harness.api.profileFailure = switch (kind) {
      'limited' => const AppAuthFailure(
        AppAuthFailureKind.passwordChangeRequired,
      ),
      'offline' => const AppAuthFailure(AppAuthFailureKind.networkUnavailable),
      'expired' => const AppAuthFailure(AppAuthFailureKind.sessionExpired),
      _ => null,
    };
    await harness.repository.restore();
    expect(harness.api.profileTokens.single == sessionToken, isTrue);
    expect(harness.repository.state.phase, switch (kind) {
      'full' => AppSessionPhase.full,
      'limited' => AppSessionPhase.limited,
      'offline' => AppSessionPhase.offline,
      _ => AppSessionPhase.signedOut,
    });
    if (kind != 'full') expect(harness.repository.state.profile, isNull);
    expect(harness.store.value == null, kind == 'expired');
    await harness.repository.dispose();
  }
}

/// Logout ghi outbox trước active delete, rồi chỉ signedOut sau terminal response.
Future<void> checkLogoutOrder() async {
  final harness = SessionHarness();
  harness.store.value = sessionToken;
  await harness.repository.restore();
  final server = Completer<void>();
  final deletion = Completer<void>();
  harness.api.logoutGate = server;
  harness.store.deleteGate = deletion;
  final intent = harness.repository.logout();
  await settleSession();
  expect(harness.repository.state.phase, AppSessionPhase.loggingOut);
  expect(harness.repository.state.profile, isNull);
  expect(harness.repository.busy, isTrue);
  expect(harness.store.logoutIntent?.sessionToken, sessionToken);
  expect(harness.store.value, sessionToken);
  expect(harness.store.deletes, 1);
  expect(harness.api.logoutTokens, isEmpty);
  expect(
    harness.events.indexOf('store.outbox.write.ack'),
    lessThan(harness.events.indexOf('store.delete.begin')),
  );
  deletion.complete();
  await settleSession();
  expect(harness.api.logoutTokens, [sessionToken]);
  expect(harness.repository.state.phase, AppSessionPhase.loggingOut);
  server.complete();
  await intent;
  expect(harness.repository.state.phase, AppSessionPhase.signedOut);
  expect(harness.api.logoutTokens.single == sessionToken, isTrue);
  expect(harness.store.value, isNull);
  expect(harness.store.logoutIntent, isNull);
  expect(harness.store.outboxDeletes, 1);
  await harness.repository.dispose();
}

/// Known rejection cho retry chủ động; POST unknown không replay và chỉ recover bằng cleanup key.
Future<void> checkLoginFailureClassification() async {
  for (final kind in [
    AppAuthFailureKind.invalidCredentials,
    AppAuthFailureKind.rateLimited,
    AppAuthFailureKind.validation,
    AppAuthFailureKind.networkUnavailable,
    AppAuthFailureKind.unavailable,
  ]) {
    final harness = SessionHarness();
    await harness.ready();
    final unknown = kind == AppAuthFailureKind.unavailable;
    harness.api.loginFailure = AppAuthFailure(
      kind,
      outcomeUnknown: unknown,
      retryAfterSeconds: kind == AppAuthFailureKind.rateLimited ? 3 : null,
    );
    await harness.repository.login(sessionEmail, privatePassword);
    expect(
      harness.repository.state.phase,
      unknown ? AppSessionPhase.pending : AppSessionPhase.signedOut,
    );
    expect(harness.repository.state.failure?.kind, kind);
    expect(harness.store.writtenTokens, isEmpty);
    expect(harness.api.loginInputs.length, 1);
    expect(harness.api.logoutTokens, isEmpty);
    if (unknown) {
      // Key lạ không được dùng để adopt account khi response login đã mất candidate.
      harness.store.value = alternateToken;
      await harness.repository.recover();
      expect(harness.repository.state.phase, AppSessionPhase.signedOut);
      expect(harness.store.value, isNull);
      expect(harness.api.profileTokens, isEmpty);
      expect(harness.api.loginInputs.length, 1);
      expect(harness.api.logoutTokens.contains(alternateToken), isFalse);
    }
    await harness.repository.dispose();
  }
}

/// Outbox read error không giả thành signedOut; recover chỉ clear own key, không nhận profile.
Future<void> checkStorageReadFailure() async {
  final harness = SessionHarness();
  harness.store.value = alternateToken;
  harness.store.failRead = true;
  await harness.repository.restore();
  expect(harness.repository.state.phase, AppSessionPhase.storageFailure);
  expectLocked(harness.repository);
  harness.store.failRead = false;
  await harness.repository.recover();
  expect(harness.repository.state.phase, AppSessionPhase.signedOut);
  expect(harness.store.reads, 0);
  expect(harness.api.profileTokens, isEmpty);
  expect(harness.store.value, isNull);
  await harness.repository.dispose();
}

/// Clear key mất ACK phải chặn login network; retry restore không được đi vòng latch storage.
Future<void> checkInitialClearFailure() async {
  final harness = SessionHarness();
  await harness.ready();
  harness.store.failDelete = true;
  await harness.repository.login(sessionEmail, privatePassword);
  expect(harness.repository.state.phase, AppSessionPhase.storageFailure);
  expect(harness.api.loginInputs, isEmpty);
  final reads = harness.store.reads;
  harness.store.value = alternateToken;
  await harness.repository.restore();
  expectLocked(harness.repository);
  expect(harness.store.reads, reads);
  expect(harness.api.profileTokens, isEmpty);
  harness.store.failDelete = false;
  await harness.repository.recover();
  expect(harness.repository.state.phase, AppSessionPhase.signedOut);
  expect(harness.store.value, isNull);
  await harness.repository.dispose();
}

/// DTO/profile lệch identity hoặc Unicode trim phải cleanup candidate, không admit/revoke bearer khác.
Future<void> checkIdentityAndAsciiEmail() async {
  for (final variant in [
    'dtoEmail',
    'profileId',
    'profileEmail',
    'unicodeTrim',
    'verticalTab',
  ]) {
    final harness = SessionHarness();
    await harness.ready();
    if (variant == 'dtoEmail')
      harness.api.result = issuedSession(email: alternateEmail);
    if (variant == 'profileId')
      harness.api.profileResult = serverProfile(id: alternateIdentity);
    if (variant == 'profileEmail')
      harness.api.profileResult = serverProfile(email: alternateEmail);
    // Rust is_ascii_whitespace không gồm VT; Unicode trim hoặc range 09–0D sẽ nhận sai identity.
    final email = switch (variant) {
      'unicodeTrim' => '\u00a0$sessionEmail\u00a0',
      'verticalTab' => '\u000b$sessionEmail\u000b',
      _ => sessionEmail,
    };
    await harness.repository.login(email, privatePassword);
    expectLocked(harness.repository);
    expect(harness.repository.state.phase, AppSessionPhase.pending);
    expect(harness.api.loginInputs.single.$1, email);
    expect(harness.api.logoutTokens, [sessionToken]);
    expect(harness.api.logoutTokens.contains(alternateToken), isFalse);
    if (variant == 'dtoEmail' ||
        variant == 'unicodeTrim' ||
        variant == 'verticalTab') {
      expect(harness.store.writtenTokens, isEmpty);
    }
    expect(harness.store.value, isNull);
    await harness.repository.dispose();
  }
}

/// Expiry được kiểm lại sau write/profile ACK, kể cả limited không có request profile tiếp theo.
Future<void> checkExpiryBeforeAdmission() async {
  for (final variant in [
    'alreadyExpired',
    'fullWrite',
    'limitedWrite',
    'fullProfile',
  ]) {
    final harness = SessionHarness();
    await harness.ready();
    harness.api.result = issuedSession(
      limited: variant == 'limitedWrite',
      expiry: variant == 'alreadyExpired'
          ? initialTime
          : initialTime.add(const Duration(seconds: 1)),
    );
    final write = Completer<void>();
    final profile = Completer<FullSessionProfile>();
    if (variant == 'fullWrite' || variant == 'limitedWrite')
      harness.store.writeGate = write;
    if (variant == 'fullProfile') harness.api.profileGate = profile;
    final intent = harness.repository.login(sessionEmail, privatePassword);
    await settleSession();
    if (variant != 'alreadyExpired') {
      expect(harness.repository.busy, isTrue);
      expectLocked(harness.repository);
      harness.clock = initialTime.add(const Duration(seconds: 2));
      if (variant == 'fullProfile') {
        profile.complete(serverProfile());
      } else {
        write.complete();
      }
    }
    await intent;
    expectLocked(harness.repository);
    expect(harness.repository.state.phase, AppSessionPhase.pending);
    expect(
      harness.repository.state.failure?.kind,
      AppAuthFailureKind.sessionExpired,
    );
    expect(harness.api.logoutTokens, [sessionToken]);
    expect(harness.store.value, isNull);
    await harness.repository.dispose();
  }
}

/// Lost write ACK kèm delete lỗi phải quarantine cả restore200/403 cho tới delete ACK thật.
Future<void> checkQuarantineCannotAdoptStoredCandidate() async {
  for (final limited in [false, true]) {
    final harness = SessionHarness();
    await harness.ready();
    final write = Completer<void>();
    harness.store.writeGate = write;
    harness.store.writeBeforeAck = true;
    harness.store.failWrite = true;
    final intent = harness.repository.login(sessionEmail, privatePassword);
    await settleSession();
    expect(harness.store.value == sessionToken, isTrue);
    // Pre-clear đã ACK; chỉ cleanup sau issuance mới mất ACK để tái hiện orphan đúng nghĩa.
    harness.store.failDelete = true;
    write.complete();
    await intent;
    expect(harness.repository.state.phase, AppSessionPhase.storageFailure);
    expectLocked(harness.repository);
    final reads = harness.store.reads;
    final profiles = harness.api.profileTokens.length;
    if (limited)
      harness.api.profileFailure = const AppAuthFailure(
        AppAuthFailureKind.passwordChangeRequired,
      );
    await harness.repository.restore();
    await harness.repository.recover();
    expectLocked(harness.repository);
    expect(harness.store.reads, reads);
    expect(harness.api.profileTokens.length, profiles);
    expect(harness.api.loginInputs.length, 1);
    expect(harness.api.logoutTokens, isNotEmpty);
    for (final token in harness.api.logoutTokens) {
      expect(token == sessionToken, isTrue);
    }
    harness.store.failDelete = false;
    await harness.repository.recover();
    expect(harness.repository.state.phase, AppSessionPhase.signedOut);
    expect(harness.store.value, isNull);
    expect(harness.api.profileTokens.length, profiles);
    await harness.repository.dispose();
  }
}

/// Invalid phase và overlapping intent không queue password hoặc chen API/store khi Future trước còn sống.
Future<void> checkDuplicateIntents() async {
  final harness = SessionHarness();
  await harness.repository.login(sessionEmail, privatePassword);
  expect(harness.api.loginInputs, isEmpty);
  await harness.ready();
  final login = Completer<AppLoginResponse>();
  harness.api.loginGate = login;
  final intent = harness.repository.login(sessionEmail, privatePassword);
  await settleSession();
  final generation = harness.repository.state.generation;
  final reads = harness.store.reads;
  final deletes = harness.store.deletes;
  await harness.repository.login(alternateEmail, 'synthetic-second-password');
  await harness.repository.logout();
  await harness.repository.restore();
  await harness.repository.recover();
  expect(harness.repository.busy, isTrue);
  expect(harness.api.loginInputs.length, 1);
  expect(harness.api.logoutTokens, isEmpty);
  expect(harness.store.reads, reads);
  expect(harness.store.deletes, deletes);
  expect(harness.repository.state.generation, generation);
  login.complete(issuedSession());
  await intent;
  expect(harness.repository.state.phase, AppSessionPhase.full);
  await harness.repository.dispose();
}

/// Suspend stable session xóa protected state ngay nhưng giữ bearer để resume recheck server.
Future<void> checkStableSuspendAndResume() async {
  final harness = SessionHarness();
  harness.store.value = sessionToken;
  await harness.repository.restore();
  final oldGeneration = harness.repository.state.generation;
  final reads = harness.store.reads;
  harness.repository.suspend();
  expectLocked(harness.repository);
  expect(harness.repository.state.generation, greaterThan(oldGeneration));
  await harness.repository.restore();
  await harness.repository.recover();
  expect(harness.store.reads, reads);
  expect(harness.api.profileTokens.length, 1);
  expect(harness.store.value == sessionToken, isTrue);
  expect(harness.api.logoutTokens, isEmpty);
  final profile = Completer<FullSessionProfile>();
  harness.api.profileGate = profile;
  final resumed = harness.repository.resume();
  await settleSession();
  expectLocked(harness.repository);
  expect(harness.api.profileTokens, [sessionToken, sessionToken]);
  final duplicate = harness.repository.resume();
  var duplicateDone = false;

  /// Resume lặp sau khi restore bắt đầu vẫn phải đợi cùng ACK, không trả một Future đã complete.
  /// Input
  /// Param: ignored — completion void không mang dữ liệu; chỉ thời điểm ACK có ý nghĩa.
  final observed = duplicate.then((ignored) {
    duplicateDone = true;
  });
  await settleSession();
  expect(duplicateDone, isFalse);
  profile.complete(serverProfile());
  await resumed;
  await observed;
  expect(harness.repository.state.phase, AppSessionPhase.full);
  expect(harness.api.profileTokens.length, 2);
  await harness.repository.dispose();
  expect(harness.store.value == sessionToken, isTrue);
  expect(harness.api.logoutTokens, isEmpty);
}

/// Resume phải đợi late login/write và cleanup candidate; stale publish không đủ giải phóng ownership.
Future<void> checkSuspendDrainsCandidate() async {
  for (final boundary in ['login', 'write']) {
    final harness = SessionHarness();
    await harness.ready();
    final login = Completer<AppLoginResponse>();
    final write = Completer<void>();
    if (boundary == 'login') harness.api.loginGate = login;
    if (boundary == 'write') harness.store.writeGate = write;
    final intent = harness.repository.login(sessionEmail, privatePassword);
    await settleSession();
    harness.repository.suspend();
    final reads = harness.store.reads;
    final resumed = harness.repository.resume();
    final duplicate = harness.repository.resume();
    var resumeDone = false;

    /// Quan sát completion của resume để phát hiện Future trả sớm trước native drain.
    /// Input
    /// Param: ignored — completion void dùng quan sát thứ tự drain, không phải dữ liệu phiên.
    final observed = resumed.then((ignored) {
      resumeDone = true;
    });
    await settleSession();
    expectLocked(harness.repository);
    expect(harness.repository.busy, isTrue);
    expect(resumeDone, isFalse);
    expect(harness.store.reads, reads);
    if (boundary == 'login') {
      login.complete(issuedSession());
    } else {
      write.complete();
    }
    await intent;
    await observed;
    await duplicate;
    expect(harness.repository.state.phase, AppSessionPhase.signedOut);
    expect(harness.api.logoutTokens, [sessionToken]);
    expect(harness.store.value, isNull);
    expect(harness.api.loginInputs.length, 1);
    expect(harness.api.profileTokens, isEmpty);
    expect(harness.store.reads, reads + 1);
    await harness.repository.dispose();
  }
}

/// Dispose khóa tức thì, đợi late login/write cleanup rồi đóng stream, không publish completion cũ.
Future<void> checkDisposeDrainsCandidate() async {
  for (final boundary in ['login', 'write']) {
    final harness = SessionHarness();
    await harness.ready();
    final login = Completer<AppLoginResponse>();
    final write = Completer<void>();
    if (boundary == 'login') harness.api.loginGate = login;
    if (boundary == 'write') harness.store.writeGate = write;
    final intent = harness.repository.login(sessionEmail, privatePassword);
    await settleSession();
    final disposed = harness.repository.dispose();
    expectLocked(harness.repository);
    var done = false;

    /// Đánh dấu Future dispose thực sự complete thay vì chỉ đổi cờ disposed.
    /// Input
    /// Param: ignored — completion void chỉ cho biết owned I/O và cleanup đã drain.
    final observed = disposed.then((ignored) {
      done = true;
    });
    await harness.repository.login(alternateEmail, privatePassword);
    await harness.repository.restore();
    await harness.repository.recover();
    await harness.repository.resume();
    await settleSession();
    expect(done, isFalse);
    expect(harness.api.loginInputs.length, 1);
    if (boundary == 'login') {
      login.complete(issuedSession());
    } else {
      write.complete();
    }
    await intent;
    await observed;
    expectLocked(harness.repository);
    expect(harness.api.logoutTokens, [sessionToken]);
    expect(harness.store.value, isNull);
    await harness.repository.dispose();
  }
}

/// Unknown outcome giữ secure outbox; explicit recovery gửi lại đúng token đã lưu.
Future<void> checkLogoutPendingOwnership() async {
  final harness = SessionHarness();
  harness.store.value = sessionToken;
  await harness.repository.restore();
  harness.api.logoutFailure = const AppAuthFailure(
    AppAuthFailureKind.unavailable,
    outcomeUnknown: true,
  );
  await harness.repository.logout();
  expect(harness.repository.state.phase, AppSessionPhase.pending);
  expectLocked(harness.repository);
  await settleSession();
  expect(harness.api.logoutTokens, [sessionToken]);
  expect(harness.store.value, isNull);
  expect(harness.store.logoutIntent?.sessionToken, sessionToken);
  final nextAttemptAt = harness.store.logoutIntent!.nextAttemptAt;
  harness.clock = nextAttemptAt;
  harness.api.logoutFailure = null;
  await harness.repository.recover();
  expect(harness.api.logoutTokens, [sessionToken, sessionToken]);
  expect(harness.api.profileTokens, [sessionToken]);
  expect(harness.repository.state.phase, AppSessionPhase.signedOut);
  expect(harness.store.value, isNull);
  expect(harness.store.logoutIntent, isNull);
  await harness.repository.dispose();
}

/// Suspend mới khi resume cũ đang chờ phải được một resume mới phục vụ sau stale I/O drain.
Future<void> checkResumeAfterSecondSuspend() async {
  final harness = SessionHarness();
  harness.store.value = sessionToken;
  await harness.repository.restore();
  final firstProfile = Completer<FullSessionProfile>();
  final secondProfile = Completer<FullSessionProfile>();
  harness.api.profileGate = firstProfile;
  harness.repository.suspend();
  final firstResume = harness.repository.resume();
  await settleSession();
  expect(harness.api.profileTokens.length, 2);
  harness.repository.suspend();
  final secondResume = harness.repository.resume();
  var secondDone = false;

  /// Resume generation mới chỉ complete sau recheck của chính generation đó.
  /// Input
  /// Param: ignored — completion void không dùng làm bằng chứng admission; state được kiểm riêng.
  final observed = secondResume.then((ignored) {
    secondDone = true;
  });
  harness.api.profileGate = secondProfile;
  firstProfile.complete(serverProfile());
  await settleSession();
  expectLocked(harness.repository);
  expect(secondDone, isFalse);
  expect(harness.api.profileTokens, [sessionToken, sessionToken, sessionToken]);
  secondProfile.complete(serverProfile());
  await firstResume;
  await observed;
  expect(harness.repository.state.phase, AppSessionPhase.full);
  expect(harness.repository.busy, isFalse);
  expect(harness.api.logoutTokens, isEmpty);
  await harness.repository.dispose();
}

/// Lifecycle retry outbox đúng token nhưng không gọi profile hoặc mở lại protected state.
Future<void> checkPendingLogoutLifecycleFence() async {
  final harness = SessionHarness();
  harness.store.value = sessionToken;
  await harness.repository.restore();
  harness.api.logoutFailure = const AppAuthFailure(
    AppAuthFailureKind.unavailable,
    outcomeUnknown: true,
  );
  await harness.repository.logout();
  final firstRetryAt = harness.store.logoutIntent!.nextAttemptAt;
  harness.clock = firstRetryAt;
  harness.repository.suspend();
  final resumed = harness.repository.resume();
  await resumed;
  expectLocked(harness.repository);
  expect(harness.api.logoutTokens, [sessionToken, sessionToken]);
  expect(harness.api.profileTokens, [sessionToken]);
  expect(harness.store.value, isNull);
  expect(harness.store.logoutIntent?.sessionToken, sessionToken);
  final secondRetryAt = harness.store.logoutIntent!.nextAttemptAt;
  harness.clock = secondRetryAt;
  harness.api.logoutFailure = null;
  await harness.repository.recover();
  expect(harness.repository.state.phase, AppSessionPhase.signedOut);
  expect(harness.api.logoutTokens, [sessionToken, sessionToken, sessionToken]);
  expect(harness.api.profileTokens, [sessionToken]);
  await harness.repository.dispose();
}

/// Restore xử lý outbox trước profile; 401 session-expired là terminal và dọn record.
Future<void> checkRestoreClearsTerminalLogoutOutbox() async {
  final harness = SessionHarness();
  harness.store.value = sessionToken;
  await harness.repository.restore();
  harness.api.logoutFailure = const AppAuthFailure(
    AppAuthFailureKind.unavailable,
    outcomeUnknown: true,
  );
  await harness.repository.logout();
  harness.clock = harness.store.logoutIntent!.nextAttemptAt;
  harness.api.logoutFailure = const AppAuthFailure(
    AppAuthFailureKind.sessionExpired,
  );
  await harness.repository.restore();
  expect(harness.repository.state.phase, AppSessionPhase.signedOut);
  expect(harness.api.logoutTokens, [sessionToken, sessionToken]);
  expect(harness.api.profileTokens, [sessionToken]);
  expect(harness.store.logoutIntent, isNull);
  expect(harness.store.value, isNull);
  await harness.repository.dispose();
}

/// Lỗi đọc outbox khóa restore; khi storage phục hồi, server terminal mới xóa intent.
Future<void> checkPendingLogoutSurvivesStorageQuarantine() async {
  final harness = SessionHarness();
  harness.store.value = sessionToken;
  await harness.repository.restore();
  harness.api.logoutFailure = const AppAuthFailure(
    AppAuthFailureKind.unavailable,
    outcomeUnknown: true,
  );
  await harness.repository.logout();
  final retryAt = harness.store.logoutIntent!.nextAttemptAt;
  harness.store.failRead = true;
  harness.repository.suspend();
  await harness.repository.resume();
  expect(harness.repository.state.phase, AppSessionPhase.storageFailure);
  expect(harness.store.logoutIntent?.sessionToken, sessionToken);
  expect(harness.store.value, isNull);
  expect(harness.api.logoutTokens, [sessionToken]);
  harness.store.failRead = false;
  harness.clock = retryAt;
  harness.api.logoutFailure = const AppAuthFailure(
    AppAuthFailureKind.sessionExpired,
  );
  await harness.repository.recover();
  expect(harness.repository.state.phase, AppSessionPhase.signedOut);
  expect(harness.api.logoutTokens, [sessionToken, sessionToken]);
  expect(harness.store.logoutIntent, isNull);
  await harness.repository.dispose();
}

/// Dựng repository mới trên fake outbox để kiểm pending ưu tiên profile và active key.
Future<void> checkRepositoryReconstructionFromPendingLogout() async {
  final harness = SessionHarness();
  harness.store.value = sessionToken;
  await harness.repository.restore();
  harness.api.logoutFailure = const AppAuthFailure(
    AppAuthFailureKind.networkUnavailable,
    outcomeUnknown: true,
  );
  await harness.repository.logout();
  final pending = harness.store.logoutIntent;
  expect(harness.repository.state.phase, AppSessionPhase.pending);
  expect(pending?.sessionToken, sessionToken);
  expect(pending?.expiresAt, initialTime.add(const Duration(hours: 1)));
  expect(harness.store.value, isNull);
  // Fake này chỉ mô phỏng trạng thái lưu lại khi process được dựng lại, không phải native persistence.
  harness.store.value = sessionToken;
  await harness.repository.dispose();

  harness.clock = pending!.nextAttemptAt;
  final restartedApi = SessionApiFake(harness.events);
  final restarted = AppSessionRepository(
    api: restartedApi,
    tokenStore: harness.store,
    now: harness.now,
  );
  await restarted.restore();
  expect(restarted.state.phase, AppSessionPhase.signedOut);
  expect(restartedApi.profileTokens, isEmpty);
  expect(restartedApi.logoutTokens, [sessionToken]);
  expect(harness.store.logoutIntent, isNull);
  expect(harness.store.value, isNull);
  expect(
    harness.events.lastIndexOf('store.delete.ack'),
    lessThan(harness.events.lastIndexOf('api.logout')),
  );
  await restarted.dispose();
}

/// Giữ revoke intent qua expiry và restart offline; chỉ server-terminal mới mở khóa app.
Future<void> checkExpiredLogoutIntentSurvivesOfflineRestart() async {
  final harness = SessionHarness();
  final expiresAt = initialTime.add(const Duration(hours: 1));
  harness.clock = expiresAt.add(const Duration(days: 2));
  harness.store.logoutIntent = PendingLogoutIntent(
    intentId: 'logout-synthetic-expired',
    sessionToken: sessionToken,
    expiresAt: expiresAt,
    attemptCount: 5,
    nextAttemptAt: initialTime,
  );
  harness.api.logoutFailure = const AppAuthFailure(
    AppAuthFailureKind.networkUnavailable,
    outcomeUnknown: true,
  );
  final restarted = AppSessionRepository(
    api: harness.api,
    tokenStore: harness.store,
    now: harness.now,
  );

  await restarted.restore();

  expect(restarted.state.phase, AppSessionPhase.pending);
  expectLocked(restarted);
  expect(harness.api.profileTokens, isEmpty);
  expect(harness.api.logoutTokens, [sessionToken]);
  expect(harness.store.logoutIntent?.sessionToken, sessionToken);
  expect(harness.store.logoutIntent?.expiresAt, expiresAt);
  expect(harness.store.value, isNull);

  harness.clock = harness.store.logoutIntent!.nextAttemptAt;
  harness.api.logoutFailure = const AppAuthFailure(
    AppAuthFailureKind.sessionExpired,
  );
  await restarted.recover();
  expect(restarted.state.phase, AppSessionPhase.signedOut);
  expect(harness.store.logoutIntent, isNull);
  expect(harness.store.value, isNull);
  await restarted.dispose();
}

/// Retry-After là deadline sớm nhất; explicit recovery không gửi POST sớm hơn.
Future<void> checkLogoutRespectsRetryAfter() async {
  final harness = SessionHarness();
  harness.store.value = sessionToken;
  await harness.repository.restore();
  harness.api.logoutFailure = const AppAuthFailure(
    AppAuthFailureKind.rateLimited,
    retryAfterSeconds: 60,
  );
  await harness.repository.logout();
  final retryAt = harness.store.logoutIntent!.nextAttemptAt;
  expect(retryAt, initialTime.add(const Duration(seconds: 60)));
  expect(harness.api.logoutTokens, [sessionToken]);

  harness.clock = retryAt.subtract(const Duration(seconds: 1));
  harness.api.logoutFailure = null;
  await harness.repository.recover();
  expect(harness.api.logoutTokens, [sessionToken]);
  expect(harness.repository.state.phase, AppSessionPhase.pending);

  harness.clock = retryAt;
  await harness.repository.recover();
  expect(harness.api.logoutTokens, [sessionToken, sessionToken]);
  expect(harness.repository.state.phase, AppSessionPhase.signedOut);
  await harness.repository.dispose();
}

/// Kiểm tra retry cùng bearer có jitter bounded, tôn trọng deadline và dừng sau năm lần.
Future<void> checkAutomaticLogoutRetryLimit() async {
  final harness = SessionHarness();
  harness.store.value = sessionToken;
  await harness.repository.restore();
  harness.api.logoutFailure = const AppAuthFailure(
    AppAuthFailureKind.networkUnavailable,
    outcomeUnknown: true,
  );
  final firstFailureAt = harness.clock;
  await harness.repository.logout();
  expect(harness.api.logoutTokens, [sessionToken]);
  expect(harness.timers.activeCount, 1);

  final firstDueAt = harness.store.logoutIntent!.nextAttemptAt;
  expect(firstDueAt.difference(firstFailureAt), const Duration(seconds: 1));
  harness.repository.suspend();
  expect(harness.timers.activeCount, 0);
  harness.clock = firstDueAt;
  await harness.repository.resume();
  expect(harness.api.logoutTokens, [sessionToken, sessionToken]);
  expect(harness.store.logoutIntent?.attemptCount, 1);
  expect(harness.timers.activeCount, 1);

  for (var expectedCount = 2; expectedCount <= 5; expectedCount++) {
    final pending = harness.store.logoutIntent!;
    expect(pending.attemptCount, expectedCount - 1);
    final retryDueAt = pending.nextAttemptAt;
    final requestCountBeforeRetry = harness.api.logoutTokens.length;
    harness.clock = retryDueAt.subtract(const Duration(milliseconds: 1));
    harness.timers.fireDue();
    await settleSession();
    expect(harness.api.logoutTokens.length, requestCountBeforeRetry);
    expect(harness.timers.activeCount, 1);

    harness.clock = retryDueAt;
    harness.timers.fireDue();
    await settleSession();
    expect(harness.api.logoutTokens.length, expectedCount + 1);
    expect(harness.api.logoutTokens.last, sessionToken);
    expect(harness.store.logoutIntent?.attemptCount, expectedCount);

    final nextRetryDelay = harness.store.logoutIntent!.nextAttemptAt.difference(
      harness.clock,
    );
    final maximumJitterDelay = Duration(seconds: 1 << (expectedCount - 1));
    expect(nextRetryDelay >= const Duration(seconds: 1), isTrue);
    expect(nextRetryDelay <= maximumJitterDelay, isTrue);
  }
  expect(harness.timers.activeCount, 0);
  expect(harness.repository.state.phase, AppSessionPhase.pending);

  final nextCycleAt = harness.store.logoutIntent!.nextAttemptAt;
  harness.repository.suspend();
  harness.clock = nextCycleAt;
  harness.api.logoutFailure = null;
  await harness.repository.resume();
  expect(harness.api.logoutTokens.length, 7);
  expect(harness.api.logoutTokens.last, sessionToken);
  expect(harness.repository.state.phase, AppSessionPhase.signedOut);
  expect(harness.store.logoutIntent, isNull);
  await harness.repository.dispose();
}

/// Write thất bại giữ active key nhưng khóa dữ liệu; recovery chỉ tiến sau outbox ACK.
Future<void> checkOutboxWriteFailureKeepsLocked() async {
  final harness = SessionHarness();
  harness.store.value = sessionToken;
  await harness.repository.restore();
  harness.store.failOutboxWrite = true;
  await harness.repository.logout();
  expect(harness.repository.state.phase, AppSessionPhase.storageFailure);
  expectLocked(harness.repository);
  expect(harness.store.value, sessionToken);
  expect(harness.store.logoutIntent, isNull);
  expect(harness.api.logoutTokens, isEmpty);

  harness.store.failOutboxWrite = false;
  await harness.repository.recover();
  expect(harness.repository.state.phase, AppSessionPhase.signedOut);
  expect(harness.store.value, isNull);
  expect(harness.store.logoutIntent, isNull);
  expect(harness.api.logoutTokens, [sessionToken]);
  await harness.repository.dispose();
}

/// Lỗi khi ghi quota trước POST phải giữ local lock và không gửi request chưa bền vững.
Future<void> checkPreRequestOutboxWriteFailureKeepsLocked() async {
  final harness = SessionHarness();
  harness.store.value = sessionToken;
  await harness.repository.restore();
  harness.store
    ..failOutboxWrite = true
    ..failOutboxWriteAtCall = 2;

  await harness.repository.logout();

  expect(harness.repository.state.phase, AppSessionPhase.storageFailure);
  expectLocked(harness.repository);
  expect(harness.store.value, isNull);
  expect(harness.store.logoutIntent?.attemptCount, 0);
  expect(harness.api.logoutTokens, isEmpty);
  expect(harness.timers.activeCount, 0);

  harness.store.failOutboxWrite = false;
  await harness.repository.recover();
  expect(harness.repository.state.phase, AppSessionPhase.signedOut);
  expect(harness.api.logoutTokens, [sessionToken]);
  expect(harness.store.logoutIntent, isNull);
  await harness.repository.dispose();
}

/// Lỗi ghi retry deadline không được tạo timer hoặc mở local state trước storage recovery.
Future<void> checkRetryDeadlineWriteFailureKeepsLocked() async {
  final harness = SessionHarness();
  harness.store.value = sessionToken;
  await harness.repository.restore();
  harness.api.logoutFailure = const AppAuthFailure(
    AppAuthFailureKind.networkUnavailable,
    outcomeUnknown: true,
  );
  harness.store
    ..failOutboxWrite = true
    ..failOutboxWriteAtCall = 3;

  await harness.repository.logout();

  expect(harness.repository.state.phase, AppSessionPhase.storageFailure);
  expectLocked(harness.repository);
  expect(harness.store.logoutIntent?.attemptCount, 1);
  expect(harness.api.logoutTokens, [sessionToken]);
  expect(harness.timers.activeCount, 0);

  harness.store.failOutboxWrite = false;
  harness.api.logoutFailure = const AppAuthFailure(
    AppAuthFailureKind.sessionExpired,
  );
  await harness.repository.recover();
  expect(harness.repository.state.phase, AppSessionPhase.signedOut);
  expect(harness.api.logoutTokens, [sessionToken, sessionToken]);
  expect(harness.store.logoutIntent, isNull);
  await harness.repository.dispose();
}

/// ACK ghi outbox thất lạc vẫn khóa account và recovery dùng lại đúng intent đã lưu.
Future<void> checkOutboxWriteLostAckRecovery() async {
  final harness = SessionHarness();
  harness.store.value = sessionToken;
  await harness.repository.restore();
  harness.store
    ..failOutboxWrite = true
    ..writeOutboxBeforeFailure = true;
  await harness.repository.logout();
  expect(harness.repository.state.phase, AppSessionPhase.storageFailure);
  expectLocked(harness.repository);
  expect(harness.store.value, sessionToken);
  expect(harness.store.logoutIntent?.sessionToken, sessionToken);
  expect(harness.api.logoutTokens, isEmpty);

  harness.store.failOutboxWrite = false;
  await harness.repository.recover();
  expect(harness.repository.state.phase, AppSessionPhase.signedOut);
  expect(harness.api.logoutTokens, [sessionToken]);
  expect(harness.api.profileTokens, [sessionToken]);
  expect(harness.store.value, isNull);
  expect(harness.store.logoutIntent, isNull);
  await harness.repository.dispose();
}

/// Lost delete ACK sau 204 được recover bằng terminal proof nếu key đã thực sự biến mất.
Future<void> checkOutboxDeleteLostAckRecovery() async {
  final harness = SessionHarness();
  harness.store.value = sessionToken;
  await harness.repository.restore();
  harness.store
    ..failOutboxDelete = true
    ..deleteOutboxBeforeFailure = true;
  await harness.repository.logout();
  expect(harness.repository.state.phase, AppSessionPhase.storageFailure);
  expect(harness.store.value, isNull);
  expect(harness.store.logoutIntent, isNull);
  expect(harness.api.logoutTokens, [sessionToken]);

  harness.store.failOutboxDelete = false;
  await harness.repository.recover();
  expect(harness.repository.state.phase, AppSessionPhase.signedOut);
  expect(harness.api.logoutTokens, [sessionToken]);
  expect(harness.api.profileTokens, [sessionToken]);
  await harness.repository.dispose();
}

/// Khôi phục tombstone còn lại sau cleanup lỗi mà không gửi lại logout đã terminal.
Future<void> checkOutboxDeleteFailureRetainsTerminalTombstone() async {
  final harness = SessionHarness();
  harness.store.value = sessionToken;
  await harness.repository.restore();
  harness.store.failOutboxDelete = true;

  await harness.repository.logout();

  expect(harness.repository.state.phase, AppSessionPhase.storageFailure);
  expect(harness.store.value, isNull);
  expect(harness.store.logoutIntent?.sessionToken, sessionToken);
  expect(harness.api.logoutTokens, [sessionToken]);

  harness.store.failOutboxDelete = false;
  await harness.repository.recover();
  expect(harness.repository.state.phase, AppSessionPhase.signedOut);
  expect(harness.store.logoutIntent, isNull);
  expect(harness.api.logoutTokens, [sessionToken]);
  await harness.repository.dispose();
}

/// Own key không phải token68 cần quarantine trước network; recover clear key thay vì protocol-loop.
Future<void> checkInvalidStoredBearerRecovery() async {
  for (final malformed in ['invalid#token', 'invalid\u00e9token']) {
    final harness = SessionHarness();
    harness.store.value = malformed;
    await harness.repository.restore();
    expect(harness.repository.state.phase, AppSessionPhase.storageFailure);
    expectLocked(harness.repository);
    expect(harness.api.profileTokens, isEmpty);
    expect(harness.api.logoutTokens, isEmpty);
    final deletion = Completer<void>();
    harness.store.deleteGate = deletion;
    final recovery = harness.repository.recover();
    await settleSession();
    expect(harness.repository.state.phase, isNot(AppSessionPhase.signedOut));
    expect(harness.repository.busy, isTrue);
    deletion.complete();
    await recovery;
    expect(harness.repository.state.phase, AppSessionPhase.signedOut);
    expect(harness.store.value, isNull);
    expect(harness.store.reads, 1);
    expect(harness.api.profileTokens, isEmpty);
    await harness.repository.dispose();
  }
}

/// Đăng ký core và negative behavior độc lập; không gọi network/plugin thật hoặc timeout thả native I/O.
void main() {
  test(
    'restore null confirms signed out and broadcast state',
    checkInitialRestore,
  );
  test(
    'full admission waits clear and write ACK before matching profile',
    checkFullAdmissionOrder,
  );
  test(
    'limited login waits storage ACK and skips full profile',
    checkLimitedAdmission,
  );
  test(
    'restore distinguishes server scope offline and expired token',
    checkRestoreBoundaries,
  );
  test(
    'logout writes secure outbox before local delete and waits terminal server ACK',
    checkLogoutOrder,
  );
  test(
    'login rejection and unknown outcomes have distinct safe recovery',
    checkLoginFailureClassification,
  );
  test(
    'storage read error never adopts a later stored account',
    checkStorageReadFailure,
  );
  test(
    'clear failure prevents login and latches restore admission',
    checkInitialClearFailure,
  );
  test(
    'login identity fences use ASCII email normalization only',
    checkIdentityAndAsciiEmail,
  );
  test(
    'login expiry is checked again after delayed ACKs',
    checkExpiryBeforeAdmission,
  );
  test(
    'lost write ACK and failed cleanup quarantine restore 200 and 403',
    checkQuarantineCannotAdoptStoredCandidate,
  );
  test(
    'duplicate and invalid intents do not queue or add calls',
    checkDuplicateIntents,
  );
  test(
    'suspend preserves stable token but resume rechecks server once',
    checkStableSuspendAndResume,
  );
  test(
    'resume waits late candidate and cleanup before a new restore',
    checkSuspendDrainsCandidate,
  );
  test(
    'dispose awaits late candidate cleanup without admission',
    checkDisposeDrainsCandidate,
  );
  test(
    'pending logout retries only the original private token',
    checkLogoutPendingOwnership,
  );
  test(
    'new suspend generation gets a fresh resume after stale profile drains',
    checkResumeAfterSecondSuspend,
  );
  test(
    'lifecycle retries logout intent without admitting profile state',
    checkPendingLogoutLifecycleFence,
  );
  test(
    'restore clears terminal logout outbox without profile bootstrap',
    checkRestoreClearsTerminalLogoutOutbox,
  );
  test(
    'outbox read failure keeps logout locked until storage recovers',
    checkPendingLogoutSurvivesStorageQuarantine,
  );
  test(
    'repository reconstruction prioritizes the pending logout outbox',
    checkRepositoryReconstructionFromPendingLogout,
  );
  test(
    'expired revoke intent survives offline restart until terminal server response',
    checkExpiredLogoutIntentSurvivesOfflineRestart,
  );
  test(
    'logout retry honors Retry-After during explicit recovery',
    checkLogoutRespectsRetryAfter,
  );
  test(
    'automatic logout retries stop at five and resume starts a new cycle',
    checkAutomaticLogoutRetryLimit,
  );
  test(
    'outbox write failure keeps local state locked until recover',
    checkOutboxWriteFailureKeepsLocked,
  );
  test(
    'pre-request outbox quota write failure prevents logout POST',
    checkPreRequestOutboxWriteFailureKeepsLocked,
  );
  test(
    'retry deadline write failure keeps state locked without a timer',
    checkRetryDeadlineWriteFailureKeepsLocked,
  );
  test(
    'lost outbox write ACK recovers the committed tombstone',
    checkOutboxWriteLostAckRecovery,
  );
  test(
    'lost outbox delete ACK recovers after terminal logout response',
    checkOutboxDeleteLostAckRecovery,
  );
  test(
    'outbox delete failure retains terminal intent without replay',
    checkOutboxDeleteFailureRetainsTerminalTombstone,
  );
  test(
    'malformed stored bearer is recoverable without a protocol retry loop',
    checkInvalidStoredBearerRecovery,
  );
}
