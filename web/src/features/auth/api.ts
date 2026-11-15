export interface Profile {
  id: string;
  email: string;
  mustChangePassword: boolean;
}

export interface Workspace {
  id: string;
  name: string;
  status: 'ACTIVE';
  role: 'ADMIN' | 'USER';
  revision: number;
}

export interface SessionMetadata {
  contextId: string;
  csrfToken: string;
}

export interface LoginResult extends SessionMetadata {
  me: Profile;
  limited: boolean;
  expiresAt: string;
}

export type MeResult = SessionMetadata & (
  { kind: 'full'; me: Profile } | { kind: 'limited' }
);

/** Lỗi an toàn cho UI; không giữ body response hoặc thông tin credential. */
export class AuthError extends Error {
  /** Gắn code/status và thời gian chờ để UI xử lý mà không echo dữ liệu server tùy ý. */
  constructor(public code: string, public status = 0, public retryAfter = 0) {
    super(code);
  }
}

// Giới hạn thời gian chờ probe trước login (ms); đủ cho loopback nhưng không giữ form ở trạng thái loading lâu.
const AUTH_API_READINESS_TIMEOUT_MS = 5000;

/** Kiểm object JSON ở biên mạng trước khi đọc field không đáng tin. */
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** Xác minh UUID context/identity; UUID chỉ là định danh, không là quyền. */
export function isUuid(value: unknown): value is string {
  return typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

/** Parse profile tối thiểu; bỏ qua extension nhưng không tin role global. */
function parseProfile(value: unknown): Profile {
  if (!isRecord(value) || !isUuid(value.id) || typeof value.email !== 'string'
    || typeof value.mustChangePassword !== 'boolean') throw new AuthError('PROTOCOL_ERROR');
  return { id: value.id, email: value.email, mustChangePassword: value.mustChangePassword };
}

/** Đọc metadata Web bắt buộc; CSRF chỉ đi qua memory của coordinator. */
function parseMetadata(response: Response): SessionMetadata {
  const contextId = response.headers.get('X-Auth-Context-Id');
  const csrfToken = response.headers.get('X-CSRF-Token');
  if (!isUuid(contextId) || !csrfToken) throw new AuthError('PROTOCOL_ERROR');
  return { contextId, csrfToken };
}

/** Kiểm tra dependency trước khi tạo login intent để outage proxy không bị nhầm với credential bị từ chối.
 * Output: hoàn tất khi `/me` trả đúng HTTP 401 `application/json`; nếu không thì không cho caller tiếp tục.
 * Errors: ném `SERVICE_UNAVAILABLE` khi timeout, mất kết nối, redirect hoặc status/media type khác contract.
 * Side effects: chỉ gửi GET `/api/v1/me` với cookie bị bỏ qua; không đọc body hoặc thay đổi phiên.
 */
export async function assertAuthApiReady(): Promise<void> {
  const controller = new AbortController();
  const timeout = window.setTimeout(
    /** Hủy probe treo để người dùng có thể thử lại mà không chờ vô hạn. */
    () => controller.abort(), AUTH_API_READINESS_TIMEOUT_MS,
  );
  try {
    // Probe bỏ cookie cũ để readiness luôn dựa trên response unauthenticated của cùng API route.
    const response = await fetch('/api/v1/me', {
      method: 'GET',
      credentials: 'omit',
      cache: 'no-store',
      redirect: 'error',
      signal: controller.signal,
    });
    const contentType = response.headers.get('content-type')
      ?.split(';', 1)[0]
      .trim()
      .toLowerCase();

    // Chỉ coi API sẵn sàng khi route xác thực trả đúng trạng thái unauthenticated; mọi proxy/fallback khác đều chặn POST.
    if (response.status !== 401 || contentType !== 'application/json') {
      throw new AuthError('SERVICE_UNAVAILABLE', response.status);
    }
  } catch (error) {
    if (error instanceof AuthError) throw error;
    throw new AuthError('SERVICE_UNAVAILABLE');
  } finally {
    window.clearTimeout(timeout);
  }
}

/** Gửi request có timeout hữu hạn, giữ UNKNOWN khi mutation mất response và nhận diện 5xx không có JSON là dịch vụ gián đoạn. */
async function request(path: string, init: RequestInit = {}): Promise<{ response: Response; body: unknown }> {
  const controller = new AbortController();
  // Đây là deadline UX, không thay thế timeout/transaction guard phía backend.
  const timeout = window.setTimeout(
    /** Hủy chờ khi hết deadline; kết quả mutation trên server vẫn có thể UNKNOWN. */
    () => controller.abort(), 15000,
  );
  try {
    const response = await fetch(`/api/v1${path}`, {
      ...init, credentials: 'include', cache: 'no-store', signal: controller.signal,
    });
    if (response.status === 204) return { response, body: null };
    let body: unknown;
    try {
      body = await response.json();
    } catch (error) {
      if (!response.ok && response.status >= 500) {
        // Proxy có thể trả body rỗng hoặc HTML khi auth upstream dừng; caller vẫn giữ mutation ở UNKNOWN và báo dịch vụ gián đoạn.
        return { response, body: { error: { code: 'SERVICE_UNAVAILABLE' } } };
      }
      throw error;
    }
    return { response, body };
  } catch (error) {
    if (error instanceof AuthError) throw error;
    throw new AuthError(error instanceof SyntaxError ? 'PROTOCOL_ERROR' : 'NETWORK_ERROR');
  } finally {
    window.clearTimeout(timeout);
  }
}

/** Chỉ lấy mã lỗi/cooldown đã định dạng; không đưa message/stack thô của server ra UI. */
function rejectResponse(response: Response, body: unknown): never {
  const code = isRecord(body) && isRecord(body.error) && typeof body.error.code === 'string'
    ? body.error.code : 'PROTOCOL_ERROR';
  const retryValue = response.headers.get('Retry-After');
  const retryAfter = retryValue && /^\d+$/.test(retryValue) ? Number(retryValue) : 0;
  throw new AuthError(code, response.status, Number.isSafeInteger(retryAfter) ? retryAfter : 0);
}

/** Login Web qua cookie HttpOnly; từ chối body chứa token kể cả có field extension. */
export async function login(email: string, password: string): Promise<LoginResult> {
  const { response, body } = await request('/auth/login', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password, clientType: 'WEB' }),
  });
  if (!response.ok) rejectResponse(response, body);
  if (!isRecord(body) || 'token' in body || typeof body.limited !== 'boolean'
    || typeof body.expiresAt !== 'string' || !Number.isFinite(Date.parse(body.expiresAt))) {
    throw new AuthError('PROTOCOL_ERROR');
  }
  const me = parseProfile(body.me);
  if (me.mustChangePassword !== body.limited) throw new AuthError('PROTOCOL_ERROR');
  return { me, limited: body.limited, expiresAt: body.expiresAt, ...parseMetadata(response) };
}

/** /me xác nhận full/limited; caller phải đối soát context trước khi mở protected UI. */
export async function getMe(contextId?: string): Promise<MeResult> {
  const { response, body } = await request('/me', {
    headers: contextId ? { 'X-Auth-Context-Id': contextId } : {},
  });
  if (response.status === 403 && isRecord(body) && isRecord(body.error)
    && body.error.code === 'PASSWORD_CHANGE_REQUIRED') {
    return { kind: 'limited', ...parseMetadata(response) };
  }
  if (!response.ok) rejectResponse(response, body);
  const me = parseProfile(body);
  if (me.mustChangePassword || !isRecord(body) || typeof body.displayTimezone !== 'string'
    || !Number.isInteger(body.preferencesRevision) || Number(body.preferencesRevision) < 1) {
    throw new AuthError('PROTOCOL_ERROR');
  }
  return { kind: 'full', me, ...parseMetadata(response) };
}

/** Parse summary chỉ cho workspace ACTIVE, role từ membership và revision nguyên dương. */
function parseWorkspace(value: unknown): Workspace {
  if (!isRecord(value) || !isUuid(value.id) || typeof value.name !== 'string'
    || value.status !== 'ACTIVE' || (value.role !== 'ADMIN' && value.role !== 'USER')
    || !Number.isInteger(value.revision) || Number(value.revision) < 1) {
    throw new AuthError('PROTOCOL_ERROR');
  }
  return { id: value.id, name: value.name, status: value.status, role: value.role, revision: Number(value.revision) };
}

/** Tải một trang picker; trang rỗng có cursor chưa được coi là empty cuối cùng. */
export async function listWorkspaces(contextId: string, cursor?: string): Promise<{ items: Workspace[]; nextCursor: string | null }> {
  const { response, body } = await request(`/workspaces${cursor ? `?cursor=${encodeURIComponent(cursor)}` : ''}`, {
    headers: { 'X-Auth-Context-Id': contextId },
  });
  if (!response.ok) rejectResponse(response, body);
  if (!isRecord(body) || !Array.isArray(body.items)
    || !(body.nextCursor === null || typeof body.nextCursor === 'string')) throw new AuthError('PROTOCOL_ERROR');
  return { items: body.items.map(parseWorkspace), nextCursor: body.nextCursor };
}

/** Recheck quyền hiện hành sau lựa chọn; summary cũ không là authorization grant. */
export async function selectWorkspace(contextId: string, workspaceId: string): Promise<Workspace> {
  const { response, body } = await request(`/workspaces/${encodeURIComponent(workspaceId)}`, {
    headers: { 'X-Auth-Context-Id': contextId },
  });
  if (!response.ok) rejectResponse(response, body);
  const workspace = parseWorkspace(body);
  if (workspace.id !== workspaceId || !isRecord(body) || body.membershipStatus !== 'ACTIVE') throw new AuthError('PROTOCOL_ERROR');
  return workspace;
}

/** Mutation chỉ được gửi với CSRF/context đã xác nhận của cùng phiên cookie. */
export async function mutateSession(path: '/auth/logout' | '/auth/password', session: SessionMetadata, body?: { currentPassword: string; newPassword: string }): Promise<void> {
  const { response, body: result } = await request(path, {
    method: 'POST', headers: {
      'X-Auth-Context-Id': session.contextId, 'X-CSRF-Token': session.csrfToken,
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    }, body: body ? JSON.stringify(body) : undefined,
  });
  if (response.status !== 204) rejectResponse(response, result);
}
