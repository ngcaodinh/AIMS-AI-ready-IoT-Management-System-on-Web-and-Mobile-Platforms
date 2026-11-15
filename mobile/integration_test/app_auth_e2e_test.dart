import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show pid, HttpClient, HandshakeException;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nexa_iot/main.dart' as product;
import 'package:nexa_iot/features/auth/presentation/login_screen.dart';
import 'package:nexa_iot/features/auth/presentation/app_auth_application.dart';
import 'package:nexa_iot/features/auth/data/app_session_state.dart';
import 'package:nexa_iot/features/auth/data/session_token_store.dart';
import 'package:nexa_iot/features/auth/presentation/login_view_state.dart';
import 'package:nexa_iot/features/auth/presentation/password_change_screen.dart';
import 'package:nexa_iot/features/auth/presentation/password_change_state.dart';
import 'package:nexa_iot/features/workspaces/presentation/workspace_selection_screen.dart';
import 'package:nexa_iot/features/workspaces/presentation/workspace_selection_state.dart';

import 'support/native_membership_probe.dart';
import 'support/native_membership_scenario.dart';
import 'support/native_offline_probe.dart';
import 'support/native_offline_scenario.dart';
import 'support/native_rate_probe.dart';
import 'support/native_rate_scenario.dart';

// Chỉ enum giai đoạn test phục vụ chẩn đoán; không lưu input/UI text hoặc auth authority.
var _caseStage = 'fixture';
String _checkpointStage = '';
Completer<void>? _checkpointRelease;
String _validationObservation = 'NONE';
String _tapStage = 'NONE';
String _tapFailure = 'NONE';
String _tapHit = 'NONE';
final _rateCheckpoint = NativeRateCheckpoint();
final _ratePhaseClock = Stopwatch();
final _membershipCheckpoint = NativeMembershipCheckpoint();
final _membershipPhaseClock = Stopwatch();
final _offlinePreArmClock = Stopwatch();
final _offlinePhaseClock = Stopwatch();
final _offlineCheckpoint = NativeOfflineCheckpoint(
  elapsed: _readOfflineElapsed,
);

/// Output: native phase elapsed neo valid packet, không neo lại khi đọc status hoặc tạo gate.
Duration _readOfflineElapsed() => _offlinePhaseClock.elapsed;

/**
 * Xác minh fixture RAM và chạy main thật ở full/resume/access, giữ preflight không I/O như C0.
 * Side effects: chỉ integration target đăng ký extension debug; production main không nhận test hook.
 */
void main() {
  const phase = String.fromEnvironment(
    'AUTH_E2E_PHASE',
    defaultValue: 'preflight',
  );
  if (!kDebugMode ||
      !const [
        'preflight',
        'full',
        'response-loss',
        'resume',
        'access',
        'password',
        'password-relogin',
        'rate-limit',
        'membership-stale',
        'offline-login',
      ].contains(phase)) {
    throw StateError('INVALID_NATIVE_TEST_CONFIGURATION');
  }
  if (phase == 'offline-login') _offlinePreArmClock.start();
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final fixture = Completer<Map<String, Object?>>();
  var status = 'WAITING';
  developer.registerExtension(
    'ext.nexa_auth_test.fixture',
    /**
     * Nhận một packet RAM từ daemon SDK; không echo/log password và không admission session.
     * Input
     * Param: method — tên extension cố định do Dart VM dispatch.
     * Param: parameters — packet JSON và isolateId SDK; schema lỗi/replay chỉ nhận accepted=false.
     * Output: ACK boolean cố định, không chứa input hoặc exception.
     */
    (method, parameters) async {
      var accepted = false;
      try {
        final raw = parameters['packet'];
        if (fixture.isCompleted ||
            raw == null ||
            raw.length > 4096 ||
            parameters.keys.any(
              /**
               * Không mở channel cấu hình tùy ý ngoài packet và isolateId SDK.
               * Input
               * Param: key — khóa metadata do daemon gửi.
               */
              (key) => key != 'packet' && key != 'isolateId',
            )) {
          return developer.ServiceExtensionResponse.result(
            '{"accepted":false}',
          );
        }
        final decoded = jsonDecode(raw);
        final passwordPhase =
            phase == 'password' || phase == 'password-relogin';
        final ratePhase = phase == 'rate-limit';
        if (decoded is! Map<String, dynamic> ||
            decoded.length != (passwordPhase || ratePhase ? 5 : 4) ||
            decoded['version'] != 1 ||
            decoded['phase'] != phase ||
            (passwordPhase &&
                (decoded['newPassword'] is! String ||
                    !RegExp(r'^Aa2[0-9a-f]{32}$')
                        .hasMatch(decoded['newPassword'] as String))) ||
            (ratePhase && !validNativeRateCredentials(decoded))) {
          return developer.ServiceExtensionResponse.result(
            '{"accepted":false}',
          );
        }
        final emails = decoded['emails'];
        final password = decoded['password'];
        if (emails is! List<dynamic> ||
            emails.length != 5 ||
            emails.toSet().length != 5 ||
            emails.any(
              /**
               * Chỉ nhận identities synthetic của lab, không account thật hoặc URL do input điều khiển.
               * Input
               * Param: value — email cần kiểm kiểu/shape, không dùng làm authority.
               */
              (value) =>
                  value is! String ||
                  !RegExp(
                    r'^probe-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}-[0-4]@example\.invalid$',
                  ).hasMatch(value),
            ) ||
            password is! String ||
            (phase == 'resume'
                ? password.isNotEmpty
                : !RegExp(r'^Aa1[0-9a-f]{32}$').hasMatch(password))) {
          return developer.ServiceExtensionResponse.result(
            '{"accepted":false}',
          );
        }
        // Neo native cap từ valid packet trước complete/ACK; replay không được reset Stopwatch.
        if (ratePhase) _ratePhaseClock.start();
        if (phase == 'membership-stale') _membershipPhaseClock.start();
        if (phase == 'offline-login') {
          if (decoded['version'] is! int ||
              _offlinePreArmClock.elapsed >= const Duration(seconds: 240)) {
            return developer.ServiceExtensionResponse.result(
              '{"accepted":false}',
            );
          }
          final run = RegExp(r'^probe-([0-9a-f-]{36})-0@example\.invalid$')
              .firstMatch(emails.first as String);
          if (run == null)
            return developer.ServiceExtensionResponse.result(
              '{"accepted":false}',
            );
          for (var index = 0; index < 5; index++) {
            if (emails[index] !=
                'probe-${run.group(1)}-$index@example.invalid') {
              return developer.ServiceExtensionResponse.result(
                '{"accepted":false}',
              );
            }
          }
          _offlinePhaseClock.start();
        }
        fixture.complete(Map<String, Object?>.from(decoded));
        accepted = true;
      } on FormatException catch (_) {
        // JSON không hợp lệ không được phản chiếu raw packet/secret trong error response.
      }
      return developer.ServiceExtensionResponse.result(
        accepted ? '{"accepted":true}' : '{"accepted":false}',
      );
    },
  );
  developer.registerExtension(
    'ext.nexa_auth_test.checkpoint',
    /**
     * ACK một pause access đúng stage sau host counter oracle, không mở điều khiển sản phẩm tùy ý.
     * Input
     * Param: method — tên extension debug cố định.
     * Param: parameters — stage/isolateId SDK, không nhận URL/SQL hoặc credential.
     * Output: accepted boolean; sai schema/phase/stage hoặc replay không được release lần nữa.
     */
    (method, parameters) async {
      if (phase == 'rate-limit') {
        // Commit và status receipt dùng cùng gate monotonic; complete xảy ra trước response ACK.
        final accepted = _rateCheckpoint.acknowledge(parameters);
        return developer.ServiceExtensionResponse.result(
          accepted ? '{"accepted":true}' : '{"accepted":false}',
        );
      }
      if (phase == 'membership-stale') {
        final accepted = _membershipCheckpoint.acknowledge(parameters);
        return developer.ServiceExtensionResponse.result(
          accepted ? '{"accepted":true}' : '{"accepted":false}',
        );
      }
      if (phase == 'offline-login') {
        final accepted = _offlineCheckpoint.acknowledge(parameters);
        return developer.ServiceExtensionResponse.result(
          accepted ? '{"accepted":true}' : '{"accepted":false}',
        );
      }
      final release = _checkpointRelease;
      final accepted =
          const [
            'full',
            'access',
            'password',
            'password-relogin',
            'response-loss',
          ].contains(phase) &&
          release != null &&
          !release.isCompleted &&
          _checkpointStage.isNotEmpty &&
          parameters['stage'] == _checkpointStage &&
          parameters.keys.every(
            /**
             * Không để metadata phụ trở thành command hoặc credential channel.
             * Input
             * Param: key — khóa RPC được SDK chuyển vào extension test.
             */
            (key) => key == 'stage' || key == 'isolateId',
          );
      if (accepted) release.complete();
      return developer.ServiceExtensionResponse.result(
        accepted ? '{"accepted":true}' : '{"accepted":false}',
      );
    },
  );
  developer.registerExtension(
    'ext.nexa_auth_test.status',
    /**
     * Chỉ trả trạng thái fixed và own PID để host gắn evidence vào đúng native process.
     * Input
     * Param: method — extension status cố định.
     * Param: parameters — metadata SDK, không đọc credential từ query/status.
     * Output: trạng thái/PID của test, không password/email/token/raw failure.
     */
    (method, parameters) async => developer.ServiceExtensionResponse.result(
      jsonEncode({
        'phase': phase,
        'status': status,
        'nativeProcessId': pid,
        'caseStage': _caseStage,
        if (phase == 'rate-limit')
          ..._rateCheckpoint.receipt()
        else if (phase == 'membership-stale')
          ..._membershipCheckpoint.receipt()
        else if (phase == 'offline-login')
          ..._offlineCheckpoint.receipt()
        else
          'checkpoint': _checkpointStage,
        if (phase == 'offline-login' && !fixture.isCompleted)
          'preArmRemainingMilliseconds':
              (const Duration(seconds: 240) - _offlinePreArmClock.elapsed)
                  .inMilliseconds
                  .clamp(0, 240000),
        'validationObservation': _validationObservation,
        'tapStage': _tapStage,
        'tapFailure': _tapFailure,
        'tapHit': _tapHit,
      }),
    ),
  );
  debugPrint('NATIVE_AUTH_TEST_CHANNEL_READY');
  unawaited(
    binding.allTestsPassed.future.then(
      /**
       * Chỉ đánh PASS sau khi framework đã tổng hợp kết quả toàn target và teardown.
       * Input
       * Param: passed — kết quả native suite do integration_test sở hữu.
       */
      (passed) {
        status = passed ? 'PASS' : 'FAIL';
      },
    ),
  );
  testWidgets(
    'native SDK private fixture and actual main phase',
    /**
     * Đợi packet RAM rồi chạy đúng phase, không inject mock API/store/coordinator vào main.
     * Input
     * Param: tester — runtime native, không mock HTTP hoặc secure storage.
     */
    (tester) async {
      final previousPointerPolicy =
          WidgetController.hitTestWarningShouldBeFatal;
      WidgetController.hitTestWarningShouldBeFatal = true;
      addTearDown(
        /** Trả hit-test policy sau target; missed tap luôn FAIL trong actual flow, không chỉ warning bị discard. */
        () {
          WidgetController.hitTestWarningShouldBeFatal = previousPointerPolicy;
        },
      );
      final fixtureWait = phase == 'offline-login'
          ? const Duration(seconds: 240) - _offlinePreArmClock.elapsed
          : const Duration(seconds: 60);
      if (fixtureWait <= Duration.zero)
        throw StateError('NATIVE_OFFLINE_PREARM_EXPIRED');
      final packet = await fixture.future.timeout(fixtureWait);
      if (phase == 'offline-login') {
        await withNativeOfflineCredentials(
          packet,

          /// Bao cả noCA/main/teardown để lỗi trước UI cũng bỏ reference credential.
          () => verifyActualMain(tester, packet, phase),
        );
        return;
      }
      if (phase == 'rate-limit') {
        await withNativeRateCredentials(
          packet,
          () => verifyActualMain(tester, packet, phase),
        );
        return;
      }
      if (phase == 'membership-stale') {
        await withNativeMembershipCredentials(
          packet,

          /// Bao cả TLS và teardown để lỗi sớm cũng không giữ password trong packet.
          () => verifyActualMain(tester, packet, phase),
        );
        return;
      }
      if (phase != 'preflight') {
        await verifyActualMain(tester, packet, phase);
        return;
      }
      expect(packet['phase'] == 'preflight', isTrue);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('Native SDK test'))),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Native SDK test'), findsOneWidget);
      expect(pid > 0, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
    // Backstop framework, không thay phase1260 hoặc chứng minh cancel I/O từ timeout.
    timeout: phase == 'offline-login'
        ? const Timeout(Duration(minutes: 17))
        : phase == 'rate-limit'
        ? const Timeout(Duration(minutes: 22))
        : phase == 'membership-stale'
        ? const Timeout(Duration(minutes: 8))
        : null,
  );
}

/**
 * Đợi UI có deadline thật, tránh pumpAndSettle treo khi đang có spinner/network.
 * Input
 * Param: tester — native engine tester.
 * Param: finder — control hoặc trạng thái dự kiến của phase hiện tại.
 * Param: deadline — absolute deadline chung của operation; null dùng guard20s cũ, không reset qua helper mới.
 * Errors: timeout cố định, không đưa field value/credential vào matcher failure.
 */
Future<void> waitForNative(
  WidgetTester tester,
  Finder finder, {
  DateTime? deadline,
}) async {
  final limit = deadline ?? DateTime.now().add(const Duration(seconds: 20));
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(limit)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  if (DateTime.now().isAfter(limit) || finder.evaluate().length != 1)
    throw StateError('NATIVE_UI_STATE_TIMEOUT');
}

/**
 * Bấm control sau khi center nhận hit-test thật, xử lý cuộn cạnh tranh trong cùng deadline thay vì gọi callback.
 * Input
 * Param: tester — native runtime của test.
 * Param: key — key public của UI sản phẩm, không chứa bearer hoặc password.
 * Param: deadline — budget chung của operation; null dùng một guard20s, không reset khi re-scroll.
 * Errors: giữ nguyên lỗi tester; status chỉ ghi enum thao tác/loại lỗi, không raw trace hoặc input.
 */
Future<void> tapNative(
  WidgetTester tester,
  String key, {
  DateTime? deadline,
}) async {
  final finder = find.byKey(ValueKey(key));
  final limit = deadline ?? DateTime.now().add(const Duration(seconds: 20));
  _tapFailure = 'NONE';
  _tapHit = 'NONE';
  try {
    _tapStage = 'WAIT';
    await waitForNative(tester, finder, deadline: limit);
    _tapStage = 'SCROLL';
    await tester.ensureVisible(finder);
    _tapStage = 'SETTLE';
    // Focus/IME còn lịch auto-scroll sau frame nhập; dùng cùng350ms như widget harness đã kiểm, không settle spinner vô hạn.
    await tester.pump(const Duration(milliseconds: 350));
    /*
     * ensureVisible chỉ cuộn tại thời điểm gọi; focus/IME có thể cuộn lại trong frame sau.
     * Đợi đúng center nhận pointer trước tap, giữ lỗi fatal và chung deadline nếu UI không thể tới.
     * https://api.flutter.dev/flutter/flutter_test/Finder/hitTestable.html
     */
    while (finder.hitTestable().evaluate().isEmpty) {
      _tapHit = 'MISS';
      _tapStage = 'DEADLINE';
      await waitForNative(tester, finder, deadline: limit);
      _tapStage = 'SCROLL';
      await tester.ensureVisible(finder);
      _tapStage = 'SETTLE';
      await tester.pump(const Duration(milliseconds: 50));
    }
    _tapStage = 'DEADLINE';
    await waitForNative(tester, finder, deadline: limit);
    // Chỉ quan sát hit-test trước tap; không thay control hoặc gọi thẳng callback để né failure.
    _tapHit = finder.hitTestable().evaluate().isEmpty ? 'MISS' : 'HIT';
    _tapStage = 'TAP';
    await tester.tap(finder);
    _tapStage = 'PUMP';
    await tester.pump();
    _tapStage = 'DONE';
  } catch (error) {
    _tapFailure =
        error is StateError && error.message == 'NATIVE_UI_STATE_TIMEOUT'
        ? 'TIMEOUT'
        : (error is FlutterError ? 'FLUTTER' : 'OTHER');
    rethrow;
  }
}

/// Chạy offline main riêng để không đổi noCA/timing của các phase đã có evidence.
/// Input
/// Param: tester — engine actual, không inject API/store hoặc probe enum.
/// Param: packet — packet đã strict validate và neo phase clock trước ACK.
Future<void> verifyNativeOfflineMain(
  WidgetTester tester,
  Map<String, Object?> packet,
) async {
  _caseStage = 'no-ca';
  final client = HttpClient()
    ..findProxy = null
    ..connectionTimeout = const Duration(seconds: 5);

  /// Negative trust phải thực sự handshake-fail; request fixed không bearer hoặc raw response logging.
  Future<void> exchange() async {
    final request = await client.getUrl(
      Uri.parse('https://10.0.2.2:8443/api/v1/me'),
    );
    request.followRedirects = false;
    request.persistentConnection = false;
    final response = await request.close();
    await response.drain<void>();
  }

  final pending = exchange();
  unawaited(
    pending.catchError(
      /// Observer sớm không thay awaited future gốc và không giữ raw SDK error.
      (Object error) {},
    ),
  );
  var rejected = false;
  try {
    await pending.timeout(const Duration(seconds: 10));
  } on HandshakeException {
    rejected = true;
  } finally {
    client.close(force: true);
    try {
      await pending;
    } on Object {
      // Force-close chưa là terminal; drain original future trước khi được mount main hoặc trả failure.
    }
  }
  if (!rejected) throw StateError('NATIVE_NO_CA_MUST_REJECT');
  if (_offlinePhaseClock.elapsed >= const Duration(seconds: 20)) {
    throw StateError('NATIVE_OFFLINE_UI_TIMEOUT');
  }
  _caseStage = 'main';
  product.main();
  await tester.pump();
  await verifyNativeOfflineScenario(
    tester,
    packet,

    /// Clock từ valid packet, không reset sau noCA/main hoặc status polling.
    elapsed: _readOfflineElapsed,
    checkpoint:
        /// Input Param: stage — fixed offline pause, host giữ network/DB owners trước ACK.
        (stage) => waitForOfflineCheckpoint(tester, stage),
    markStage:
        /// Input Param: stage — fixed enum diagnostic, không raw key/input/state.
        (stage) {
          _caseStage = stage;
        },
  );
  if (!_offlineCheckpoint.complete)
    throw StateError('NATIVE_OFFLINE_CHECKPOINT_INCOMPLETE');
  _caseStage = 'teardown';
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  if (_offlinePhaseClock.elapsed >= const Duration(seconds: 675)) {
    throw StateError('NATIVE_OFFLINE_UI_TIMEOUT');
  }
}

/// Giữ native pause bằng real async yield để RPC còn chạy; gate local không thay host raw-terminal proof.
/// Input
/// Param: tester — same engine main đang sống, không launch target thứ hai.
/// Param: stage — fixed stage tiếp theo của offline gate.
Future<void> waitForOfflineCheckpoint(WidgetTester tester, String stage) async {
  _offlineCheckpoint.begin(stage);
  _caseStage = stage;
  try {
    while (!_offlineCheckpoint.acknowledged && !_offlineCheckpoint.expired) {
      await tester.runAsync(
        /// Yield thật giữ native clock/SDK tiến, không tua budget bằng fake pump time.
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    if (!_offlineCheckpoint.acknowledged)
      throw StateError('NATIVE_OFFLINE_CHECKPOINT_TIMEOUT');
    _offlineCheckpoint.endPause();
  } catch (_) {
    _offlineCheckpoint.cancel();
    rethrow;
  }
}

/**
 * Chạy TLS negative rồi composition sản phẩm, kiểm2workspace/role và giữ hoặc logout phiên theo phase.
 * Input
 * Param: tester — native engine, dùng HTTP/secure storage sản phẩm thật.
 * Param: packet — synthetic identities/password qua RAM; resume không có password.
 * Param: phase — full đăng nhập một lần, resume chỉ đọc secure storage/server recheck rồi logout.
 */
Future<void> verifyActualMain(
  WidgetTester tester,
  Map<String, Object?> packet,
  String phase,
) async {
  if (phase == 'offline-login') {
    await verifyNativeOfflineMain(tester, packet);
    return;
  }
  _caseStage = 'no-ca';
  final untrustedClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);
  var rejected = false;
  try {
    final request = await untrustedClient
        .getUrl(Uri.parse('https://10.0.2.2:8443/api/v1/me'))
        .timeout(const Duration(seconds: 5));
    await request.close().timeout(const Duration(seconds: 5));
  } on HandshakeException {
    rejected = true;
  } finally {
    untrustedClient.close(force: true);
  }
  if (!rejected) throw StateError('NATIVE_NO_CA_MUST_REJECT');
  if (phase == 'rate-limit' &&
      _ratePhaseClock.elapsed >= const Duration(seconds: 1260)) {
    throw StateError('NATIVE_RATE_UI_TIMEOUT');
  }
  if (phase == 'membership-stale' &&
      _membershipPhaseClock.elapsed >= const Duration(seconds: 420)) {
    throw StateError('NATIVE_MEMBERSHIP_UI_TIMEOUT');
  }
  _caseStage = 'main';
  product.main();
  await tester.pump();
  if (phase == 'response-loss') {
    await verifyNativeResponseLoss(tester, packet);
    packet['password'] = '';
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    return;
  }
  if (phase == 'rate-limit') {
    await verifyNativeRateScenario(
      tester,
      packet,
      elapsed: () => _ratePhaseClock.elapsed,
      checkpoint: (stage) => waitForRateCheckpoint(tester, stage),
      markStage: (stage) {
        _caseStage = stage;
      },
    );
    if (!_rateCheckpoint.complete)
      throw StateError('NATIVE_RATE_CHECKPOINT_INCOMPLETE');
    _caseStage = 'teardown';
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    if (_ratePhaseClock.elapsed >= const Duration(seconds: 1260))
      throw StateError('NATIVE_RATE_UI_TIMEOUT');
    return;
  }
  if (phase == 'membership-stale') {
    await verifyNativeMembershipScenario(
      tester,
      packet,

      /// Clock đã neo valid packet trước fixture ACK, không reset sau TLS hoặc main.
      elapsed: () => _membershipPhaseClock.elapsed,

      /// Native giữ pause để host xong oracle/DB mutation trước valid ACK.
      /// Input
      /// Param: stage — fixed enum của producer, không identity hoặc secret.
      checkpoint: (stage) => waitForMembershipCheckpoint(tester, stage),

      /// Chỉ enum chẩn đoán, status không phát raw UI/state.
      /// Input
      /// Param: stage — thao tác hoặc checkpoint hiện hành.
      markStage: (stage) {
        _caseStage = stage;
      },
    );
    if (!_membershipCheckpoint.complete) {
      throw StateError('NATIVE_MEMBERSHIP_CHECKPOINT_INCOMPLETE');
    }
    _caseStage = 'teardown';
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    if (_membershipPhaseClock.elapsed >= const Duration(seconds: 420)) {
      throw StateError('NATIVE_MEMBERSHIP_UI_TIMEOUT');
    }
    return;
  }
  if (phase == 'password' || phase == 'password-relogin') {
    await verifyNativePassword(tester, packet, phase);
    packet['password'] = '';
    packet['newPassword'] = '';
    _caseStage = 'teardown';
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    return;
  }
  if (phase == 'access') {
    await verifyNativeAccess(tester, packet);
    packet['password'] = '';
    _caseStage = 'teardown';
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    return;
  }
  if (phase == 'full') {
    _caseStage = 'login';
    await waitForNative(tester, find.byKey(const ValueKey('auth-email')));
    await tester.enterText(
      find.byKey(const ValueKey('auth-email')),
      (packet['emails'] as List).first as String,
    );
    await tester.enterText(
      find.byKey(const ValueKey('auth-password')),
      packet['password'] as String,
    );
    await tapNative(tester, 'auth-submit');
  }
  _caseStage = 'picker';
  final picker = find.byWidgetPredicate(
    /**
     * Chỉ admission picker có đủ2row đã tải, không dùng loading/empty làm success.
     * Input
     * Param: widget — widget đang thực sự mount trong main.
     */
    (widget) =>
        widget is WorkspaceSelectionScreen && widget.state.options.length == 2,
  );
  await waitForNative(tester, picker);
  final options = tester.widget<WorkspaceSelectionScreen>(picker).state.options;
  final byName = {for (final option in options) option.name: option};
  // Mapping cố định từ fixture canonical, không so summary với chính row sai để che đảo vai trò A/B.
  if (byName.length != 2 ||
      byName['Phòng vận hành A']?.role != WorkspaceRole.admin ||
      byName['Nhà kính B']?.role != WorkspaceRole.user)
    throw StateError('NATIVE_WORKSPACE_ROLES_INVALID');
  if (phase == 'full') {
    await waitForAccessCheckpoint(tester, 'workspace-picker-before-select');
  }
  final ordered = [byName['Phòng vận hành A']!, byName['Nhà kính B']!];
  for (var index = 0; index < ordered.length; index++) {
    _caseStage = index == 0 ? 'workspace-a' : 'workspace-b';
    final option = ordered[index];
    await tapNative(tester, 'workspace-select-${option.id}');
    await waitForNative(tester, find.byKey(const ValueKey('session-summary')));
    expect(
      find.text((packet['emails'] as List).first as String),
      findsOneWidget,
    );
    expect(find.text(option.name), findsOneWidget);
    expect(find.text(option.role.label), findsOneWidget);
    if (index == 0) {
      await tapNative(tester, 'session-back');
      await waitForNative(tester, picker);
    }
  }
  if (phase == 'resume') {
    _caseStage = 'logout';
    await tapNative(tester, 'session-logout');
    await waitForNative(tester, find.byKey(const ValueKey('auth-email')));
  }
  packet['password'] = '';
  _caseStage = 'teardown';
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

/** Kiểm mất response sau commit bằng main/API/storage thật, chỉ submit lại qua gesture chủ động.
 * Input
 * Param: tester — engine Android thực, không thay API hoặc token store bằng fake.
 * Param: packet — credential synthetic qua RAM, không ghi vào diagnostic.
 * Side effects: tạo orphan session đầu do mất body, session thứ hai được logout đúng UUID. */
Future<void> verifyNativeResponseLoss(
  WidgetTester tester,
  Map<String, Object?> packet,
) async {
  const store = SecureSessionTokenStore();
  final email = (packet['emails'] as List).first as String;
  final password = packet['password'] as String;
  await waitForNative(tester, find.byKey(const ValueKey('auth-email')));
  if (await store.read() != null)
    throw StateError('NATIVE_LOSS_PREEXISTING_SESSION');
  await tester.enterText(find.byKey(const ValueKey('auth-email')), email);
  await tester.enterText(find.byKey(const ValueKey('auth-password')), password);
  await tapNative(tester, 'auth-submit');
  final pending = find.byKey(const ValueKey('app-recovery'));
  await waitForNative(tester, pending);
  final coordinator = tester
      .widget<AppAuthApplication>(find.byType(AppAuthApplication))
      .coordinator;
  if (coordinator.session.phase != AppSessionPhase.pending ||
      coordinator.session.profile != null ||
      coordinator.session.workspaces.isNotEmpty ||
      coordinator.session.selectedWorkspace != null ||
      await store.read() != null)
    throw StateError('NATIVE_LOSS_ADMISSION_INVALID');
  await waitForAccessCheckpoint(tester, 'loss-result');
  final quiet = Stopwatch()..start();
  while (quiet.elapsed < const Duration(seconds: 30)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (coordinator.session.phase != AppSessionPhase.pending ||
        pending.evaluate().length != 1 ||
        find.byType(WorkspaceSelectionScreen).evaluate().isNotEmpty) {
      throw StateError('NATIVE_LOSS_AUTOMATIC_RECOVERY');
    }
  }
  await waitForAccessCheckpoint(tester, 'loss-quiet');
  await tapNative(tester, 'app-recover');
  await waitForNative(
    tester,
    find.byWidgetPredicate(
      // Recovery không có bearer chỉ trở về form trống, không nhận orphan phiên từ server.
      (widget) => widget is LoginScreen && widget.state == LoginViewState.ready,
    ),
  );
  for (final key in ['auth-email', 'auth-password']) {
    if (tester
            .widget<TextFormField>(find.byKey(ValueKey(key)))
            .controller
            ?.text !=
        '') {
      throw StateError('NATIVE_LOSS_CREDENTIAL_RETAINED');
    }
  }
  if (await store.read() != null) throw StateError('NATIVE_LOSS_STORED_ORPHAN');
  await waitForAccessCheckpoint(tester, 'loss-ready');
  await tester.enterText(find.byKey(const ValueKey('auth-email')), email);
  await tester.enterText(find.byKey(const ValueKey('auth-password')), password);
  await tapNative(tester, 'auth-submit');
  await waitForNative(tester, find.byType(WorkspaceSelectionScreen));
  final picker = tester.widget<WorkspaceSelectionScreen>(
    find.byType(WorkspaceSelectionScreen),
  );
  if (picker.state.options.length != 2 || await store.read() == null)
    throw StateError('NATIVE_LOSS_NEW_LOGIN_INVALID');
  await waitForAccessCheckpoint(tester, 'loss-picker');
  await tapNative(tester, 'workspace-select-${picker.state.options.first.id}');
  await waitForNative(tester, find.byKey(const ValueKey('session-summary')));
  await tapNative(tester, 'session-logout');
  await waitForNative(tester, find.byKey(const ValueKey('auth-email')));
  if (await store.read() != null)
    throw StateError('NATIVE_LOSS_LOGOUT_STORE_RETAINED');
  await waitForAccessCheckpoint(tester, 'loss-loggedout');
}

/**
 * Pause native tại boundary UI để host kiểm counters trước intent tiếp, không suy từ final count tổng.
 * Input
 * Param: tester — engine thật vẫn pump để SDK extension xử lý ACK.
 * Param: stage — checkpoint cố định của access flow, không chứa identity hoặc input.
 * Errors: thiếu ACK trong5s hoặc pause chồng nhau khiến case FAIL; owner host vẫn cleanup.
 */
Future<void> waitForAccessCheckpoint(WidgetTester tester, String stage) async {
  if (_checkpointRelease != null) throw StateError('NATIVE_CHECKPOINT_OVERLAP');
  final release = Completer<void>();
  _checkpointRelease = release;
  _checkpointStage = stage;
  _caseStage = stage;
  try {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!release.isCompleted && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    if (!release.isCompleted) throw StateError('NATIVE_CHECKPOINT_TIMEOUT');
  } finally {
    _checkpointStage = '';
    _checkpointRelease = null;
  }
}

/**
 * Rate pause5s thật: giữ engine/extension hoạt động, không pump giả5s hoặc dùng wallclock reset deadline.
 * Chỉ integration scenario rate gọi, không production callback hoặc auth authority.
 */
Future<void> waitForRateCheckpoint(WidgetTester tester, String stage) async {
  _rateCheckpoint.begin(stage);
  _caseStage = stage;
  try {
    while (!_rateCheckpoint.acknowledged && !_rateCheckpoint.expired) {
      await tester.runAsync(
        /** Real async yield để Stopwatch và SDK RPC đều tiến trên device thật. */
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    if (!_rateCheckpoint.acknowledged) {
      throw StateError('NATIVE_RATE_CHECKPOINT_TIMEOUT');
    }
    _rateCheckpoint.endPause();
  } catch (_) {
    _rateCheckpoint.cancel();
    rethrow;
  }
}

/**
 * Giữ membership pause bằng thời gian thật, picker210s và năm stage5s do gate sở hữu.
 * Input
 * Param: tester — engine native vẫn pump để SDK RPC và timers tiến.
 * Param: stage — fixed checkpoint tiếp theo, không command SQL hoặc identity.
 * Errors: gate/phase timeout fail sticky, không chứng minh host SQL/SDK đã terminal.
 */
Future<void> waitForMembershipCheckpoint(
  WidgetTester tester,
  String stage,
) async {
  _membershipCheckpoint.begin(stage);
  _caseStage = stage;
  try {
    while (!_membershipCheckpoint.acknowledged &&
        !_membershipCheckpoint.expired) {
      if (_membershipPhaseClock.elapsed >= const Duration(seconds: 420)) {
        throw StateError('NATIVE_MEMBERSHIP_UI_TIMEOUT');
      }
      await tester.runAsync(
        /// Real async yield giữ Stopwatch/extension tiến, không pump nhanh qua deadline.
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    if (!_membershipCheckpoint.acknowledged) {
      throw StateError('NATIVE_MEMBERSHIP_CHECKPOINT_TIMEOUT');
    }
    _membershipCheckpoint.endPause();
  } catch (_) {
    _membershipCheckpoint.cancel();
    rethrow;
  }
}

/**
 * Gửi form thật rồi bắt fresh busy frame để không nhận rejection/empty cũ như completion mới.
 * Input
 * Param: tester — native UI engine của main sản phẩm.
 * Param: email — identity synthetic của đúng fixture, không log.
 * Param: password — secret một lần trong RAM, không lưu qua màn hoặc compiler define.
 * Param: deadline — deadline chung từ caller password flow, null giữ access behavior đã kiểm.
 */
Future<void> submitNativeAccessLogin(
  WidgetTester tester,
  String email,
  String password, {
  DateTime? deadline,
}) async {
  await waitForNative(
    tester,
    find.byKey(const ValueKey('auth-email')),
    deadline: deadline,
  );
  await tester.enterText(find.byKey(const ValueKey('auth-email')), email);
  await tester.enterText(find.byKey(const ValueKey('auth-password')), password);
  await tapNative(tester, 'auth-submit', deadline: deadline);
  // Composition thật che form bằng app-loading khi submit; không giả định presentation enum submitting được render.
  await waitForNative(
    tester,
    find.byKey(const ValueKey('app-loading')),
    deadline: deadline,
  );
}

/**
 * Đọc rendered generic copy sau fresh submit completion, không lộ trạng thái account hoặc protected UI.
 * Input
 * Param: tester — cây widget main thật sau một request chủ động.
 * Param: deadline — budget chung của operation sau fresh busy frame, không cộng thêm20s riêng.
 * Output: copy được render trong notice; chỉ fixed public message được chấp nhận.
 */
Future<String> readNativeRejection(
  WidgetTester tester, {
  DateTime? deadline,
}) async {
  final rejected = find.byWidgetPredicate(
    /**
     * Chỉ rejected đã mount, không chấp nhận loading hoặc form cũ còn ready.
     * Input
     * Param: widget — widget UI hiện hành, không dùng token/state mock.
     */
    (widget) =>
        widget is LoginScreen && widget.state == LoginViewState.rejected,
  );
  await waitForNative(tester, rejected, deadline: deadline);
  await tester.pump(const Duration(milliseconds: 500));
  await waitForNative(tester, rejected, deadline: deadline);
  expect(find.byType(WorkspaceSelectionScreen), findsNothing);
  expect(find.byKey(const ValueKey('session-summary')), findsNothing);
  final messages = find.descendant(
    of: find.byKey(const ValueKey('auth-notice')),
    matching: find.byType(Text),
  );
  final text = tester.widgetList<Text>(messages).last.data;
  if (text != 'Thông tin đăng nhập không hợp lệ. Kiểm tra email và mật khẩu.') {
    throw StateError('NATIVE_GENERIC_REJECTION_INVALID');
  }
  return text!;
}

/**
 * Kiểm disabled/wrong chung lỗi và empty account với refresh/logout qua UI thật cùng ordered host ACK.
 * Input
 * Param: tester — native UI engine, không inject API/store hoặc gọi callback nghiệp vụ trực tiếp.
 * Param: packet —5identities và password synthetic RAM của canonical fixture.
 */
Future<void> verifyNativeAccess(
  WidgetTester tester,
  Map<String, Object?> packet,
) async {
  final emails = packet['emails'] as List;
  final password = packet['password'] as String;
  await waitForNative(tester, find.byKey(const ValueKey('auth-email')));
  await waitForAccessCheckpoint(tester, 'before-disabled');
  await submitNativeAccessLogin(tester, emails[1] as String, password);
  final disabledCopy = await readNativeRejection(tester);
  await waitForAccessCheckpoint(tester, 'disabled-rejected');
  await submitNativeAccessLogin(tester, emails[3] as String, '${password}0');
  final wrongCopy = await readNativeRejection(tester);
  if (wrongCopy != disabledCopy)
    throw StateError('NATIVE_GENERIC_REJECTION_MISMATCH');
  await waitForAccessCheckpoint(tester, 'wrong-rejected');
  await submitNativeAccessLogin(tester, emails[3] as String, password);
  final empty = find.byWidgetPredicate(
    /**
     * Empty chỉ khi ready/items0/hasMorefalse đã xác nhận, không coi loading/error như list rỗng.
     * Input
     * Param: widget — workspace UI snapshot của repository sản phẩm thật.
     */
    (widget) => widget is WorkspaceSelectionScreen && widget.state.isEmpty,
  );
  await waitForNative(tester, empty);
  expect(find.text('Không có workspace khả dụng'), findsOneWidget);
  expect(
    find.text('Tạo workspace chưa khả dụng trong phiên bản này.'),
    findsOneWidget,
  );
  final create = tester.widget<FilledButton>(
    find.byKey(const ValueKey('workspace-create')),
  );
  if (create.onPressed != null)
    throw StateError('NATIVE_EMPTY_CREATE_MUST_BE_DISABLED');
  expect(find.byKey(const ValueKey('session-summary')), findsNothing);
  await waitForAccessCheckpoint(tester, 'empty-ready');
  await tapNative(tester, 'workspace-refresh');
  await waitForNative(tester, find.byKey(const ValueKey('app-loading')));
  await waitForNative(tester, empty);
  await waitForAccessCheckpoint(tester, 'empty-refreshed');
  await tapNative(tester, 'workspace-logout');
  await waitForNative(tester, find.byKey(const ValueKey('auth-email')));
  expect(find.byType(WorkspaceSelectionScreen), findsNothing);
  await waitForAccessCheckpoint(tester, 'logged-out');
}

/**
 * Chọn password screen theo completion state thật, không coi frame loading/form cũ là response mới.
 * Input
 * Param: state — ready/rejected cần thấy sau operation, không chứng minh server authority riêng.
 * Output: finder typed duy nhất của UI đang mount.
 */
Finder nativePasswordScreen(PasswordChangeState state) =>
    find.byWidgetPredicate(
      /**
   * Đọc presentation state sản phẩm chỉ để kiểm frame, không inject state/mock vào main.
   * Input
   * Param: widget — widget trong native tree hiện hành.
   */
      (widget) => widget is PasswordChangeScreen && widget.state == state,
    );

/**
 * Điền password form thật trong absolute deadline; caller bấm submit riêng để kiểm before/after transition.
 * Input
 * Param: tester — engine native của main thật.
 * Param: current — secret hiện tại cho một submit, không log hoặc giữ trong controller sau gửi.
 * Param: next — secret mới hoặc invalid input synthetic để kiểm validation.
 * Param: confirmation — xác nhận chỉ ở UI, không đi vào API.
 * Param: deadline — cùng wall deadline5s local hoặc20s remote, không reset mỗi helper.
 */
Future<void> fillNativePasswordForm(
  WidgetTester tester,
  String current,
  String next,
  String confirmation,
  DateTime deadline,
) async {
  await waitForNative(
    tester,
    find.byKey(const ValueKey('password-current')),
    deadline: deadline,
  );
  await tester.enterText(
    find.byKey(const ValueKey('password-current')),
    current,
  );
  await tester.enterText(find.byKey(const ValueKey('password-new')), next);
  await tester.enterText(
    find.byKey(const ValueKey('password-confirm')),
    confirmation,
  );
}

/**
 * Kiểm limited/strong validation/password ACK rồi process mới old-reject/new-login/logout bằng UI thật.
 * Input
 * Param: tester — native engine, real TLS/API/secure storage của product main.
 * Param: packet — synthetic account2 và hai CSPRNG secrets one-shot trong RAM.
 * Param: phase — password hoặc password-relogin; native process mới được host/PID oracle chứng minh.
 */
Future<void> verifyNativePassword(
  WidgetTester tester,
  Map<String, Object?> packet,
  String phase,
) async {
  final email = (packet['emails'] as List)[2] as String;
  final password = packet['password'] as String;
  final newPassword = packet['newPassword'] as String;
  await waitForNative(tester, find.byKey(const ValueKey('auth-email')));
  if (phase == 'password') {
    await waitForAccessCheckpoint(tester, 'password-before');
    var deadline = DateTime.now().add(const Duration(seconds: 20));
    await submitNativeAccessLogin(tester, email, password, deadline: deadline);
    await waitForNative(
      tester,
      nativePasswordScreen(PasswordChangeState.ready),
      deadline: deadline,
    );
    expect(find.byType(WorkspaceSelectionScreen), findsNothing);
    expect(find.byKey(const ValueKey('session-summary')), findsNothing);
    expect(find.byKey(const ValueKey('app-back')), findsNothing);
    await waitForAccessCheckpoint(tester, 'limited-ready');
    // Public invalid cases không chứa fixture secret; mỗi case phải hiện lỗi mới đúng field và không phát POST.
    for (final scenario in [
      (
        'invalid-short',
        'Aa1aaaaa',
        'Aa1aaaaa',
        'Mật khẩu mới cần từ 9 đến 128 ký tự.',
      ),
      (
        'invalid-uppercase',
        'aa1aaaaaaaa',
        'aa1aaaaaaaa',
        'Mật khẩu mới phải có chữ hoa, chữ thường và số (0–9).',
      ),
      (
        'invalid-lowercase',
        'AA1AAAAAAAA',
        'AA1AAAAAAAA',
        'Mật khẩu mới phải có chữ hoa, chữ thường và số (0–9).',
      ),
      (
        'invalid-digit',
        'Aaaaaaaaaaa',
        'Aaaaaaaaaaa',
        'Mật khẩu mới phải có chữ hoa, chữ thường và số (0–9).',
      ),
      (
        'invalid-confirm',
        newPassword,
        '${newPassword}0',
        'Mật khẩu xác nhận chưa khớp.',
      ),
    ]) {
      deadline = DateTime.now().add(const Duration(seconds: 5));
      const lengthMessage = 'Mật khẩu mới cần từ 9 đến 128 ký tự.';
      if (scenario.$1 != 'invalid-short') {
        _caseStage = 'validation-reset';
        // Reset bằng một invalid submit thật; message khác buộc ca tiếp chứng minh validation mới thay vì đọc copy cũ.
        await fillNativePasswordForm(
          tester,
          password,
          'Aa1aaaaa',
          'Aa1aaaaa',
          deadline,
        );
        await tapNative(tester, 'password-submit', deadline: deadline);
        await waitForNative(
          tester,
          find.text(lengthMessage),
          deadline: deadline,
        );
      }
      _caseStage = 'validation-fill';
      await fillNativePasswordForm(
        tester,
        password,
        scenario.$2,
        scenario.$3,
        deadline,
      );
      _caseStage = 'validation-before';
      final lengthVisible = find.text(lengthMessage).evaluate().isNotEmpty;
      final targetVisible = find.text(scenario.$4).evaluate().isNotEmpty;
      // Chỉ fixed visibility enums dùng chẩn đoán harness, không field content/credential hoặc assertion trace.
      _validationObservation = lengthVisible
          ? (targetVisible ? 'BOTH' : 'LENGTH_ONLY')
          : (targetVisible ? 'TARGET_ONLY' : 'NEITHER');
      // Negative ở widget boundary: điền input chưa submit không được tự biến old error thành target error.
      expect(find.text(scenario.$4), findsNothing);
      if (scenario.$1 != 'invalid-short')
        expect(find.text(lengthMessage), findsOneWidget);
      _caseStage = 'validation-submit';
      await tapNative(tester, 'password-submit', deadline: deadline);
      _caseStage = 'validation-result';
      await waitForNative(tester, find.text(scenario.$4), deadline: deadline);
      if (scenario.$1 != 'invalid-short')
        expect(find.text(lengthMessage), findsNothing);
      expect(find.byKey(const ValueKey('app-loading')), findsNothing);
      expect(find.byType(WorkspaceSelectionScreen), findsNothing);
      await waitForAccessCheckpoint(tester, scenario.$1);
    }
    deadline = DateTime.now().add(const Duration(seconds: 20));
    await fillNativePasswordForm(
      tester,
      '${password}0',
      newPassword,
      newPassword,
      deadline,
    );
    await tapNative(tester, 'password-submit', deadline: deadline);
    await waitForNative(
      tester,
      find.byKey(const ValueKey('app-loading')),
      deadline: deadline,
    );
    await waitForNative(
      tester,
      nativePasswordScreen(PasswordChangeState.rejected),
      deadline: deadline,
    );
    expect(
      find.text('Kiểm tra mật khẩu hiện tại rồi nhập lại thông tin để thử.'),
      findsOneWidget,
    );
    expect(find.byType(WorkspaceSelectionScreen), findsNothing);
    await waitForAccessCheckpoint(tester, 'current-rejected');
    deadline = DateTime.now().add(const Duration(seconds: 20));
    await fillNativePasswordForm(
      tester,
      password,
      newPassword,
      newPassword,
      deadline,
    );
    await tapNative(tester, 'password-submit', deadline: deadline);
    await waitForNative(
      tester,
      find.byKey(const ValueKey('app-loading')),
      deadline: deadline,
    );
    await waitForNative(
      tester,
      find.byKey(const ValueKey('auth-email')),
      deadline: deadline,
    );
    expect(find.byType(PasswordChangeScreen), findsNothing);
    expect(find.byType(WorkspaceSelectionScreen), findsNothing);
    await waitForAccessCheckpoint(tester, 'password-changed');
  } else {
    await waitForAccessCheckpoint(tester, 'relogin-before');
    var deadline = DateTime.now().add(const Duration(seconds: 20));
    await submitNativeAccessLogin(tester, email, password, deadline: deadline);
    await readNativeRejection(tester, deadline: deadline);
    await waitForAccessCheckpoint(tester, 'old-rejected');
    deadline = DateTime.now().add(const Duration(seconds: 20));
    await submitNativeAccessLogin(
      tester,
      email,
      newPassword,
      deadline: deadline,
    );
    final empty = find.byWidgetPredicate(
      /**
       * Account2 không membership nên chỉ confirmed empty mới là new-password login success.
       * Input
       * Param: widget — snapshot native của sản phẩm, không dữ liệu test inject.
       */
      (widget) => widget is WorkspaceSelectionScreen && widget.state.isEmpty,
    );
    await waitForNative(tester, empty, deadline: deadline);
    expect(find.text('Không có workspace khả dụng'), findsOneWidget);
    expect(find.byType(PasswordChangeScreen), findsNothing);
    await waitForAccessCheckpoint(tester, 'new-empty');
    deadline = DateTime.now().add(const Duration(seconds: 20));
    await tapNative(tester, 'workspace-logout', deadline: deadline);
    await waitForNative(
      tester,
      find.byKey(const ValueKey('app-loading')),
      deadline: deadline,
    );
    await waitForNative(
      tester,
      find.byKey(const ValueKey('auth-email')),
      deadline: deadline,
    );
    expect(find.byType(WorkspaceSelectionScreen), findsNothing);
    await waitForAccessCheckpoint(tester, 'password-logout');
  }
}
