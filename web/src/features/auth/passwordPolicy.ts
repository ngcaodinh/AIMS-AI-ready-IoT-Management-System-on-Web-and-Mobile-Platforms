export type PasswordPurpose = 'login' | 'current' | 'new';
export type PasswordValidationError = { code: 'LENGTH' | 'FORMAT'; message: string };

export const newPasswordHint = '9–128 ký tự, có chữ hoa, chữ thường và số (0–9). Khoảng trắng là một phần của mật khẩu.';

/**
 * Kiểm UX theo shared policy version1, đếm codepoints và giữ nguyên credential để backend verify/hash.
 * Input
 * Param: value — text người dùng nhập, không trim/normalize hoặc lưu/log.
 * Param: purpose — login/current không áp composition mới lên account đã có; new áp đủ hoa/thường/số.
 * Output: lỗi cố định có code/message hoặc null; không thay kiểm server và không đánh giá entropy thực tế.
 */
export function validatePassword(value: string, purpose: PasswordPurpose): PasswordValidationError | null {
  const length = [...value].length;
  const minimum = purpose === 'current' ? 1 : 9;
  if (length < minimum || length > 128) {
    const message = purpose === 'current' ? 'Nhập mật khẩu hiện tại (1–128 ký tự).'
      : purpose === 'new' ? 'Mật khẩu mới cần từ 9 đến 128 ký tự.' : 'Mật khẩu cần từ 9 đến 128 ký tự.';
    return { code: 'LENGTH', message };
  }
  // Binary Unicode properties nhận cả chữ tiếng Việt; digit0–9 giống Rust/Dart, không ép ASCII cho toàn password.
  if (purpose === 'new' && (!/\p{Uppercase}/u.test(value) || !/\p{Lowercase}/u.test(value) || !/[0-9]/.test(value))) {
    return { code: 'FORMAT', message: 'Mật khẩu mới phải có chữ hoa, chữ thường và số (0–9).' };
  }
  return null;
}
