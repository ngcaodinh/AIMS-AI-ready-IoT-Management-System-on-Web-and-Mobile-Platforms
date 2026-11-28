import { Suspense, lazy, useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import { AuthCoordinator, type AuthState } from './coordinator';
import { IconSprite } from '../../IconSprite';
import { BrandLink } from '../../BrandLink';
import { newPasswordHint, validatePassword } from './passwordPolicy';
import { WorkspaceApiError } from '../workspace/workspaceApi';
import { listTemplatesApi } from '../templates/templateApi';
import { recoverDeviceBySerialApi } from '../devices/deviceApi';
import './auth.css';

/** Nạp lười workbench Templates WB-03 khi phiên đã chọn workspace hợp lệ. */
const LazyTemplatesWorkbench = lazy(
  /** Tải module TemplatesWorkbench chỉ sau khi workspace được xác minh. */
  async () => ({ default: (await import('../templates/TemplatesWorkbench')).TemplatesWorkbench }),
);

/** Nạp lười workbench Devices/USB WB-04 khi phiên đã chọn workspace hợp lệ. */
const LazyDevicesPage = lazy(
  /** Tải module DevicesPage chỉ sau khi workspace được xác minh. */
  async () => ({ default: (await import('../devices/DevicesPage')).DevicesPage }),
);

const ERROR_MESSAGES: Record<string, string> = {
  AUTH_INVALID: 'Thông tin đăng nhập không hợp lệ.',
  RATE_LIMITED: 'Bạn đã thử quá nhiều lần. Vui lòng đợi trước khi đăng nhập lại.',
  NETWORK_ERROR: 'Không thể xác nhận kết quả do mất kết nối. Kiểm tra mạng rồi đối soát phiên.',
  SERVICE_UNAVAILABLE: 'Dịch vụ đang gián đoạn. Chưa thể xác nhận kết quả. Hãy đối soát phiên trước khi thử lại.',
  AUTH_CONTEXT_MISMATCH: 'Phiên trên trình duyệt đã thay đổi. Cần xác nhận lại trước khi tiếp tục.',
  AUTH_INTENT_CHANGED: 'Cần xác nhận lại trạng thái đăng nhập. Vui lòng đối soát phiên.',
  SESSION_EXPIRED: 'Phiên đã hết hạn hoặc bị thu hồi. Vui lòng đăng nhập lại.',
  STORAGE_ERROR: 'Không thể lưu trạng thái phiên. Hãy cho phép storage và thử lại.',
  PROTOCOL_ERROR: 'Phản hồi chưa hợp lệ. Chưa thể xác nhận phiên đăng nhập.',
  CSRF_INVALID: 'Thông tin bảo vệ phiên đã thay đổi. Vui lòng đối soát lại phiên.',
  LOGOUT_PENDING: 'Đang chờ xác nhận đăng xuất. Hãy đối soát và hoàn tất đăng xuất trước khi đăng nhập mới.',
  PASSWORD_CHANGED: 'Đã đổi mật khẩu và thu hồi các phiên. Hãy đăng nhập bằng mật khẩu mới.',
  LOGOUT_TERMINAL: 'Phiên hiện tại không còn hiệu lực. Bạn có thể đăng nhập lại.',
  VALIDATION_ERROR: 'Dữ liệu chưa hợp lệ. Kiểm tra email và mật khẩu.',
  NOT_FOUND: 'Workspace không còn khả dụng hoặc bạn không còn quyền truy cập.',
  RESOURCE_NOT_FOUND: 'Workspace không còn khả dụng hoặc bạn không còn quyền truy cập.',
  CURSOR_INVALID: 'Danh sách đã thay đổi. Vui lòng tải lại từ đầu.',
};

// Thông báo chỉ hiển thị khi luồng signOut trong phiên trình duyệt chuyển từ logoutPending về login thành công.
const LOGOUT_SUCCESS_MESSAGE = 'Đã đăng xuất khỏi phiên hiện tại. Bạn có thể đăng nhập lại.';

const EMPTY_FIELD_ERRORS: Record<string, string> = {};

const INITIAL_STATE: AuthState = {
  phase: 'loading', busy: true, error: '', retryAt: 0,
  workspaces: [], nextCursor: null, logoutPending: false,
};

/**
 * Vẽ icon trang trí từ sprite dùng chung, không thêm tên đọc trùng với nhãn của control.
 * Input
 * Param: name — symbol nội bộ đã chọn theo trạng thái, không là URL từ API.
 * Param: className — lớp trình bày cho hướng mũi tên hoặc kích thước.
 * Output: SVG nét 1.8, bị ẩn khỏi accessibility tree.
 */
function AuthIcon({ name, className = '' }: { name: string; className?: string }) {
  return <svg className={`auth-icon ${className}`} viewBox="0 0 24 24" aria-hidden="true" focusable="false"><use href={`#i-${name}`} /></svg>;
}

/**
 * Khôi phục theme đã lưu hoặc theo hệ thống; storage bị chặn chỉ ảnh hưởng lựa chọn thị giác.
 * Output: true khi người dùng đã chọn theme tối hoặc hệ thống đang ưu tiên theme tối.
 */
function getInitialDark(): boolean {
  try {
    const saved = localStorage.getItem('nexa-theme');
    if (saved === 'dark' || saved === 'light') return saved === 'dark';
  } catch {
    // Phiên xác thực vẫn do coordinator kiểm soát; theme có thể hoạt động trong memory.
  }
  return window.matchMedia('(prefers-color-scheme: dark)').matches;
}

/**
 * Điều phối giao diện xác thực, chọn workspace, khôi phục phiên và đăng xuất trên một thẻ tác vụ tập trung
 * để khóa dữ liệu bảo vệ ngay khi trạng thái phiên chưa chắc chắn và ngăn thao tác chồng chéo.
 * Output
 * Cây JSX của quy trình xác thực tương ứng với phase hiện tại của coordinator.
 */
export function AuthPage() {
  const [state, setState] = useState<AuthState>(INITIAL_STATE);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [confirmation, setConfirmation] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [validation, setValidation] = useState<{
    phase: AuthState['phase']; fields: Record<string, string>;
  }>({ phase: INITIAL_STATE.phase, fields: EMPTY_FIELD_ERRORS });
  const [offline, setOffline] = useState(!navigator.onLine);
  const [now, setNow] = useState(Date.now());
  const [dark, setDark] = useState(getInitialDark);
  const [logoutSuccess, setLogoutSuccess] = useState(false);
  const [workspaceTab, setWorkspaceTab] = useState<'summary' | 'templates' | 'devices'>('summary');
  const [runtimeAvailability, setRuntimeAvailability] = useState<{ templates: boolean; devices: boolean }>({
    templates: false,
    devices: false,
  });
  const wasLogoutPendingRef = useRef(false);
  const headingRef = useRef<HTMLHeadingElement>(null);
  const errorRef = useRef<HTMLDivElement>(null);
  const coordinatorRef = useRef<AuthCoordinator | null>(null);
  if (!coordinatorRef.current) coordinatorRef.current = new AuthCoordinator(setState);
  const coordinator = coordinatorRef.current;
  const waitSeconds = Math.max(0, Math.ceil((state.retryAt - now) / 1000));
  // Ẩn lỗi của form cũ ngay render đầu của phase mới, trước khi effect xóa input chạy.
  const fieldErrors = validation.phase === state.phase ? validation.fields : EMPTY_FIELD_ERRORS;
  const formErrors = Object.entries(fieldErrors);
  // Lỗi field của lần submit hiện tại thay lỗi credential cũ; vẫn giữ rate/storage/recovery để không che hướng xử lý.
  const outdatedCredentialError = formErrors.length > 0
    && (state.error === 'AUTH_INVALID' || state.error === 'VALIDATION_ERROR');
  // Khi readiness probe thất bại ở màn login trước lúc gửi credential, cho phép kiểm tra kết nối và thử lại trực tiếp mà không yêu cầu đối soát phiên.
  const serverMessage = state.error && !outdatedCredentialError
    ? (state.error === 'SERVICE_UNAVAILABLE' && state.phase === 'login'
      ? 'Dịch vụ xác thực chưa sẵn sàng. Hãy kiểm tra kết nối và thử lại.'
      : ERROR_MESSAGES[state.error] ?? 'Không thể hoàn tất thao tác. Vui lòng đối soát lại phiên.') : '';
  const hasConfirmedLogoutNotice = !serverMessage && logoutSuccess && state.phase === 'login' && formErrors.length === 0;
  const message = serverMessage || (hasConfirmedLogoutNotice ? LOGOUT_SUCCESS_MESSAGE : '');
  const isSuccessNotice = state.error === 'PASSWORD_CHANGED'
    || state.error === 'LOGOUT_TERMINAL'
    || hasConfirmedLogoutNotice;

  /**
   * Bỏ dữ liệu và lỗi của form cũ khi coordinator chuyển phase để logout/recovery không mang
   * validation đổi mật khẩu hoặc credential đang nhập sang màn đăng nhập tiếp theo.
   * Side effects
   * Xóa lỗi field, ba password input và trạng thái reveal theo lifetime phase hiện hành.
   */
  useEffect(() => {
    setValidation({ phase: state.phase, fields: EMPTY_FIELD_ERRORS });
    setPassword('');
    setNewPassword('');
    setConfirmation('');
    setShowPassword(false);
    if (state.phase !== 'selected') {
      setWorkspaceTab('summary');
    }
  }, [state.phase]);

  /**
   * Theo dõi chuyển tiếp thực tế từ logoutPending sang login để xóa email của phiên vừa thoát
   * và chỉ công bố thông báo đăng xuất thành công khi coordinator đã kết thúc đăng xuất an toàn.
   * Side effects
   * Xóa email khi hoàn tất đăng xuất về màn login; bật hoặc tắt cờ thông báo đăng xuất thành công.
   */
  useEffect(() => {
    if (state.logoutPending) {
      wasLogoutPendingRef.current = true;
      setLogoutSuccess(false);
      return;
    }
    if (wasLogoutPendingRef.current) {
      wasLogoutPendingRef.current = false;
      if (state.phase === 'login' && !state.busy && (!state.error || state.error === 'LOGOUT_TERMINAL')) {
        setEmail('');
        setLogoutSuccess(!state.error);
        return;
      }
    }
    if (state.phase !== 'login' || state.busy || state.error) {
      setLogoutSuccess(false);
    }
  }, [state.phase, state.busy, state.logoutPending, state.error]);

  // Đồng bộ theme lúc mở trực tiếp /login; token gốc áp cho cả native form control sáng/tối.
  useEffect(() => { document.documentElement.dataset.theme = dark ? 'dark' : 'light'; }, [dark]);

  const selectedWorkspaceId = state.selected?.id ?? '';
  const selectedWorkspaceRole = state.selected?.role;
  const sessionSnapshot = state.phase === 'selected' ? coordinator.getSessionMetadata() : undefined;
  const activeContextId = sessionSnapshot?.contextId ?? '';
  const activeCsrfToken = sessionSnapshot?.csrfToken ?? '';
  const activeSession = useMemo(
    /** Ổn định tham chiếu `SessionMetadata` theo giá trị thực để không reset workbench khi re-render AuthPage. */
    () => (activeContextId && activeCsrfToken
      ? { contextId: activeContextId, csrfToken: activeCsrfToken }
      : undefined),
    [activeContextId, activeCsrfToken],
  );

  /**
   * Thăm dò read-only khi mở workspace của ADMIN để chỉ hiển thị WB-03/WB-04 khi runtime cung cấp endpoint tương ứng.
   * Side effects: cập nhật `runtimeAvailability`, giữ UI tối giản khi route trả 404 và khóa phiên nếu gặp 401/409.
   */
  useEffect(() => {
    setRuntimeAvailability({ templates: false, devices: false });
    if (state.phase !== 'selected' || selectedWorkspaceRole !== 'ADMIN' || !selectedWorkspaceId || !activeSession) {
      return;
    }

    const controller = new AbortController();
    let active = true;
    const ctx = { workspaceId: selectedWorkspaceId, session: activeSession };

    /** Chạy cặp GET thăm dò chỉ đọc cho template và device recovery trong phạm vi workspace hiện hành. */
    async function probeRuntimeWorkbenches(): Promise<void> {
      const [templatesResult, devicesResult] = await Promise.allSettled([
        listTemplatesApi(ctx, { limit: 1, signal: controller.signal }),
        recoverDeviceBySerialApi(ctx, 'runtime-availability-probe', controller.signal),
      ]);
      if (!active || controller.signal.aborted) return;

      const results = [templatesResult, devicesResult];
      for (const result of results) {
        if (result.status === 'rejected' && result.reason instanceof WorkspaceApiError
          && [401, 409].includes(result.reason.status)
          && ['SESSION_EXPIRED', 'SESSION_REVOKED', 'AUTH_CONTEXT_MISMATCH', 'CSRF_INVALID'].includes(result.reason.code)) {
          coordinator.invalidate();
          void coordinator.restore();
          return;
        }
      }

      const templatesReady = templatesResult.status === 'fulfilled';
      const devicesReady = devicesResult.status === 'fulfilled';
      setRuntimeAvailability({ templates: templatesReady, devices: devicesReady });
      setWorkspaceTab((prev) => {
        if (prev === 'templates' && !templatesReady) return 'summary';
        if (prev === 'devices' && !devicesReady) return 'summary';
        return prev;
      });
    }

    void probeRuntimeWorkbenches();
    /** Hủy thăm dò runtime ngay khi đổi workspace, rời phase selected hoặc unmount. */
    return () => {
      active = false;
      controller.abort();
    };
  }, [coordinator, state.phase, selectedWorkspaceId, selectedWorkspaceRole, activeSession]);

  // Restore qua guard thật; cleanup ngăn callback của instance đã unmount mở lại protected UI.
  useEffect(() => {
    void coordinator.restore();
    /** Tab khác đổi marker phải khóa ngay cả khi trình duyệt vẫn giữ cookie cũ. */
    function handleStorage(event: StorageEvent): void {
      if (event.key === 'nexa-auth-intent' || event.key === null) coordinator.invalidate();
    }
    /** Cập nhật chỉ báo mạng; không tự gửi lại POST khi kết nối được phục hồi. */
    function handleConnectivity(): void { setOffline(!navigator.onLine); }
    /** Resume khóa dữ liệu cũ và đối soát accepted session trước khi hiện nội dung trở lại. */
    function handleResume(): void {
      if (document.visibilityState === 'visible') {
        coordinator.invalidate();
        void coordinator.restore();
      }
    }
    window.addEventListener('storage', handleStorage);
    window.addEventListener('online', handleConnectivity);
    window.addEventListener('offline', handleConnectivity);
    window.addEventListener('focus', handleResume);
    document.addEventListener('visibilitychange', handleResume);
    /** Gỡ listener theo vòng đời và vô hiệu callback request cũ. */
    return () => {
      window.removeEventListener('storage', handleStorage);
      window.removeEventListener('online', handleConnectivity);
      window.removeEventListener('offline', handleConnectivity);
      window.removeEventListener('focus', handleResume);
      document.removeEventListener('visibilitychange', handleResume);
      coordinator.invalidate();
    };
  }, [coordinator]);

  // Cooldown chỉ mở lại nút theo Retry-After; server vẫn là authority cho rate limit.
  useEffect(() => {
    if (!state.retryAt) return;
    const interval = window.setInterval(
      /** Đồng bộ nhãn thời gian chờ, không tạo login tự động. */
      () => setNow(Date.now()), 1000,
    );
    /** Dừng timer khi cooldown được thay hoặc form unmount. */
    return () => window.clearInterval(interval);
  }, [state.retryAt]);

  // Mỗi màn mới có tiêu điểm rõ ràng; lỗi submit chuyển tới summary có liên kết field.
  // Mỗi lần đổi màn hình, đưa tiêu điểm về tiêu đề để thông báo trạng thái cho người dùng bàn phím.
  useEffect(() => { headingRef.current?.focus(); }, [state.phase]);
  // Chuyển tiêu điểm tới tóm tắt lỗi khi lỗi server hoặc lỗi kiểm tra form xuất hiện.
  useEffect(() => { if (message || formErrors.length) errorRef.current?.focus(); }, [message, fieldErrors]);

  /**
   * Kiểm login theo độ dài9–128 rồi xác thực credential đã lưu; không áp composition mới lên account legacy.
   * Input
   * Param: event — submit từ form, chặn navigation mặc định để giữ coordinator intent.
   * Side effects: cập nhật lỗi field; khi hợp lệ xóa password khỏi React state trước callback, không trim password.
   */
  async function handleLogin(event: FormEvent<HTMLFormElement>): Promise<void> {
    event.preventDefault();
    setLogoutSuccess(false);
    const errors: Record<string, string> = {};
    if (!email.trim() || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) errors.email = 'Nhập địa chỉ email hợp lệ.';
    const passwordError = validatePassword(password, 'login');
    if (passwordError) errors.password = passwordError.message;
    setValidation({ phase: state.phase, fields: errors });
    if (Object.keys(errors).length || state.busy || waitSeconds || offline) return;
    const submittedPassword = password;
    setPassword('');
    await coordinator.signIn(email, submittedPassword);
  }

  /**
   * Kiểm current/new/confirm đúng vai trò trước request; backend vẫn enforce policy và revoke sau commit.
   * Input
   * Param: event — intent submit của chính form đổi password, không chứa authority của account khác.
   * Side effects: gắn lỗi gần field; chỉ khi hợp lệ mới xóa credential khỏi state và gọi coordinator một lần.
   */
  async function handlePasswordChange(event: FormEvent<HTMLFormElement>): Promise<void> {
    event.preventDefault();
    const errors: Record<string, string> = {};
    const currentError = validatePassword(password, 'current');
    const newError = validatePassword(newPassword, 'new');
    if (currentError) errors.password = currentError.message;
    if (newError) errors.newPassword = newError.message;
    if (newPassword !== confirmation) errors.confirmation = 'Mật khẩu xác nhận chưa khớp.';
    if (!newError && newPassword === password) errors.newPassword = 'Mật khẩu mới phải khác mật khẩu hiện tại.';
    setValidation({ phase: state.phase, fields: errors });
    if (Object.keys(errors).length || state.busy || waitSeconds || offline) return;
    const currentValue = password;
    const newValue = newPassword;
    setPassword(''); setNewPassword(''); setConfirmation('');
    await coordinator.changePassword(currentValue, newValue);
  }

  /** Đổi theme bằng token sẵn có; lỗi lưu theme không ảnh hưởng session coordinator. */
  function toggleTheme(): void {
    const nextDark = !dark;
    setDark(nextDark);
    document.documentElement.dataset.theme = nextDark ? 'dark' : 'light';
    try { localStorage.setItem('nexa-theme', nextDark ? 'dark' : 'light'); } catch {
      // Theme có thể dùng trong memory khi browser chặn lưu lựa chọn.
    }
  }

  const title = {
    login: 'Đăng nhập',
    loading: state.logoutPending ? 'Đang đăng xuất' : 'Đang xác minh phiên',
    limited: 'Đổi mật khẩu để tiếp tục',
    picker: 'Chọn workspace',
    selected: state.selected?.name ?? 'Workspace',
    recovery: state.logoutPending ? 'Hoàn tất đăng xuất' : 'Xác nhận trạng thái phiên',
  }[state.phase];
  const stateIcon = { login: 'lock', loading: 'clock', limited: 'key', picker: 'grid', selected: 'check', recovery: 'shield' }[state.phase];

  return (
    <div className="auth-page">
      <IconSprite />
      {/* Lớp ánh sáng trang trí đồng bộ với blob ở hero trang chủ; ẩn khỏi trợ năng vì không mang nội dung. */}
      <div className="auth-aurora" aria-hidden="true"><span /><span /><span /></div>
      <a className="auth-skip-link" href="#main">Chuyển đến nội dung chính</a>
      <header className="auth-header">
        <div className="auth-header-inner">
        <BrandLink href="/" />
        <nav className="auth-header-actions" aria-label="Điều hướng trang xác thực">
          <button className="auth-theme-toggle" type="button" onClick={toggleTheme} aria-label={dark ? 'Chuyển sang giao diện sáng' : 'Chuyển sang giao diện tối'} title={dark ? 'Giao diện sáng' : 'Giao diện tối'}><AuthIcon name={dark ? 'sun' : 'moon'} /></button>
          <a className="auth-home-link btn btn-ghost" href="/" aria-label="Về trang chủ"><AuthIcon name="arrow" className="auth-icon-back" /><span>Trang chủ</span></a>
        </nav>
        </div>
      </header>
      <main className="auth-main" id="main" tabIndex={-1}>
        <div className={`auth-layout${state.phase === 'selected' && workspaceTab !== 'summary' ? ' auth-layout-wide' : ''}`}>
        <div className="auth-card" data-state={state.phase}>
          <div className="auth-card-heading"><span className="auth-state-icon"><AuthIcon name={stateIcon} /></span><span className="auth-eyebrow">NEXA WORKSPACE</span></div>
          {state.phase === 'selected' && <nav className="auth-breadcrumb" aria-label="Đường dẫn"><span>Workspaces</span><span aria-hidden="true">/</span><span aria-current="page">{state.selected?.name}</span></nav>}
          <h1 ref={headingRef} tabIndex={-1}>{title}</h1>
          {state.phase === 'login' && <p className="auth-description">Chào mừng trở lại.<br />Tiếp tục vào không gian làm việc của bạn.</p>}
          {offline && <div className="auth-notice" role="status"><AuthIcon name="radio" /><p>Bạn đang ngoại tuyến. Kiểm tra kết nối trước khi tiếp tục.</p></div>}
          {(message || formErrors.length > 0) && (
            <div className={`auth-notice${isSuccessNotice ? ' auth-success' : ' auth-error'}`} ref={errorRef} tabIndex={-1} role={isSuccessNotice ? 'status' : 'alert'}>
              <AuthIcon name={isSuccessNotice ? 'check' : 'help'} />
              <div className="auth-notice-content">
                {message && <p>{message}</p>}
                {formErrors.length > 0 && <ul>{formErrors.map(
                  /** Liên kết lỗi tới đúng control để keyboard và screen reader sửa nhanh. */
                  ([field, text]) => <li key={field}><a href={`#${field}`}>{text}</a></li>,
                )}</ul>}
              </div>
            </div>
          )}
          {state.phase === 'loading' && <div className="auth-loading"><div className="auth-skeleton" aria-hidden="true"><span /><span /><span /></div><p className="auth-progress" role="status"><span className="auth-spinner" aria-hidden="true" />{state.logoutPending ? 'Đang thu hồi phiên và khóa dữ liệu trên trình duyệt…' : 'Đang kết nối dịch vụ xác thực và xác minh phiên…'}</p></div>}
          {state.phase === 'login' && (
            <form onSubmit={handleLogin} noValidate className="auth-form" aria-busy={state.busy}>
              <label htmlFor="email">Email</label>
              <div className="auth-input-field">
                <AuthIcon name="mail" />
                <input id="email" name="email" type="email" inputMode="email" autoCapitalize="none" spellCheck={false} autoComplete="username" placeholder="ten@congty.vn" value={email}
                  onChange={
                    /** Chỉ giữ email trong form; server chuẩn hóa ASCII theo contract. */
                    (event) => setEmail(event.target.value)
                  } aria-invalid={Boolean(fieldErrors.email)} aria-describedby={fieldErrors.email ? 'email-error' : undefined} disabled={state.busy} required />
              </div>
              {fieldErrors.email && <p id="email-error" className="auth-field-error">{fieldErrors.email}</p>}
              <label htmlFor="password">Mật khẩu</label>
              <div className="auth-input-field auth-password-field">
                <AuthIcon name="lock" />
                <input id="password" name="password" type={showPassword ? 'text' : 'password'} autoComplete="current-password" value={password}
                  onChange={
                    /** Không trim/normalize để không thay đổi credential người dùng. */
                    (event) => setPassword(event.target.value)
                  } aria-invalid={Boolean(fieldErrors.password)} aria-describedby={fieldErrors.password ? 'password-error' : undefined} disabled={state.busy} required />
                <button type="button" className="auth-reveal" aria-label={showPassword ? 'Ẩn mật khẩu' : 'Hiện mật khẩu'} aria-pressed={showPassword}
                  onClick={
                    /** Cho người dùng kiểm tra chuỗi nhập mà vẫn hỗ trợ password manager/paste. */
                    () => setShowPassword(!showPassword)
                  }><AuthIcon name={showPassword ? 'eye-off' : 'eye'} /></button>
              </div>
              {fieldErrors.password && <p id="password-error" className="auth-field-error">{fieldErrors.password}</p>}
              <button className="auth-primary auth-login-submit" type="submit" disabled={state.busy || waitSeconds > 0 || offline}><span>{state.busy ? 'Đang đăng nhập…' : waitSeconds ? `Thử lại sau ${waitSeconds} giây` : 'Đăng nhập'}</span>{state.busy ? <span className="auth-spinner" aria-hidden="true" /> : <AuthIcon name={waitSeconds ? 'clock' : 'arrow'} />}</button>
              <div className="auth-account-help"><AuthIcon name="help" /><p><strong>Chưa có tài khoản?</strong><span>Liên hệ quản trị viên workspace để được cấp quyền truy cập.</span></p></div>
            </form>
          )}
          {state.phase === 'limited' && (
            <>
              <p className="auth-description">Phiên hiện tại chỉ cho phép đổi mật khẩu hoặc đăng xuất.</p>
              <form onSubmit={handlePasswordChange} className="auth-form" noValidate aria-busy={state.busy}>
                <label htmlFor="password">Mật khẩu hiện tại</label>
                <input id="password" name="currentPassword" type="password" autoComplete="current-password" value={password}
                  onChange={
                    /** Giữ mật khẩu hiện tại trong memory tới lúc gửi đổi mật khẩu. */
                    (event) => setPassword(event.target.value)
                  } aria-invalid={Boolean(fieldErrors.password)} aria-describedby={fieldErrors.password ? 'password-error' : undefined} disabled={state.busy} required />
                {fieldErrors.password && <p id="password-error" className="auth-field-error">{fieldErrors.password}</p>}
                <label htmlFor="newPassword">Mật khẩu mới</label>
                <input id="newPassword" name="newPassword" type="password" autoComplete="new-password" value={newPassword}
                  onChange={
                    /** Chuỗi mới được kiểm lại server-side, không lưu ngoài form. */
                    (event) => setNewPassword(event.target.value)
                  } aria-invalid={Boolean(fieldErrors.newPassword)} aria-describedby="newPassword-hint newPassword-error" disabled={state.busy} required />
                <p id="newPassword-hint" className="auth-hint">{newPasswordHint}</p>
                <p id="newPassword-error" className="auth-field-error">{fieldErrors.newPassword}</p>
                <label htmlFor="confirmation">Nhập lại mật khẩu mới</label>
                <input id="confirmation" name="confirmation" type="password" autoComplete="new-password" value={confirmation}
                  onChange={
                    /** Xác nhận chỉ phục vụ UX và không gửi field ngoài contract. */
                    (event) => setConfirmation(event.target.value)
                  } aria-invalid={Boolean(fieldErrors.confirmation)} aria-describedby="confirmation-error" disabled={state.busy} required />
                <p id="confirmation-error" className="auth-field-error">{fieldErrors.confirmation}</p>
                <button className="auth-primary" disabled={state.busy || waitSeconds > 0 || offline} type="submit">{state.busy ? 'Đang đổi mật khẩu…' : waitSeconds ? `Thử lại sau ${waitSeconds} giây` : 'Đổi mật khẩu'}</button>
              </form>
            </>
          )}
          {state.phase === 'picker' && (
            <>
              <p className="auth-description">{state.profile?.email}. Chọn workspace để tiếp tục.</p>
              {state.workspaces.length === 0 && !state.nextCursor ? <div className="auth-empty"><h2>Không có workspace khả dụng</h2><p>Bạn chưa có quyền trong workspace đang hoạt động. Liên hệ người quản trị để được cấp quyền, rồi tải lại danh sách.</p><button className="auth-secondary" type="button" disabled aria-describedby="workspace-create-dependency">Tạo workspace</button><p id="workspace-create-dependency" className="auth-hint">Chức năng tạo workspace chưa khả dụng trên phiên bản này.</p></div> : (
                <ul className="auth-workspaces">{state.workspaces.map(
                  /** Mỗi workspace có thao tác chọn riêng, không tự chọn dù chỉ có một item. */
                  (workspace) => <li key={workspace.id}><span className="auth-workspace-icon"><AuthIcon name="grid" /></span><div><h2>{workspace.name}</h2><p>{workspace.role === 'ADMIN' ? 'Quản trị viên' : 'Thành viên'}</p></div><button className="auth-secondary" type="button" disabled={state.busy || offline}
                    onClick={
                      /** Chỉ mở shell sau recheck membership thật trên server. */
                      () => void coordinator.choose(workspace.id)
                    } aria-label={`Chọn workspace ${workspace.name}`}>Chọn</button></li>,
                )}</ul>
              )}
              {state.nextCursor && <button className="auth-secondary" type="button" disabled={state.busy || offline}
                onClick={
                  /** Phân trang chủ động và không suy empty từ một trang chưa kết thúc. */
                  () => void coordinator.loadMore()
                }>Tải thêm workspace</button>}
              <button className="auth-secondary" type="button" disabled={state.busy || offline}
                onClick={
                  /** Bootstrap lại quyền hiện hành; không tái sử dụng summary cũ khi danh sách thay đổi. */
                  () => void coordinator.restore()
                }>Tải lại danh sách</button>
            </>
          )}
          {state.phase === 'selected' && (
            <div className="auth-success-panel">
              <p className="auth-access-status" role="status">
                Đã xác minh quyền {state.selected?.role === 'ADMIN' ? 'quản trị viên' : 'thành viên'} của bạn.
              </p>
              <dl className="auth-session-summary">
                <div><dt>Tài khoản đang sử dụng</dt><dd>{state.profile?.email}</dd></div>
                <div><dt>Workspace hiện tại</dt><dd>{state.selected?.name}</dd></div>
              </dl>

              {state.selected?.role === 'ADMIN' && activeSession && (runtimeAvailability.templates || runtimeAvailability.devices) ? (
                <div className="auth-workbench-nav" role="navigation" aria-label="Chức năng quản trị workspace">
                  <button
                    type="button"
                    className={`auth-secondary ${workspaceTab === 'summary' ? 'auth-tab-active' : ''}`}
                    aria-pressed={workspaceTab === 'summary'}
                    onClick={
                      /** Hiển thị lại thẻ tổng quan phiên xác thực của workspace. */
                      () => setWorkspaceTab('summary')
                    }
                  >
                    Tổng quan phiên
                  </button>
                  {runtimeAvailability.templates ? (
                    <button
                      type="button"
                      className={`auth-secondary ${workspaceTab === 'templates' ? 'auth-tab-active' : ''}`}
                      aria-pressed={workspaceTab === 'templates'}
                      onClick={
                        /** Mở workbench WB-03 (005 T4 + 006 V4) cho workspace hiện hành. */
                        () => setWorkspaceTab('templates')
                      }
                    >
                      Templates (WB-03)
                    </button>
                  ) : null}
                  {runtimeAvailability.devices ? (
                    <button
                      type="button"
                      className={`auth-secondary ${workspaceTab === 'devices' ? 'auth-tab-active' : ''}`}
                      aria-pressed={workspaceTab === 'devices'}
                      onClick={
                        /** Mở workbench WB-04 (007 D4 + 008 metadata-only poll) cho workspace hiện hành. */
                        () => setWorkspaceTab('devices')
                      }
                    >
                      Thiết bị &amp; USB (WB-04)
                    </button>
                  ) : null}
                </div>
              ) : null}

              <p className="auth-hint">Bạn có thể chuyển workspace hoặc đăng xuất tại đây.</p>
              <button
                className="auth-secondary"
                type="button"
                disabled={state.busy || offline}
                onClick={
                  /** Quay về picker qua guard thật, xóa nội dung scope trước khi nhận danh sách mới. */
                  () => void coordinator.restore()
                }
              >
                Chuyển workspace
              </button>
            </div>
          )}
          {state.phase === 'recovery' && (
            <div className="auth-recovery">
              <p>{state.logoutPending ? 'Chưa xác nhận kết quả đăng xuất với máy chủ. Nội dung workspace đang được khóa trên trình duyệt.' : 'Chưa xác nhận trạng thái phiên. Nội dung workspace đang được khóa.'}</p>
              {state.candidate && !state.logoutPending ? <><p>{state.candidate.kind === 'full' ? `Phiên hiện tại: ${state.candidate.me.email}` : 'Phiên hiện tại yêu cầu đổi mật khẩu.'}</p><button className="auth-primary" type="button" disabled={state.busy || offline}
                onClick={
                  /** Bắt buộc xác nhận chủ động sau discovery, không tự nhận account từ cookie. */
                  () => void coordinator.acceptCandidate()
                }>Xác nhận tiếp tục phiên này</button></> : <button className="auth-primary" type="button" disabled={state.busy || offline}
                onClick={
                  /** GET discovery chỉ đưa ra ứng viên hoặc đối soát logoutPending. */
                  () => void coordinator.discover()
                }>{state.busy ? (state.logoutPending ? 'Đang đối soát đăng xuất…' : 'Đang đối soát…') : state.logoutPending ? 'Đối soát và tiếp tục đăng xuất' : 'Đối soát phiên hiện tại'}</button>}
              {!state.logoutPending && <button className="auth-secondary" type="button" disabled={state.busy}
                onClick={
                  /** Người dùng quyết định bỏ intent login UNKNOWN để gửi lần đăng nhập mới. */
                  () => void coordinator.startNewLogin()
                }>Đăng nhập lại</button>}
            </div>
          )}
          {['limited', 'picker', 'selected'].includes(state.phase) && <button className="auth-secondary auth-logout" type="button" disabled={state.busy || offline}
            onClick={
              /** Logout luôn qua coordinator để khóa cache và giữ marker khi kết quả chưa rõ. */
              () => void coordinator.signOut()
            }>{state.busy && state.logoutPending ? 'Đang đăng xuất…' : 'Đăng xuất'}</button>}
          {state.busy && state.phase !== 'loading' && <p className="auth-progress" role="status"><span className="auth-spinner" aria-hidden="true" />{state.logoutPending ? 'Đang xử lý đăng xuất…' : 'Đang xử lý…'}</p>}
        </div>
        {state.phase === 'selected' && state.selected && activeSession
          && ((workspaceTab === 'templates' && runtimeAvailability.templates)
            || (workspaceTab === 'devices' && runtimeAvailability.devices)) ? (
          <div className="auth-workbench-stage">
            <Suspense fallback={<p className="auth-hint" role="status">Đang tải màn hình quản trị workspace…</p>}>
              {workspaceTab === 'templates' ? (
                <LazyTemplatesWorkbench
                  workspaceId={state.selected.id}
                  workspaceName={state.selected.name}
                  workspaceRole={state.selected.role}
                  session={activeSession}
                  onAuthError={
                    /** Hủy quyền điều phối cũ và đối soát lại phiên khi gặp lỗi 401/409 từ API workspace. */
                    () => {
                      coordinator.invalidate();
                      void coordinator.restore();
                    }
                  }
                />
              ) : (
                <LazyDevicesPage
                  workspaceId={state.selected.id}
                  workspaceName={state.selected.name}
                  workspaceRole={state.selected.role}
                  session={activeSession}
                  onAuthError={
                    /** Hủy quyền điều phối cũ và đối soát lại phiên khi gặp lỗi 401/409 từ API thiết bị. */
                    () => {
                      coordinator.invalidate();
                      void coordinator.restore();
                    }
                  }
                />
              )}
            </Suspense>
          </div>
        ) : null}
        </div>
      </main>
      <footer className="auth-footer"><span translate="no">Nexa IoT</span><span className="auth-footer-dot" aria-hidden="true" /><span>Không gian làm việc kết nối</span></footer>
    </div>
  );
}
