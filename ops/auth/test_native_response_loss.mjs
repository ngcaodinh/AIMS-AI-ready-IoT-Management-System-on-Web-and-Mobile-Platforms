import assert from 'node:assert/strict';
import { test } from 'node:test';
import { scanDebugOutput } from './run_native_response_loss_e2e.mjs';
import { nativePhaseBudget } from './run_native_e2e.mjs';

const secret = 'synthetic-private-canary-0123456789';

test('debug scanner uses observed bytes and never prints a raw canary',
  /** Nonempty control phải có zero match; sink trống không được báo PASS giả. */
  () => {
    const result = scanDebugOutput('app_debug', Buffer.from('{"event":"NATIVE_READY"}'), [secret]);
    assert.equal(result.status, 'PASS');
    assert.equal(result.canaryMatches, 0);
    assert.equal(result.namedFieldMatches, 0);
    assert.equal(scanDebugOutput('sdk_stderr', Buffer.alloc(0), [secret]).status, 'EMPTY');
    assert.ok(!JSON.stringify(result).includes(secret));
  });

test('raw and encoded canaries fail the same scanner',
  /** Positive fault controls bắt plaintext/Base64, không để matcher luônfalse tạo evidence an toàn giả. */
  () => {
    for (const value of [secret, Buffer.from(secret).toString('base64')]) {
      assert.throws(
        /** Assertion failure chỉ serialize số match, không đưa token vào expected/actual. */
        () => scanDebugOutput('app_debug', Buffer.from(value), [secret]));
    }
  });

test('named sensitive fields fail without needing their exact values',
  /** Tên field bắt credential chưa được đăng ký canary trong escaped SDK log. */
  () => {
    for (const name of ['Authorization', 'Cookie', 'Set-Cookie', 'password', 'token', 'email']) {
      assert.throws(
        /** Đưa value tổng hợp trong RAM vào matcher, chỉ kiểm có throw. */
        () => scanDebugOutput('sdk_stdout', Buffer.from(JSON.stringify({ [name]: 'synthetic-value' })), [secret]));
    }
  });

test('response loss has a finite native phase budget',
  /** Cap240s đủ fault/quiet/recover nhưng không mở deadline do packet hoặc repeated ACK. */
  () => assert.deepEqual(nativePhaseBudget('response-loss'), { testMilliseconds: 240000, reserveMilliseconds: 960000 }));
