import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type ChangeEvent,
  type MouseEvent,
  type MutableRefObject,
  type RefObject,
} from 'react';
import { BrandLink } from '../../BrandLink';
import { IconSprite } from '../../IconSprite';
import { TemplateEditor } from './TemplateEditor';
import {
  createEmptyTemplateForm,
  createInMemoryTemplateStore,
  PREVIEW_WORKSPACES,
  serializeFormForDirtyCheck,
  templateDtoToForm,
  type PreviewScenario,
  type TemplateDraftForm,
  type TemplateDto,
  type TemplatePreviewStore,
  type TemplateSaveOutcome,
  type WorkspaceFixture,
} from './templateMockApi';
import './templates.css';

type PendingGuardAction =
  | { type: 'back_to_list' }
  | { type: 'switch_workspace'; workspaceId: string }
  | null;

interface ListErrorState {
  kind: 'permission' | 'network';
  status: number;
  message: string;
}

/**
 * Vẽ icon SVG nét từ IconSprite dùng chung, ẩn khỏi trình đọc màn hình vì đi cùng nhãn chữ.
 * Input
 * Param: name — tên symbol trong IconSprite.
 * Output: phần tử SVG kích thước 18px kế thừa currentColor.
 */
function TemplateIcon({ name }: { name: string }) {
  return (
    <svg className="tpl-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <use href={`#i-${name}`} />
    </svg>
  );
}

/**
 * Khôi phục chế độ sáng/tối ban đầu từ thuộc tính DOM hiện tại hoặc tùy chọn hệ thống, không ghi storage.
 * Output: true nếu giao diện đang ở nền tối.
 */
function getInitialDarkTheme(): boolean {
  const current = document.documentElement.dataset.theme;
  if (current === 'dark') return true;
  if (current === 'light') return false;
  return window.matchMedia('(prefers-color-scheme: dark)').matches;
}

/**
 * Tra cứu workspace mẫu theo ID; luôn fallback về phần tử đầu khi cần thiết trong phiên preview.
 * Input
 * Param: workspaceId — mã workspace cần tìm.
 * Output: đối tượng WorkspaceFixture tương ứng.
 */
function findWorkspaceFixture(workspaceId: string): WorkspaceFixture {
  /** Khớp chính xác workspaceId tổng hợp đã chọn. */
  function isMatchingWorkspace(item: WorkspaceFixture): boolean {
    return item.id === workspaceId;
  }
  return PREVIEW_WORKSPACES.find(isMatchingWorkspace) ?? PREVIEW_WORKSPACES[0];
}

/**
 * Gộp thêm một trang template mới theo ID duy nhất khi phân trang qua cursor.
 * Input
 * Param: prev — danh sách template đã có ở các trang trước.
 * Param: nextItems — danh sách trang vừa tải thêm.
 * Output: mảng template đã khử trùng lặp theo ID.
 */
function mergeTemplatePage(prev: TemplateDto[], nextItems: TemplateDto[]): TemplateDto[] {
  /** Thu thập các ID đã hiển thị để không nhân bản khi cursor trùng biên. */
  function readTemplateId(item: TemplateDto): string {
    return item.id;
  }
  const seen = new Set(prev.map(readTemplateId));
  const merged = [...prev];
  for (const nextItem of nextItems) {
    if (!seen.has(nextItem.id)) merged.push(nextItem);
  }
  return merged;
}

/**
 * Lọc danh sách ứng viên DRAFT thuộc workspace hiện tại cho bước đối chiếu sau POST unknown.
 * Input
 * Param: items — danh sách template trả về từ scope workspace hiện hành.
 * Output: chỉ các template có trạng thái DRAFT.
 */
function filterDraftCandidates(items: TemplateDto[]): TemplateDto[] {
  /** Chỉ giữ các bản nháp để người dùng chọn đối chiếu hoặc tạo mới thủ công. */
  function isDraftTemplate(item: TemplateDto): boolean {
    return item.status === 'DRAFT';
  }
  return items.filter(isDraftTemplate);
}

/**
 * Tăng bộ đếm tải lại lên một đơn vị để kích hoạt effect nạp danh sách.
 * Input
 * Param: prev — giá trị bộ đếm hiện tại.
 * Output: giá trị kế tiếp.
 */
function incrementCounter(prev: number): number {
  return prev + 1;
}

/**
 * Hiển thị dải thông báo cố định rằng màn hình chỉ chạy preview phát triển trong bộ nhớ tab,
 * kèm bộ chọn workspace mẫu và kịch bản lỗi để kiểm thử toàn bộ state matrix WB-03.
 * Input
 * Param: workspaces — danh sách workspace tổng hợp sẵn có.
 * Param: selectedWorkspaceId — mã workspace đang chọn.
 * Param: scenario — chế độ mô phỏng trạng thái mạng/xung đột/404.
 * Param: onSelectWorkspace — yêu cầu chuyển workspace (đi qua dirty guard nếu đang sửa dở).
 * Param: onSelectScenario — chuyển kịch bản mô phỏng trong phiên preview.
 * Output: vùng banner cố định luôn hiển thị trên cùng màn hình.
 */
function PreviewBanner({
  workspaces,
  selectedWorkspaceId,
  scenario,
  onSelectWorkspace,
  onSelectScenario,
}: {
  workspaces: readonly WorkspaceFixture[];
  selectedWorkspaceId: string;
  scenario: PreviewScenario;
  onSelectWorkspace: (workspaceId: string) => void;
  onSelectScenario: (scenario: PreviewScenario) => void;
}) {
  /** Chuyển đổi workspace tổng hợp qua hàm kiểm tra dirty guard. */
  function handleWorkspaceChange(event: ChangeEvent<HTMLSelectElement>): void {
    onSelectWorkspace(event.target.value);
  }

  /** Cập nhật kịch bản mô phỏng cho thao tác kiểm thử kế tiếp. */
  function handleScenarioChange(event: ChangeEvent<HTMLSelectElement>): void {
    onSelectScenario(event.target.value as PreviewScenario);
  }

  /** Hiển thị tên, vai trò ADMIN/USER và nhãn tổng hợp của từng workspace mẫu. */
  function renderWorkspaceOption(ws: WorkspaceFixture) {
    return (
      <option key={ws.id} value={ws.id}>
        {ws.name} — Vai trò {ws.role}
      </option>
    );
  }

  return (
    <section className="tpl-preview-banner" aria-label="Cảnh báo chế độ xem trước phát triển">
      <div className="tpl-preview-banner-head">
        <TemplateIcon name="shield" />
        <div>
          <strong>Chế độ xem trước phát triển (WB-03 · /dev/templates-preview) — Không lưu trên máy chủ</strong>
          <p>
            Màn hình đang dùng dữ liệu mẫu tổng hợp trong bộ nhớ tab hiện tại; mọi thao tác không gửi API, không dùng workspace ID thật và không ghi xuống cơ sở dữ liệu.
          </p>
        </div>
      </div>

      <div className="tpl-preview-controls">
        <div className="tpl-control-group">
          <label htmlFor="tpl-workspace-select">Ngữ cảnh workspace tổng hợp</label>
          <select
            id="tpl-workspace-select"
            name="previewWorkspace"
            autoComplete="off"
            className="tpl-select"
            value={selectedWorkspaceId}
            onChange={handleWorkspaceChange}
          >
            {workspaces.map(renderWorkspaceOption)}
          </select>
        </div>

        <div className="tpl-control-group">
          <label htmlFor="tpl-scenario-select">Kịch bản mô phỏng phản hồi (chỉ preview)</label>
          <select
            id="tpl-scenario-select"
            name="previewScenario"
            autoComplete="off"
            className="tpl-select"
            value={scenario}
            onChange={handleScenarioChange}
          >
            <option value="normal">Bình thường (In-memory validation + CAS)</option>
            <option value="offline">Ngoại tuyến / lỗi mạng (Offline)</option>
            <option value="stale_412">Xung đột phiên bản 412 (Stale If-Match)</option>
            <option value="not_found_404">Ngoài phạm vi / không tồn tại 404</option>
            <option value="pending_post_unknown">Mất phản hồi sau POST (Pending / Unknown)</option>
          </select>
        </div>
      </div>
    </section>
  );
}

/**
 * Hiển thị danh sách template trong workspace đang chọn cùng trạng thái loading, empty, từ chối quyền, lỗi mạng và phân trang.
 * Input
 * Param: workspace — thông tin workspace mẫu đang xem.
 * Param: templates — danh sách template đã tải thuộc đúng workspace hiện tại.
 * Param: nextCursor — con trỏ tải trang kế tiếp hoặc null nếu đã hết.
 * Param: isLoading — đang tải lại danh sách từ đầu.
 * Param: isLoadingMore — đang tải thêm trang tiếp theo.
 * Param: listError — lỗi quyền 403/404 hoặc lỗi mạng.
 * Param: headingRef — tham chiếu tiêu đề h1 để đưa tiêu điểm khi chuyển màn.
 * Param: onCreateNew — mở form tạo draft mới.
 * Param: onOpenTemplate — mở chi tiết một template theo ID.
 * Param: onLoadMore — tải trang kế tiếp theo cursor.
 * Param: onReload — tải lại danh sách khi người dùng bấm thử lại.
 * Output: khối danh sách template hoàn chỉnh các trạng thái của WB-03.
 */
function TemplateList({
  workspace,
  templates,
  nextCursor,
  isLoading,
  isLoadingMore,
  listError,
  headingRef,
  onCreateNew,
  onOpenTemplate,
  onLoadMore,
  onReload,
}: {
  workspace: WorkspaceFixture;
  templates: TemplateDto[];
  nextCursor: string | null;
  isLoading: boolean;
  isLoadingMore: boolean;
  listError: ListErrorState | null;
  headingRef: RefObject<HTMLHeadingElement | null>;
  onCreateNew: () => void;
  onOpenTemplate: (templateId: string) => void;
  onLoadMore: () => void;
  onReload: () => void;
}) {
  /** Mở đúng template được chọn qua thuộc tính `data-template-id`. */
  function handleOpenClick(event: MouseEvent<HTMLButtonElement>): void {
    const templateId = event.currentTarget.dataset.templateId;
    if (templateId) onOpenTemplate(templateId);
  }

  /** Hiển thị tóm tắt trạng thái, model, số kênh, revision và thời điểm cập nhật. */
  function renderTemplateRow(item: TemplateDto) {
    return (
      <li key={item.id} className="tpl-list-item">
        <div className="tpl-list-item-main">
          <div className="tpl-list-item-title">
            <h2>{item.name}</h2>
            <span className={`tpl-badge ${item.status === 'PUBLISHED' ? 'tpl-badge-published' : 'tpl-badge-draft'}`}>
              <TemplateIcon name={item.status === 'PUBLISHED' ? 'lock' : 'layers'} />
              <span>{item.status === 'PUBLISHED' ? `PUBLISHED · v${item.publishedVersion ?? 1}` : 'DRAFT'}</span>
            </span>
          </div>
          <div className="tpl-meta-line">
            <span>Model: <span className="tpl-mono">{item.model}</span></span>
            <span>{item.streams.length} datastream</span>
            <span>Revision #{item.revision}</span>
            <span>Cập nhật: {item.updatedAt}</span>
          </div>
        </div>
        <button
          type="button"
          className="tpl-btn"
          data-template-id={item.id}
          onClick={handleOpenClick}
        >
          <span>{item.status === 'PUBLISHED' ? 'Xem chỉ đọc' : 'Mở bản nháp'}</span>
          <TemplateIcon name="arrow" />
        </button>
      </li>
    );
  }

  return (
    <section className="tpl-card" aria-labelledby="tpl-list-heading">
      <div className="tpl-page-head">
        <div>
          <h1 id="tpl-list-heading" ref={headingRef} tabIndex={-1}>
            Templates
          </h1>
          <p className="tpl-lead">
            Thiết kế schema datastream và capability <code>SET_VALUE</code> cho thiết bị trong{' '}
            <strong>{workspace.name}</strong> ({workspace.description})
          </p>
        </div>
        <div className="tpl-actions-row">
          <button type="button" className="tpl-btn" disabled={isLoading} onClick={onReload}>
            Tải lại danh sách
          </button>
          {workspace.role === 'ADMIN' ? (
            <button type="button" className="tpl-btn tpl-btn-primary" disabled={isLoading} onClick={onCreateNew}>
              <TemplateIcon name="layers" />
              <span>Tạo template</span>
            </button>
          ) : null}
        </div>
      </div>

      {isLoading ? (
        <div className="tpl-skeleton-list" aria-busy="true" aria-label="Đang tải danh sách template">
          <div className="tpl-skeleton-row" aria-hidden="true" />
          <div className="tpl-skeleton-row" aria-hidden="true" />
          <p className="tpl-hint" role="status">Đang tải danh sách template trong workspace…</p>
        </div>
      ) : listError ? (
        <div className="tpl-notice tpl-notice-error" role="alert">
          <TemplateIcon name={listError.kind === 'permission' ? 'lock' : 'radio'} />
          <div className="tpl-notice-body">
            <p>
              <strong>
                {listError.kind === 'permission'
                  ? (listError.status === 404
                    ? 'Không tìm thấy tài nguyên trong workspace (404)'
                    : `Truy cập bị từ chối (${listError.status})`)
                  : 'Không thể tải danh sách template'}
              </strong>
            </p>
            <p>{listError.message}</p>
            {listError.kind === 'network' ? (
              <div className="tpl-actions-row">
                <button type="button" className="tpl-btn" onClick={onReload}>
                  Thử tải lại
                </button>
              </div>
            ) : null}
          </div>
        </div>
      ) : templates.length === 0 ? (
        <div className="tpl-state-box" role="status">
          <h2>Workspace này chưa có template nào</h2>
          <p>
            {workspace.role === 'ADMIN'
              ? 'Bắt đầu tạo bản nháp template để khai báo tên, mã model chuẩn và các kênh dữ liệu.'
              : 'Liên hệ quản trị viên workspace nếu cần cấu hình template mới.'}
          </p>
          {workspace.role === 'ADMIN' ? (
            <button type="button" className="tpl-btn tpl-btn-primary" onClick={onCreateNew}>
              Tạo template
            </button>
          ) : null}
        </div>
      ) : (
        <div className="tpl-editor-main">
          <ul className="tpl-list-grid">
            {templates.map(renderTemplateRow)}
          </ul>

          {nextCursor ? (
            <div className="tpl-actions-row">
              <button type="button" className="tpl-btn" disabled={isLoadingMore} onClick={onLoadMore}>
                {isLoadingMore ? 'Đang tải thêm…' : 'Tải thêm template'}
              </button>
            </div>
          ) : null}
        </div>
      )}
    </section>
  );
}

/**
 * Hộp thoại xác nhận trước khi bỏ thay đổi chưa lưu trong bản nháp khi quay lại danh sách hoặc đổi workspace.
 * Input
 * Param: pendingAction — hành động đang chờ xác nhận hoặc null nếu hộp thoại đóng.
 * Param: onStay — đóng hộp thoại và giữ nguyên biểu mẫu đang nhập.
 * Param: onDiscard — xác nhận bỏ thay đổi chưa lưu để tiếp tục điều hướng.
 * Output: modal `role="alertdialog"` hoặc null khi đóng.
 */
function DirtyConfirmDialog({
  pendingAction,
  onStay,
  onDiscard,
}: {
  pendingAction: PendingGuardAction;
  onStay: () => void;
  onDiscard: () => void;
}) {
  const stayButtonRef = useRef<HTMLButtonElement>(null);
  const discardButtonRef = useRef<HTMLButtonElement>(null);
  const previousFocusRef = useRef<HTMLElement | null>(null);
  // Giữ callback onStay mới nhất trong ref để effect chỉ chạy khi trạng thái mở modal thay đổi.
  const onStayRef = useRef(onStay);
  onStayRef.current = onStay;
  const isOpen = pendingAction !== null;

  /**
   * Quản lý focus bàn phím khi modal mở: đưa focus vào nút Ở lại, giữ Tab vòng trong modal và khôi phục khi đóng.
   * Output: hàm dọn dẹp gỡ listener và trả lại tiêu điểm trước đó.
   */
  function manageDialogFocusEffect(): void | (() => void) {
    if (!isOpen) return;
    previousFocusRef.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    stayButtonRef.current?.focus();

    /** Xử lý phím Escape (đóng an toàn) và Tab (giữ tiêu điểm bên trong hộp thoại). */
    function handleDialogKeyDown(event: KeyboardEvent): void {
      if (event.key === 'Escape') {
        event.preventDefault();
        onStayRef.current();
        return;
      }
      if (event.key !== 'Tab') return;
      const firstBtn = stayButtonRef.current;
      const lastBtn = discardButtonRef.current;
      if (!firstBtn || !lastBtn) return;

      if (event.shiftKey && document.activeElement === firstBtn) {
        event.preventDefault();
        lastBtn.focus();
      } else if (!event.shiftKey && document.activeElement === lastBtn) {
        event.preventDefault();
        firstBtn.focus();
      }
    }

    document.addEventListener('keydown', handleDialogKeyDown);
    /** Gỡ sự kiện bàn phím và trả tiêu điểm về phần tử trước khi mở modal nếu còn gắn trong DOM. */
    return function cleanupDialogFocus(): void {
      document.removeEventListener('keydown', handleDialogKeyDown);
      if (previousFocusRef.current && document.contains(previousFocusRef.current)) {
        previousFocusRef.current.focus();
      }
    };
  }

  useEffect(manageDialogFocusEffect, [isOpen]);

  if (!isOpen) return null;

  const destinationLabel =
    pendingAction.type === 'switch_workspace'
      ? 'chuyển sang workspace khác'
      : 'quay lại danh sách template';

  return (
    <div className="tpl-dialog-backdrop">
      <div
        className="tpl-dialog"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="tpl-dirty-title"
        aria-describedby="tpl-dirty-desc"
      >
        <h2 id="tpl-dirty-title">Bỏ thay đổi chưa lưu trong bản nháp?</h2>
        <p id="tpl-dirty-desc">
          Bạn đang có thay đổi chưa được áp dụng vào bản xem trước. Nếu {destinationLabel}, toàn bộ chỉnh sửa hiện tại trong tab này sẽ bị xóa.
        </p>
        <div className="tpl-actions-row">
          <button ref={stayButtonRef} type="button" className="tpl-btn" onClick={onStay}>
            Ở lại trình chỉnh sửa
          </button>
          <button ref={discardButtonRef} type="button" className="tpl-btn tpl-btn-danger" onClick={onDiscard}>
            Bỏ thay đổi và tiếp tục
          </button>
        </div>
      </div>
    </div>
  );
}

/**
 * Hook quản lý tải danh sách template theo workspace, phân trang cursor và hủy request cũ khi đổi ngữ cảnh.
 * Input
 * Param: store — kho dữ liệu mô phỏng trong bộ nhớ tab.
 * Param: workspaceId — mã workspace tổng hợp hiện đang chọn.
 * Param: scenarioRef — ref kịch bản mô phỏng mới nhất.
 * Param: contextGenerationRef — ref bộ đếm thế hệ để loại bỏ callback đến trễ từ workspace trước.
 * Param: activeAbortRef — ref AbortController hiện hành để hủy request đang chờ khi chuyển ngữ cảnh.
 * Output: state danh sách, hàm phân trang/tải lại và hàm xóa sạch dữ liệu khi đổi workspace.
 */
function useWorkspaceTemplateList(
  store: TemplatePreviewStore,
  workspaceId: string,
  scenarioRef: MutableRefObject<PreviewScenario>,
  contextGenerationRef: MutableRefObject<number>,
  activeAbortRef: MutableRefObject<AbortController | null>,
) {
  const [templates, setTemplates] = useState<TemplateDto[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [isLoadingList, setIsLoadingList] = useState<boolean>(true);
  const [isLoadingMore, setIsLoadingMore] = useState<boolean>(false);
  const [listError, setListError] = useState<ListErrorState | null>(null);
  const [reloadNonce, setReloadNonce] = useState<number>(0);

  /** Tải danh sách template đúng scope workspaceId; hủy yêu cầu cũ khi đổi workspace hoặc unmount. */
  function loadWorkspaceListEffect(): () => void {
    const generation = contextGenerationRef.current;
    activeAbortRef.current?.abort();
    const controller = new AbortController();
    activeAbortRef.current = controller;

    setIsLoadingList(true);
    setIsLoadingMore(false);
    setListError(null);

    /** Thực thi tải danh sách trong scope workspace hiện hành và bỏ qua kết quả nếu đã sang generation mới. */
    async function runLoad(): Promise<void> {
      try {
        const result = await store.listTemplates(workspaceId, scenarioRef.current, null, controller.signal);
        if (generation !== contextGenerationRef.current || controller.signal.aborted) return;
        if (result.ok) {
          setTemplates(result.items);
          setNextCursor(result.nextCursor);
          setListError(null);
        } else {
          setTemplates([]);
          setNextCursor(null);
          setListError({ kind: result.kind, status: result.status, message: result.message });
        }
      } catch (error) {
        if (error instanceof DOMException && error.name === 'AbortError') return;
        if (generation !== contextGenerationRef.current) return;
        setTemplates([]);
        setNextCursor(null);
        setListError({ kind: 'network', status: 0, message: 'Không thể tải danh sách template.' });
      } finally {
        if (generation === contextGenerationRef.current && !controller.signal.aborted) {
          setIsLoadingList(false);
        }
      }
    }

    void runLoad();

    /** Hủy yêu cầu đang chờ khi workspace đổi hoặc component rời DOM để chặn rò rỉ dữ liệu cũ. */
    return function abortListLoad(): void {
      controller.abort();
    };
  }

  useEffect(loadWorkspaceListEffect, [store, workspaceId, reloadNonce, scenarioRef, contextGenerationRef, activeAbortRef]);

  /** Tải thêm trang template kế tiếp theo con trỏ cursor mà không trùng lặp dữ liệu. */
  async function handleLoadMore(): Promise<void> {
    if (!nextCursor || isLoadingMore) return;
    const generation = contextGenerationRef.current;
    const controller = new AbortController();
    activeAbortRef.current = controller;
    setIsLoadingMore(true);

    try {
      const outcome = await store.listTemplates(workspaceId, scenarioRef.current, nextCursor, controller.signal);
      if (generation !== contextGenerationRef.current || controller.signal.aborted) return;
      if (outcome.ok) {
        const nextItems = outcome.items;
        /** Gộp thêm phần tử trang mới vào danh sách đang hiển thị. */
        function appendNextPage(prev: TemplateDto[]): TemplateDto[] {
          return mergeTemplatePage(prev, nextItems);
        }
        setTemplates(appendNextPage);
        setNextCursor(outcome.nextCursor);
      } else {
        setListError({ kind: outcome.kind, status: outcome.status, message: outcome.message });
      }
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') return;
      if (generation !== contextGenerationRef.current) return;
      setListError({ kind: 'network', status: 0, message: 'Không thể tải thêm danh sách template.' });
    } finally {
      if (generation === contextGenerationRef.current) {
        setIsLoadingMore(false);
      }
    }
  }

  /** Xóa toàn bộ dữ liệu danh sách của workspace cũ ngay lập tức trước khi chuyển ngữ cảnh. */
  function clearListState(): void {
    setTemplates([]);
    setNextCursor(null);
    setIsLoadingMore(false);
    setListError(null);
  }

  /** Kích hoạt tải lại danh sách theo workspace hiện hành. */
  function triggerReloadList(): void {
    setReloadNonce(incrementCounter);
  }

  return {
    templates,
    nextCursor,
    isLoadingList,
    isLoadingMore,
    listError,
    setIsLoadingList,
    setListError,
    handleLoadMore,
    clearListState,
    triggerReloadList,
  };
}

/**
 * Hook quản lý phiên chỉnh sửa bản nháp: phát hiện dirty, gửi tạo/cập nhật nháp,
 * xử lý xung đột 412 và tra cứu ứng viên khi gặp POST unknown.
 * Input
 * Param: store — kho dữ liệu mô phỏng trong tab.
 * Param: workspaceId — mã workspace hiện tại để cô lập yêu cầu lưu.
 * Param: scenario — kịch bản mô phỏng hiện hành.
 * Param: setScenario — cập nhật kịch bản về bình thường sau khi hòa giải 412.
 * Param: view — màn hình đang mở ('list' hoặc 'editor') để kích hoạt dirty check.
 * Param: setView — chuyển màn hình danh sách/chỉnh sửa.
 * Param: scenarioRef — ref kịch bản hiện hành cho các lệnh async.
 * Param: contextGenerationRef — ref thế hệ hiện tại chặn callback trễ từ workspace cũ.
 * Param: activeAbortRef — ref AbortController để hủy request đang gửi khi đổi workspace.
 * Output: state biểu mẫu, trạng thái lưu, ứng viên unknown và các handler thao tác editor.
 */
function useTemplateDraftSession(
  store: TemplatePreviewStore,
  workspaceId: string,
  scenario: PreviewScenario,
  setScenario: (next: PreviewScenario) => void,
  view: 'list' | 'editor',
  setView: (next: 'list' | 'editor') => void,
  scenarioRef: MutableRefObject<PreviewScenario>,
  contextGenerationRef: MutableRefObject<number>,
  activeAbortRef: MutableRefObject<AbortController | null>,
) {
  /** Tạo chuỗi mốc dirty ban đầu cho biểu mẫu trống ngay khi khởi tạo hook. */
  function createInitialBaselineKey(): string {
    return serializeFormForDirtyCheck(createEmptyTemplateForm());
  }

  const [editorForm, setEditorForm] = useState<TemplateDraftForm>(createEmptyTemplateForm);
  const [baselineKey, setBaselineKey] = useState<string>(createInitialBaselineKey);
  const [lastServerTemplate, setLastServerTemplate] = useState<TemplateDto | null>(null);
  const [saveOutcome, setSaveOutcome] = useState<TemplateSaveOutcome | null>(null);
  const [pendingCandidates, setPendingCandidates] = useState<TemplateDto[]>([]);
  const [isSubmitting, setIsSubmitting] = useState<boolean>(false);
  const [errorFocusNonce, setErrorFocusNonce] = useState<number>(0);

  /** So sánh bản chụp form hiện tại với mốc gốc đã tải hoặc mới lưu thành công. */
  function computeIsDirty(): boolean {
    return view === 'editor' && serializeFormForDirtyCheck(editorForm) !== baselineKey;
  }

  const isDirty = useMemo(computeIsDirty, [view, editorForm, baselineKey]);

  /** Đặt lại toàn bộ state editor về bản nháp rỗng sạch. */
  function resetEditorSession(): void {
    const emptyForm = createEmptyTemplateForm();
    setEditorForm(emptyForm);
    setBaselineKey(serializeFormForDirtyCheck(emptyForm));
    setLastServerTemplate(null);
    setSaveOutcome(null);
    setPendingCandidates([]);
    setIsSubmitting(false);
  }

  /** Đưa DTO nhận được vào trình chỉnh sửa và đặt lại mốc dirty baseline. */
  function applyTemplateToEditor(dto: TemplateDto): void {
    const nextForm = templateDtoToForm(dto);
    setEditorForm(nextForm);
    setBaselineKey(serializeFormForDirtyCheck(nextForm));
    setLastServerTemplate(dto);
    setPendingCandidates([]);
    setSaveOutcome(null);
    setView('editor');
  }

  /** Gửi tạo hoặc cập nhật bản nháp qua mock API; loại bỏ mọi callback trễ nếu workspace đã đổi. */
  async function submitDraft(overrideScenario?: PreviewScenario): Promise<void> {
    if (isSubmitting) return;
    const generation = contextGenerationRef.current;
    const requestWorkspaceId = workspaceId;
    const activeScenario = overrideScenario ?? scenarioRef.current;

    activeAbortRef.current?.abort();
    const controller = new AbortController();
    activeAbortRef.current = controller;
    setIsSubmitting(true);

    try {
      const outcome = editorForm.id
        ? await store.updateDraft(
          requestWorkspaceId,
          editorForm.id,
          editorForm.revision,
          editorForm,
          activeScenario,
          controller.signal,
        )
        : await store.createDraft(requestWorkspaceId, editorForm, activeScenario, controller.signal);

      if (generation !== contextGenerationRef.current || controller.signal.aborted) return;
      setSaveOutcome(outcome);

      if (outcome.ok) {
        const syncedForm = templateDtoToForm(outcome.template);
        setEditorForm(syncedForm);
        setBaselineKey(serializeFormForDirtyCheck(syncedForm));
        setLastServerTemplate(outcome.template);
        setPendingCandidates([]);
        return;
      }

      if (outcome.kind === 'permission' || outcome.kind === 'not_found') {
        // Không giữ lại snapshot server khi tài nguyên mất quyền hoặc trả về 404 ngoài phạm vi.
        setLastServerTemplate(null);
        setPendingCandidates([]);
      } else if (outcome.kind === 'validation') {
        setErrorFocusNonce(incrementCounter);
      } else if (outcome.kind === 'unknown_outcome') {
        // Không tự POST lại; tải danh sách draft theo scope workspace để người dùng chọn ứng viên thủ công.
        const listResult = await store.listTemplates(requestWorkspaceId, 'normal', null, controller.signal);
        if (generation !== contextGenerationRef.current || controller.signal.aborted) return;
        if (listResult.ok) {
          setPendingCandidates(filterDraftCandidates(listResult.items));
        }
      }
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') return;
      if (generation !== contextGenerationRef.current) return;
      setSaveOutcome({
        ok: false,
        kind: 'network',
        status: 0,
        code: 'NETWORK_ERROR',
        message: 'Mất kết nối trong lúc gửi. Dữ liệu cục bộ vẫn được giữ lại.',
      });
    } finally {
      if (generation === contextGenerationRef.current && !controller.signal.aborted) {
        setIsSubmitting(false);
      }
    }
  }

  /** Áp dụng kết quả đối chiếu sau xung đột 412 (tải theo server hoặc giữ nháp cục bộ để reapply). */
  function handleApplyServerRevision(serverTemplate: TemplateDto, keepLocalChanges: boolean): void {
    if (!keepLocalChanges) {
      applyTemplateToEditor(serverTemplate);
      return;
    }
    setEditorForm({
      ...editorForm,
      revision: serverTemplate.revision,
      updatedAt: serverTemplate.updatedAt,
    });
    setLastServerTemplate(serverTemplate);
    setSaveOutcome(null);
    if (scenario === 'stale_412') {
      setScenario('normal');
    }
  }

  return {
    editorForm,
    setEditorForm,
    lastServerTemplate,
    saveOutcome,
    pendingCandidates,
    isDirty,
    isSubmitting,
    errorFocusNonce,
    resetEditorSession,
    applyTemplateToEditor,
    submitDraft,
    handleApplyServerRevision,
  };
}

/**
 * Hook điều phối chuyển màn hình, đổi workspace an toàn theo dirty guard và quản lý tiêu điểm chuyển cảnh.
 * Input
 * Param: headingRef — tham chiếu tiêu đề h1 để đặt focus sau khi điều hướng giữa danh sách/editor hoặc đổi workspace.
 * Output: tập trạng thái và handler hợp nhất cho `TemplatesPage`.
 */
function useTemplatesPreviewController(headingRef: RefObject<HTMLHeadingElement | null>) {
  const storeRef = useRef<TemplatePreviewStore | null>(null);
  if (!storeRef.current) {
    storeRef.current = createInMemoryTemplateStore();
  }
  const store = storeRef.current;

  const [workspaceId, setWorkspaceId] = useState<string>(PREVIEW_WORKSPACES[0].id);
  const [scenario, setScenario] = useState<PreviewScenario>('normal');
  const [view, setView] = useState<'list' | 'editor'>('list');
  const [pendingGuardAction, setPendingGuardAction] = useState<PendingGuardAction>(null);

  const contextGenerationRef = useRef<number>(0);
  const activeAbortRef = useRef<AbortController | null>(null);
  const prevLocationRef = useRef<{ view: 'list' | 'editor'; workspaceId: string }>({ view, workspaceId });
  // Giữ kịch bản mới nhất trong ref để effect tải danh sách chỉ chạy lại khi đổi workspace hoặc bấm tải lại.
  const scenarioRef = useRef<PreviewScenario>(scenario);
  scenarioRef.current = scenario;

  /** Tra cứu metadata workspace tổng hợp hiện đang chọn. */
  function resolveSelectedWorkspace(): WorkspaceFixture {
    return findWorkspaceFixture(workspaceId);
  }

  const selectedWorkspace = useMemo(resolveSelectedWorkspace, [workspaceId]);

  const listSession = useWorkspaceTemplateList(
    store,
    workspaceId,
    scenarioRef,
    contextGenerationRef,
    activeAbortRef,
  );
  const draftSession = useTemplateDraftSession(
    store,
    workspaceId,
    scenario,
    setScenario,
    view,
    setView,
    scenarioRef,
    contextGenerationRef,
    activeAbortRef,
  );

  /** Chỉ chuyển focus tới tiêu đề màn mới sau các thao tác điều hướng, giữ nguyên thứ tự Tab lúc tải trang kể cả dưới StrictMode. */
  function focusHeadingOnTransitionEffect(): void {
    if (prevLocationRef.current.view === view && prevLocationRef.current.workspaceId === workspaceId) {
      return;
    }
    prevLocationRef.current = { view, workspaceId };
    headingRef.current?.focus();
  }

  useEffect(focusHeadingOnTransitionEffect, [headingRef, view, workspaceId]);

  /** Hủy request cũ, xóa toàn bộ state workspace cũ ngay lập tức và tăng generation để đổi workspace an toàn. */
  function executeWorkspaceSwitch(nextWorkspaceId: string): void {
    activeAbortRef.current?.abort();
    contextGenerationRef.current += 1;
    listSession.clearListState();
    draftSession.resetEditorSession();
    setView('list');
    setPendingGuardAction(null);
    setWorkspaceId(nextWorkspaceId);
  }

  /** Kiểm tra dirty guard trước khi chuyển workspace mới để không làm mất bản nháp chưa lưu. */
  function handleRequestWorkspaceSwitch(nextWorkspaceId: string): void {
    if (nextWorkspaceId === workspaceId) return;
    if (draftSession.isDirty) {
      setPendingGuardAction({ type: 'switch_workspace', workspaceId: nextWorkspaceId });
      return;
    }
    executeWorkspaceSwitch(nextWorkspaceId);
  }

  /** Chuyển về danh sách template nếu không có thay đổi dở dang; ngược lại mở dialog xác nhận. */
  function handleRequestBackToList(): void {
    if (draftSession.isDirty) {
      setPendingGuardAction({ type: 'back_to_list' });
      return;
    }
    draftSession.resetEditorSession();
    setView('list');
    listSession.triggerReloadList();
  }

  /** Đóng hộp thoại xác nhận và giữ người dùng ở lại trình chỉnh sửa. */
  function handleStayOnEditor(): void {
    setPendingGuardAction(null);
  }

  /** Xác nhận bỏ thay đổi chưa lưu để hoàn tất điều hướng hoặc chuyển workspace. */
  function handleConfirmDiscard(): void {
    const action = pendingGuardAction;
    setPendingGuardAction(null);
    if (!action) return;
    if (action.type === 'switch_workspace') {
      executeWorkspaceSwitch(action.workspaceId);
      return;
    }
    draftSession.resetEditorSession();
    setView('list');
    listSession.triggerReloadList();
  }

  /** Mở trình chỉnh sửa ở chế độ tạo bản nháp DRAFT mới cho ADMIN. */
  function handleCreateNew(): void {
    if (selectedWorkspace.role !== 'ADMIN') return;
    draftSession.resetEditorSession();
    setView('editor');
  }

  /** Tải chi tiết một template từ kho mô phỏng theo đúng scope workspace và generation hiện tại. */
  async function handleOpenTemplate(templateId: string): Promise<void> {
    const generation = contextGenerationRef.current;
    activeAbortRef.current?.abort();
    const controller = new AbortController();
    activeAbortRef.current = controller;
    listSession.setIsLoadingList(true);

    try {
      const outcome = await store.getTemplate(workspaceId, templateId, scenarioRef.current, controller.signal);
      if (generation !== contextGenerationRef.current || controller.signal.aborted) return;
      if (outcome.ok) {
        draftSession.applyTemplateToEditor(outcome.template);
      } else {
        listSession.setListError({
          kind: outcome.kind === 'network' ? 'network' : 'permission',
          status: outcome.status,
          message: outcome.message,
        });
      }
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') return;
      if (generation !== contextGenerationRef.current) return;
      listSession.setListError({ kind: 'network', status: 0, message: 'Không thể mở chi tiết template.' });
    } finally {
      if (generation === contextGenerationRef.current && !controller.signal.aborted) {
        listSession.setIsLoadingList(false);
      }
    }
  }

  /** Chạy thao tác lưu chuẩn từ nút submit của TemplateEditor. */
  function handleEditorSubmit(): void {
    void draftSession.submitDraft();
  }

  /** Chủ động tạo bản nháp mới sau khi người dùng đã xem qua danh sách ứng viên ở nhánh unknown. */
  function handleCreateNewAfterUnknown(): void {
    void draftSession.submitDraft('normal');
  }

  return {
    workspaceId,
    selectedWorkspace,
    scenario,
    setScenario,
    view,
    pendingGuardAction,
    ...listSession,
    ...draftSession,
    handleRequestWorkspaceSwitch,
    handleRequestBackToList,
    handleStayOnEditor,
    handleConfirmDiscard,
    handleCreateNew,
    handleOpenTemplate,
    handleEditorSubmit,
    handleCreateNewAfterUnknown,
  };
}

/**
 * Trang preview phát triển WB-03 Templates: kết hợp shell Nexa, banner preview không lưu server,
 * breadcrumb workspace, danh sách template và trình chỉnh sửa/xem trước hai cột.
 * Output: cây giao diện đầy đủ của route `/dev/templates-preview`.
 */
export function TemplatesPage() {
  const [darkTheme, setDarkTheme] = useState<boolean>(getInitialDarkTheme);
  const headingRef = useRef<HTMLHeadingElement | null>(null);
  const controller = useTemplatesPreviewController(headingRef);

  /** Đồng bộ thuộc tính `data-theme` trên root element trong tab hiện tại; không ghi xuống storage. */
  function syncDocumentThemeEffect(): void {
    document.documentElement.dataset.theme = darkTheme ? 'dark' : 'light';
  }

  useEffect(syncDocumentThemeEffect, [darkTheme]);

  /** Đổi giao diện sáng/tối chỉ trong bộ nhớ phiên hiện hành. */
  function handleToggleTheme(): void {
    /** Đảo từ trạng thái hiện hành để tránh phụ thuộc giá trị render cũ. */
    function invertTheme(prev: boolean): boolean {
      return !prev;
    }
    setDarkTheme(invertTheme);
  }

  return (
    <div className="tpl-page">
      <IconSprite />
      <a className="tpl-skip-link" href="#templates-main">Chuyển đến nội dung chính</a>

      <header className="tpl-header">
        <div className="tpl-header-inner">
          <BrandLink href="/" />
          <div className="tpl-header-actions">
            <span className="tpl-dev-pill">
              <TemplateIcon name="cpu" />
              <span>DEV PREVIEW · WB-03</span>
            </span>
            <button
              type="button"
              className="tpl-theme-btn"
              aria-label={darkTheme ? 'Chuyển sang giao diện sáng' : 'Chuyển sang giao diện tối'}
              title={darkTheme ? 'Giao diện sáng' : 'Giao diện tối'}
              onClick={handleToggleTheme}
            >
              <TemplateIcon name={darkTheme ? 'sun' : 'moon'} />
            </button>
          </div>
        </div>
      </header>

      <main id="templates-main" className="tpl-shell" tabIndex={-1}>
        <PreviewBanner
          workspaces={PREVIEW_WORKSPACES}
          selectedWorkspaceId={controller.workspaceId}
          scenario={controller.scenario}
          onSelectWorkspace={controller.handleRequestWorkspaceSwitch}
          onSelectScenario={controller.setScenario}
        />

        <nav className="tpl-breadcrumb" aria-label="Đường dẫn điều hướng">
          <span>Workspace: {controller.selectedWorkspace.name}</span>
          <span aria-hidden="true">/</span>
          {controller.view === 'list' ? (
            <span aria-current="page">Templates</span>
          ) : (
            <>
              <button type="button" className="tpl-breadcrumb-btn" onClick={controller.handleRequestBackToList}>
                Templates
              </button>
              <span aria-hidden="true">/</span>
              <span aria-current="page">
                {controller.editorForm.id
                  ? (controller.editorForm.name.trim() || controller.editorForm.id)
                  : 'Tạo template mới'}
              </span>
            </>
          )}
        </nav>

        {controller.view === 'list' ? (
          <TemplateList
            workspace={controller.selectedWorkspace}
            templates={controller.templates}
            nextCursor={controller.nextCursor}
            isLoading={controller.isLoadingList}
            isLoadingMore={controller.isLoadingMore}
            listError={controller.listError}
            headingRef={headingRef}
            onCreateNew={controller.handleCreateNew}
            onOpenTemplate={controller.handleOpenTemplate}
            onLoadMore={controller.handleLoadMore}
            onReload={controller.triggerReloadList}
          />
        ) : (
          <TemplateEditor
            workspaceId={controller.workspaceId}
            workspaceName={controller.selectedWorkspace.name}
            form={controller.editorForm}
            lastServerTemplate={controller.lastServerTemplate}
            saveOutcome={controller.saveOutcome}
            pendingCandidates={controller.pendingCandidates}
            isDirty={controller.isDirty}
            isSubmitting={controller.isSubmitting}
            errorFocusNonce={controller.errorFocusNonce}
            headingRef={headingRef}
            onChangeForm={controller.setEditorForm}
            onSubmit={controller.handleEditorSubmit}
            onBackToList={controller.handleRequestBackToList}
            onApplyServerRevision={controller.handleApplyServerRevision}
            onSelectCandidate={controller.applyTemplateToEditor}
            onCreateNewAfterUnknown={controller.handleCreateNewAfterUnknown}
          />
        )}
      </main>

      <footer className="tpl-footer">
        <span translate="no">Nexa IoT · WB-03 Development Preview</span>
        <span>Chỉ dùng dữ liệu mô phỏng trong bộ nhớ tab; không thay thế nghiệm thu API G1.</span>
      </footer>

      <DirtyConfirmDialog
        pendingAction={controller.pendingGuardAction}
        onStay={controller.handleStayOnEditor}
        onDiscard={controller.handleConfirmDiscard}
      />
    </div>
  );
}
