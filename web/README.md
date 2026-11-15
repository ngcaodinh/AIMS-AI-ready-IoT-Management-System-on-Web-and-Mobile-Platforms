# Web client

React and TypeScript web application for workspace administration, template editing, dashboard building and rule management.

The landing page in `src/` is a React + TypeScript conversion of `../docs/UI web/home (2).html`. It uses Tailwind CSS 4 utilities for the page layout and shared visual styles, with `styles.css` retaining theme tokens, gradients, pseudo-elements, animation and detailed device/rule demo styles. The landing demonstrations use local sample state only and do not send API or MQTT commands. `/login` now uses the real auth API and coordinator; the test suite uses explicit mocks.

From `web/`, use `npm ci` to install the dependencies recorded in `package-lock.json`, `npm run dev` to preview, and `npm run build` to check TypeScript and create a production bundle. The dependency versions are compatibility candidates until the recorded Node/Web PoC is complete.

Web clients use the shared HTTP/WS contracts in `../contracts`; they never connect to MQTT directly or store bearer sessions in local storage.

Password policy2026-10-26: new passwords require9–128Unicode codepoints,
Uppercase +Lowercase and an ASCII digit0–9. Login checks9–128length without
rejecting legacy composition; currentPassword remains1–128. No trim or required
special character. Current2026-10-28 checks:25auth tests and TypeScript/Vite
build42modules pass. Chrome validation/theme/responsive/keyboard and recovery
without backend are verified; successful API E2E remains pending. See the [policy handoff and Tester steps](../docs/test-reports/FEAT-TN-001-password-policy-2026-10-26.md)
for shared fixture parity, client/server behavior and current limitations.

Auth preview: `npm.cmd run dev`, then `http://localhost:5173/login`; Vite proxies
`/api/v1` to loopback3000. Keep `localhost` because exact Origin is configured.
`npm.cmd run build` and `npm.cmd run test:auth` pass, but browser E2E remains
partial. Temporary DB role/fixtures are already authorized. After the updated
execution policy, outside-sandbox canonical provider176assertions/163distinct
and cleanup readback0 pass. That verify run exited and cleaned its fixture;
there is no interactive backend from that run. CUA browser/native hosts are
currently unavailable for further browser execution.

### FEAT-TN-002 login E2E readiness

Before entering any fixture credentials, start the approved Auth API fixture
workflow from the repository root and keep its terminal open:

```powershell
python -X utf8 -B ops/auth/run_local.py --port 3000
```

The fixture launcher may build `auth-lab` into `backend/target`; run it only
where the applicable build artifact policy permits that write, and use only the
synthetic fixture account/password it provides. Then start Vite from `web/` with
`npm.cmd run dev`; in another `web/` terminal, run `npm.cmd run check:auth-api`.
The check sends only an unauthenticated `GET /api/v1/me` through the same-origin
proxy and passes only on `401 application/json`. If it fails, do not submit login:
the auth dependency is not ready, so a password attempt cannot diagnose that
startup failure. Open `http://localhost:5173/login` only after the check passes.
The Web coordinator also repeats this no-cookie probe on every login submit,
before it writes an intent or sends the password. If the probe fails, the form
shows service unavailable without sending a login POST; if the API drops after
the probe, the existing recovery state stays UNKNOWN and does not replay POST.
Android main now wires the real API/store/coordinator and passes128root widget/
unit tests. Independent test design/review passes; runtime execution is by root.
Independent runtime and native HTTPS E2E remain pending.
See the [current Web report](../docs/test-reports/FEAT-TN-001-web-browser-2026-10-28.md)
and [App tester runbook](../docs/test-reports/FEAT-TN-001-android-application-2026-10-28.md)
before testing login, limited session, workspace switching and error recovery.

The `/login` presentation now follows the Nexa task form: responsive centered
card, shared SVG icons, light/dark theme, accessible field labels, password
visibility and status/error/loading treatments. See the [UI handoff and manual QA checklist](../docs/test-reports/FEAT-TN-001-login-ui-2026-10-24.md).
Earlier Chrome runtime is recorded; the current CUA host is unavailable.
Input boundaries use existing muted/teal-deep tokens;
error surfaces use a subtle coral tint with ink text in both themes. Browser
screenshots and DOM measurements are recorded separately from API acceptance.

