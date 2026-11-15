# Mobile client

Latest T1-A checkpoint2026-10-28: main now supports a public `AUTH_LAB_CA_CERT`
for debug only and the exact origin `https://10.0.2.2:8443`. The factory uses a
private SecurityContext, keeps SDK hostname/expiry validation, and rejects lab
trust in non-debug builds. Root6focused/134full tests, product/profile compiler
flag checks, analyzer/format and2native configuration regressions pass. The
GPT-6.1/xhigh tester independently ran6focused tests with matching hashes.
These flag tests do not establish release/profile APK acceptance. The HTTPS
proxy is still pending, so no native HTTPS login is verified. See the
[T1-A handoff and evidence](../docs/test-reports/FEAT-TN-001-debug-lab-trust-2026-10-28.md).

Current integration checkpoint2026-10-28: `lib/main.dart` now composes the real
HTTPS API, secure session store, repository and lifecycle coordinator. The Nexa
host routes login, limited password change, full workspace picker, server-checked
summary and recovery/countdown states. At the earlier UI2 checkpoint, Root13focused/128full tests passed, Dart
analyzer has no issues, formatter checks42files with0changes (`lib test tool`). These use synthetic
API/store boundaries. Independent test design/review passes; runtime is by root,
not independent execution at that checkpoint. T1-A adds the independent focused
run recorded above. Native main/API
E2E is **NOT_VERIFIED**, so this is **READY_FOR_QA scoped**, not acceptance.

Resumed execution checkpoint2026-10-28: approved outside-sandbox SDK/Docker
work. Pixel_7/API36 is connected; two real-main native configuration cases pass
(missing origin and HTTP rejection), analyzer is clean and the new integration
file formats with0changes. The real default main was rebuilt, installed and
launched with `--no-resident` after the test APK, exit0. It remains at the setup
gate because no trusted HTTPS origin is configured. This does not verify login.
Canonical provider176assertions/163distinct and cleanup readback0 pass; browser
CUA currently reports both native pipe/browser host unavailable. See the
[current runtime evidence](../docs/test-reports/FEAT-TN-001-runtime-resumed-2026-10-28.md).

Run the actual main from `mobile` with a verified device and trusted HTTPS origin:

```powershell
flutter run --no-pub -d YOUR_DEVICE_ID --dart-define=AUTH_API_BASE_URL=https://YOUR_API_ORIGIN
```

Replace both placeholders. Origin must have no path/query/userinfo; missing or
HTTP configuration shows a blocking setup screen before authentication I/O.
Do not bypass certificate checks or enable cleartext to reach the HTTP-only lab.
The current environment has no confirmed App HTTPS endpoint. Earlier sandbox
checks hit Docker access and SDK Git ownership errors; approved outside-sandbox
normal SDK commands now run successfully. No trust/ownership/dependency change
was used to fix those historical restrictions. See the [current App handoff and
step-by-step Tester runbook](../docs/test-reports/FEAT-TN-001-android-application-2026-10-28.md)
and [independent QA report](../docs/test-reports/FEAT-TN-001-android-application-independent-2026-10-28.md).

The checkpoint descriptions below retain earlier results. Statements that main
was a scaffold or not wired describe those historical sources and are superseded
by the current integration checkpoint. Preview targets remain explicit mocks.

Password-policy checkpoint2026-10-26: new passwords require9–128Unicode
codepoints, Uppercase +Lowercase and an ASCII digit0–9. Login uses9–128length
without applying new composition to legacy credentials; currentPassword stays
1–128. No trim/normalization or required special character. The shared17-case
oracle is used by Dart/Web/Rust.37Flutter tests PASS;8native login/password
profiles pass across API24/36, portrait/landscape200%, with strict taps and
display restoration verified. Login header temporarily yields space when the
keyboard would consume its viewport, returning when closed. Verification and
current analyzer/format evidence are in the [policy handoff and detailed Tester steps](../docs/test-reports/FEAT-TN-001-password-policy-2026-10-26.md).
**READY_FOR_QA source; main app still scaffold, previews remain labelled mocks.**
Run `flutter run --no-pub -d emulator-5554 -t tool/password_change_preview.dart`
from `mobile/` to inspect new-password validation. Use `tool/auth_preview.dart`
for login. Device IDs must match the current emulator inventory.

Previous checkpoint2026-10-26: C0d1/2 adds the Nexa limited-password form and
labelled preview `tool/password_change_preview.dart`.35Flutter tests PASS
(9password UI tests),9host runner tests PASS, analyzer no issues/7.8s and
formatter29files0changes. Four native mock profiles pass across API24/36,
portrait and landscape200%, with metrics and display restoration checked.
The header yields space when a short keyboard viewport would hide controls;
text scaling,48dp targets and the mock banner remain. **READY_FOR_QA for
source/native mock; main app and real auth session are not integrated.**
Run from `mobile/`: `flutter run --no-pub -d emulator-5554 -t tool/password_change_preview.dart`
using the current deviceId from `flutter devices --machine`.
[Current handoff, failure evidence and Tester steps](../docs/test-reports/FEAT-TN-001-android-password-ui-2026-10-26.md).

Previous source checkpoint2026-10-26: R9-D2 adds an immutable `/me` full-profile
consumer and shares the existing UUID policy across login/profile/workspace
parsers. `flutter test --no-pub` passes26tests, including42login +72workspace
+57profile synthetic cases; analyzer reports no issues and formatter checks
24files with0changes. This is **READY_FOR_QA source**, without HTTP/session
wiring. `lib/main.dart` remains scaffold; independent preview targets are mock.
Email/timezone receive structural string checks, not email/IANA catalogue
certification. See [current handoff and Tester steps](../docs/test-reports/FEAT-TN-001-android-full-profile-2026-10-26.md).
Counts below describe earlier checkpoints and do not supersede this result.

Flutter/Dart application for Android in the current implementation scope. Native Kotlin bridges are limited to BLE SDK integration when necessary; business logic stays in Dart and Rust.

iOS is explicitly out of scope in the BA/handoff source documents; see [ADR-001](../docs/adr/adr-001-defer-ios-client.md).

The Android scaffold now exists with Flutter **3.47.5 stable / Dart3.13.4** and
approved **flutter_secure_storage11.2.0** (exact pin, pubspec.lock). BLE is not a
dependency for the auth storage PoC. Candidate minSdk24 is not yet certified.
AVD Pixel_7 runs Android16/API36 as emulator-5554. No real device evidence yet.

Current scope is contract parsing and secure-storage PoC; `lib/main.dart` is
still the generated scaffold, not a completed login app. The 42 synthetic
consumer cases pass; they do not verify the backend, storage or Android UI.
The first Android integration build failed for missing NDK28.2.13676358;
the exact NDK, platform35/36 and CMake3.22.1 are now installed. Native write,
cold boot, read/delete passed on both API36 and the separate Nexa_Auth_API24
AVD running Android7/API24 with --no-uninstall. These results do
not certify backup/key-failure handling or physical-device compatibility.

From `mobile/`, using the pinned SDK executable (outside the restricted agent
sandbox when needed):

```powershell
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
flutter emulators --launch Pixel_7
flutter devices --machine
flutter test --no-pub --no-uninstall integration_test/secure_storage_test.dart -d emulator-5554 --plain-name "persist probe"
flutter test --no-pub --no-uninstall integration_test/secure_storage_test.dart -d emulator-5554 --plain-name "read persisted probe and delete"
```

Run the two filtered integration commands separately on the same emulator to
check persistence between test app launches; the second removes only the PoC
key. `--no-uninstall` is required: Flutter test otherwise uninstalls the app
after the run and clears its data, invalidating a relaunch persistence check.
Running both in one process verifies read/write/delete, not process restart.
Only synthetic nonfunctional values are used. App-level key-failure recovery, backup/restore,
app-level API24 and physical-device checks remain required. Dependency approval is not
storage acceptance. See [Android proposal and task dependencies](../ops/toolchains/android-auth-proposal.md)
and the [Android PoC evidence/runbook](../docs/test-reports/FEAT-TN-001-android-poc-2026-10-24.md)
for status before testing the real auth workflow.

`SessionTokenStore` now wraps one session key without caching, bulk deletion or
automatic retry. Native errors become fixed operation codes; an I/O error is
never treated as a missing session or a successful write. Its separate auth
namespace and `resetOnError: false` prevent implicit storage reset. Six focused
channel-fake tests pass, including lost ACK after persistence and pending ACK.
The complete unit suite is seven tests (one contains42 contract cases), with
no analyzer issues. The adapter is not wired into the scaffold. Its exact
namespace/reset configuration now passes four additional native cases on API24
and36, including cold boot and preservation of a separate synthetic proof.
Two native instrumentation runs also reject key loss, preserve ciphertext and
the sibling namespace, and verify owned cleanup. A reset=true mutation fails;
the restored test APK was rebuilt and passed again. Unit/native tests do not
certify app-level recovery, backup/restore, revocation or successful login.

From `mobile/`, run the two filtered stages in
`integration_test/session_token_store_test.dart` with names `persist adapter
probe` and `restore adapter probe and preserve proof`, using the same cold-boot
procedure and --no-uninstall. After those finish, from `mobile/android/` run:

```powershell
.\gradlew.bat :app:installDebugAndroidTest -Ptarget-platform=android-x64 --offline
```

Then invoke `StorageFaultInstrumentation` with adb on the verified test AVD.
All four fields must match: probe=NATIVE_KEY_LOSS_REJECTED, stage=verified,
cleanup=true, INSTRUMENTATION_CODE=-1. Shell exit0 alone is insufficient.
The x64 target verifies emulator builds only, not a physical ARM device.
See the [current native handoff](../docs/test-reports/FEAT-TN-001-android-native-storage-2026-10-25.md)
for exact commands, evidence, source state and remaining gates.

## Login UI design preview (mock only)

The reusable Nexa form, light/dark theme and state matrix now exist. The default
`lib/main.dart` remains a scaffold until real auth integration gates are met.
Use the separate preview target on a verified running AVD:

```powershell
flutter devices --machine
flutter run --no-pub --debug -t tool/auth_preview.dart -d emulator-5554
```

Replace the device ID using inventory. The screen must show the mock banner.
Use synthetic values only: it never calls the API or saves a token; submit
simulates loading then rejection, and scenario/recovery controls are design
tools. A simulated confirmed state does not open a workspace or prove login.
The full unit/widget suite passes15tests (including8UI and42 parser cases).
Native preview interactions now pass all four portrait and landscape/200% text
profiles on API24 and36. A host handshake applies settings after app startup:
API36 policy had changed from lock1 to lock0 during integration launch. The
test now waits for real logical/native metrics before interacting; missing
host apply fails natively. Six host runner unit tests and an inverted-comparison
mutation verify rejection/cleanup guards. TalkBack/visual QA and rotation
during input/request remain open; these tests are not backend E2E.

From repo root, stop preview first and run profiles serially on the verified AVD:

```powershell
python -X utf8 -B mobile/tool/run_auth_display_test.py --device emulator-5554 --avd Pixel_7 --profile portrait
python -X utf8 -B mobile/tool/run_auth_display_test.py --device emulator-5554 --avd Pixel_7 --profile landscape-large-text
```

For the minimum target use `--avd Nexa_Auth_API24`. Exact AVD+SDK guards reject
a mismatched device. Custom CLI paths use `--adb` and `--flutter`; the runner
does not read OS environment. A PASS requires flow, profile and restoration
verification. Do not start another runner merely because observation timed out.

The first separate launch failed after the emulator stopped. After relaunch,
startup exceeded the observation window; the same instance later became ready
without another launch. The old API24 preview runner23158 was then stopped for
display tests. Display settings were restored on both AVDs; API36 WindowManager
rotation policy was restored to free. Recheck availability before use; do not
launch duplicate AVDs from an observation timeout.
See the [latest native handshake handoff](../docs/test-reports/FEAT-TN-001-android-display-handshake-2026-10-26.md)
for current source hashes, four profile results and remaining QA gates.
See the [current UI/backup handoff](../docs/test-reports/FEAT-TN-001-android-login-preview-2026-10-25.md)
for detailed Tester steps, actual logs, source snapshot and remaining gates.

## Workspace picker preview (mock only)

The typed picker presentation now supports explicit selection, pagination,
empty/offline/error/stale/permission/unknown/storage states and generation-aware
callback fencing. It does not call the API or grant workspace access from a
summary. From `mobile/`, on a verified running AVD:

```powershell
flutter run --no-pub --debug -t tool/workspace_preview.dart -d emulator-5554
```

The mock banner must remain visible. Page1 shows A/admin; load more adds B/user;
selecting only shows a simulated notice. Scenario controls, refresh/recovery
and logout reset mock data, not server state. Create workspace is disabled
until its host capability exists. This entry and auth_preview are independent
design tools; main.dart remains the scaffold, not a real login-to-picker app.

Full Flutter suite passes24tests (9workspace+8loginUI+6storage+1parser42cases).
Analyzer passes; scoped formatting passes5files. The earlier full-mobile format
failure in login_screen.dart was subsequently fixed in a separate formatter-only
task after reviewing its four hunks; existing UI/animation behavior was retained.
Full formatting now passes19files with0changes, and all24Flutter tests still pass.
Native workspace mock flow passes one test each on API24 and36 in portrait.
Workspace native landscape/font2x/visual/TalkBack remain unverified; login's
four display profiles do not certify a different component.
See the [workspace Tester runbook and evidence](../docs/test-reports/FEAT-TN-001-android-workspace-ui-2026-10-26.md).

Workspace native display profiles use the shared runner with `--suite workspace`:

```powershell
python -X utf8 -B mobile/tool/run_auth_display_test.py --device emulator-5554 --avd Pixel_7 --suite workspace --profile landscape-large-text
```

Use `--profile portrait` for normal text/portrait and `--avd Nexa_Auth_API24`
on the minimum AVD. The default `--suite login` remains compatible with previous
commands. JSON includes suite/testTarget to distinguish the two mock components;
invalid suites or arbitrary file paths are rejected before launch.
See the [shared display handoff](../docs/test-reports/FEAT-TN-001-android-workspace-display-2026-10-26.md)
for the current matrix, expected-failure evidence, restoration and limitations.

`AvailableWorkspacePage` now validates the default ACTIVE bootstrap response
independently of UI/network/storage. Its consumer test checks72synthetic cases,
including shared fixtures, required cursor, immutable snapshots and duplicate
UUIDs. Cursor strings are preserved verbatim; summaries never grant access.
It does not support historical queries or replace transport/status checks.
The current full Flutter suite passes25tests (including42login and72workspace
consumer cases), analyzer passes and full formatting passes21files unchanged.
See the [consumer handoff](../docs/test-reports/FEAT-TN-001-android-workspace-consumer-2026-10-26.md).
