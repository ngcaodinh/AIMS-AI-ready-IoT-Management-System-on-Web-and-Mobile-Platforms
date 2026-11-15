import {
  assertAuthApiReady, AuthError, getMe, isUuid, listWorkspaces, login, mutateSession, selectWorkspace,
  type MeResult, type Profile, type SessionMetadata, type Workspace,
} from './api.ts';

type Marker = {
  intentId: string;
  phase: 'loginPending' | 'loginUnknown' | 'accepted' | 'logoutPending';
  contextId?: string;
};

export interface AuthState {
  phase: 'login' | 'loading' | 'limited' | 'picker' | 'selected' | 'recovery';
  busy: boolean;
  error: string;
  retryAt: number;
  profile?: Profile;
  workspaces: Workspace[];
  nextCursor: string | null;
  selected?: Workspace;
  candidate?: MeResult;
  logoutPending: boolean;
}

/** Khóa lưu intent phi bí mật; credential và CSRF không được ghi vào Web Storage. */
const MARKER_KEY = 'nexa-auth-intent';
/** Trạng thái fail-closed dùng để xóa mọi dữ liệu hiển thị từ phiên trước. */
const INITIAL_STATE: AuthState = {
  phase: 'login', busy: false, error: '', retryAt: 0,
  workspaces: [], nextCursor: null, logoutPending: false,
  profile: undefined, selected: undefined, candidate: undefined,
};

/** Điều phối auth theo intent bền vững; không lưu password, token hoặc CSRF vào storage. */
export class AuthCoordinator {
  private session?: SessionMetadata;
  private currentIntent = '';
  private generation = 0;
  private state: AuthState = { ...INITIAL_STATE };

  /** Nhận callback UI; một coordinator quản lý cả login, restore, password và logout. */
  constructor(private publish: (state: AuthState) => void) {}

  /**
   * Tuần tự hóa auth giữa các tab và bỏ tác vụ bị invalidate trong lúc chờ Web Lock.
   * Input
   * Param: operation — tác vụ thuộc generation lúc xếp hàng, chỉ chạy khi generation còn hiện hành.
   * Output: hoàn tất tác vụ hoặc bỏ tác vụ cũ; thiếu Web Locks chuyển UI sang recovery.
   */
  private async exclusive(operation: () => Promise<void>): Promise<void> {
    const generation = this.generation;
    if (!navigator.locks) {
      this.fail(new AuthError('STORAGE_ERROR'), true);
      return;
    }
    await navigator.locks.request('nexa-auth-mutation',
      /** Cleanup/storage event hủy cả callback còn xếp hàng, trước mọi request hoặc ghi marker. */
      async () => { if (generation === this.generation) await operation(); },
    );
  }

  /** Khôi phục phiên chỉ sau khi mutation ở tab khác đã nhả quyền điều phối. */
  async restore(): Promise<void> {
    const generation = this.generation;
    await this.exclusive(
      /** Không chạy restore song song login/logout giữa các tab cùng origin. */
      async () => { if (generation === this.generation) await this.executeRestore(); },
    );
  }

  /**
   * Khóa submit ngay khi xếp hàng rồi serialize login tới confirmation với các tab khác.
   * Input
   * Param: email — địa chỉ người dùng nhập, được API chuẩn hóa theo contract.
   * Param: password — credential giữ trong closure của đúng lần submit, không ghi storage.
   * Side effects: công bố busy và xóa lỗi POST cũ trước khi chờ lock để UI không gán lỗi cũ
   * cho credential mới; submit lặp không tạo thêm POST. Không thay cooldown hoặc marker.
   */
  async signIn(email: string, password: string): Promise<void> {
    if (this.state.busy) return;
    this.update({ busy: true, error: '' });
    await this.exclusive(
      /** Password chỉ được giữ trong closure của lần submit, không lưu marker. */
      () => this.executeSignIn(email, password),
    );
  }

  /** Xác nhận ứng viên bằng cùng khóa với các mutation auth để tránh accepted ghi đè. */
  async acceptCandidate(): Promise<void> {
    await this.exclusive(
      /** Kiểm lại marker sau khi lấy khóa, vì tab khác có thể vừa logout. */
      () => this.executeAcceptCandidate(),
    );
  }

  /** Logout dùng chung mutex browser với login; server context fence vẫn kiểm cookie thực tế. */
  async signOut(): Promise<void> {
    await this.exclusive(
      /** Không cho hai auth mutation chiếm cùng cookie jar đồng thời từ UI. */
      () => this.executeSignOut(),
    );
  }

  /** Đổi mật khẩu cũng phải tuần tự với logout/account switch giữa các tab. */
  async changePassword(currentPassword: string, newPassword: string): Promise<void> {
    await this.exclusive(
      /** Credential chỉ tồn tại trong closure request hiện hành. */
      () => this.executeChangePassword(currentPassword, newPassword),
    );
  }

  /** Đọc marker strict; storage lỗi hoặc JSON hỏng phải khóa protected UI. */
  private readMarker(): Marker | null {
    try {
      const raw = localStorage.getItem(MARKER_KEY);
      if (!raw) return null;
      const value: unknown = JSON.parse(raw);
      if (typeof value !== 'object' || value === null || !('intentId' in value)
        || !isUuid(value.intentId) || !('phase' in value)
        || !['loginPending', 'loginUnknown', 'accepted', 'logoutPending'].includes(String(value.phase))
        || ('contextId' in value && !isUuid(value.contextId))) throw new Error();
      if ((value.phase === 'accepted' || value.phase === 'logoutPending') && !('contextId' in value)) throw new Error();
      return value as Marker;
    } catch {
      throw new AuthError('STORAGE_ERROR');
    }
  }

  /** Ghi marker trước mutation; thất bại thì không gửi request có side effect. */
  private writeMarker(marker: Marker | null): void {
    try {
      if (marker) localStorage.setItem(MARKER_KEY, JSON.stringify(marker));
      else localStorage.removeItem(MARKER_KEY);
    } catch {
      throw new AuthError('STORAGE_ERROR');
    }
  }

  /** Chỉ callback thuộc intent hiện hành và marker hiện tại mới được cập nhật UI/cache. */
  private assertCurrent(intentId: string): void {
    if (this.currentIntent !== intentId || this.readMarker()?.intentId !== intentId) {
      throw new AuthError('AUTH_INTENT_CHANGED');
    }
  }

  /** Công bố một snapshot mới để React không dùng lại state/cached workspace của account cũ. */
  private update(patch: Partial<AuthState>): void {
    this.state = { ...this.state, ...patch };
    this.publish(this.state);
  }

  /** Xử lý lỗi auth theo outcome; lỗi mạng không tự revoke hoặc replay login. */
  private fail(error: unknown, recovery = false): void {
    const failure = error instanceof AuthError ? error : new AuthError('PROTOCOL_ERROR');
    this.update({
      phase: recovery ? 'recovery' : this.state.phase, busy: false, error: failure.code,
      retryAt: failure.retryAfter ? Date.now() + failure.retryAfter * 1000 : 0,
      workspaces: [], nextCursor: null, selected: undefined,
      profile: undefined, candidate: undefined,
    });
  }

  /** Phục hồi accepted marker bằng /me có context; pending/unknown chỉ hiện recovery khóa. */
  private async executeRestore(): Promise<void> {
    this.session = undefined;
    this.update({ ...INITIAL_STATE, phase: 'loading', busy: true });
    try {
      const marker = this.readMarker();
      if (!marker) {
        this.update({ phase: 'login', busy: false });
        return;
      }
      this.currentIntent = marker.intentId;
      if (marker.phase !== 'accepted') {
        this.update({ phase: 'recovery', busy: false, logoutPending: marker.phase === 'logoutPending' });
        return;
      }
      await this.bootstrap(marker.intentId, marker.contextId);
    } catch (error) {
      this.fail(error, true);
    }
  }

  /** Khóa ngay khi tab khác đổi intent; cookie dùng chung nên không có session riêng theo tab. */
  invalidate(): void {
    this.generation += 1;
    this.currentIntent = '';
    this.session = undefined;
    this.update({ ...INITIAL_STATE, phase: 'recovery', error: 'AUTH_INTENT_CHANGED' });
  }

  /**
   * Chặn login nếu API chưa sẵn sàng, đồng thời bỏ thao tác đã invalidate sau mọi điểm chờ bất đồng bộ.
   * Input
   * Param: email — địa chỉ chuyển tới boundary API sau khi readiness probe thành công.
   * Param: password — credential của lần submit; không trim hoặc persist.
   * Output: cập nhật state sang login, recovery hoặc luồng bootstrap theo response quan sát được.
   * Errors: outage trước POST về form với `SERVICE_UNAVAILABLE`; lỗi sau POST có thể giữ `loginUnknown`.
   * Side effects: probe GET không cookie; sau đó ghi marker trước mutation POST để reload không tự phát lại login.
   */
  private async executeSignIn(email: string, password: string): Promise<void> {
    const generation = this.generation;
    let intentId = '';
    let credentialIssued = false;
    try {
      if (this.readMarker()?.phase === 'logoutPending') throw new AuthError('LOGOUT_PENDING');
      this.update({ ...INITIAL_STATE, phase: 'loading', busy: true });
      await assertAuthApiReady();
    } catch (error) {
      if (generation !== this.generation) return;
      if (error instanceof AuthError && error.code === 'LOGOUT_PENDING') {
        this.fail(error, true);
      } else if (error instanceof AuthError && error.code === 'SERVICE_UNAVAILABLE') {
        // Probe lỗi xảy ra trước marker và POST nên form có thể thử lại mà không cần đối soát intent UNKNOWN.
        this.update({ phase: 'login' });
        this.fail(error);
      } else {
        this.fail(error, true);
      }
      return;
    }

    // Probe là điểm chờ bất đồng bộ; cleanup/focus resume phải hủy intent cũ trước mọi marker hoặc POST credential.
    if (generation !== this.generation) return;

    try {
      intentId = crypto.randomUUID();
      this.writeMarker({ intentId, phase: 'loginPending' });
      this.currentIntent = intentId;
      this.session = undefined;
      this.update({ ...INITIAL_STATE, phase: 'loading', busy: true });
      const result = await login(email, password);
      credentialIssued = true;
      this.assertCurrent(intentId);
      await this.bootstrap(intentId, result.contextId, result.me);
    } catch (error) {
      // Chỉ lỗi chắc chắn từ server trước credential mới được quay lại form; network/503 là UNKNOWN.
      const rejected = !credentialIssued && error instanceof AuthError
        && [400, 401, 403, 413, 415, 422, 429].includes(error.status);
      try {
        if (intentId && this.readMarker()?.intentId === intentId) {
          this.writeMarker(rejected ? null : { intentId, phase: 'loginUnknown' });
        }
      } catch {
        this.fail(new AuthError('STORAGE_ERROR'), true);
        return;
      }
      if (rejected) this.update({ phase: 'login' });
      this.fail(error, !rejected);
    }
  }

  /** Xác nhận cùng identity/context trước picker; limited chỉ nhận 403 đúng context. */
  private async bootstrap(intentId: string, contextId?: string, expected?: Profile): Promise<void> {
    const result = await getMe(contextId);
    this.assertCurrent(intentId);
    if (!contextId || result.contextId !== contextId
      || (expected && ((result.kind === 'limited') !== expected.mustChangePassword
        || (result.kind === 'full' && result.me.id !== expected.id)))) {
      throw new AuthError('AUTH_CONTEXT_MISMATCH', 409);
    }
    this.session = { contextId: result.contextId, csrfToken: result.csrfToken };
    this.writeMarker({ intentId, phase: 'accepted', contextId });
    if (result.kind === 'limited') {
      this.update({ phase: 'limited', busy: false, candidate: undefined, error: '' });
      return;
    }
    this.update({ profile: result.me });
    const page = await listWorkspaces(contextId);
    this.assertCurrent(intentId);
    this.update({ phase: 'picker', busy: false, workspaces: page.items, nextCursor: page.nextCursor, error: '', candidate: undefined });
  }

  /** Discovery không cấp quyền UI; chỉ lấy ứng viên để người dùng xác nhận phiên hiện tại. */
  async discover(): Promise<void> {
    const generation = this.generation;
    let originalMarker: Marker | null = null;
    this.update({ busy: true, error: '', candidate: undefined });
    try {
      originalMarker = this.readMarker();
      const candidate = await getMe();
      const marker = this.readMarker();
      if (generation !== this.generation
        || JSON.stringify(marker) !== JSON.stringify(originalMarker)) return;
      if (marker?.phase === 'logoutPending') {
        if (candidate.contextId !== marker.contextId) throw new AuthError('AUTH_CONTEXT_MISMATCH', 409);
        this.session = candidate;
        this.currentIntent = marker.intentId;
        await this.signOut();
        return;
      }
      this.update({ phase: 'recovery', busy: false, candidate });
    } catch (error) {
      if (generation !== this.generation) return;
      // 401 terminal chỉ xác nhận credential hiện tại không còn dùng được, không khẳng định DB commit logout.
      if (originalMarker?.phase === 'logoutPending' && error instanceof AuthError
        && error.status === 401 && error.code === 'SESSION_EXPIRED') {
        try {
          if (JSON.stringify(this.readMarker()) !== JSON.stringify(originalMarker)) return;
          this.writeMarker(null);
          this.session = undefined;
          this.update({ ...INITIAL_STATE, error: 'LOGOUT_TERMINAL' });
          return;
        } catch {
          this.fail(new AuthError('STORAGE_ERROR'), true);
          return;
        }
      }
      this.fail(error, true);
    }
  }

  /** Chỉ thao tác xác nhận chủ động mới chấp nhận context lấy từ discovery UNKNOWN. */
  private async executeAcceptCandidate(): Promise<void> {
    if (!this.state.candidate || this.state.busy) return;
    try {
      const marker = this.readMarker();
      if (marker?.phase === 'logoutPending') throw new AuthError('LOGOUT_PENDING');
      const intentId = crypto.randomUUID();
      this.currentIntent = intentId;
      const contextId = this.state.candidate.contextId;
      this.writeMarker({ intentId, phase: 'loginUnknown', contextId });
      this.update({ phase: 'loading', busy: true });
      await this.bootstrap(intentId, contextId);
    } catch (error) {
      this.fail(error, true);
    }
  }

  /** Bắt đầu login mới theo ý người dùng; không bỏ qua logout chưa xác nhận. */
  async startNewLogin(): Promise<void> {
    await this.exclusive(
      /** Đọc lại pending marker dưới cùng Web Lock trước khi xóa intent cũ. */
      async () => this.executeStartNewLogin(),
    );
  }

  /** Reset chủ động dưới Web Lock, không được xóa logoutPending của tab khác. */
  private executeStartNewLogin(): void {
    try {
      if (this.readMarker()?.phase === 'logoutPending') throw new AuthError('LOGOUT_PENDING');
      this.writeMarker(null);
      this.currentIntent = '';
      this.session = undefined;
      this.update({ ...INITIAL_STATE });
    } catch (error) {
      this.fail(error, true);
    }
  }

  /**
   * Tải thêm có dedupe; cả kết quả và lỗi chỉ được áp dụng cho generation/intent đang chọn workspace.
   * Side effects: cập nhật danh sách hiện hành; bỏ callback cũ mà không xóa state của phiên mới.
   */
  async loadMore(): Promise<void> {
    if (!this.session || !this.state.nextCursor || this.state.busy) return;
    const generation = this.generation;
    const intentId = this.currentIntent;
    this.update({ busy: true, error: '' });
    try {
      const page = await listWorkspaces(this.session.contextId, this.state.nextCursor);
      // Restore có thể giữ nguyên intent ID; generation vẫn phải chặn dữ liệu từ vòng đời trước.
      if (generation !== this.generation || intentId !== this.currentIntent) return;
      this.assertCurrent(intentId);
      const workspaces = new Map(this.state.workspaces.map(
        /** Gộp theo UUID để cursor lặp không tạo hai lựa chọn cùng workspace. */
        (workspace) => [workspace.id, workspace] as const,
      ));
      for (const workspace of page.items) workspaces.set(workspace.id, workspace);
      this.update({ busy: false, workspaces: [...workspaces.values()], nextCursor: page.nextCursor });
    } catch (error) {
      // Lỗi hoặc assert từ read cũ không được gọi fail() để xóa picker của phiên vừa accepted.
      if (generation !== this.generation || intentId !== this.currentIntent) return;
      this.fail(error, true);
    }
  }

  /**
   * Recheck membership bằng API thật trước khi công bố workspace đã chọn trong đúng intent.
   * Input
   * Param: workspaceId — UUID của lựa chọn; server vẫn kiểm quyền hiện hành.
   * Side effects: cập nhật lựa chọn hoặc lỗi của phiên hiện hành, bỏ mọi callback thuộc phiên cũ.
   */
  async choose(workspaceId: string): Promise<void> {
    // Callback picker cũ không được phát resource request khi recovery đã xóa admission/cache.
    if (!this.session || this.state.busy || this.state.phase !== 'picker'
      || !this.state.workspaces.some(
        /** Chỉ lựa chọn đang có trong picker hiện hành mới được recheck với server. */
        (workspace) => workspace.id === workspaceId,
      )) return;
    const generation = this.generation;
    const intentId = this.currentIntent;
    this.update({ busy: true, error: '' });
    try {
      const selected = await selectWorkspace(this.session.contextId, workspaceId);
      // Không mở workspace từ lựa chọn cũ dù restore mới dùng lại accepted intent ID.
      if (generation !== this.generation || intentId !== this.currentIntent) return;
      this.assertCurrent(intentId);
      this.update({ phase: 'selected', busy: false, selected });
    } catch (error) {
      // Cả response thành công bị fence lẫn lỗi HTTP muộn đều không sở hữu state phiên mới.
      if (generation !== this.generation || intentId !== this.currentIntent) return;
      this.fail(error, true);
    }
  }

  /** Logout khóa ngay và giữ marker khi network UNKNOWN; không mở lại cache phiên cũ. */
  private async executeSignOut(): Promise<void> {
    if (!this.session) return;
    const session = this.session;
    const intentId = this.currentIntent;
    try {
      this.writeMarker({ intentId, phase: 'logoutPending', contextId: session.contextId });
      this.update({ ...INITIAL_STATE, phase: 'loading', busy: true, logoutPending: true });
      await mutateSession('/auth/logout', session);
      this.assertCurrent(intentId);
      this.writeMarker(null);
      this.session = undefined;
      this.update({ ...INITIAL_STATE });
    } catch (error) {
      this.fail(error, true);
    }
  }

  /** Đổi password bằng limited session; server revoke mọi phiên và bắt đăng nhập mới. */
  private async executeChangePassword(currentPassword: string, newPassword: string): Promise<void> {
    if (!this.session || this.state.busy || this.state.retryAt > Date.now()) return;
    const intentId = this.currentIntent;
    this.update({ busy: true, error: '' });
    try {
      await mutateSession('/auth/password', this.session, { currentPassword, newPassword });
      this.assertCurrent(intentId);
      this.writeMarker(null);
      this.session = undefined;
      this.update({ ...INITIAL_STATE, error: 'PASSWORD_CHANGED' });
    } catch (error) {
      const canCorrect = error instanceof AuthError
        && ((error.status === 401 && error.code === 'AUTH_INVALID') || [422, 429].includes(error.status));
      this.fail(error, !canCorrect);
    }
  }
}
