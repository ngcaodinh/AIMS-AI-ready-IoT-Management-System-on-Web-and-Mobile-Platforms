import { AuthError, getMe, listWorkspaces, login } from '../src/features/auth/api.ts';

let probeStage = 'input';

/** Kiểm invariant mà không đưa input hoặc diagnostic có secret vào lỗi. */
function verify(condition) {
  if (!condition) throw new Error('PROBE_FAILED');
}

/**
 * Chuyển đúng một envelope provider trong RAM qua API/parser Web thật, không mở network.
 * Input
 * Param: operation — một trong ba operation cố định của probe.
 * Param: envelope — status/headers/body thực, không ghi file hoặc echo khi lỗi.
 * Output: DTO thực đã parse; ledger kiểm mọi fetch attempt kể cả request thừa bị catch.
 */
async function parse(operation, envelope) {
  let attempts = 0;
  globalThis.window = { setTimeout, clearTimeout };
  /** Chỉ trả response RAM hiện tại; lần fetch thừa bị đếm trước khi từ chối. */
  globalThis.fetch = async (path, init) => {
    attempts += 1;
    verify(attempts === 1 && path === `/api/v1/${operation === 'login' ? 'auth/login' : operation}`);
    verify(init.credentials === 'include' && init.cache === 'no-store');
    return new Response(JSON.stringify(envelope.body), { status: envelope.status, headers: envelope.headers });
  };
  try {
    return operation === 'login'
      ? await login('probe@example.invalid', 'synthetic-probe-input')
      : operation === 'me' ? await getMe(envelope.headers['X-Auth-Context-Id'] ?? envelope.headers['x-auth-context-id'])
        : await listWorkspaces('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  } finally {
    verify(attempts === 1);
  }
}

/**
 * Kiểm missing/null/type trên từng required key; extension phải không đổi DTO đã parse.
 * Input
 * Param: operation — route/parser được kiểm.
 * Param: envelope — response provider gốc, chỉ clone JSON trong RAM.
 * Param: fields — required keys cùng policy null/type của schema hiện hành.
 * Output: hoàn tất khi parser nhận baseline/extension và từ chối đúng mutation.
 */
async function check(operation, envelope, fields) {
  verify(envelope.status === 200);
  const baseline = await parse(operation, envelope);
  const extended = structuredClone(envelope);
  extended.body.compatibilityExtension = true;
  verify(JSON.stringify(await parse(operation, extended)) === JSON.stringify(baseline));
  for (const [field, nullable, wrongType] of fields) {
    for (const mutation of nullable ? ['missing', 'type'] : ['missing', 'null', 'type']) {
      const changed = structuredClone(envelope);
      if (mutation === 'missing') delete changed.body[field];
      else changed.body[field] = mutation === 'null' ? null : wrongType;
      let rejected = false;
      try {
        await parse(operation, changed);
      } catch (error) {
        rejected = error instanceof AuthError && error.code === 'PROTOCOL_ERROR' && error.message === 'PROTOCOL_ERROR';
      }
      verify(rejected);
    }
  }
  return baseline;
}

/**
 * Kiểm các response lỗi provider qua đúng API operation và mã public hiện hành.
 * Input
 * Param: errors — năm envelope validation/auth/rate/service/context, chỉ giữ trong RAM.
 * Output: true khi đúng status/code, Retry-After và lỗi không giữ message thô của provider.
 */
async function checkErrors(errors) {
  for (const [label, status, code] of [
    ['validation', 422, 'VALIDATION_ERROR'], ['auth', 401, 'AUTH_INVALID'],
    ['rate', 429, 'RATE_LIMITED'], ['service', 503, 'SERVICE_UNAVAILABLE'],
    ['context', 409, 'AUTH_CONTEXT_MISMATCH'],
  ]) {
    probeStage = 'error_' + label;
    const envelope = errors[label];
    verify(envelope.status === status && envelope.body.error.code === code);
    let rejected = false;
    try {
      await parse(label === 'context' ? 'me' : 'login', envelope);
    } catch (error) {
      rejected = error instanceof AuthError && error.status === status && error.code === code
        && error.message === code;
      if (label === 'rate') {
        const retry = new Headers(envelope.headers).get('retry-after');
        verify(retry !== null && /^\d+$/.test(retry) && Number(retry) > 0 && error.retryAfter === Number(retry));
      }
    }
    verify(rejected);
  }
  return true;
}

/** Đọc một packet4envelopes từ stdin hữu hạn; chỉ xuất các boolean cố định, không serialize exception. */
async function main() {
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    verify(size <= 1024 * 1024);
    chunks.push(chunk);
  }
  const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  probeStage = 'full_login';
  const loginResult = await check('login', input.webLogin, [
    ['me', false, []], ['limited', false, []], ['expiresAt', false, []],
  ]);
  verify(loginResult.me.id === input.webLogin.body.me.id && loginResult.me.email === input.webLogin.body.me.email);
  probeStage = 'profile';
  const me = await check('me', input.profile, [
    ['id', false, []], ['email', false, []], ['mustChangePassword', false, []],
    ['displayTimezone', false, []], ['preferencesRevision', false, []],
  ]);
  verify(me.kind === 'full' && me.me.id === input.profile.body.id);
  probeStage = 'workspaces';
  const page = await check('workspaces', input.workspaces, [['items', false, 17], ['nextCursor', true, 17]]);
  verify(page.items.length === input.workspaces.body.items.length);
  // Chặn fixture không row để mutation summary không bị bỏ qua mà vẫn báo thành công.
  verify(page.items.length > 0);
  for (const field of ['id', 'name', 'status', 'role', 'revision']) {
    for (const mutation of ['missing', 'null', 'type']) {
      const changed = structuredClone(input.workspaces);
      if (mutation === 'missing') delete changed.body.items[0][field];
      else changed.body.items[0][field] = mutation === 'null' ? null : [];
      let rejected = false;
      try { await parse('workspaces', changed); }
      catch (error) { rejected = error instanceof AuthError && error.code === 'PROTOCOL_ERROR' && error.message === 'PROTOCOL_ERROR'; }
      verify(rejected);
    }
  }
  probeStage = 'transport';
  let bearerRejected = false;
  try { await parse('login', { ...input.webLogin, body: input.appLogin.body }); }
  catch (error) { bearerRejected = error instanceof AuthError && error.code === 'PROTOCOL_ERROR' && error.message === 'PROTOCOL_ERROR'; }
  verify(bearerRejected);
  const result = { webLogin: true, profile: true, workspaces: true, compatibility: true, webBearerRejected: true };
  if ('webLimitedLogin' in input || 'webLimitedMe' in input) {
    probeStage = 'limited_login';
    const limited = await check('login', input.webLimitedLogin, [
      ['me', false, []], ['limited', false, []], ['expiresAt', false, []],
    ]);
    verify(limited.limited === true && limited.me.mustChangePassword === true);
    verify(input.webLimitedMe.status === 403 && input.webLimitedMe.body.error.code === 'PASSWORD_CHANGE_REQUIRED');
    probeStage = 'limited_me';
    const confirmed = await parse('me', input.webLimitedMe);
    verify(confirmed.kind === 'limited' && confirmed.contextId === limited.contextId && !('me' in confirmed));
    result.limited = true;
  }
  if ('webErrors' in input) result.errors = await checkErrors(input.webErrors);
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

try { await main(); }
catch {
  process.stderr.write(`PROBE_STAGE_${probeStage}\n`);
  process.stdout.write('{"webLogin":false,"profile":false,"workspaces":false,"compatibility":false,"webBearerRejected":false}\n');
  process.exitCode = 1;
}
