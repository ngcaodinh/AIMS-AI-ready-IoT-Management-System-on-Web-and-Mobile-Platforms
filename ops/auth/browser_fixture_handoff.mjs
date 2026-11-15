import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { constants, createPublicKey, publicEncrypt, privateDecrypt } from 'node:crypto';

/**
 * Kiểm packet chỉ chứa credential synthetic của namespace lab, trước khi mã hóa hoặc điền UI.
 * Input
 * Param: packet — object version/runId/password, không nhận account thật hoặc trường bổ sung.
 * Errors: assertion chỉ nội bộ, các public boundary chuyển thành fixed error không có dữ liệu.
 */
function validateBrowserPacket(packet) {
  const keys = ['version', 'runId', 'password'];
  assert.ok(packet && typeof packet === 'object' && !Array.isArray(packet) && Object.keys(packet).length === 3 &&
    keys.every(/** Mọi key trong schema phải là own property của packet. */ (key) => Object.hasOwn(packet, key)) &&
    packet.version === 1 && typeof packet.runId === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(packet.runId) &&
    typeof packet.password === 'string' && /^Aa1[0-9a-f]{32}$/.test(packet.password));
}

/**
 * Chỉ admit public SPKI RSA2048 canonical trước khi tạo fixture hoặc credential.
 * Input
 * Param: encodedKey — DER SPKI Base64 công khai từ controller giữ private key trong RAM.
 * Output: public KeyObject RSA2048, không có private material.
 * Errors: fixed BROWSER_RECIPIENT_INVALID, không echo ASN.1 error hoặc input.
 */
export function parseBrowserRecipient(encodedKey) {
  try {
    assert.ok(typeof encodedKey === 'string' && encodedKey.length > 0 && encodedKey.length <= 1024);
    const bytes = Buffer.from(encodedKey, 'base64');
    assert.equal(bytes.toString('base64'), encodedKey);
    const key = createPublicKey({ key: bytes, format: 'der', type: 'spki' });
    assert.ok(key.type === 'public' && key.asymmetricKeyType === 'rsa' && key.asymmetricKeyDetails.modulusLength === 2048);
    assert.ok(key.export({ format: 'der', type: 'spki' }).equals(bytes));
    return key;
  } catch { throw new Error('BROWSER_RECIPIENT_INVALID'); }
}

/**
 * Mã hóa credential của đúng5identities owned để chuyển qua tool stdout dưới dạng ciphertext.
 * Input
 * Param: ready — READY của original fixture, chứa runId và emails chuẩn namespace.
 * Param: password — CSPRNG Aa1+32hex của lượt thử, giữ trong RAM.
 * Param: recipient — public KeyObject đã được parseBrowserRecipient kiểm.
 * Output: ciphertext256bytes dạng Base64, không thể dùng làm password hoặc bearer token.
 * Errors: fixed BROWSER_FIXTURE_HANDOFF_INVALID. Provenance dựa vào owned tool handle, OAEP không xác thực sender.
 */
export function encryptBrowserFixture(ready, password, recipient) {
  let plaintext;
  try {
    const packet = { version: 1, runId: ready?.runId, password };
    validateBrowserPacket(packet);
    assert.ok(Array.isArray(ready.emails) && ready.emails.length === 5 && ready.emails.every(
      /** Kiểm email tại index0–4 thuộc chính runId đã được fixture cấp. */
      (email, index) => email === `probe-${packet.runId}-${index}@example.invalid`));
    assert.ok(recipient?.type === 'public' && recipient.asymmetricKeyType === 'rsa' && recipient.asymmetricKeyDetails.modulusLength === 2048);
    plaintext = Buffer.from(JSON.stringify(packet), 'utf8');
    // OAEP SHA256 trên RSA2048 nhận tối đa256−2×32−2=190bytes, không tự chia credential thành nhiều frame.
    assert.ok(plaintext.length <= 190);
    return publicEncrypt({ key: recipient, padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' }, plaintext).toString('base64');
  } catch { throw new Error('BROWSER_FIXTURE_HANDOFF_INVALID'); }
  finally { plaintext?.fill(0); }
}

/**
 * Giải mã đúng frame từ owned helper trong controller, kiểm schema trước mọi thao tác browser.
 * Input
 * Param: encodedCiphertext — đúng256bytes RSA ciphertext Base64 canonical, nhận từ trusted tool handle.
 * Param: privateKey — RSA2048 private KeyObject chỉ giữ trong RAM controller.
 * Output: runId/password và5emails synthetic trong RAM, caller không log hoặc đưa vào screenshot.
 * Errors: fixed BROWSER_FIXTURE_HANDOFF_INVALID, không trả raw crypto/JSON/plaintext error.
 */
export function decryptBrowserFixture(encodedCiphertext, privateKey) {
  let plaintext;
  try {
    assert.ok(typeof encodedCiphertext === 'string' && encodedCiphertext.length === 344);
    const ciphertext = Buffer.from(encodedCiphertext, 'base64');
    assert.ok(ciphertext.length === 256 && ciphertext.toString('base64') === encodedCiphertext);
    assert.ok(privateKey?.type === 'private' && privateKey.asymmetricKeyType === 'rsa' && privateKey.asymmetricKeyDetails.modulusLength === 2048);
    plaintext = privateDecrypt({ key: privateKey, padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' }, ciphertext);
    assert.ok(plaintext.length <= 190);
    const packet = JSON.parse(plaintext.toString('utf8'));
    validateBrowserPacket(packet);
    return { runId: packet.runId, password: packet.password,
      emails: Array.from({ length: 5 }, /** Derive email tại index0–4, không nhận destination từ ciphertext. */
        (_, index) => `probe-${packet.runId}-${index}@example.invalid`) };
  } catch { throw new Error('BROWSER_FIXTURE_HANDOFF_INVALID'); }
  finally { plaintext?.fill(0); }
}
