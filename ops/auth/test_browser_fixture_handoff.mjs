import assert from 'node:assert/strict';
import { constants, generateKeyPairSync, publicEncrypt } from 'node:crypto';
import { parseBrowserRecipient, encryptBrowserFixture, decryptBrowserFixture } from './browser_fixture_handoff.mjs';

/** Kiểm transfer credential synthetic bằng OAEP, không DB/SDK/browser hoặc xuất private data. */
function main() {
  const recipient = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const other = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const publicKey = recipient.publicKey.export({ format: 'der', type: 'spki' }).toString('base64');
  const parsed = parseBrowserRecipient(publicKey);
  const runId = 'aaaaaaaa-1111-4111-8111-111111111111';
  const ready = { runId, emails: Array.from({ length: 5 }, /** Namespace fixture có đúng index0–4. */
    (_, index) => `probe-${runId}-${index}@example.invalid`) };
  const password = 'Aa1' + 'd'.repeat(32);
  const encrypted = encryptBrowserFixture(ready, password, parsed);
  assert.equal(Buffer.from(encrypted, 'base64').length, 256);
  assert.ok(!encrypted.includes(password));
  const decoded = decryptBrowserFixture(encrypted, recipient.privateKey);
  assert.equal(decoded.runId, runId); assert.equal(decoded.password, password);
  assert.deepEqual(decoded.emails, ready.emails);
  assert.notEqual(encryptBrowserFixture(ready, password, parsed), encrypted);
  for (const value of ['', publicKey + '\n', 'invalid', null]) assert.throws(
    /** Base64 noncanonical hoặc key thiếu không được admit fixture. */
    () => parseBrowserRecipient(value), { message: 'BROWSER_RECIPIENT_INVALID' });
  assert.throws(/** Key EC không dùng làm RSA recipient dù là SPKI hợp lệ. */
    () => parseBrowserRecipient(generateKeyPairSync('ed25519').publicKey.export({ format: 'der', type: 'spki' }).toString('base64')),
    { message: 'BROWSER_RECIPIENT_INVALID' });
  assert.throws(/** Foreign identity không được mã hóa để gửi credential cho browser. */
    () => encryptBrowserFixture({ ...ready, emails: ['foreign@example.invalid', ...ready.emails.slice(1)] }, password, parsed),
    { message: 'BROWSER_FIXTURE_HANDOFF_INVALID' });
  for (const value of ['', encrypted.slice(1), encrypted + 'AA==', encrypted + '\n']) assert.throws(
    /** Frame phải canonical và đúng256bytes, không bỏ qua phần dư hoặc truncated frame. */
    () => decryptBrowserFixture(value, recipient.privateKey), { message: 'BROWSER_FIXTURE_HANDOFF_INVALID' });
  assert.throws(/** Ciphertext không có giá trị với private key khác. */
    () => decryptBrowserFixture(encrypted, other.privateKey), { message: 'BROWSER_FIXTURE_HANDOFF_INVALID' });
  for (const payload of [
    { version: 2, runId, password }, { version: 1, runId, password, extra: true },
    { version: 1, runId: 'foreign', password }, { version: 1, runId, password: 'short' },
  ]) {
    const frame = publicEncrypt({ key: parsed, padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' },
      Buffer.from(JSON.stringify(payload))).toString('base64');
    assert.throws(/** OAEP hợp lệ vẫn cần payload schema/namespace validation trước UI. */
      () => decryptBrowserFixture(frame, recipient.privateKey), { message: 'BROWSER_FIXTURE_HANDOFF_INVALID' });
  }
  console.log('BROWSER_FIXTURE_OAEP_NAMESPACE_FRAME_REDACTION_PASS');
}

try { main(); } catch {
  // Assertion có thể chứa password synthetic nên chỉ phát fixed marker.
  console.error('BROWSER_FIXTURE_HANDOFF_TEST_FAILED'); process.exitCode = 1;
}
