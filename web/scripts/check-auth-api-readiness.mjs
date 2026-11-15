const apiProbeUrl = 'http://localhost:5173/api/v1/me';
const probeTimeoutMs = 5000;

/**
 * Xác nhận Web proxy và Auth API trả đúng trạng thái unauthenticated trước khi tester gửi credential.
 * Output: ghi readiness PASS/FAIL và đặt exit code khác 0 nếu API chưa sẵn sàng.
 * Errors: timeout hoặc lỗi kết nối được chuyển thành hướng dẫn khởi động, không in chi tiết response.
 * Side effects: chỉ gửi GET /me không credential, không thay đổi phiên hoặc dữ liệu.
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

    if (response.status !== 401 || contentType !== 'application/json') {
      console.error(
        `Auth API readiness FAIL: cần HTTP 401 application/json, nhận HTTP ${response.status} ${contentType ?? 'không có Content-Type'}. Chưa gửi credential.`,
      );
      process.exitCode = 1;
      return;
    }

    console.log('Auth API readiness PASS: GET /api/v1/me trả HTTP 401 application/json; có thể bắt đầu kiểm thử login.');
  } catch {
    console.error(
      'Auth API readiness FAIL: chưa kết nối được Web/Auth API. Khởi động các dịch vụ và chạy lại trước khi nhập credential.',
    );
    process.exitCode = 1;
  }
}

void main();
