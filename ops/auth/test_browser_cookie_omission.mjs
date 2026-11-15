import assert from 'node:assert/strict';
import { createBrowserCookieOmission } from './browser_cookie_omission.mjs';

const request = { method: 'POST', url: '/api/v1/auth/login' };
/** Output: header marker synthetic không là auth credential, body reference kiểm byte-preserving. */
function response() {
  return { statusCode: 200, headers: { 'set-cookie': ['synthetic-cookie-marker'], 'x-auth-context-id': 'public-marker' },
    body: Buffer.from('synthetic-response-body') };
}
const fault = createBrowserCookieOmission(); const first = response();
fault.intercept(first, request); assert.ok(Object.hasOwn(first.headers, 'set-cookie'));
fault.arm(); const body = first.body; fault.intercept(first, request);
assert.equal(Object.hasOwn(first.headers, 'set-cookie'), false); assert.equal(first.body, body);
assert.equal(first.headers['x-auth-context-id'], 'public-marker');
assert.deepEqual(fault.receipt(), { armed: false, consumed: true });
const second = response(); fault.intercept(second, request); assert.ok(Object.hasOwn(second.headers, 'set-cookie'));
assert.throws(/** Replay phải chặn trước response tiếp theo. */ () => fault.arm());
console.log('BROWSER_COOKIE_OMISSION_ONE_SHOT_PASS');
for (const mode of ['method', 'path', 'query', 'status']) {
  const test = createBrowserCookieOmission(); test.arm(); const reply = response(); const candidate = { ...request };
  if (mode === 'method') candidate.method = 'GET';
  if (mode === 'path') candidate.url = '/api/v1/auth/logout';
  if (mode === 'query') candidate.url += '?extra=1';
  if (mode === 'status') reply.statusCode = 401;
  test.intercept(reply, candidate); assert.ok(Object.hasOwn(reply.headers, 'set-cookie'));
  assert.deepEqual(test.receipt(), { armed: true, consumed: false });
  console.log('BROWSER_COOKIE_OMISSION_' + mode.toUpperCase() + '_PASS');
}
const missing = createBrowserCookieOmission(); missing.arm();
assert.throws(/** Không được công bố consumed khi upstream không phát cookie. */
  () => missing.intercept({ statusCode: 200, headers: {} }, request));
assert.deepEqual(missing.receipt(), { armed: true, consumed: false });
console.log('BROWSER_COOKIE_OMISSION_MISSING_HEADER_PASS');
