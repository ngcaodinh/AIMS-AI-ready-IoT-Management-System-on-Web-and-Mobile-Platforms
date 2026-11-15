const apiProbeUrl = 'http://localhost:5173/api/v1/me';
const probeTimeoutMs = 5000;
// Mã FieldError lấy từ OpenAPI; chỉ chấp nhận các mã nằm trong schema đóng.
const readinessFieldErrorCodes = new Set([
  'REQUIRED', 'TYPE', 'FORMAT', 'LENGTH', 'ENUM', 'UNKNOWN_FIELD', 'MALFORMED_JSON',
  'DUPLICATE_FIELD', 'BODY_TOO_LARGE', 'CONTENT_TYPE', 'SAME_AS_CURRENT',
]);

/** Xác thực details theo OpenAPI trước khi cho tester tiếp tục.
 * Input
 * Param: value — details JSON chưa tin cậy trong ErrorEnvelope.
 * Output: true khi object chỉ có fieldErrors hợp lệ hoặc rỗng.
 */
function isReadinessErrorDetails(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const detailKeys = Object.keys(value);
  if (detailKeys.length === 0) return true;
  if (detailKeys.length !== 1 || detailKeys[0] !== 'fieldErrors' || !Array.isArray(value.fieldErrors)) return false;
  for (const fieldError of value.fieldErrors) {
    if (!fieldError || typeof fieldError !== 'object' || Array.isArray(fieldError)
      || Object.keys(fieldError).length !== 2
      || typeof fieldError.path !== 'string' || typeof fieldError.code !== 'string'
      || !readinessFieldErrorCodes.has(fieldError.code)) return false;
  }
  return true;
}

/**
 * Xác nhận Web proxy và Auth API trả ErrorEnvelope unauthenticated đúng contract trước khi tester gửi credential.
 * Output: ghi readiness PASS/FAIL và đặt exit code khác 0 nếu API chưa sẵn sàng.
 * Errors: timeout, lỗi kết nối hoặc response sai contract được chuyển thành hướng dẫn khởi động, không in body.
 * Side effects: chỉ gửi GET /me không credential; đọc schema error để xác nhận đúng Auth API, không thay đổi phiên.
 */
async function main() {
  try {
    const response = await fetch(apiProbeUrl, {
      method: 'GET',
      cache: 'no-store',
      credentials: 'omit',
      redirect: 'error',
      // Giới hạn thời gian chờ để preflight không treo khi Vite hoặc Auth API đã dừng.
      signal: AbortSignal.timeout(probeTimeoutMs),
    });
    const contentType = response.headers.get('content-type')
      ?.split(';', 1)[0]
      .trim()
      .toLowerCase();
    let error;
    if (response.status === 401 && contentType === 'application/json') {
      try {
        const body = await response.json();
        const candidate = body && typeof body === 'object' && !Array.isArray(body)
          ? body.error : undefined;
        if (candidate && typeof candidate === 'object' && !Array.isArray(candidate)) {
          error = candidate;
        }
      } catch {
        // Body lỗi hoặc không parse được phải chặn tester trước khi nhập credential.
      }
    }
    const validErrorEnvelope = error
      && typeof error.code === 'string'
      && ['SESSION_EXPIRED', 'SESSION_REVOKED'].includes(error.code)
      && typeof error.message === 'string'
      && isReadinessErrorDetails(error.details)
      && typeof error.correlationId === 'string';

    if (response.status !== 401 || contentType !== 'application/json' || !validErrorEnvelope) {
      console.error(
        `Auth API readiness FAIL: cần HTTP 401 application/json với ErrorEnvelope SESSION_EXPIRED/SESSION_REVOKED hợp lệ, nhận HTTP ${response.status} ${contentType ?? 'không có Content-Type'} hoặc body sai schema. Chưa gửi credential.`,
      );
      process.exitCode = 1;
      return;
    }

    console.log('Auth API readiness PASS: GET /api/v1/me trả 401 ErrorEnvelope SESSION_EXPIRED/REVOKED; có thể kiểm thử login.');
  } catch {
    console.error(
      'Auth API readiness FAIL: chưa kết nối được Web/Auth API. Khởi động các dịch vụ và chạy lại trước khi nhập credential.',
    );
    process.exitCode = 1;
  }
}

void main();
