import type { SessionMetadata } from '../auth/api.ts';

/** Lỗi chi tiết gắn theo đường dẫn JSON Pointer từ ErrorEnvelope của API. */
export interface ApiFieldError {
  path: string;
  code: string;
}

/** Dữ liệu lỗi đã chuẩn hóa từ backend; không chứa thông điệp thô hoặc secret. */
export class WorkspaceApiError extends Error {
  /** Khởi tạo lỗi boundary với mã enum, HTTP status và metadata đối soát an toàn. */
  constructor(
    public code: string,
    public status = 0,
    public fieldErrors: ApiFieldError[] = [],
    public correlationId?: string,
    public currentRevision?: number,
    public operationId?: string,
  ) {
    super(code);
  }
}

export interface WorkspaceRequestOptions {
  method?: 'GET' | 'POST' | 'PATCH' | 'DELETE';
  workspaceId: string;
  session: SessionMetadata;
  ifMatchRevision?: number;
  idempotencyKey?: string;
  body?: unknown;
  rawJsonBody?: string;
  parseResponseText?: (rawText: string) => unknown;
  signal?: AbortSignal;
}

// Mẫu UUID 8-4-4-4-12 theo định nghĩa `$defs/Uuid` trong schema G1.
const CONTRACT_UUID_PATTERN = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
// Mẫu thời gian UTC kết thúc bằng `Z` theo `$defs/UtcTimestamp` trong schema G1.
const UTC_TIMESTAMP_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/;
// Giới hạn ký tự cho Idempotency-Key: 16–128 ký tự ASCII in được, không khoảng trắng.
const IDEMPOTENCY_KEY_PATTERN = /^[!-~]{16,128}$/;
// Giới hạn kích thước JSON 64 KiB chung cho toàn bộ mutation REST.
export const MAX_REST_BODY_BYTES = 65_536;
// Thời gian chờ tối đa (ms) cho một lời gọi REST ở giao diện; timeout không khẳng định rollback trên server.
const WORKSPACE_REQUEST_TIMEOUT_MS = 15_000;

/**
 * Kiểm tra giá trị có phải đối tượng JSON phẳng (không phải mảng hay null) ở biên mạng.
 * Input
 * Param: value — dữ liệu chưa tin cậy từ JSON.parse.
 * Output: true khi value là record hợp lệ.
 */
export function isJsonRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * Kiểm tra chuỗi có khớp định dạng UUID 36 ký tự trong contract G1 hay không.
 * Input
 * Param: value — giá trị cần kiểm định danh UUID.
 * Output: true khi là chuỗi UUID hợp lệ.
 */
export function isContractUuid(value: unknown): value is string {
  return typeof value === 'string' && CONTRACT_UUID_PATTERN.test(value);
}

/**
 * Kiểm tra chuỗi timestamp UTC kết thúc bằng `Z` và phân tích được bằng `Date.parse`.
 * Input
 * Param: value — chuỗi thời gian cần kiểm tra.
 * Output: true khi khớp UtcTimestamp hợp lệ.
 */
export function isUtcTimestamp(value: unknown): value is string {
  return typeof value === 'string'
    && UTC_TIMESTAMP_PATTERN.test(value)
    && Number.isFinite(Date.parse(value));
}

/**
 * Kiểm tra chuỗi số có phải số nguyên dương >= 1 hay không (dùng cho revision/version).
 * Input
 * Param: value — giá trị cần kiểm tra.
 * Output: true khi là số nguyên an toàn >= 1.
 */
export function isPositiveInt(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 1;
}

/**
 * Kiểm tra chuỗi số có phải số nguyên không âm >= 0 hay không (dùng cho retryCount).
 * Input
 * Param: value — giá trị cần kiểm tra.
 * Output: true khi là số nguyên an toàn >= 0.
 */
export function isNonNegativeInt(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

/**
 * Đếm số Unicode code point thực tế để đồng nhất với rule độ dài backend/schema.
 * Input
 * Param: text — chuỗi đầu vào cần đo.
 * Output: số lượng code point.
 */
export function countCodePoints(text: string): number {
  return Array.from(text).length;
}

/**
 * Từ chối object chứa key ngoài danh sách cho phép để giữ `additionalProperties: false` ở boundary.
 * Input
 * Param: record — object JSON đã kiểm kiểu record.
 * Param: allowedKeys — tập key được schema G1 cho phép.
 * Errors: ném `WorkspaceApiError('PROTOCOL_ERROR')` nếu phát hiện key lạ.
 */
export function assertAllowedKeys(
  record: Record<string, unknown>,
  allowedKeys: ReadonlySet<string>,
): void {
  for (const key of Object.keys(record)) {
    if (!allowedKeys.has(key)) {
      throw new WorkspaceApiError('PROTOCOL_ERROR');
    }
  }
}

/**
 * Phân tích ErrorEnvelope chuẩn G1 mà không phản chiếu message thô hay dữ liệu nhạy cảm.
 * Input
 * Param: status — HTTP status trả về từ fetch.
 * Param: body — payload JSON đã parse từ phản hồi lỗi.
 * Output: đối tượng `WorkspaceApiError` mang mã enum, fieldErrors và chi tiết an toàn.
 */
export function parseErrorEnvelope(status: number, body: unknown): WorkspaceApiError {
  if (!isJsonRecord(body) || !isJsonRecord(body.error)) {
    return new WorkspaceApiError(status >= 500 ? 'SERVICE_UNAVAILABLE' : 'PROTOCOL_ERROR', status);
  }
  const err = body.error;
  if (typeof err.code !== 'string' || !/^[A-Z][A-Z0-9_]*$/.test(err.code)) {
    return new WorkspaceApiError('PROTOCOL_ERROR', status);
  }
  const correlationId = isContractUuid(err.correlationId) ? err.correlationId : undefined;
  const fieldErrors: ApiFieldError[] = [];
  let currentRevision: number | undefined;
  let operationId: string | undefined;

  if (isJsonRecord(err.details)) {
    if (Array.isArray(err.details.fieldErrors)) {
      for (const item of err.details.fieldErrors) {
        if (isJsonRecord(item) && typeof item.path === 'string' && typeof item.code === 'string' && item.code.length > 0) {
          fieldErrors.push({ path: item.path, code: item.code });
        }
      }
    }
    if (isPositiveInt(err.details.currentRevision)) {
      currentRevision = err.details.currentRevision;
    }
    if (isContractUuid(err.details.operationId)) {
      operationId = err.details.operationId;
    }
  }

  return new WorkspaceApiError(
    err.code,
    status,
    fieldErrors,
    correlationId,
    currentRevision,
    operationId,
  );
}

/**
 * Gửi HTTP request có phạm vi workspace với cookie phiên, auth context, CSRF cho mutation và timeout hữu hạn.
 * Input
 * Param: path — đường dẫn con dưới `/api/v1` (ví dụ `/templates`).
 * Param: options — thông tin phương thức, `workspaceId`, `session`, `If-Match`, `Idempotency-Key`, body và signal hủy.
 * Output: response status và JSON body đã parse (null nếu 204).
 * Errors: ném `WorkspaceApiError` cho lỗi HTTP contract, lỗi mạng/timeout (`NETWORK_ERROR`), hoặc dữ liệu lỗi giao thức.
 */
export async function workspaceRequest(
  path: string,
  options: WorkspaceRequestOptions,
): Promise<{ status: number; body: unknown }> {
  const method = options.method ?? 'GET';
  if (!isContractUuid(options.workspaceId) || !isContractUuid(options.session.contextId) || !options.session.csrfToken) {
    throw new WorkspaceApiError('AUTH_CONTEXT_MISMATCH', 409);
  }

  const headers: Record<string, string> = {
    'X-Workspace-Id': options.workspaceId,
    'X-Auth-Context-Id': options.session.contextId,
  };
  if (method !== 'GET') {
    headers['X-CSRF-Token'] = options.session.csrfToken;
  }
  if (options.ifMatchRevision !== undefined) {
    if (!isPositiveInt(options.ifMatchRevision)) {
      throw new WorkspaceApiError('VALIDATION_ERROR', 422);
    }
    headers['If-Match'] = `"${options.ifMatchRevision}"`;
  }
  if (options.idempotencyKey !== undefined) {
    if (!IDEMPOTENCY_KEY_PATTERN.test(options.idempotencyKey)) {
      throw new WorkspaceApiError('VALIDATION_ERROR', 422);
    }
    headers['Idempotency-Key'] = options.idempotencyKey;
  }

  let serializedBody: string | undefined;
  if (options.rawJsonBody !== undefined) {
    serializedBody = options.rawJsonBody;
    if (new TextEncoder().encode(serializedBody).length > MAX_REST_BODY_BYTES) {
      throw new WorkspaceApiError('VALIDATION_ERROR', 413);
    }
    headers['Content-Type'] = 'application/json';
  } else if (options.body !== undefined) {
    // Từ chối nếu caller cố gắn workspaceId vào body vì backend cấm ghi đè scope từ payload.
    if (isJsonRecord(options.body) && 'workspaceId' in options.body) {
      throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: '/workspaceId', code: 'UNKNOWN_FIELD' }]);
    }
    serializedBody = JSON.stringify(options.body);
    if (new TextEncoder().encode(serializedBody).length > MAX_REST_BODY_BYTES) {
      throw new WorkspaceApiError('VALIDATION_ERROR', 413);
    }
    headers['Content-Type'] = 'application/json';
  }

  const controller = new AbortController();
  const timeoutId = window.setTimeout(
    /** Hủy chờ khi quá thời hạn phản hồi UX; không suy đoán rollback cho mutation. */
    () => controller.abort(),
    WORKSPACE_REQUEST_TIMEOUT_MS,
  );
  /** Chuyển tiếp tín hiệu hủy từ caller khi người dùng đổi workspace hoặc unmount component. */
  function forwardExternalAbort(): void {
    controller.abort();
  }
  if (options.signal) {
    if (options.signal.aborted) {
      window.clearTimeout(timeoutId);
      throw new DOMException('Yêu cầu đã bị hủy do đổi ngữ cảnh workspace.', 'AbortError');
    }
    options.signal.addEventListener('abort', forwardExternalAbort, { once: true });
  }

  try {
    const response = await fetch(`/api/v1${path}`, {
      method,
      headers,
      body: serializedBody,
      credentials: 'include',
      cache: 'no-store',
      signal: controller.signal,
    });
    if (response.status === 204) {
      return { status: 204, body: null };
    }
    if (!response.ok) {
      let errorBody: unknown;
      try {
        errorBody = await response.json();
      } catch {
        if (response.status >= 500) {
          throw new WorkspaceApiError('SERVICE_UNAVAILABLE', response.status);
        }
        throw new WorkspaceApiError('PROTOCOL_ERROR', response.status);
      }
      throw parseErrorEnvelope(response.status, errorBody);
    }
    let parsedBody: unknown;
    try {
      if (options.parseResponseText) {
        const rawText = await response.text();
        parsedBody = options.parseResponseText(rawText);
      } else {
        parsedBody = await response.json();
      }
    } catch (parseError) {
      if (parseError instanceof WorkspaceApiError) throw parseError;
      throw new WorkspaceApiError('PROTOCOL_ERROR', response.status);
    }
    return { status: response.status, body: parsedBody };
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') {
      if (options.signal?.aborted) throw error;
      throw new WorkspaceApiError('NETWORK_ERROR', 0);
    }
    if (error instanceof WorkspaceApiError) throw error;
    throw new WorkspaceApiError('NETWORK_ERROR', 0);
  } finally {
    window.clearTimeout(timeoutId);
    options.signal?.removeEventListener('abort', forwardExternalAbort);
  }
}
