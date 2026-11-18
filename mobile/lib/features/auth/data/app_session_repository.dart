import 'dart:async';
import 'dart:math';

import '../../workspaces/data/available_workspace_page.dart';
import '../../workspaces/data/workspace_access_detail.dart';
import 'app_auth_api.dart';
import 'app_auth_failure.dart';
import 'app_login_response.dart';
import 'app_session_state.dart';
import 'full_session_profile.dart';
import 'session_token_store.dart';

/// Sở hữu một store suốt app lifetime; chỉ admission sau ACK và server, không cache password.
final class AppSessionRepository {
  /// Nhận dependency đã có để kiểm transition bằng fake, không thêm package hoặc lưu password.
  /// Input
  /// Param: api — transport Android thuộc origin cố định.
  /// Param: tokenStore — own auth key, một repository sở hữu suốt app lifetime.
  /// Param: now — giờ UTC kiểm expiry DTO; mặc định clock hệ thống, test có thể điều khiển.
  /// Param: retryTimerFactory — bộ lập lịch retry; production dùng Timer, test có thể cấp clock giả.
  /// Param: workspaceApi — capability thật chỉ khi composition đã nối; không tự mock thành công.
  /// Param: passwordApi — capability password riêng để limited không có workspace API mặc định.
  AppSessionRepository({
    required AppAuthApi api,
    required SessionTokenStore tokenStore,
    DateTime Function()? now,
    Timer Function(Duration, void Function())? retryTimerFactory,
    AppWorkspaceApi? workspaceApi,
    AppPasswordApi? passwordApi,
  }) : _api = api,
       _store = tokenStore,
       _now = now ?? DateTime.now,
       _retryTimerFactory = retryTimerFactory ?? _createLogoutRetryTimer,
       _workspaceApi = workspaceApi,
       _passwordApi = passwordApi;

  final AppAuthApi _api;
  final SessionTokenStore _store;
  final DateTime Function() _now;
  final Timer Function(Duration, void Function()) _retryTimerFactory;
  final AppWorkspaceApi? _workspaceApi;
  final AppPasswordApi? _passwordApi;
  final _events = StreamController<AppSessionState>.broadcast();
  AppSessionState _state = AppSessionState(
    phase: AppSessionPhase.checking,
    generation: 0,
  );
  int _generation = 0;
  String? _token;
  (String, String)? _identity;
  String? _orphanToken;
  bool _quarantined = false;
  bool _suspended = false;
  bool _disposed = false;
  bool _logoutPending = false;
  bool _logoutServerResolved = false;
  bool _passwordPending = false;
  DateTime? _sessionExpiresAt;
  Timer? _logoutRetryTimer;
  final _workspaceCursors = <String>{};
  int _workspacePageCount = 0;
  int? _requestedResumeGeneration;
  Future<void>? _active;
  Future<void>? _resumeFuture;
  Future<void>? _disposeFuture;

  /// Output: trạng thái hiện tại không chứa bearer.
  AppSessionState get state => _state;

  /// Output: stream thay đổi; consumer luôn đối chiếu generation với state hiện tại.
  Stream<AppSessionState> get changes => _events.stream.where(
    /// Loại event xếp hàng trước suspend/dispose hoặc state mới; tránh giao profile stale cho UI.
    /// Input
    /// Param: snapshot — event bất biến đã được enqueue, không nhất thiết còn hiện hành.
    /// Output: chỉ snapshot hiện tại được chuyển tiếp tới từng subscriber.
    (snapshot) => !_disposed && identical(snapshot, _state),
  );

  /// Output: true khi intent đang giữ ownership; không queue password cho thao tác trùng.
  bool get busy => _active != null || _resumeFuture != null;

  /// Output: true khi repository đang giữ intent đăng xuất chờ hoàn tất trên máy chủ hoặc thiết bị.
  bool get logoutPending => _logoutPending;

  /// Output: chỉ cho phát logout khi private token/lifecycle/intent cho phép; không chứng minh server đã revoke.
  bool get canLogout =>
      _canStart &&
      (!_quarantined || _logoutPending || _passwordPending) &&
      _token != null;

  /// Chỉ signedOut được gửi login mới sau clear ACK.
  /// Input
  /// Param: email — input nguyên bản gửi API, identity được đối chiếu sau response.
  /// Param: password — chỉ dùng cho một API call, không cache/replay.
  Future<void> login(String email, String password) {
    if (!_canStart ||
        _quarantined ||
        _state.phase != AppSessionPhase.signedOut) {
      return Future<void>.value();
    }
    return _start(
      AppSessionPhase.submitting,

      /// Gắn input với đúng intent, không xếp hàng hoặc tự phát lại credential.
      /// Input
      /// Param: generation — ownership đã giữ trước khi publish submitting.
      (generation) => _login(generation, email, password),
    );
  }

  /// Đối soát outbox trước token active; chỉ hỏi profile khi không còn revoke intent.
  Future<void> restore() {
    if (!_canStart) return Future<void>.value();
    return _start(
      AppSessionPhase.checking,
      /// Đọc lại intent tồn tại trước khi kiểm session để khởi động retry có giới hạn.
      /// Input
      /// Param: generation — phiên restore hiện hành được phép cập nhật state.
      (generation) => _restore(
        generation,
        beginLogoutRetryCycle: true,
      ),
    );
  }

  /// Recovery chủ động ưu tiên gửi logout outbox; không phát lại login/password.
  Future<void> recover() {
    if (!_canStart) return Future<void>.value();
    return _start(
      AppSessionPhase.checking,
      /// Đọc outbox trước active session; recovery không mở lại account khi còn revoke intent.
      /// Input
      /// Param: generation — intent recovery chủ động của người dùng.
      (generation) => _restore(
        generation,
        preserveLogoutIntent: false,
        beginLogoutRetryCycle: true,
      ),
    );
  }

  /// Bắt đầu logout bằng secure tombstone trước active delete để restart không admission account cũ.
  Future<void> logout() {
    if (!canLogout) {
      return Future<void>.value();
    }
    return _start(AppSessionPhase.loggingOut, _logout);
  }

  /// Tải list ACTIVE bằng bearer private, khóa protected data khi chờ server và giữ generation.
  /// Input
  /// Param: loadMore — true chỉ khi trang hiện tại có cursor, không auto replay page.
  Future<void> loadWorkspaces({bool loadMore = false}) {
    if (!_canUseCapabilities ||
        _state.phase != AppSessionPhase.full ||
        (loadMore &&
            (!_state.workspacesLoaded || _state.nextWorkspaceCursor == null))) {
      return Future<void>.value();
    }
    final previous = _state;
    final token = _token!;
    if (!loadMore) {
      _workspaceCursors.clear();
      _workspacePageCount = 0;
    }
    return _start(
      AppSessionPhase.checking,

      /// Tích lũy page immutable, không dùng JSON serialization ngược hoặc tự chọn summary.
      /// Input
      /// Param: generation — ownership của list request, stale result không được publish.
      (generation) async {
        try {
          if (_workspaceApi == null || _workspacePageCount >= 100)
            throw _protocolFailure;
          final page = await _workspaceApi.listWorkspaces(
            token,
            cursor: loadMore ? previous.nextWorkspaceCursor : null,
          );
          if (!_isCurrent(generation)) return;
          final items = <AvailableWorkspaceSummary>[
            if (loadMore) ...previous.workspaces,
            ...page.items,
          ];
          final identities = <String>{};
          for (final item in items) {
            if (!identities.add(item.id.toLowerCase())) throw _protocolFailure;
          }
          // Memory/page budget là UI resource bound, không giả đây là quota server hoặc end-of-list.
          if (items.length > 1000 ||
              (page.nextCursor != null &&
                  !_workspaceCursors.add(page.nextCursor!)))
            throw _protocolFailure;
          _workspacePageCount++;
          _publish(
            generation,
            AppSessionPhase.full,
            profile: previous.profile,
            workspaces: items,
            nextWorkspaceCursor: page.nextCursor,
            workspacesLoaded: true,
          );
        } on AppAuthFailure catch (failure) {
          await _workspaceFailure(generation, failure, previous.profile);
        }
      },
    );
  }

  /// Chỉ recheck lựa chọn thuộc page đã tải; id/role client không thay server membership guard.
  /// Input
  /// Param: id — UUID của summary đã tải, vẫn cần server detail guard.
  Future<void> selectWorkspace(String id) {
    if (!_canUseCapabilities ||
        _state.phase != AppSessionPhase.full ||
        !_state.workspaces.any(
          /// Input
          /// Param: item — summary đã tải, so identity case-insensitive không tự cấp quyền.
          /// Output: true khi id caller thuộc page hiện hành, vẫn cần server detail.
          (item) => item.id.toLowerCase() == id.toLowerCase(),
        ))
      return Future<void>.value();
    final previous = _state;
    final token = _token!;
    return _start(
      AppSessionPhase.checking,

      /// Chỉ operational detail đúng identity được chuyển tới selected snapshot sau ACK server.
      /// Input
      /// Param: generation — selection intent, bị invalidated ngay khi lifecycle thay đổi.
      (generation) async {
        try {
          if (_workspaceApi == null) throw _protocolFailure;
          final selected = await _workspaceApi.getWorkspace(token, id);
          if (!_isCurrent(generation)) return;
          if (selected.id.toLowerCase() != id.toLowerCase())
            throw _protocolFailure;
          if (!selected.isOperational)
            throw const AppAuthFailure(AppAuthFailureKind.permissionDenied);
          _publish(
            generation,
            AppSessionPhase.full,
            profile: previous.profile,
            workspaces: previous.workspaces,
            nextWorkspaceCursor: previous.nextWorkspaceCursor,
            workspacesLoaded: previous.workspacesLoaded,
            selectedWorkspace: selected,
          );
        } on AppAuthFailure catch (failure) {
          await _workspaceFailure(generation, failure, previous.profile);
        }
      },
    );
  }

  /// Password mutation thuộc đúng session và không persist/replay secret.
  /// Input
  /// Param: currentPassword — secret nguyên bản của intent.
  /// Param: newPassword — secret mới nguyên bản, không tự nâng limited sau ACK.
  Future<void> changePassword(String currentPassword, String newPassword) {
    if (!_canUseCapabilities ||
        (_state.phase != AppSessionPhase.full &&
            _state.phase != AppSessionPhase.limited)) {
      return Future<void>.value();
    }
    final previous = _state;
    final token = _token!;
    return _start(
      AppSessionPhase.checking,

      /// Gắn password với một intent, xử lý effect sau response trước khi kiểm quyền publish còn hiện hành.
      /// Input
      /// Param: generation — chỉ generation này được publish kết quả, cleanup ACK vẫn phải drain khi stale.
      (generation) async {
        if (_passwordApi == null) {
          _publish(
            generation,
            AppSessionPhase.pending,
            failure: _protocolFailure,
          );
          return;
        }
        _passwordPending = true;
        try {
          await _passwordApi.changePassword(
            token,
            currentPassword,
            newPassword,
          );
          _passwordPending = false;
          _logoutPending = false;
          await _clearQuarantine(generation);
        } on AppAuthFailure catch (failure) {
          if (failure.kind == AppAuthFailureKind.sessionExpired) {
            _passwordPending = false;
            _logoutPending = false;
            await _clearQuarantine(generation);
          } else if (failure.outcomeUnknown) {
            _publish(generation, AppSessionPhase.pending, failure: failure);
          } else {
            _passwordPending = false;
            _publish(
              generation,
              previous.phase,
              profile: previous.profile,
              failure: failure,
            );
          }
        } catch (_) {
          // Raw exception không chứng minh POST chưa commit; latch sống qua resume/recover, không giữ lỗi gốc.
          _publish(
            generation,
            AppSessionPhase.pending,
            failure: _protocolFailure,
          );
        }
      },
    );
  }

  /// Output: chỉ stable admitted session mới được mở capability; unknown/lifecycle/busy không được queue.
  bool get _canUseCapabilities =>
      _canStart &&
      !_quarantined &&
      !_logoutPending &&
      !_passwordPending &&
      _token != null;

  /// Chuyển lỗi workspace về auth hoặc reload state, xóa stale selection trước mọi route mới.
  /// Input
  /// Param: generation — ownership request, lỗi tới muộn không thay state hiện hành.
  /// Param: failure — typed error đã redaction, không raw server data.
  /// Param: profile — stable account profile trước workspace request, không workspace permission cache.
  Future<void> _workspaceFailure(
    int generation,
    AppAuthFailure failure,
    FullSessionProfile? profile,
  ) async {
    if (!_isCurrent(generation)) return;
    switch (failure.kind) {
      case AppAuthFailureKind.sessionExpired:
        await _clearQuarantine(generation);
      case AppAuthFailureKind.passwordChangeRequired:
        _publish(generation, AppSessionPhase.limited);
      case AppAuthFailureKind.permissionDenied ||
          AppAuthFailureKind.resourceNotFound ||
          AppAuthFailureKind.conflict ||
          AppAuthFailureKind.cursorInvalid ||
          AppAuthFailureKind.validation:
        _publish(
          generation,
          AppSessionPhase.full,
          profile: profile,
          failure: failure,
        );
      case AppAuthFailureKind.networkUnavailable ||
          AppAuthFailureKind.unavailable:
        _publish(generation, AppSessionPhase.offline, failure: failure);
      default:
        _publish(generation, AppSessionPhase.pending, failure: failure);
    }
  }

  /// Khóa UI ngay, hủy timer retry và giữ ownership của I/O cũ tới khi Future drain.
  void suspend() {
    if (_disposed) return;
    _logoutRetryTimer?.cancel();
    _logoutRetryTimer = null;
    _suspended = true;
    _generation++;
    _state = AppSessionState(
      phase: AppSessionPhase.checking,
      generation: _generation,
    );
    _events.add(_state);
  }

  /// Chờ intent cũ drain rồi recheck server; không chen write mới qua native Future.
  Future<void> resume() {
    if (_disposed) return Future<void>.value();
    if (_suspended) _requestedResumeGeneration = _generation;
    // Caller thứ hai phải chờ cùng ACK dù resume đầu đã bỏ cờ suspended để bắt đầu /me.
    if (_resumeFuture != null) return _resumeFuture!;
    if (!_suspended) return Future<void>.value();
    return _resumeFuture = _resumeAfterDrain();
  }

  /// Hủy timer, chặn publish muộn, drain I/O rồi đóng stream mà không tự xóa stable session.
  Future<void> dispose() {
    if (_disposeFuture != null) return _disposeFuture!;
    _disposed = true;
    _suspended = true;
    _logoutRetryTimer?.cancel();
    _logoutRetryTimer = null;
    _generation++;
    _state = AppSessionState(
      phase: AppSessionPhase.checking,
      generation: _generation,
    );
    return _disposeFuture = _closeAfterDrain();
  }

  /// Output: không cho intent mới đi qua intent đang chạy hoặc lifecycle lock.
  bool get _canStart => !_disposed && !_suspended && !busy;

  /// Kiểm ownership ở mỗi async boundary, không giả rằng timeout đã hủy Future gốc.
  /// Input
  /// Param: generation — intent sở hữu network/storage hiện tại.
  /// Output: true khi còn được publish/admit hoặc bắt đầu side effect kế tiếp.
  bool _isCurrent(int generation) =>
      !_disposed && !_suspended && generation == _generation;

  /// Giữ busy trước publish để callback/UI trùng không thể mở thêm intent.
  /// Input
  /// Param: phase — loading state không có profile.
  /// Param: operation — một thao tác sở hữu I/O tới khi Future gốc hoàn tất.
  /// Output: hoàn tất intent; lỗi boundary được đổi thành trạng thái an toàn.
  Future<void> _start(
    AppSessionPhase phase,
    Future<void> Function(int) operation,
  ) {
    final completion = Completer<void>();
    _active = completion.future;
    final generation = ++_generation;
    _publish(generation, phase);
    unawaited(_execute(generation, operation, completion));
    return completion.future;
  }

  /// Drain intent và chỉ thả busy sau mọi cleanup, kể cả khi UI đã suspend/dispose.
  /// Input
  /// Param: generation — ownership của intent đã bắt đầu.
  /// Param: operation — network/store workflow không được chạy đồng thời.
  /// Param: completion — ACK process-local cho caller và resume/dispose chờ drain.
  Future<void> _execute(
    int generation,
    Future<void> Function(int) operation,
    Completer<void> completion,
  ) async {
    try {
      await operation(generation);
    } catch (_) {
      // Exception ngoài typed boundary không được lộ raw detail hoặc mở lại UI.
      _quarantined = true;
      _publish(generation, AppSessionPhase.pending, failure: _protocolFailure);
    } finally {
      _active = null;
      completion.complete();
    }
  }

  /// Login đúng một lần, lưu ACK rồi mới kiểm bootstrap/identity và admission.
  /// Input
  /// Param: generation — intent login, không được chuyển token sang intent khác.
  /// Param: email — gửi nguyên bản; chỉ normalize ASCII để so identity response.
  /// Param: password — credential tạm của lần gọi API, không lưu vào field.
  Future<void> _login(int generation, String email, String password) async {
    if (!await _deleteKey()) {
      _quarantined = true;
      _publish(generation, AppSessionPhase.storageFailure);
      return;
    }
    if (!_isCurrent(generation)) return;
    AppLoginResponse candidate;
    try {
      candidate = await _api.login(email, password);
    } on AppAuthFailure catch (failure) {
      _quarantined = failure.outcomeUnknown;
      _publish(
        generation,
        failure.outcomeUnknown
            ? AppSessionPhase.pending
            : AppSessionPhase.signedOut,
        failure: failure,
      );
      return;
    } catch (_) {
      _quarantined = true;
      _publish(generation, AppSessionPhase.pending, failure: _protocolFailure);
      return;
    }
    if (!_isCurrent(generation)) {
      await _rejectCandidate(generation, candidate.token);
      return;
    }
    if (_normalizedEmail(email) != candidate.email) {
      await _rejectCandidate(
        generation,
        candidate.token,
        failure: _protocolFailure,
      );
      return;
    }
    if (!candidate.expiresAt.isAfter(_now())) {
      await _rejectCandidate(
        generation,
        candidate.token,
        failure: const AppAuthFailure(AppAuthFailureKind.sessionExpired),
      );
      return;
    }
    try {
      await _store.writeSession(
        StoredSessionCredential(
          token: candidate.token,
          expiresAt: candidate.expiresAt,
        ),
      );
    } catch (_) {
      // Write có thể đã lưu trước mất ACK; không đọc token đó để vượt quarantine.
      await _rejectCandidate(generation, candidate.token, storageFailure: true);
      return;
    }
    if (!_isCurrent(generation)) {
      await _rejectCandidate(generation, candidate.token);
      return;
    }
    FullSessionProfile? profile;
    if (!candidate.limited) {
      try {
        profile = await _api.getProfile(candidate.token);
        if (profile.userId != candidate.userId ||
            profile.email != candidate.email) {
          throw _protocolFailure;
        }
      } on AppAuthFailure catch (failure) {
        await _rejectCandidate(generation, candidate.token, failure: failure);
        return;
      } catch (_) {
        await _rejectCandidate(
          generation,
          candidate.token,
          failure: _protocolFailure,
        );
        return;
      }
    }
    // Kiểm fresh sau write/profile ACK; limited không có /me để phát hiện expiry thay client.
    if (!_isCurrent(generation) || !candidate.expiresAt.isAfter(_now())) {
      await _rejectCandidate(
        generation,
        candidate.token,
        failure: const AppAuthFailure(AppAuthFailureKind.sessionExpired),
      );
      return;
    }
    _token = candidate.token;
    _identity = (candidate.userId, candidate.email);
    _sessionExpiresAt = candidate.expiresAt;
    _publish(
      generation,
      candidate.limited ? AppSessionPhase.limited : AppSessionPhase.full,
      profile: profile,
    );
  }

  /// Restore ưu tiên outbox trước active token để restart không mở lại account đang logout.
  /// Input
  /// Param: generation — intent restore hiện hành.
  /// Param: preserveLogoutIntent — lifecycle không thay action recover/retry logout chủ động.
  /// Param: beginLogoutRetryCycle — startup/resume/recovery mở chu kỳ retry bounded mới.
  Future<void> _restore(
    int generation, {
    bool preserveLogoutIntent = true,
    bool beginLogoutRetryCycle = false,
  }) async {
    PendingLogoutIntent? pendingLogout;
    try {
      pendingLogout = await _store.readLogoutIntent();
    } catch (_) {
      _quarantined = true;
      _publish(generation, AppSessionPhase.storageFailure);
      return;
    }
    if (!_isCurrent(generation)) return;
    if (pendingLogout != null) {
      if (_logoutPending && _logoutServerResolved) {
        // Giữ ACK terminal trong cùng tiến trình để recovery chỉ retry xóa outbox, không gọi revoke lần nữa.
        await _completePendingLogout(generation);
        return;
      }
      _logoutServerResolved = false;
      await _processPendingLogout(
        generation,
        pendingLogout,
        beginRetryCycle: beginLogoutRetryCycle,
      );
      return;
    }
    if (_logoutPending && _logoutServerResolved && _token == null) {
      // Terminal server proof đã có; nếu outbox absent sau lost delete ACK thì có thể mở login an toàn.
      _logoutPending = false;
      _logoutServerResolved = false;
      _passwordPending = false;
      _quarantined = false;
      _publish(generation, AppSessionPhase.signedOut);
      return;
    }
    if (_logoutPending && _token != null) {
      // Write ACK của outbox thất bại/không rõ; giữ token private trong RAM để recovery thử ghi lại.
      await _logout(generation);
      return;
    }
    if (_logoutPending) {
      _quarantined = true;
      _publish(generation, AppSessionPhase.pending, failure: _protocolFailure);
      return;
    }
    if (_quarantined) {
      await _clearQuarantine(generation);
      return;
    }
    StoredSessionCredential? stored;
    try {
      stored = await _store.readSession();
    } catch (_) {
      _quarantined = true;
      _publish(generation, AppSessionPhase.storageFailure);
      return;
    }
    if (!_isCurrent(generation)) return;
    if (stored == null &&
        (_logoutPending || _passwordPending) &&
        _token != null) {
      // Key biến mất không chứng minh server revoke; giữ token RAM để user retry đúng logout.
      _quarantined = true;
      _publish(generation, AppSessionPhase.storageFailure);
      return;
    }
    if (stored == null) {
      _token = null;
      _identity = null;
      _sessionExpiresAt = null;
      _logoutPending = false;
      _logoutServerResolved = false;
      _publish(generation, AppSessionPhase.signedOut);
      return;
    }
    final token = stored.token;
    final bearerMatch = _storedBearerPattern.firstMatch(token);
    if (bearerMatch == null || bearerMatch.end != token.length) {
      // Adapter cũ có thể nhận token không-whitespace nhưng sai token68; không khóa vào protocol retry vô hạn.
      _quarantined = true;
      _publish(generation, AppSessionPhase.storageFailure);
      return;
    }
    if (_token != null && token != _token) {
      _quarantined = true;
      _publish(generation, AppSessionPhase.pending, failure: _protocolFailure);
      return;
    }
    _token = token;
    _sessionExpiresAt = stored.expiresAt;
    try {
      final profile = await _api.getProfile(token);
      if (!_isCurrent(generation)) return;
      if (_identity != null && _identity != (profile.userId, profile.email)) {
        _quarantined = true;
        _publish(
          generation,
          AppSessionPhase.pending,
          failure: _protocolFailure,
        );
        return;
      }
      _identity = (profile.userId, profile.email);
      if (_passwordPending || (preserveLogoutIntent && _logoutPending)) {
        // /me200 chỉ chứng minh phiên vẫn sống, không hủy ý định logout chưa rõ kết quả.
        _publish(generation, AppSessionPhase.pending);
        return;
      }
      _logoutPending = false;
      _publish(generation, AppSessionPhase.full, profile: profile);
    } on AppAuthFailure catch (failure) {
      if (!_isCurrent(generation)) return;
      switch (failure.kind) {
        case AppAuthFailureKind.passwordChangeRequired:
          if (_passwordPending || (preserveLogoutIntent && _logoutPending)) {
            _publish(generation, AppSessionPhase.pending);
          } else {
            _logoutPending = false;
            _publish(generation, AppSessionPhase.limited);
          }
        case AppAuthFailureKind.sessionExpired:
          _logoutPending = false;
          _passwordPending = false;
          await _clearQuarantine(generation);
        case AppAuthFailureKind.networkUnavailable:
          _publish(generation, AppSessionPhase.offline, failure: failure);
        default:
          _publish(generation, AppSessionPhase.pending, failure: failure);
      }
    }
  }

  /// Ghi tombstone trước khi xóa active credential rồi gửi đúng bearer đã chụp.
  /// Input
  /// Param: generation — intent logout hiện hành, dùng để publish trạng thái không secret.
  /// Side effects: khóa capability, xóa token khỏi RAM sau outbox ACK và bắt đầu revoke.
  Future<void> _logout(int generation) async {
    final token = _token!;
    final intent = PendingLogoutIntent(
      intentId: _newLogoutIntentId(),
      sessionToken: token,
      expiresAt: _sessionExpiresAt,
      attemptCount: 0,
      nextAttemptAt: _now().toUtc(),
    );
    _logoutPending = true;
    _logoutServerResolved = false;
    _quarantined = true;
    _logoutRetryTimer?.cancel();
    _logoutRetryTimer = null;
    try {
      await _store.writeLogoutIntent(intent);
    } catch (_) {
      // Chưa có write ACK thì active key không bị xóa; UI vẫn khóa và recovery giữ token RAM.
      _publish(generation, AppSessionPhase.storageFailure);
      return;
    }
    _token = null;
    _identity = null;
    _sessionExpiresAt = null;
    _passwordPending = false;
    if (!await _deleteKey()) {
      _publish(generation, AppSessionPhase.storageFailure);
      return;
    }
    await _processPendingLogout(
      generation,
      intent,
      activeSessionDeleted: true,
    );
  }

  /// Drain outbox; worker chỉ dùng bearer cho logout nhưng server vẫn coi là credential đầy quyền.
  /// Input
  /// Param: generation — generation sở hữu state và retry timer.
  /// Param: intent — outbox được đọc hoặc ghi ACK; luôn nhắm đúng phiên ban đầu.
  /// Param: beginRetryCycle — true khi startup/resume/recovery bắt đầu quota tự động mới.
  /// Param: activeSessionDeleted — true chỉ sau delete ACK trong logout đang chạy.
  Future<void> _processPendingLogout(
    int generation,
    PendingLogoutIntent intent, {
    bool beginRetryCycle = false,
    bool activeSessionDeleted = false,
  }) async {
    _logoutPending = true;
    _logoutServerResolved = false;
    _passwordPending = false;
    _quarantined = true;
    _token = null;
    _identity = null;
    _sessionExpiresAt = null;
    _logoutRetryTimer?.cancel();
    _logoutRetryTimer = null;
    if (!activeSessionDeleted && !await _deleteKey()) {
      _publish(generation, AppSessionPhase.storageFailure);
      return;
    }
    if (beginRetryCycle && intent.attemptCount != 0) {
      intent = _updatedLogoutIntent(intent, attemptCount: 0);
      try {
        await _store.writeLogoutIntent(intent);
      } catch (_) {
        _publish(generation, AppSessionPhase.storageFailure);
        return;
      }
    }
    final now = _now().toUtc();
    if (intent.nextAttemptAt.isAfter(now)) {
      _publish(generation, AppSessionPhase.pending);
      _scheduleLogoutRetry(generation, intent, now);
      return;
    }
    if (intent.attemptCount >= 5) {
      _publish(generation, AppSessionPhase.pending);
      return;
    }
    final attempt = _updatedLogoutIntent(
      intent,
      attemptCount: intent.attemptCount + 1,
      nextAttemptAt: now,
    );
    try {
      // Ghi quota trước network I/O để process death không làm mất dấu lần gửi đã nhận ownership.
      await _store.writeLogoutIntent(attempt);
    } catch (_) {
      _publish(generation, AppSessionPhase.storageFailure);
      return;
    }
    try {
      await _api.logout(attempt.sessionToken);
      await _completePendingLogout(generation);
    } on AppAuthFailure catch (failure) {
      if (failure.kind == AppAuthFailureKind.sessionExpired) {
        // 401 revoke/expired là terminal cho đúng bearer, kể cả khi server đã commit trước timeout.
        await _completePendingLogout(generation);
        return;
      }
      await _recordLogoutFailure(generation, attempt, failure);
    } catch (_) {
      await _recordLogoutFailure(generation, attempt, _protocolFailure);
    }
  }

  /// Ghi lần thử kế tiếp bền vững và chỉ tự lên lịch lỗi có thể hồi phục.
  /// Input
  /// Param: generation — generation được phép nhận state/timer hiện hành.
  /// Param: intent — attempt đã ghi trước request, không chứa account context khác.
  /// Param: failure — mã lỗi đã loại payload, dùng để chọn Retry-After hoặc full jitter.
  Future<void> _recordLogoutFailure(
    int generation,
    PendingLogoutIntent intent,
    AppAuthFailure failure,
  ) async {
    final retryable =
        failure.kind == AppAuthFailureKind.networkUnavailable ||
        failure.kind == AppAuthFailureKind.unavailable ||
        failure.kind == AppAuthFailureKind.rateLimited ||
        failure.outcomeUnknown;
    final delaySeconds = failure.kind == AppAuthFailureKind.rateLimited
        ? failure.retryAfterSeconds
        : null;
    final waitSeconds = delaySeconds ?? _fullJitterSeconds(intent.attemptCount);
    final now = _now().toUtc();
    final scheduled = _updatedLogoutIntent(
      intent,
      nextAttemptAt: now.add(Duration(seconds: waitSeconds)),
    );
    try {
      await _store.writeLogoutIntent(scheduled);
    } catch (_) {
      _publish(generation, AppSessionPhase.storageFailure, failure: failure);
      return;
    }
    _publish(generation, AppSessionPhase.pending, failure: failure);
    if (retryable && intent.attemptCount < 5) {
      _scheduleLogoutRetry(generation, scheduled, now);
    }
  }

  /// Xóa tombstone sau server terminal; active key đã được xóa trước POST và ACK xác nhận.
  /// Input
  /// Param: generation — logout intent có server resolution terminal.
  Future<void> _completePendingLogout(int generation) async {
    // Server terminal và active-key delete đã ACK; lost outbox delete ACK cần recovery riêng.
    _logoutServerResolved = true;
    try {
      await _store.deleteLogoutIntent();
    } catch (_) {
      _publish(generation, AppSessionPhase.storageFailure);
      return;
    }
    _logoutPending = false;
    _logoutServerResolved = false;
    _passwordPending = false;
    _quarantined = false;
    _token = null;
    _identity = null;
    _sessionExpiresAt = null;
    _logoutRetryTimer?.cancel();
    _logoutRetryTimer = null;
    _publish(generation, AppSessionPhase.signedOut);
  }

  /// Lên lịch retry đúng thời điểm persisted, tối đa năm lần tự động trong một chu kỳ.
  /// Input
  /// Param: generation — generation mà timer không được vượt qua khi callback tới muộn.
  /// Param: intent — retry record đã ghi bền vững.
  /// Param: now — clock hiện tại dùng tính khoảng chờ, không dùng để xóa intent hết hạn.
  void _scheduleLogoutRetry(
    int generation,
    PendingLogoutIntent intent,
    DateTime now,
  ) {
    if (!_isCurrent(generation) || intent.attemptCount >= 5) return;
    _logoutRetryTimer?.cancel();
    final delay = intent.nextAttemptAt.difference(now);
    // Timer được đánh thức theo lát tối đa một ngày, nhưng worker luôn tái kiểm Retry-After trước POST.
    final boundedDelay = delay > const Duration(days: 1)
        ? const Duration(days: 1)
        : delay;
    _logoutRetryTimer = _retryTimerFactory(
      boundedDelay.isNegative ? Duration.zero : boundedDelay,
      _runScheduledLogoutRetry,
    );
  }

  /// Bắt đầu timer retry sau khi intent cũ kết thúc và lifecycle còn ở foreground.
  void _runScheduledLogoutRetry() {
    _logoutRetryTimer = null;
    if (!_canStart || !_logoutPending) return;
    _start(
      AppSessionPhase.pending,
      /// Callback timer đọc lại durable state để không dùng snapshot đã bị thay thế.
      /// Input
      /// Param: generation — generation mới chỉ của worker retry hiện hành.
      (generation) async {
        PendingLogoutIntent? intent;
        try {
          intent = await _store.readLogoutIntent();
        } catch (_) {
          _quarantined = true;
          _publish(generation, AppSessionPhase.storageFailure);
          return;
        }
        if (!_isCurrent(generation)) return;
        if (intent == null) {
          _quarantined = true;
          _publish(generation, AppSessionPhase.storageFailure);
          return;
        }
        await _processPendingLogout(generation, intent);
      },
    );
  }

  /// Tạo thời gian chờ full jitter tăng dần, chặn trần tại 60 giây theo OQ-LOGOUT-003.
  /// Input
  /// Param: attemptCount — lần gửi đã ghi bền vững, bắt đầu từ một.
  /// Output: số giây trong khoảng 1..min(2^(attemptCount-1), 60).
  int _fullJitterSeconds(int attemptCount) {
    final exponent = attemptCount <= 1 ? 0 : attemptCount - 1;
    final ceiling = exponent >= 6 ? 60 : 1 << exponent;
    return Random().nextInt(ceiling) + 1;
  }

  /// Sao chép retry metadata mà vẫn giữ nguyên intent/token/expiry ban đầu.
  /// Input
  /// Param: intent — record hiện hành đã được đọc từ secure outbox.
  /// Param: attemptCount — counter mới nếu bắt đầu chu kỳ hoặc ghi attempt.
  /// Param: nextAttemptAt — thời điểm retry mới; mặc định giữ lịch hiện tại.
  /// Output: record bất biến dùng cho lần ghi secure tiếp theo.
  PendingLogoutIntent _updatedLogoutIntent(
    PendingLogoutIntent intent, {
    int? attemptCount,
    DateTime? nextAttemptAt,
  }) => PendingLogoutIntent(
    intentId: intent.intentId,
    sessionToken: intent.sessionToken,
    expiresAt: intent.expiresAt,
    attemptCount: attemptCount ?? intent.attemptCount,
    nextAttemptAt: nextAttemptAt ?? intent.nextAttemptAt,
  );

  /// Sinh id local duy nhất trong tiến trình mà không cấp authority hoặc chứa account data.
  /// Output: id ASCII hợp lệ cho outbox; bearer không tham gia vào id.
  String _newLogoutIntentId() =>
      'logout-${_now().microsecondsSinceEpoch}-${_generation + 1}';

  /// Candidate thất bại/stale không trở thành stable token dù storage đã ghi thành công.
  /// Input
  /// Param: generation — intent cũ, chỉ dùng để quyết định publish còn hợp lệ.
  /// Param: token — chính candidate cần revoke, không đọc token khác từ store.
  /// Param: failure — lỗi đã khử secret để giải thích vì sao không admission.
  /// Param: storageFailure — true khi write ACK lỗi, không giả rollback.
  Future<void> _rejectCandidate(
    int generation,
    String token, {
    AppAuthFailure? failure,
    bool storageFailure = false,
  }) async {
    _quarantined = true;
    _orphanToken = token;
    final deleted = await _deleteKey();
    await _revokeOrphan();
    if (deleted) _quarantined = false;
    _publish(
      generation,
      storageFailure || !deleted
          ? AppSessionPhase.storageFailure
          : AppSessionPhase.pending,
      failure: failure,
    );
  }

  /// Chỉ delete ACK sau server resolution khi cần mới mở signedOut; không read lại để vượt quarantine.
  /// Input
  /// Param: generation — intent cleanup/recovery/logout đang sở hữu store.
  Future<void> _clearQuarantine(int generation) async {
    if ((_logoutPending || _passwordPending) && _token != null) {
      // Không dùng delete ACK thay server204/401 hoặc bỏ token cần retry khi logout còn unknown.
      _publish(generation, AppSessionPhase.pending);
      return;
    }
    _quarantined = true;
    final deleted = await _deleteKey();
    await _revokeOrphan();
    if (!deleted) {
      _publish(generation, AppSessionPhase.storageFailure);
      return;
    }
    _token = null;
    _identity = null;
    _sessionExpiresAt = null;
    _logoutPending = false;
    _logoutServerResolved = false;
    _passwordPending = false;
    _quarantined = false;
    _publish(generation, AppSessionPhase.signedOut);
  }

  /// Xóa active-session key và giữ ownership tới ACK thật, không cho write mới chen vào.
  /// Output: true chỉ khi plugin trả ACK; không giữ exception native hoặc giả deleteAll.
  Future<bool> _deleteKey() async {
    try {
      await _store.deleteSession();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Revoke best effort đúng candidate trong RAM; không tự replay khi response unknown.
  Future<void> _revokeOrphan() async {
    final token = _orphanToken;
    _orphanToken = null;
    if (token == null) return;
    try {
      await _api.logout(token);
    } catch (_) {
      // Local cleanup không chứng minh server revoke; không log token hoặc báo server success.
    }
  }

  /// Chờ native/network intent cũ drain trước khi bỏ lifecycle lock và kiểm server lại.
  /// Input
  /// Side effects: chỉ resume chủ động mới cập nhật generation muốn khôi phục, không tự mở sau suspend.
  Future<void> _resumeAfterDrain() async {
    try {
      while (!_disposed) {
        final requestedGeneration = _requestedResumeGeneration;
        await _active;
        if (_disposed) return;
        if (requestedGeneration != _generation) {
          // Có resume mới thì drain xong chuyển sang generation đó; chỉ suspend thì vẫn khóa.
          if (_requestedResumeGeneration != requestedGeneration) continue;
          return;
        }
        _suspended = false;
        await _start(
          AppSessionPhase.checking,

          /// Resume kiểm server nhưng không tự hủy ý định logout đang pending.
          /// Input
          /// Param: generation — restore mới sau khi intent cũ đã drain.
          (generation) => _restore(
            generation,
            preserveLogoutIntent: true,
            beginLogoutRetryCycle: true,
          ),
        );
        if (_requestedResumeGeneration == requestedGeneration) return;
      }
    } finally {
      _requestedResumeGeneration = null;
      _resumeFuture = null;
    }
  }

  /// Đóng stream sau cleanup của intent đã sở hữu, không tự revoke stable session khi app chết.
  Future<void> _closeAfterDrain() async {
    await _active;
    await _resumeFuture;
    await _events.close();
  }

  /// Cập nhật snapshot không secret chỉ khi generation vẫn hiện hành.
  /// Input
  /// Param: generation — intent được phép publish.
  /// Param: phase — phase mới, profile chỉ cho full.
  /// Param: profile — kết quả server đã đối chiếu identity khi full.
  /// Param: failure — lỗi typed không raw payload/native detail.
  /// Param: workspaces — list summary tích lũy chỉ publish khi full, copy immutable trong state.
  /// Param: nextWorkspaceCursor — cursor opaque của page tiếp theo, không persist.
  /// Param: workspacesLoaded — phân biệt chưa tải với confirmed empty.
  /// Param: selectedWorkspace — detail operational đã recheck server và đúng id.
  void _publish(
    int generation,
    AppSessionPhase phase, {
    FullSessionProfile? profile,
    AppAuthFailure? failure,
    List<AvailableWorkspaceSummary> workspaces = const [],
    String? nextWorkspaceCursor,
    bool workspacesLoaded = false,
    WorkspaceAccessDetail? selectedWorkspace,
  }) {
    if (!_isCurrent(generation)) return;
    _state = AppSessionState(
      phase: phase,
      generation: generation,
      profile: phase == AppSessionPhase.full ? profile : null,
      failure: failure,
      workspaces: phase == AppSessionPhase.full ? workspaces : const [],
      nextWorkspaceCursor: phase == AppSessionPhase.full
          ? nextWorkspaceCursor
          : null,
      workspacesLoaded: phase == AppSessionPhase.full && workspacesLoaded,
      selectedWorkspace: phase == AppSessionPhase.full
          ? selectedWorkspace
          : null,
    );
    _events.add(_state);
  }
}

/// Dùng timer của Dart cho retry production; repository có thể thay clock scheduler trong test.
/// Input
/// Param: duration — khoảng chờ đã được kiểm bằng `nextAttemptAt`.
/// Param: callback — worker retry sẽ đọc lại secure outbox trước POST.
/// Output: Timer có thể hủy khi suspend/dispose.
Timer _createLogoutRetryTimer(Duration duration, void Function() callback) =>
    Timer(duration, callback);

const _protocolFailure = AppAuthFailure(
  AppAuthFailureKind.protocol,
  outcomeUnknown: true,
);

// Boundary secure storage cũng phải đúng token68 như transport; full-match chống newline cuối chuỗi.
final _storedBearerPattern = RegExp(r'^[A-Za-z0-9._~+/\-]+=*$');

/// So identity giống provider: chỉ trim whitespace ASCII và hạ chữ hoa ASCII.
/// Input
/// Param: value — email gốc; không dùng hàm này để sửa password hoặc wire request.
/// Output: null khi có Unicode; không gộp dot/+tag hoặc normalize địa chỉ thành account khác.
String? _normalizedEmail(String value) {
  if (value.codeUnits.any(
    /// Input
    /// Param: unit — code unit email; Output: chặn normalization Unicode khác provider.
    (unit) => unit > 127,
  ))
    return null;
  // Rust is_ascii_whitespace loại vertical tab 0B; không mở rộng thành Dart.trim/POSIX whitespace.
  // https://doc.rust-lang.org/std/primitive.char.html#method.is_ascii_whitespace
  return value
      .replaceAll(
        RegExp(r'^[\x09\x0a\x0c\x0d\x20]+|[\x09\x0a\x0c\x0d\x20]+$'),
        '',
      )
      .toLowerCase();
}
