import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../data/app_auth_failure.dart';
import '../data/app_session_repository.dart';
import '../data/app_session_state.dart';
import '../../workspaces/presentation/workspace_selection_state.dart';

/// Trang nghiệp vụ; không dùng route làm bằng chứng authorization server.
enum AppAuthPage { loading, login, password, workspaces, summary, recovery }

/// Ngữ cảnh intent để lỗi của operation trước không bị gắn vào form khác.
enum AppAuthIntent {
  none,
  restore,
  login,
  password,
  list,
  more,
  select,
  recover,
  logout,
  resume,
}

/// Điều phối navigation/intent; repository vẫn là chủ duy nhất của token/store và admission.
final class AppAuthCoordinator extends ChangeNotifier {
  /// Nhận một repository sống suốt lifetime và clock không chứa authority.
  /// Input
  /// Param: repository — chủ sở hữu API/store, coordinator không cầm bearer.
  /// Param: elapsedSeconds — clock monotonic phục vụ cooldown, null dùng Stopwatch.
  AppAuthCoordinator({
    required AppSessionRepository repository,
    int Function()? elapsedSeconds,
  }) : _repository = repository {
    _stopwatch.start();
    _elapsedSeconds = elapsedSeconds ?? _readElapsedSeconds;
    _subscription = _repository.changes.listen(_receive);
  }
  final AppSessionRepository _repository;
  final _stopwatch = Stopwatch();
  late final int Function() _elapsedSeconds;
  late final StreamSubscription<AppSessionState> _subscription;
  AppAuthIntent _intent = AppAuthIntent.none;
  AppAuthIntent _cooldownIntent = AppAuthIntent.none;
  int _generation = 0;
  int _lifecycleVersion = 0;
  int _resumeRevision = 0;
  int _cooldownSeconds = 0;
  int _cooldownStartedAt = 0;
  bool _initialized = false;
  bool _working = false;
  bool _suspended = false;
  bool _disposed = false;
  bool _passwordOpened = false;
  Timer? _timer;
  Future<void>? _resumeFuture;
  Future<void>? _latestRepositoryResume;
  Future<void>? _closing;

  /// Output: snapshot hiện tại không có secret, không replay event cũ.
  AppSessionState get session => _repository.state;

  /// Output: route chỉ từ snapshot hiện hành; busy/lifecycle luôn che protected state ngay.
  AppAuthPage get page {
    if (_disposed ||
        _suspended ||
        _working ||
        _repository.busy ||
        _resumeFuture != null)
      return AppAuthPage.loading;
    return switch (session.phase) {
      AppSessionPhase.signedOut => AppAuthPage.login,
      AppSessionPhase.limited => AppAuthPage.password,
      AppSessionPhase.full =>
        _passwordOpened
            ? AppAuthPage.password
            : session.selectedWorkspace != null
            ? AppAuthPage.summary
            : AppAuthPage.workspaces,
      AppSessionPhase.pending ||
      AppSessionPhase.storageFailure ||
      AppSessionPhase.offline => AppAuthPage.recovery,
      _ => AppAuthPage.loading,
    };
  }

  /// Output: epoch callback của presentation.
  int get generation => _generation;

  /// Output: intent hiện hành không chứa input.
  AppAuthIntent get intent => _intent;

  /// Output: true khi repository đang giữ quy trình đăng xuất chưa hoàn tất qua các bước đối soát hoặc resume.
  bool get logoutPending => _repository.logoutPending;

  /// Output: chỉ hiển thị logout khi repository có intent hợp lệ, không tiết lộ bearer.
  bool get canLogout =>
      !_disposed &&
      !_suspended &&
      !_working &&
      _resumeFuture == null &&
      _repository.canLogout;

  /// Output: số giây chưa được gửi mutation mới.
  int get retryAfterSeconds => switch (page) {
    AppAuthPage.login => _remainingFor(AppAuthIntent.login),
    AppAuthPage.password => _remainingFor(AppAuthIntent.password),
    _ => 0,
  };

  /// Khôi phục đúng một lần; không nhận snapshot đang có trong store làm quyền.
  Future<void> initialize() {
    if (_initialized || _disposed || _suspended) return Future<void>.value();
    _initialized = true;
    return _run(AppAuthIntent.restore, _repository.restore);
  }

  /// Gửi credential chỉ sau kiểm epoch/page/cooldown ở thời điểm event thực sự tới.
  /// Input
  /// Param: email — input login một lần.
  /// Param: password — secret không lưu field.
  /// Param: expectedGeneration — epoch gắn callback đã render.
  Future<void> login(
    String email,
    String password, {
    required int expectedGeneration,
  }) {
    if (!_accept(expectedGeneration, {AppAuthPage.login}) ||
        _remainingFor(AppAuthIntent.login) > 0)
      return Future<void>.value();
    _passwordOpened = false;
    return _run(
      AppAuthIntent.login,

      /// Input chỉ sống trong Future của một intent đã reserve, không queue/replay.
      () => _repository.login(email, password),
    );
  }

  /// Mở password của full session chủ động; limited đã bị route vào đây bởi repository.
  /// Input
  /// Param: expectedGeneration — epoch của nút mở form password.
  void openPassword({required int expectedGeneration}) {
    if (!_accept(expectedGeneration, {
          AppAuthPage.workspaces,
          AppAuthPage.summary,
        }) ||
        session.phase != AppSessionPhase.full)
      return;
    _passwordOpened = true;
    _intent = AppAuthIntent.none;
    _emit();
  }

  /// Password giữ nguyên chuỗi; unknown chỉ đi recovery, không dùng GET200 tự mở lại form.
  /// Input
  /// Param: currentPassword — secret cũ một lần.
  /// Param: newPassword — secret mới một lần.
  /// Param: expectedGeneration — epoch của form hiện hành.
  Future<void> changePassword(
    String currentPassword,
    String newPassword, {
    required int expectedGeneration,
  }) {
    if (!_accept(expectedGeneration, {AppAuthPage.password}) ||
        _remainingFor(AppAuthIntent.password) > 0)
      return Future<void>.value();
    return _run(
      AppAuthIntent.password,

      /// Hai secret chỉ chuyển vào repository một lần sau admission presentation.
      () => _repository.changePassword(currentPassword, newPassword),
    );
  }

  /// So row hiện tại trước server recheck; revision client không là authority của workspace.
  /// Input
  /// Param: option — row đã render cần kiểm lại revision/status.
  /// Param: expectedGeneration — epoch của picker hiện hành.
  Future<void> selectWorkspace(
    WorkspaceOption option, {
    required int expectedGeneration,
  }) {
    if (!_accept(expectedGeneration, {AppAuthPage.workspaces}) ||
        !session.workspacesLoaded ||
        session.failure != null ||
        option.status != WorkspaceStatus.active)
      return Future<void>.value();
    for (final current in session.workspaces) {
      if (current.id == option.id &&
          current.revision == option.revision &&
          current.status == 'ACTIVE') {
        return _run(
          AppAuthIntent.select,

          /// Id vẫn phải GET detail đúng bearer/identity trước selected route.
          () => _repository.selectWorkspace(current.id),
        );
      }
    }
    return Future<void>.value();
  }

  /// Tải lại cũng là đường back từ summary/full password; xóa selection bằng request mới.
  /// Input
  /// Param: expectedGeneration — epoch của nút tải lại/back.
  Future<void> refreshWorkspaces({required int expectedGeneration}) {
    if (!_accept(expectedGeneration, {
          AppAuthPage.workspaces,
          AppAuthPage.summary,
          AppAuthPage.password,
        }) ||
        session.phase != AppSessionPhase.full)
      return Future<void>.value();
    _passwordOpened = false;
    return _run(AppAuthIntent.list, _repository.loadWorkspaces);
  }

  /// Chỉ cursor hiện tại trong repository được tải thêm; không nhận cursor qua widget.
  /// Input
  /// Param: expectedGeneration — epoch của nút tải thêm.
  Future<void> loadMore({required int expectedGeneration}) {
    if (!_accept(expectedGeneration, {AppAuthPage.workspaces}) ||
        !session.workspacesLoaded ||
        session.failure != null ||
        session.nextWorkspaceCursor == null)
      return Future<void>.value();
    return _run(
      AppAuthIntent.more,

      /// Không tự retry hoặc suy cursor rỗng thành hết trang.
      () => _repository.loadWorkspaces(loadMore: true),
    );
  }

  /// Đối soát riêng cả known denial của password; repository giữ unknown/quarantine kể cả server200.
  /// Input
  /// Param: expectedGeneration — epoch của nút đối soát riêng.
  Future<void> recover({required int expectedGeneration}) {
    if (!_accept(expectedGeneration, {
          AppAuthPage.recovery,
          AppAuthPage.login,
          AppAuthPage.password,
        }) ||
        (page == AppAuthPage.password && session.failure == null))
      return Future<void>.value();
    return _run(AppAuthIntent.recover, _repository.recover);
  }

  /// Logout chủ động; chỉ server resolution và native delete ACK mới có signedOut.
  /// Input
  /// Param: expectedGeneration — epoch của nút logout chủ động.
  Future<void> logout({required int expectedGeneration}) {
    if (!_accept(expectedGeneration, {
      AppAuthPage.password,
      AppAuthPage.workspaces,
      AppAuthPage.summary,
      AppAuthPage.recovery,
    }))
      return Future<void>.value();
    return _run(AppAuthIntent.logout, _repository.logout);
  }

  /// Khóa đồng bộ trước stream notification, vô hiệu callback và completion của foreground cũ.
  void suspend() {
    if (_disposed || _suspended) return;
    _suspended = true;
    _lifecycleVersion++;
    _repository.suspend();
    _emit();
  }

  /// Đăng ký latest resume trước shared wrapper; không làm mất chu kỳ mới giữa bootstrap cũ.
  /// Output: Future drain/recheck/bootstrap, không replay login/password/logout.
  Future<void> resume() {
    if (_disposed || !_suspended) return _resumeFuture ?? Future<void>.value();
    _initialized = true;
    _suspended = false;
    _resumeRevision++;
    _latestRepositoryResume = _repository.resume();
    _intent = AppAuthIntent.resume;
    _emit();
    return _resumeFuture ??= _drainResumes();
  }

  /// Đợi mọi latest resume và bootstrap; revision check sau GET ngăn wrapper kết thúc quá sớm.
  Future<void> _drainResumes() async {
    try {
      while (!_disposed) {
        final revision = _resumeRevision;
        await _latestRepositoryResume;
        if (_disposed || _suspended) return;
        if (revision != _resumeRevision) continue;
        await _bootstrap();
        if (revision == _resumeRevision) return;
      }
    } finally {
      _resumeFuture = null;
      _emit();
    }
  }

  /// Giữ busy trước notify; stale lifecycle không được bootstrap sau intent cũ hoàn tất.
  /// Input
  /// Param: intent — ngữ cảnh an toàn, không credential.
  /// Param: operation — một workflow repository đã được admission, không queue intent mới.
  Future<void> _run(
    AppAuthIntent intent,
    Future<void> Function() operation,
  ) async {
    if (_disposed ||
        _suspended ||
        _working ||
        _repository.busy ||
        _resumeFuture != null)
      return;
    _working = true;
    _intent = intent;
    final lifecycleVersion = _lifecycleVersion;
    _emit();
    try {
      if (_disposed || _suspended || lifecycleVersion != _lifecycleVersion)
        return;
      await operation();
      if (_disposed || _suspended || lifecycleVersion != _lifecycleVersion)
        return;
      _startCooldown(intent);
      if (session.phase == AppSessionPhase.signedOut) _passwordOpened = false;
      await _bootstrap();
    } finally {
      _working = false;
      _emit();
    }
  }

  /// Chỉ success full chưa tải được bootstrap; lỗi/limited/unknown không tự retry hoặc auto-select.
  Future<void> _bootstrap() async {
    if (_disposed ||
        _suspended ||
        _repository.busy ||
        _passwordOpened ||
        session.phase != AppSessionPhase.full ||
        session.failure != null ||
        session.workspacesLoaded)
      return;
    _intent = AppAuthIntent.list;
    await _repository.loadWorkspaces();
  }

  /// Kiểm quyền phát intent từ view epoch hiện hành, không chỉ disabled state lúc render.
  /// Input
  /// Param: expectedGeneration — epoch callback đã chụp, không lấy epoch mới khi chạy callback cũ.
  /// Param: pages — các trang cho phép action cụ thể; repository vẫn kiểm quyền thực.
  /// Output: false khi stale/busy/lifecycle hoặc khác trang.
  bool _accept(int expectedGeneration, Set<AppAuthPage> pages) =>
      !_disposed &&
      !_suspended &&
      !_working &&
      !_repository.busy &&
      _resumeFuture == null &&
      expectedGeneration == _generation &&
      pages.contains(page);

  /// Bắt đầu cooldown đúng operation từ typed429; không scale int untrusted thành milliseconds.
  /// Input
  /// Param: intent — chỉ login/password mới có submit cooldown presentation.
  void _startCooldown(AppAuthIntent intent) {
    final failure = session.failure;
    if ((intent != AppAuthIntent.login && intent != AppAuthIntent.password) ||
        failure?.kind != AppAuthFailureKind.rateLimited ||
        failure?.retryAfterSeconds == null)
      return;
    _cooldownIntent = intent;
    _cooldownSeconds = failure!.retryAfterSeconds!;
    _cooldownStartedAt = _elapsedSeconds();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);
  }

  /// Tính lại từ monotonic clock ở mọi submit, không tin lịch callback Timer luôn đúng hạn.
  /// Input
  /// Param: intent — operation đang yêu cầu gửi mới.
  /// Output: số giây còn lại; clock không được dùng làm server authorization hoặc reset limiter.
  int _remainingFor(AppAuthIntent intent) => intent != _cooldownIntent
      ? 0
      : math.max(
          0,
          _cooldownSeconds -
              math.max(0, _elapsedSeconds() - _cooldownStartedAt),
        );

  /// Chỉ cập nhật nhãn, không đổi epoch/input hoặc gọi lại mutation khi hết thời gian.
  /// Input
  /// Param: timer — timer riêng coordinator, hủy khi cooldown xong/dispose.
  void _tick(Timer timer) {
    if (_disposed || _remainingFor(_cooldownIntent) == 0) timer.cancel();
    if (!_disposed) notifyListeners();
  }

  /// Output: thời gian monotonic từ Stopwatch, không đọc clock walltime hoặc environment.
  int _readElapsedSeconds() => _stopwatch.elapsed.inSeconds;

  /// Stream chỉ đánh dấu UI cần đọc lại current state, không giữ/publish snapshot stale hay auto GET.
  /// Input
  /// Param: snapshot — event repository đã lọc, vẫn đối chiếu current object trước notify.
  void _receive(AppSessionState snapshot) {
    if (!_disposed && identical(snapshot, session)) _emit();
  }

  /// Mỗi chuyển trạng thái logic vô hiệu callback cũ; timer chỉ notify để không reset form mỗi giây.
  void _emit() {
    if (_disposed) return;
    _generation++;
    notifyListeners();
  }

  /// Chờ cleanup của repository khi host/test cần ACK; dispose không giả đã hủy native Future.
  /// Output: drain hoàn tất sau tất cả effect đang sở hữu.
  Future<void> close() {
    dispose();
    return _closing!;
  }

  /// Khóa đồng bộ, gỡ listener/timer và bắt đầu drain đúng repository của lifetime hiện tại.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _stopwatch.stop();
    final drain = _repository.dispose();
    _closing = _closeAfterDrain(drain);
    super.dispose();
  }

  /// Không thả ownership trước late mutation/native completion, không gửi logout tự động.
  /// Input
  /// Param: drain — ACK của repository.dispose đã invalidate đồng bộ trước khi await.
  Future<void> _closeAfterDrain(Future<void> drain) async {
    await _subscription.cancel();
    await drain;
    await _resumeFuture;
  }
}
