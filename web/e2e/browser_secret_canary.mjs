const maximumBufferedMessages = 8_192;
const maximumBufferedCharacters = 1_048_576;
const maximumSecretCharacters = 4_096;

/** Tạo trạng thái quét sink browser với bộ đệm tạm có giới hạn.
 * Output: trạng thái chỉ giữ canary, log tạm trong RAM và các cờ kết quả.
 */
export function createBrowserSecretCanaryState() {
  return {
    leaked: false,
    overflowed: false,
    invalidInput: false,
    registrationComplete: false,
    disposed: false,
    sensitiveValues: new Set(),
    pendingMessages: [],
    bufferedCharacters: 0,
  };
}

/** Đăng ký canary mới và rà lại mọi thông báo đã nhận trước đó.
 * Input
 * Param: state — trạng thái do createBrowserSecretCanaryState tạo.
 * Param: value — credential fixture lấy từ response, cookie jar hoặc realtime ticket.
 * Errors: từ chối trạng thái đã đóng và canary rỗng/quá dài bằng mã cố định.
 * Side effects: chỉ lưu canary trong RAM và đặt cờ leak nếu log cũ chứa giá trị đó.
 */
export function registerBrowserSecret(state, value) {
  if (state.disposed || state.registrationComplete) {
    throw new Error('WEB_UI_SECRET_REGISTRATION_CLOSED');
  }
  if (typeof value !== 'string' || value.length === 0 || value.length > maximumSecretCharacters) {
    throw new Error('WEB_UI_SECRET_CANARY_INVALID');
  }
  if (!state.sensitiveValues.has(value)) {
    state.sensitiveValues.add(value);
    // Quét lại log tạm để canary đến muộn không thể bỏ sót sink phát sinh trước đó.
    for (const message of state.pendingMessages) {
      if (message.includes(value)) state.leaked = true;
    }
  }
}

/** Quét một giá trị console/page error và giữ log tạm cho canary đến muộn.
 * Input
 * Param: state — trạng thái canary của một lần chạy browser.
 * Param: value — nội dung sink chỉ được lưu tạm trong RAM tới khi đăng ký xong.
 * Side effects: đặt cờ leak hoặc overflow; không xuất nội dung sink.
 */
export function observeBrowserSink(state, value) {
  if (state.disposed) return;
  if (typeof value !== 'string') {
    state.invalidInput = true;
    return;
  }
  for (const sensitiveValue of state.sensitiveValues) {
    if (value.includes(sensitiveValue)) state.leaked = true;
  }
  if (state.registrationComplete || state.overflowed) return;
  // Quá giới hạn thì fail closed và bỏ buffer ngay để log bất thường không giữ RAM vô hạn.
  if (state.pendingMessages.length >= maximumBufferedMessages
    || state.bufferedCharacters + value.length > maximumBufferedCharacters) {
    state.overflowed = true;
    state.pendingMessages.length = 0;
    state.bufferedCharacters = 0;
    return;
  }
  state.pendingMessages.push(value);
  state.bufferedCharacters += value.length;
}

/** Chốt đăng ký canary và xóa log tạm sau khi ticket đã được quét.
 * Input
 * Param: state — trạng thái canary của một lần chạy browser.
 * Output: snapshot chỉ gồm cờ kết quả không nhạy cảm.
 * Errors: từ chối trạng thái đã dispose hoặc đã chốt trước đó.
 */
export function finishBrowserSecretRegistration(state) {
  if (state.disposed || state.registrationComplete) {
    throw new Error('WEB_UI_SECRET_REGISTRATION_CLOSED');
  }
  state.registrationComplete = true;
  state.pendingMessages.length = 0;
  state.bufferedCharacters = 0;
  return {
    leaked: state.leaked,
    overflowed: state.overflowed,
    invalidInput: state.invalidInput,
  };
}

/** Xóa canary và log tạm khi browser context kết thúc.
 * Input
 * Param: state — trạng thái canary cần giải phóng.
 * Side effects: xóa dữ liệu nhạy cảm khỏi các collection do helper sở hữu.
 */
export function disposeBrowserSecretCanary(state) {
  state.sensitiveValues.clear();
  state.pendingMessages.length = 0;
  state.bufferedCharacters = 0;
  state.disposed = true;
}
