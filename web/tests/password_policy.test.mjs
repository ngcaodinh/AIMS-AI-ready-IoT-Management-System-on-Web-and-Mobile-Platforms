import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { validatePassword } from '../src/features/auth/passwordPolicy.ts';

/** Oracle chung phân biệt mật khẩu đăng nhập/current/new, kiểm Unicode và đúng cận9–128 mà không gọi API. */
test('password policy matches shared cross-platform cases', () => {
  const fixture = JSON.parse(readFileSync(new URL('../../contracts/fixtures/auth/password-policy.json', import.meta.url), 'utf8'));
  assert.equal(fixture.policyVersion, 1);
  for (const example of fixture.cases) {
    for (const purpose of ['login', 'current', 'new']) {
      const result = validatePassword(example.password, purpose);
      assert.equal(result?.code ?? null, example[`${purpose}Error`], `${example.id}:${purpose}`);
      if (result) assert.ok(result.message.length > 0);
    }
  }
});
