import 'dart:async';

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
  /// Param: workspaceApi — capability thật chỉ khi composition đã nối; không tự mock thành công.
  /// Param: passwordApi — capability password riêng để limited không có workspace API mặc định.
  AppSessionRepository({
    required AppAuthApi api,
    required SessionTokenStore tokenStore,
    DateTime Function()? now,
    AppWorkspaceApi? workspaceApi,
    AppPasswordApi? passwordApi,
  }) : _api = api,
       _store = tokenStore,
       _now = now ?? DateTime.now,
       _workspaceApi = workspaceApi,
       _passwordApi = passwordApi;

  final AppAuthApi _api;
  final SessionTokenStore _store;
  final DateTime Function() _now;
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
  bool _passwordPending = false;
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

  /// Kiểm store/server trước admission; giữ pending logout cho tới server proof hoặc recover chủ động.
  Future<void> restore() {
    if (!_canStart) return Future<void>.value();
    return _start(AppSessionPhase.checking, _restore);
  }

  /// Đối soát chủ động hoặc cleanup quarantine; không phát lại login/password.
  Future<void> recover() {
    if (!_canStart) return Future<void>.value();
    return _start(
      AppSessionPhase.checking,

      /// Quarantine và intent không có token chỉ được cleanup, không đọc nhận account cũ.
      /// Input
      /// Param: generation — intent recovery chủ động của người dùng.
      (generation) => _quarantined || _token == null
          ? _clearQuarantine(generation)
          : _restore(generation, preserveLogoutIntent: false),
    );
  }

  /// Retry chủ động đúng private token cả khi pending logout gặp quarantine; chờ server proof rồi delete ACK.
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

  /// Khóa UI ngay, làm stale intent trước đó và vẫn chờ I/O sở hữu hoàn tất.
  void suspend() {
    if (_disposed) return;
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

  /// Chặn publish muộn, drain I/O sở hữu và đóng stream; không xóa stable session khi app dừng.
  Future<void> dispose() {
    if (_disposeFuture != null) return _disposeFuture!;
    _disposed = true;
    _suspended = true;
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
      await _store.write(candidate.token);
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
    _publish(
      generation,
      candidate.limited ? AppSessionPhase.limited : AppSessionPhase.full,
      profile: profile,
    );
  }

  /// Restore không lấy quyền từ cache; quarantine có precedence trước mọi read/profile.
  /// Input
  /// Param: generation — intent restore hiện hành.
  /// Param: preserveLogoutIntent — lifecycle không thay action recover/retry logout chủ động.
  Future<void> _restore(
    int generation, {
    bool preserveLogoutIntent = true,
  }) async {
    if (_quarantined) {
      await _clearQuarantine(generation);
      return;
    }
    String? stored;
    try {
      stored = await _store.read();
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
      _logoutPending = false;
      _publish(generation, AppSessionPhase.signedOut);
      return;
    }
    final bearerMatch = _storedBearerPattern.firstMatch(stored);
    if (bearerMatch == null || bearerMatch.end != stored.length) {
      // Adapter cũ có thể nhận token không-whitespace nhưng sai token68; không khóa vào protocol retry vô hạn.
      _quarantined = true;
      _publish(generation, AppSessionPhase.storageFailure);
      return;
    }
    if (_token != null && stored != _token) {
      _quarantined = true;
      _publish(generation, AppSessionPhase.pending, failure: _protocolFailure);
      return;
    }
    _token = stored;
    try {
      final profile = await _api.getProfile(stored);
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

  /// Thu hồi token đã chụp trước await; không thay bằng token của account/intent khác.
  /// Input
  /// Param: generation — intent logout hiện hành.
  Future<void> _logout(int generation) async {
    final token = _token!;
    _logoutPending = true;
    try {
      await _api.logout(token);
    } on AppAuthFailure catch (failure) {
      if (failure.kind == AppAuthFailureKind.sessionExpired) {
        // 401 từ đúng token cũng là server proof phiên không còn dùng được, vẫn cần delete ACK.
        _logoutPending = false;
        _passwordPending = false;
        await _clearQuarantine(generation);
        return;
      }
      _publish(generation, AppSessionPhase.pending, failure: failure);
      return;
    }
    // Server ACK thuộc intent này vẫn cần local cleanup dù app vừa suspend.
    _logoutPending = false;
    _passwordPending = false;
    await _clearQuarantine(generation);
  }

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
    _logoutPending = false;
    _passwordPending = false;
    _quarantined = false;
    _publish(generation, AppSessionPhase.signedOut);
  }

  /// Xóa own key và giữ ownership tới ACK thật, không timeout rồi cho write mới chen vào.
  /// Output: true chỉ khi plugin trả ACK; không giữ exception native hoặc giả deleteAll.
  Future<bool> _deleteKey() async {
    try {
      await _store.delete();
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
          (generation) => _restore(generation, preserveLogoutIntent: true),
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
