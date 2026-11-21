import {
  useEffect,
  useMemo,
  useRef,
  type ChangeEvent,
  type FormEvent,
  type MouseEvent,
  type RefObject,
} from 'react';
import {
  buildPreviewJsonPayload,
  createEmptyCommandDraft,
  createEmptyStreamDraft,
  fieldPathToElementId,
  MAX_COMMANDS_PER_TEMPLATE,
  MAX_STREAMS_PER_TEMPLATE,
  SYNTHETIC_MODEL_SUGGESTIONS,
  UNRESOLVED_WIRE_ASSUMPTIONS,
  type ChannelKind,
  type DatastreamType,
  type FieldErrorItem,
  type StreamDirection,
  type TemplateCommandDraft,
  type TemplateDraftForm,
  type TemplateDto,
  type TemplateSaveOutcome,
  type TemplateStreamDraft,
} from './templateMockApi';

interface TemplateEditorProps {
  workspaceId: string;
  workspaceName: string;
  form: TemplateDraftForm;
  lastServerTemplate: TemplateDto | null;
  saveOutcome: TemplateSaveOutcome | null;
  pendingCandidates: TemplateDto[];
  isDirty: boolean;
  isSubmitting: boolean;
  errorFocusNonce: number;
  headingRef: RefObject<HTMLHeadingElement | null>;
  onChangeForm: (nextForm: TemplateDraftForm) => void;
  onSubmit: () => void;
  onBackToList: () => void;
  onApplyServerRevision: (serverTemplate: TemplateDto, keepLocalChanges: boolean) => void;
  onSelectCandidate: (candidate: TemplateDto) => void;
  onCreateNewAfterUnknown: () => void;
}

const MAX_ENUM_VALUES_PER_STREAM = 64;

const STREAM_TYPE_LABELS: Record<DatastreamType, string> = {
  NUMBER: 'NUMBER — Số hữu hạn',
  BOOLEAN: 'BOOLEAN — Đúng / Sai',
  STRING: 'STRING — Chuỗi chỉ hiển thị',
  ENUM: 'ENUM — Tập giá trị cố định',
};

const CHANNEL_KIND_LABELS: Record<ChannelKind, string> = {
  TELEMETRY: 'TELEMETRY — Dữ liệu đo lường',
  STATE: 'STATE — Trạng thái kênh',
};

const DIRECTION_LABELS: Record<StreamDirection, string> = {
  READ: 'READ — Chỉ đọc',
  WRITE: 'WRITE — Chỉ ghi lệnh',
  READ_WRITE: 'READ_WRITE — Đọc và ghi lệnh',
};

/**
 * Tạo phần tử option cho danh sách gợi ý mã model tổng hợp.
 * Input
 * Param: suggestion — mã model mẫu chờ chốt PoC T1.
 * Output: phần tử `<option>` cho datalist model.
 */
function renderModelSuggestionOption(suggestion: string) {
  return <option key={suggestion} value={suggestion} />;
}

/**
 * Tạo phần tử option cho selector kiểu dữ liệu datastream.
 * Input
 * Param: typeOption — mã kiểu dữ liệu chuẩn theo WF-TN-005.
 * Output: phần tử `<option>` kèm nhãn tiếng Việt.
 */
function renderStreamTypeOption(typeOption: DatastreamType) {
  return <option key={typeOption} value={typeOption}>{STREAM_TYPE_LABELS[typeOption]}</option>;
}

/**
 * Tạo phần tử option cho selector `channelKind` tách biệt hoàn toàn với hướng đọc/ghi.
 * Input
 * Param: kindOption — giá trị phân loại kênh `TELEMETRY` hoặc `STATE`.
 * Output: phần tử `<option>` kèm mô tả tiếng Việt.
 */
function renderChannelKindOption(kindOption: ChannelKind) {
  return <option key={kindOption} value={kindOption}>{CHANNEL_KIND_LABELS[kindOption]}</option>;
}

/**
 * Tạo phần tử option cho selector `direction` tách biệt với `channelKind` theo ADR-004.
 * Input
 * Param: dirOption — giá trị hướng truy cập `READ`, `WRITE` hoặc `READ_WRITE`.
 * Output: phần tử `<option>` kèm mô tả tiếng Việt.
 */
function renderDirectionOption(dirOption: StreamDirection) {
  return <option key={dirOption} value={dirOption}>{DIRECTION_LABELS[dirOption]}</option>;
}

/**
 * Kết xuất một dòng ghi chú giả định hợp đồng G1 đang được cô lập trong mock adapter.
 * Input
 * Param: note — nội dung điểm chưa chốt ở G1.
 * Param: index — chỉ số thứ tự làm React key ổn định cho mảng hằng số.
 * Output: phần tử `<li>` mô tả giả định G1.
 */
function renderWireAssumptionItem(note: string, index: number) {
  return <li key={index}>{note}</li>;
}

/**
 * Tạo option cho select stream đích của capability SET_VALUE, đánh dấu rõ kênh READ/STRING bị cấm điều khiển.
 * Input
 * Param: streamOption — dữ liệu kênh hiện có trong danh sách.
 * Output: phần tử `<option>` hoặc null nếu kênh chưa nhập key.
 */
function renderTargetStreamOption(streamOption: TemplateStreamDraft) {
  const optionKey = streamOption.key.trim();
  if (!optionKey) return null;
  const suffix = streamOption.direction === 'READ' || streamOption.type === 'STRING'
    ? ' — chỉ đọc (422 nếu gắn lệnh)'
    : '';
  return (
    <option key={streamOption.localId} value={optionKey}>
      {optionKey} ({streamOption.type} · {streamOption.direction}{suffix})
    </option>
  );
}

/**
 * Vẽ icon SVG nét từ sprite dùng chung, luôn ẩn khỏi trình đọc màn hình vì chỉ minh họa cạnh nhãn.
 * Input
 * Param: name — tên symbol trong IconSprite.
 * Output: phần tử SVG kích thước chuẩn 18px.
 */
function EditorIcon({ name }: { name: string }) {
  return (
    <svg className="tpl-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <use href={`#i-${name}`} />
    </svg>
  );
}

/**
 * Phần đầu trang chỉnh sửa template: hiển thị trạng thái DRAFT/PUBLISHED, revision, schema version và nút quay lại.
 * Input
 * Param: form — dữ liệu bản nháp hoặc bản đã công bố đang mở.
 * Param: workspaceName — tên workspace tổng hợp hiện hành.
 * Param: isPublished — cờ đánh dấu chế độ xem chỉ đọc PUBLISHED.
 * Param: isSubmitting — khóa nút quay lại trong lúc gửi yêu cầu mô phỏng.
 * Param: headingRef — ref tiêu đề h1 để nhận tiêu điểm khi điều hướng từ danh sách.
 * Param: onBackToList — quay lại danh sách (qua dirty guard nếu có thay đổi chưa lưu).
 * Output: thẻ header của trình chỉnh sửa WB-03.
 */
function EditorHeaderCard({
  form,
  workspaceName,
  isPublished,
  isSubmitting,
  headingRef,
  onBackToList,
}: {
  form: TemplateDraftForm;
  workspaceName: string;
  isPublished: boolean;
  isSubmitting: boolean;
  headingRef: RefObject<HTMLHeadingElement | null>;
  onBackToList: () => void;
}) {
  return (
    <div className="tpl-card tpl-editor-head">
      <div className="tpl-page-head tpl-page-head-flush">
        <div>
          <div className="tpl-badge-row">
            <span className={`tpl-badge ${isPublished ? 'tpl-badge-published' : 'tpl-badge-draft'}`}>
              <EditorIcon name={isPublished ? 'lock' : 'layers'} />
              <span>{isPublished ? `PUBLISHED · v${form.publishedVersion ?? 1}` : 'DRAFT'}</span>
            </span>
            <span className="tpl-badge">
              {form.revision !== null ? `Revision #${form.revision}` : 'Chưa tạo trên server'}
            </span>
            <span className="tpl-badge">Schema v{form.schemaVersion}</span>
          </div>
          <h1 ref={headingRef} tabIndex={-1}>
            {form.id ? (form.name.trim() || 'Template không tên') : 'Tạo bản nháp template mới'}
          </h1>
          <p className="tpl-lead">
            Workspace: <strong>{workspaceName}</strong> · Mã model:{' '}
            <span className="tpl-mono">{form.model.trim() || '(chưa khai báo)'}</span>
          </p>
        </div>
        <div className="tpl-actions-row">
          <button type="button" className="tpl-btn" disabled={isSubmitting} onClick={onBackToList}>
            Quay lại danh sách
          </button>
        </div>
      </div>
    </div>
  );
}

/**
 * Hiển thị hộp đối chiếu 412 VERSION_CONFLICT giữa bản máy chủ mới hơn và bản nháp cục bộ được giữ nguyên.
 * Input
 * Param: message — thông điệp lỗi 412 từ mock API.
 * Param: serverTemplate — DTO revision mới nhất trên máy chủ.
 * Param: form — bản nháp cục bộ hiện đang nhập của người dùng.
 * Param: isSubmitting — khóa thao tác khi đang gửi yêu cầu khác.
 * Param: onApplyServerRevision — áp dụng bản máy chủ hoặc giữ thay đổi cục bộ lên revision mới.
 * Output: khối cảnh báo xung đột phiên bản kèm hai lựa chọn rõ ràng.
 */
function Conflict412Notice({
  message,
  serverTemplate,
  form,
  isSubmitting,
  onApplyServerRevision,
}: {
  message: string;
  serverTemplate: TemplateDto;
  form: TemplateDraftForm;
  isSubmitting: boolean;
  onApplyServerRevision: (serverTemplate: TemplateDto, keepLocalChanges: boolean) => void;
}) {
  /** Nạp nguyên bản máy chủ và bỏ các sửa đổi cục bộ. */
  function handleLoadServerVersion(): void {
    onApplyServerRevision(serverTemplate, false);
  }

  /** Giữ thay đổi cục bộ và nâng revision cơ sở lên revision của máy chủ để người dùng tự gửi lại. */
  function handleKeepLocalAndReapply(): void {
    onApplyServerRevision(serverTemplate, true);
  }

  return (
    <div className="tpl-notice tpl-notice-error" role="alert">
      <EditorIcon name="help" />
      <div className="tpl-notice-body">
        <p><strong>{message}</strong></p>
        <div className="tpl-conflict-compare">
          <div className="tpl-conflict-box">
            <strong>Bản hiện hành trên máy chủ (mô phỏng)</strong>
            <span>Tên: {serverTemplate.name}</span>
            <span>Model: <span className="tpl-mono">{serverTemplate.model}</span></span>
            <span>Revision: #{serverTemplate.revision} · {serverTemplate.streams.length} kênh</span>
          </div>
          <div className="tpl-conflict-box">
            <strong>Bản nháp cục bộ của bạn (được giữ lại)</strong>
            <span>Tên: {form.name || '(trống)'}</span>
            <span>Model: <span className="tpl-mono">{form.model || '(trống)'}</span></span>
            <span>Cơ sở revision: #{form.revision ?? '-'} · {form.streams.length} kênh</span>
          </div>
        </div>
        <div className="tpl-actions-row">
          <button type="button" className="tpl-btn" disabled={isSubmitting} onClick={handleLoadServerVersion}>
            Tải bản máy chủ (bỏ thay đổi cục bộ)
          </button>
          <button type="button" className="tpl-btn tpl-btn-primary" disabled={isSubmitting} onClick={handleKeepLocalAndReapply}>
            Giữ bản cục bộ để áp dụng lại lên revision #{serverTemplate.revision}
          </button>
        </div>
      </div>
    </div>
  );
}

/**
 * Hiển thị danh sách draft ứng viên trong workspace khi POST tạo mới không nhận được phản hồi xác nhận.
 * Input
 * Param: message — thông điệp giải thích không tự động gửi lại POST.
 * Param: pendingCandidates — danh sách draft trong phạm vi workspace hiện hành.
 * Param: isSubmitting — khóa nút khi đang xử lý yêu cầu khác.
 * Param: onSelectCandidate — mở một bản nháp ứng viên theo đúng ID do người dùng chọn.
 * Param: onCreateNewAfterUnknown — người dùng chủ động tạo bản nháp mới sau khi đã đối chiếu danh sách.
 * Output: khối cảnh báo ứng viên yêu cầu lựa chọn thủ công.
 */
function UnknownPostCandidatesNotice({
  message,
  pendingCandidates,
  isSubmitting,
  onSelectCandidate,
  onCreateNewAfterUnknown,
}: {
  message: string;
  pendingCandidates: TemplateDto[];
  isSubmitting: boolean;
  onSelectCandidate: (candidate: TemplateDto) => void;
  onCreateNewAfterUnknown: () => void;
}) {
  /** Mở đúng draft ứng viên được chọn theo ID, không tự đoán theo tên trùng. */
  function handlePickCandidateClick(event: MouseEvent<HTMLButtonElement>): void {
    const candidateId = event.currentTarget.dataset.candidateId;
    /** Đối chiếu chính xác ID của draft được bấm trong danh sách ứng viên. */
    function isSelectedCandidate(item: TemplateDto): boolean {
      return item.id === candidateId;
    }
    const found = pendingCandidates.find(isSelectedCandidate);
    if (found) onSelectCandidate(found);
  }

  /** Hiển thị từng dòng ứng viên kèm ID và revision để phân biệt các draft trùng tên. */
  function renderCandidateRow(candidate: TemplateDto) {
    return (
      <li key={candidate.id} className="tpl-candidate-item">
        <div>
          <strong>{candidate.name}</strong>
          <p className="tpl-hint">
            ID: <span className="tpl-mono">{candidate.id}</span> · Model: <span className="tpl-mono">{candidate.model}</span> · Revision #{candidate.revision}
          </p>
        </div>
        <button
          type="button"
          className="tpl-btn"
          data-candidate-id={candidate.id}
          onClick={handlePickCandidateClick}
        >
          Mở bản nháp này
        </button>
      </li>
    );
  }

  return (
    <div className="tpl-notice tpl-notice-warning" role="alert">
      <EditorIcon name="clock" />
      <div className="tpl-notice-body">
        <p><strong>{message}</strong></p>
        {pendingCandidates.length > 0 ? (
          <ul className="tpl-candidate-list">
            {pendingCandidates.map(renderCandidateRow)}
          </ul>
        ) : (
          <p className="tpl-hint">Chưa thấy bản nháp ứng viên nào trong workspace hiện hành.</p>
        )}
        <div className="tpl-actions-row">
          <button type="button" className="tpl-btn" disabled={isSubmitting} onClick={onCreateNewAfterUnknown}>
            Chủ động tạo bản nháp mới khác
          </button>
        </div>
      </div>
    </div>
  );
}

/**
 * Hiển thị trạng thái lưu preview, lỗi ngoại tuyến, schema bất biến 409 hoặc ủy quyền tới notice 412/unknown.
 * Input
 * Param: saveOutcome — kết quả từ mock API ở lần thao tác gần nhất.
 * Param: isPublished — cờ đánh dấu template đang xem ở trạng thái đã công bố chỉ đọc.
 * Param: isDirty — cờ cho biết biểu mẫu đang có chỉnh sửa chưa áp dụng vào preview.
 * Param: isSubmitting — khóa nút thao tác lặp khi request mô phỏng đang chạy.
 * Param: form — dữ liệu biểu mẫu cục bộ dùng đối chiếu khi gặp 412.
 * Param: pendingCandidates — danh sách draft ứng viên trong workspace hiện hành.
 * Param: onApplyServerRevision — xử lý chọn bản máy chủ hoặc giữ thay đổi cục bộ để reapply.
 * Param: onSelectCandidate — mở một bản nháp ứng viên từ danh sách tra cứu.
 * Param: onRetryManualSave — gửi lại thủ công sau lỗi mạng ngoại tuyến.
 * Param: onSimulatePublishedPatch — mô phỏng thử sửa bản PUBLISHED để quan sát phản hồi 409.
 * Param: onCreateNewAfterUnknown — người dùng chủ động xác nhận tạo bản nháp mới sau unknown.
 * Output: khối thông báo phù hợp hoặc null nếu chưa có trạng thái cần báo.
 */
function SaveStateNotice({
  saveOutcome,
  isPublished,
  isDirty,
  isSubmitting,
  form,
  pendingCandidates,
  onApplyServerRevision,
  onSelectCandidate,
  onRetryManualSave,
  onSimulatePublishedPatch,
  onCreateNewAfterUnknown,
}: {
  saveOutcome: TemplateSaveOutcome | null;
  isPublished: boolean;
  isDirty: boolean;
  isSubmitting: boolean;
  form: TemplateDraftForm;
  pendingCandidates: TemplateDto[];
  onApplyServerRevision: (serverTemplate: TemplateDto, keepLocalChanges: boolean) => void;
  onSelectCandidate: (candidate: TemplateDto) => void;
  onRetryManualSave: () => void;
  onSimulatePublishedPatch: () => void;
  onCreateNewAfterUnknown: () => void;
}) {
  if (saveOutcome?.ok) {
    return (
      <div className="tpl-notice tpl-notice-success" role="status">
        <EditorIcon name="check" />
        <div className="tpl-notice-body">
          <p>
            <strong>Đã cập nhật bản xem trước trong bộ nhớ tab (chưa lưu trên máy chủ).</strong>{' '}
            ID: <span className="tpl-mono">{saveOutcome.template.id}</span> · Revision #{saveOutcome.template.revision} · Schema v{saveOutcome.template.schemaVersion}.
          </p>
        </div>
      </div>
    );
  }

  if (saveOutcome && !saveOutcome.ok && saveOutcome.kind === 'conflict_412') {
    return (
      <Conflict412Notice
        message={saveOutcome.message}
        serverTemplate={saveOutcome.serverTemplate}
        form={form}
        isSubmitting={isSubmitting}
        onApplyServerRevision={onApplyServerRevision}
      />
    );
  }

  if (saveOutcome && !saveOutcome.ok && saveOutcome.kind === 'unknown_outcome') {
    return (
      <UnknownPostCandidatesNotice
        message={saveOutcome.message}
        pendingCandidates={pendingCandidates}
        isSubmitting={isSubmitting}
        onSelectCandidate={onSelectCandidate}
        onCreateNewAfterUnknown={onCreateNewAfterUnknown}
      />
    );
  }

  if (saveOutcome && !saveOutcome.ok && saveOutcome.kind === 'network') {
    return (
      <div className="tpl-notice tpl-notice-error" role="alert">
        <EditorIcon name="radio" />
        <div className="tpl-notice-body">
          <p><strong>{saveOutcome.message}</strong></p>
          <div className="tpl-actions-row">
            <button type="button" className="tpl-btn" disabled={isSubmitting} onClick={onRetryManualSave}>
              Thử gửi lại thủ công
            </button>
          </div>
        </div>
      </div>
    );
  }

  if (saveOutcome && !saveOutcome.ok && saveOutcome.kind === 'immutable_409') {
    return (
      <div className="tpl-notice tpl-notice-warning" role="alert">
        <EditorIcon name="lock" />
        <div className="tpl-notice-body">
          <p><strong>{saveOutcome.message}</strong></p>
        </div>
      </div>
    );
  }

  if (
    saveOutcome
    && !saveOutcome.ok
    && (saveOutcome.kind !== 'validation' || saveOutcome.fieldErrors.length === 0)
  ) {
    return (
      <div className="tpl-notice tpl-notice-error" role="alert">
        <EditorIcon name="help" />
        <div className="tpl-notice-body">
          <p><strong>{saveOutcome.message}</strong></p>
        </div>
      </div>
    );
  }

  if (isPublished) {
    return (
      <div className="tpl-notice tpl-notice-warning" role="status">
        <EditorIcon name="lock" />
        <div className="tpl-notice-body">
          <p>
            <strong>Template đã công bố (PUBLISHED · v{form.publishedVersion ?? 1}) ở chế độ chỉ đọc.</strong>{' '}
            Schema đã pin là bất biến; để chỉnh sửa cần tạo draft mới qua luồng FEAT-TN-006 khi route sẵn sàng.
          </p>
          <div className="tpl-actions-row">
            <button type="button" className="tpl-btn" disabled={isSubmitting} onClick={onSimulatePublishedPatch}>
              Mô phỏng gửi PATCH để kiểm tra lỗi 409
            </button>
          </div>
        </div>
      </div>
    );
  }

  if (isDirty) {
    return (
      <div className="tpl-notice" role="status">
        <EditorIcon name="clock" />
        <div className="tpl-notice-body">
          <p>Bản nháp có thay đổi cục bộ chưa áp dụng vào bản xem trước.</p>
        </div>
      </div>
    );
  }

  return null;
}

/**
 * Hiển thị hộp tóm tắt lỗi có thể nhận focus sau khi submit thất bại, liên kết trực tiếp tới từng control lỗi.
 * Input
 * Param: errors — danh sách lỗi trường kèm path JSON Pointer.
 * Param: summaryRef — tham chiếu DOM để tự đưa focus vào vùng tóm tắt khi lỗi phát sinh.
 * Output: hộp `role="alert"` liệt kê lỗi hoặc null nếu không có lỗi trường.
 */
function FieldErrorSummary({
  errors,
  summaryRef,
}: {
  errors: FieldErrorItem[];
  summaryRef: RefObject<HTMLDivElement | null>;
}) {
  /** Di chuyển tiêu điểm bàn phím thẳng tới control tương ứng thay vì chỉ cuộn neo URL. */
  function handleFocusTarget(event: MouseEvent<HTMLAnchorElement>): void {
    event.preventDefault();
    const targetId = event.currentTarget.dataset.targetId;
    if (!targetId) return;
    const element = document.getElementById(targetId);
    if (element) {
      element.focus();
      element.scrollIntoView({ block: 'center' });
    }
  }

  /** Liên kết từng mục lỗi theo path JSON Pointer tới đúng ô nhập liệu hoặc nút thêm tương ứng. */
  function renderErrorItem(item: FieldErrorItem, index: number) {
    const targetId = fieldPathToElementId(item.path);
    return (
      <li key={`${item.path}-${item.code}-${index}`}>
        <a href={`#${targetId}`} data-target-id={targetId} onClick={handleFocusTarget}>
          <span className="tpl-mono">{item.path}</span>: {item.message}
        </a>
      </li>
    );
  }

  if (errors.length === 0) return null;

  return (
    <div id="tpl-error-summary" ref={summaryRef} tabIndex={-1} role="alert" className="tpl-error-summary">
      <div className="tpl-error-summary-head">
        <EditorIcon name="help" />
        <span>Không thể lưu: phát hiện {errors.length} lỗi cần sửa trong schema</span>
      </div>
      <ul>
        {errors.map(renderErrorItem)}
      </ul>
    </div>
  );
}

/**
 * Khối nhập thông tin cơ bản (tên template và mã model chuẩn) với nhãn hiển thị và liên kết lỗi trợ năng.
 * Input
 * Param: name — tên template đang chỉnh sửa.
 * Param: model — mã model chuẩn canonical.
 * Param: isReadOnly — khóa chỉnh sửa khi xem bản PUBLISHED.
 * Param: errorMap — bảng ánh xạ path lỗi sang thông báo tiếng Việt.
 * Param: onChangeName — cập nhật tên template.
 * Param: onChangeModel — cập nhật mã model chuẩn.
 * Output: khối biểu mẫu thông tin chung của template.
 */
function TemplateMetadataFields({
  name,
  model,
  isReadOnly,
  errorMap,
  onChangeName,
  onChangeModel,
}: {
  name: string;
  model: string;
  isReadOnly: boolean;
  errorMap: ReadonlyMap<string, string>;
  onChangeName: (value: string) => void;
  onChangeModel: (value: string) => void;
}) {
  const nameError = errorMap.get('/name');
  const modelError = errorMap.get('/model');

  /** Cập nhật tên template khi người dùng gõ. */
  function handleNameChange(event: ChangeEvent<HTMLInputElement>): void {
    onChangeName(event.target.value);
  }

  /** Cập nhật mã model chuẩn khi người dùng gõ hoặc chọn gợi ý mẫu. */
  function handleModelChange(event: ChangeEvent<HTMLInputElement>): void {
    onChangeModel(event.target.value);
  }

  return (
    <section className="tpl-card" aria-labelledby="tpl-meta-heading">
      <div className="tpl-section-head">
        <h2 id="tpl-meta-heading">1. Thông tin chung của template</h2>
      </div>
      <div className="tpl-form-grid">
        <div className="tpl-field">
          <label htmlFor="tpl-field-name">
            Tên template<span className="tpl-required-mark" aria-hidden="true">*</span>
          </label>
          <input
            id="tpl-field-name"
            name="name"
            autoComplete="off"
            className="tpl-input"
            type="text"
            value={name}
            readOnly={isReadOnly}
            aria-required="true"
            aria-invalid={Boolean(nameError)}
            aria-describedby={nameError ? 'tpl-field-name-hint tpl-field-name-error' : 'tpl-field-name-hint'}
            placeholder="Ví dụ: Cảm biến nhiệt độ và quạt phòng lab"
            onChange={handleNameChange}
          />
          <p id="tpl-field-name-hint" className="tpl-hint">1–100 ký tự (chuẩn hóa khoảng trắng hai đầu khi kiểm tra).</p>
          {nameError ? <p id="tpl-field-name-error" className="tpl-field-error">{nameError}</p> : null}
        </div>

        <div className="tpl-field">
          <label htmlFor="tpl-field-model">
            Mã model chuẩn (Canonical model ID)<span className="tpl-required-mark" aria-hidden="true">*</span>
          </label>
          <input
            id="tpl-field-model"
            name="model"
            autoComplete="off"
            className="tpl-input tpl-mono"
            type="text"
            list="tpl-model-suggestions"
            value={model}
            readOnly={isReadOnly}
            aria-required="true"
            aria-invalid={Boolean(modelError)}
            aria-describedby={modelError ? 'tpl-field-model-hint tpl-field-model-error' : 'tpl-field-model-hint'}
            placeholder="ESP32_DEMO_ENV_V1"
            onChange={handleModelChange}
          />
          <datalist id="tpl-model-suggestions">
            {SYNTHETIC_MODEL_SUGGESTIONS.map(renderModelSuggestionOption)}
          </datalist>
          <p id="tpl-field-model-hint" className="tpl-hint">
            1–64 ký tự chuẩn (chữ không dấu, số, ., -, _). Gợi ý hiện tại chỉ là dữ liệu mẫu chờ BOM/PoC T1.
          </p>
          {modelError ? <p id="tpl-field-model-error" className="tpl-field-error">{modelError}</p> : null}
        </div>
      </div>
    </section>
  );
}

/**
 * Khối nhập danh sách giá trị chuỗi cho kênh kiểu `ENUM` (giữ nguyên hoa thường và không tự trim).
 * Input
 * Param: streamIndex — chỉ số stream trong mảng để tạo ID gắn kết lỗi theo path.
 * Param: values — mảng giá trị enum hiện hành.
 * Param: isReadOnly — khóa thao tác thêm/sửa/xóa khi xem bản PUBLISHED.
 * Param: errorMap — bảng lỗi validation theo path JSON Pointer.
 * Param: onChangeValues — callback cập nhật mảng enumValues của stream.
 * Output: khối nhập từng giá trị enum kèm nút thêm/xóa và thông báo lỗi riêng.
 */
function StreamEnumValuesEditor({
  streamIndex,
  values,
  isReadOnly,
  errorMap,
  onChangeValues,
}: {
  streamIndex: number;
  values: string[];
  isReadOnly: boolean;
  errorMap: ReadonlyMap<string, string>;
  onChangeValues: (nextValues: string[]) => void;
}) {
  const groupError = errorMap.get(`/streams/${streamIndex}/enumValues`);
  const addButtonId = `tpl-stream-${streamIndex}-enumValues-add`;
  const groupLabelId = `tpl-stream-${streamIndex}-enumValues-label`;
  const groupErrorId = `${addButtonId}-error`;

  /** Thêm một mục enum mới để người dùng nhập giá trị chính xác. */
  function handleAddEnumValue(): void {
    onChangeValues([...values, '']);
  }

  /** Cập nhật đúng phần tử enum theo vị trí `data-enum-index`. */
  function handleEnumInputChange(event: ChangeEvent<HTMLInputElement>): void {
    const rawIdx = event.currentTarget.dataset.enumIndex;
    const enumIndex = rawIdx ? Number.parseInt(rawIdx, 10) : -1;
    if (enumIndex < 0 || enumIndex >= values.length) return;
    const next = [...values];
    next[enumIndex] = event.target.value;
    onChangeValues(next);
  }

  /** Xóa giá trị enum tại chỉ số `data-enum-index`. */
  function handleRemoveEnumValue(event: MouseEvent<HTMLButtonElement>): void {
    const rawIdx = event.currentTarget.dataset.enumIndex;
    const enumIndex = rawIdx ? Number.parseInt(rawIdx, 10) : -1;
    if (enumIndex < 0 || enumIndex >= values.length) return;
    /** Giữ lại mọi giá trị enum khác chỉ số cần xóa. */
    function keepOtherEnumItem(_value: string, idx: number): boolean {
      return idx !== enumIndex;
    }
    onChangeValues(values.filter(keepOtherEnumItem));
  }

  /** Render từng ô giá trị enum với label nhìn thấy được và ID gắn đúng `/streams/{i}/enumValues/{j}`. */
  function renderEnumRow(enumValue: string, enumIndex: number) {
    const itemPath = `/streams/${streamIndex}/enumValues/${enumIndex}`;
    const itemError = errorMap.get(itemPath);
    const inputId = `tpl-stream-${streamIndex}-enumValues-${enumIndex}`;
    return (
      <div key={`${streamIndex}-enum-${enumIndex}`} className="tpl-field">
        <label htmlFor={inputId}>
          Giá trị enum {enumIndex + 1}
        </label>
        <div className="tpl-enum-row">
          <input
            id={inputId}
            name={`streams[${streamIndex}].enumValues[${enumIndex}]`}
            autoComplete="off"
            className="tpl-input tpl-mono"
            type="text"
            value={enumValue}
            readOnly={isReadOnly}
            data-enum-index={enumIndex}
            aria-label={`Giá trị enum ${enumIndex + 1} của kênh ${streamIndex + 1}`}
            aria-invalid={Boolean(itemError)}
            aria-describedby={itemError ? `${inputId}-error` : undefined}
            placeholder="Ví dụ: OFF, AUTO, HIGH"
            onChange={handleEnumInputChange}
          />
          <button
            type="button"
            className="tpl-btn tpl-btn-danger"
            disabled={isReadOnly}
            data-enum-index={enumIndex}
            aria-label={`Xóa giá trị enum ${enumIndex + 1} của kênh ${streamIndex + 1}`}
            onClick={handleRemoveEnumValue}
          >
            Xóa
          </button>
        </div>
        {itemError ? <p id={`${inputId}-error`} className="tpl-field-error">{itemError}</p> : null}
      </div>
    );
  }

  return (
    <div className="tpl-field tpl-field-full" role="group" aria-labelledby={groupLabelId}>
      <div className="tpl-section-head">
        <span id={groupLabelId} className="tpl-field-label">
          Tập giá trị ENUM (1–64 chuỗi, phân biệt hoa thường)<span className="tpl-required-mark" aria-hidden="true">*</span>
        </span>
        <button
          id={addButtonId}
          type="button"
          className="tpl-btn"
          disabled={isReadOnly || values.length >= MAX_ENUM_VALUES_PER_STREAM}
          aria-describedby={groupError ? groupErrorId : undefined}
          onClick={handleAddEnumValue}
        >
          Thêm giá trị enum
        </button>
      </div>
      <div className="tpl-enum-list">
        {values.map(renderEnumRow)}
      </div>
      {groupError ? <p id={groupErrorId} className="tpl-field-error">{groupError}</p> : null}
    </div>
  );
}

/**
 * Các trường ràng buộc riêng cho datastream kiểu `NUMBER` gồm `unit`, `min` và `max`.
 * Input
 * Param: index — vị trí của stream trong danh sách để nối ID lỗi.
 * Param: stream — dữ liệu kênh kiểu NUMBER đang chỉnh sửa.
 * Param: isReadOnly — khóa chỉnh sửa khi xem bản PUBLISHED.
 * Param: isRangeRequired — bắt buộc nhập `min`/`max` hữu hạn khi kênh nhận lệnh ghi.
 * Param: errorMap — bảng ánh xạ path lỗi sang thông báo.
 * Param: onUpdateStream — cập nhật trường thay đổi tại vị trí index.
 * Output: các ô nhập liệu `unit`, `min`, `max` nằm trong grid của stream.
 */
function StreamNumberConstraintsFields({
  index,
  stream,
  isReadOnly,
  isRangeRequired,
  errorMap,
  onUpdateStream,
}: {
  index: number;
  stream: TemplateStreamDraft;
  isReadOnly: boolean;
  isRangeRequired: boolean;
  errorMap: ReadonlyMap<string, string>;
  onUpdateStream: (index: number, patch: Partial<TemplateStreamDraft>) => void;
}) {
  const prefix = `/streams/${index}`;
  const unitError = errorMap.get(`${prefix}/unit`);
  const minError = errorMap.get(`${prefix}/min`);
  const maxError = errorMap.get(`${prefix}/max`);
  const unitId = `tpl-stream-${index}-unit`;
  const minId = `tpl-stream-${index}-min`;
  const maxId = `tpl-stream-${index}-max`;

  /** Cập nhật đơn vị hiển thị của kênh NUMBER. */
  function handleUnitChange(event: ChangeEvent<HTMLInputElement>): void {
    onUpdateStream(index, { unit: event.target.value });
  }

  /** Cập nhật giá trị tối thiểu dạng chuỗi để giữ kiểm tra số hữu hạn nghiêm ngặt. */
  function handleMinChange(event: ChangeEvent<HTMLInputElement>): void {
    onUpdateStream(index, { minText: event.target.value });
  }

  /** Cập nhật giá trị tối đa dạng chuỗi để giữ kiểm tra số hữu hạn nghiêm ngặt. */
  function handleMaxChange(event: ChangeEvent<HTMLInputElement>): void {
    onUpdateStream(index, { maxText: event.target.value });
  }

  return (
    <>
      <div className="tpl-field">
        <label htmlFor={unitId}>Đơn vị hiển thị (unit, tùy chọn)</label>
        <input
          id={unitId}
          name={`streams[${index}].unit`}
          autoComplete="off"
          className="tpl-input"
          type="text"
          value={stream.unit}
          readOnly={isReadOnly}
          aria-invalid={Boolean(unitError)}
          aria-describedby={unitError ? `${unitId}-hint ${unitId}-error` : `${unitId}-hint`}
          placeholder="Ví dụ: °C, %, lux"
          onChange={handleUnitChange}
        />
        <p id={`${unitId}-hint`} className="tpl-hint">Chỉ dùng hiển thị, tối đa 32 ký tự; để trống nếu không có đơn vị.</p>
        {unitError ? <p id={`${unitId}-error`} className="tpl-field-error">{unitError}</p> : null}
      </div>

      <div className="tpl-field">
        <label htmlFor={minId}>
          Giá trị tối thiểu (min)
          {isRangeRequired ? <span className="tpl-required-mark" aria-hidden="true">*</span> : null}
        </label>
        <input
          id={minId}
          name={`streams[${index}].min`}
          autoComplete="off"
          className="tpl-input tpl-mono"
          type="text"
          inputMode="decimal"
          value={stream.minText}
          readOnly={isReadOnly}
          aria-required={isRangeRequired}
          aria-invalid={Boolean(minError)}
          aria-describedby={minError ? `${minId}-error` : undefined}
          placeholder="-20"
          onChange={handleMinChange}
        />
        {minError ? <p id={`${minId}-error`} className="tpl-field-error">{minError}</p> : null}
      </div>

      <div className="tpl-field">
        <label htmlFor={maxId}>
          Giá trị tối đa (max)
          {isRangeRequired ? <span className="tpl-required-mark" aria-hidden="true">*</span> : null}
        </label>
        <input
          id={maxId}
          name={`streams[${index}].max`}
          autoComplete="off"
          className="tpl-input tpl-mono"
          type="text"
          inputMode="decimal"
          value={stream.maxText}
          readOnly={isReadOnly}
          aria-required={isRangeRequired}
          aria-invalid={Boolean(maxError)}
          aria-describedby={maxError ? `${maxId}-error` : undefined}
          placeholder="100"
          onChange={handleMaxChange}
        />
        {maxError ? <p id={`${maxId}-error`} className="tpl-field-error">{maxError}</p> : null}
      </div>
    </>
  );
}

/**
 * Thẻ nhập một DatastreamDefinition: tách riêng `channelKind` và `direction` cùng các ràng buộc theo `type`.
 * Input
 * Param: index — vị trí của kênh trong danh sách.
 * Param: stream — dữ liệu kênh đang chỉnh sửa.
 * Param: isReadOnly — khóa thay đổi khi xem bản PUBLISHED.
 * Param: errorMap — bảng ánh xạ path lỗi sang thông báo.
 * Param: onUpdateStream — cập nhật trường thay đổi của kênh theo index.
 * Param: onRemoveStream — xóa kênh khỏi danh sách.
 * Output: thẻ article nhóm các trường nhập của một kênh.
 */
function StreamDefinitionFields({
  index,
  stream,
  isReadOnly,
  errorMap,
  onUpdateStream,
  onRemoveStream,
}: {
  index: number;
  stream: TemplateStreamDraft;
  isReadOnly: boolean;
  errorMap: ReadonlyMap<string, string>;
  onUpdateStream: (index: number, patch: Partial<TemplateStreamDraft>) => void;
  onRemoveStream: (index: number) => void;
}) {
  const prefix = `/streams/${index}`;
  const keyError = errorMap.get(`${prefix}/key`);
  const typeError = errorMap.get(`${prefix}/type`);
  const channelKindError = errorMap.get(`${prefix}/channelKind`);
  const directionError = errorMap.get(`${prefix}/direction`);

  const keyId = `tpl-stream-${index}-key`;
  const typeId = `tpl-stream-${index}-type`;
  const kindId = `tpl-stream-${index}-channelKind`;
  const dirId = `tpl-stream-${index}-direction`;
  const isRangeRequired =
    stream.type === 'NUMBER' && (stream.direction === 'WRITE' || stream.direction === 'READ_WRITE');

  /** Cập nhật khóa kênh (key) giữ nguyên localId để không mất focus khi gõ. */
  function handleKeyChange(event: ChangeEvent<HTMLInputElement>): void {
    onUpdateStream(index, { key: event.target.value });
  }

  /** Đổi kiểu dữ liệu và dọn các ràng buộc không thuộc kiểu mới để tránh sót dữ liệu ẩn. */
  function handleTypeChange(event: ChangeEvent<HTMLSelectElement>): void {
    const nextType = event.target.value as DatastreamType;
    onUpdateStream(index, {
      type: nextType,
      unit: nextType === 'NUMBER' ? stream.unit : '',
      minText: nextType === 'NUMBER' ? stream.minText : '',
      maxText: nextType === 'NUMBER' ? stream.maxText : '',
      enumValues: nextType === 'ENUM' ? (stream.enumValues.length > 0 ? stream.enumValues : ['']) : [],
    });
  }

  /** Cập nhật thuộc tính phân loại kênh TELEMETRY / STATE độc lập với hướng đọc ghi. */
  function handleChannelKindChange(event: ChangeEvent<HTMLSelectElement>): void {
    onUpdateStream(index, { channelKind: event.target.value as ChannelKind });
  }

  /** Cập nhật thuộc tính hướng truy cập READ / WRITE / READ_WRITE độc lập với channelKind. */
  function handleDirectionChange(event: ChangeEvent<HTMLSelectElement>): void {
    onUpdateStream(index, { direction: event.target.value as StreamDirection });
  }

  /** Cập nhật danh sách giá trị ENUM từ component con. */
  function handleEnumValuesChange(nextValues: string[]): void {
    onUpdateStream(index, { enumValues: nextValues });
  }

  /** Xóa kênh hiện tại khỏi danh sách draft. */
  function handleRemoveClick(): void {
    onRemoveStream(index);
  }

  return (
    <article className="tpl-stream-card" aria-labelledby={`tpl-stream-heading-${index}`}>
      <div className="tpl-stream-card-head">
        <h3 id={`tpl-stream-heading-${index}`}>
          Kênh #{index + 1}: <span className="tpl-mono">{stream.key.trim() || '(chưa đặt key)'}</span>
        </h3>
        <button
          type="button"
          className="tpl-btn tpl-btn-danger"
          disabled={isReadOnly}
          aria-label={`Xóa kênh ${index + 1}${stream.key.trim() ? `: ${stream.key.trim()}` : ''}`}
          onClick={handleRemoveClick}
        >
          <EditorIcon name="x" />
          <span>Xóa kênh</span>
        </button>
      </div>

      <div className="tpl-form-grid">
        <div className="tpl-field">
          <label htmlFor={keyId}>
            Khóa kênh (key)<span className="tpl-required-mark" aria-hidden="true">*</span>
          </label>
          <input
            id={keyId}
            name={`streams[${index}].key`}
            autoComplete="off"
            className="tpl-input tpl-mono"
            type="text"
            value={stream.key}
            readOnly={isReadOnly}
            aria-required="true"
            aria-invalid={Boolean(keyError)}
            aria-describedby={keyError ? `${keyId}-hint ${keyId}-error` : `${keyId}-hint`}
            placeholder="temperature"
            onChange={handleKeyChange}
          />
          <p id={`${keyId}-hint`} className="tpl-hint">Bắt đầu bằng a–z, chỉ gồm a–z, 0–9, _, dài tối đa 64.</p>
          {keyError ? <p id={`${keyId}-error`} className="tpl-field-error">{keyError}</p> : null}
        </div>

        <div className="tpl-field">
          <label htmlFor={typeId}>
            Kiểu dữ liệu (type)<span className="tpl-required-mark" aria-hidden="true">*</span>
          </label>
          <select
            id={typeId}
            name={`streams[${index}].type`}
            autoComplete="off"
            className="tpl-select"
            value={stream.type}
            disabled={isReadOnly}
            aria-disabled={isReadOnly}
            aria-required="true"
            aria-invalid={Boolean(typeError)}
            aria-describedby={typeError ? `${typeId}-error` : undefined}
            onChange={handleTypeChange}
          >
            {(['NUMBER', 'BOOLEAN', 'STRING', 'ENUM'] as const).map(renderStreamTypeOption)}
          </select>
          {typeError ? <p id={`${typeId}-error`} className="tpl-field-error">{typeError}</p> : null}
        </div>

        <div className="tpl-field">
          <label htmlFor={kindId}>
            Loại kênh (channelKind)<span className="tpl-required-mark" aria-hidden="true">*</span>
          </label>
          <select
            id={kindId}
            name={`streams[${index}].channelKind`}
            autoComplete="off"
            className="tpl-select"
            value={stream.channelKind}
            disabled={isReadOnly}
            aria-disabled={isReadOnly}
            aria-required="true"
            aria-invalid={Boolean(channelKindError)}
            aria-describedby={channelKindError ? `${kindId}-hint ${kindId}-error` : `${kindId}-hint`}
            onChange={handleChannelKindChange}
          >
            {(['TELEMETRY', 'STATE'] as const).map(renderChannelKindOption)}
          </select>
          <p id={`${kindId}-hint`} className="tpl-hint">Thuộc tính phân loại độc lập với hướng đọc/ghi.</p>
          {channelKindError ? <p id={`${kindId}-error`} className="tpl-field-error">{channelKindError}</p> : null}
        </div>

        <div className="tpl-field">
          <label htmlFor={dirId}>
            Hướng truy cập (direction)<span className="tpl-required-mark" aria-hidden="true">*</span>
          </label>
          <select
            id={dirId}
            name={`streams[${index}].direction`}
            autoComplete="off"
            className="tpl-select"
            value={stream.direction}
            disabled={isReadOnly}
            aria-disabled={isReadOnly}
            aria-required="true"
            aria-invalid={Boolean(directionError)}
            aria-describedby={directionError ? `${dirId}-hint ${dirId}-error` : `${dirId}-hint`}
            onChange={handleDirectionChange}
          >
            {(['READ', 'WRITE', 'READ_WRITE'] as const).map(renderDirectionOption)}
          </select>
          <p id={`${dirId}-hint`} className="tpl-hint">
            Kênh WRITE/READ_WRITE (khác STRING) cần 1 capability SET_VALUE ở mục bên dưới.
          </p>
          {directionError ? <p id={`${dirId}-error`} className="tpl-field-error">{directionError}</p> : null}
        </div>

        {stream.type === 'NUMBER' ? (
          <StreamNumberConstraintsFields
            index={index}
            stream={stream}
            isReadOnly={isReadOnly}
            isRangeRequired={isRangeRequired}
            errorMap={errorMap}
            onUpdateStream={onUpdateStream}
          />
        ) : null}

        {stream.type === 'ENUM' ? (
          <StreamEnumValuesEditor
            streamIndex={index}
            values={stream.enumValues}
            isReadOnly={isReadOnly}
            errorMap={errorMap}
            onChangeValues={handleEnumValuesChange}
          />
        ) : null}

        {stream.type === 'BOOLEAN' || stream.type === 'STRING' ? (
          <p className="tpl-hint tpl-field-full">
            {stream.type === 'BOOLEAN'
              ? 'Kiểu BOOLEAN không nhận unit, min hoặc max.'
              : 'Kiểu STRING chỉ phục vụ hiển thị (READ); không dùng min/max và không gắn lệnh điều khiển SET_VALUE.'}
          </p>
        ) : null}
      </div>
    </article>
  );
}

/**
 * Danh sách toàn bộ DatastreamDefinition trong bản nháp kèm thao tác thêm mới (tối đa 64 kênh).
 * Input
 * Param: streams — mảng datastream hiện tại của form.
 * Param: isReadOnly — khóa thêm/sửa/xóa khi ở trạng thái PUBLISHED.
 * Param: errorMap — bảng lỗi validation theo JSON Pointer.
 * Param: onAddStream — thêm một kênh rỗng mới vào danh sách.
 * Param: onUpdateStream — cập nhật trường của kênh tại index.
 * Param: onRemoveStream — xóa kênh tại index.
 * Output: khối danh sách datastream có trạng thái rỗng và giới hạn số lượng rõ ràng.
 */
function StreamDefinitionList({
  streams,
  isReadOnly,
  errorMap,
  onAddStream,
  onUpdateStream,
  onRemoveStream,
}: {
  streams: TemplateStreamDraft[];
  isReadOnly: boolean;
  errorMap: ReadonlyMap<string, string>;
  onAddStream: () => void;
  onUpdateStream: (index: number, patch: Partial<TemplateStreamDraft>) => void;
  onRemoveStream: (index: number) => void;
}) {
  const streamsGroupError = errorMap.get('/streams');
  const groupErrorId = 'tpl-streams-add-error';

  /** Giữ React key theo `localId` bất biến để chỉnh sửa `key` của kênh không bị mất focus. */
  function renderStreamCard(stream: TemplateStreamDraft, index: number) {
    return (
      <StreamDefinitionFields
        key={stream.localId}
        index={index}
        stream={stream}
        isReadOnly={isReadOnly}
        errorMap={errorMap}
        onUpdateStream={onUpdateStream}
        onRemoveStream={onRemoveStream}
      />
    );
  }

  return (
    <section className="tpl-card" aria-labelledby="tpl-streams-heading">
      <div className="tpl-section-head">
        <div>
          <h2 id="tpl-streams-heading">2. Định nghĩa Datastream ({streams.length}/{MAX_STREAMS_PER_TEMPLATE})</h2>
          <p className="tpl-hint">Bản nháp có thể lưu với 0 kênh; khi công bố ở FEAT-TN-006 sẽ yêu cầu ít nhất 1 kênh.</p>
        </div>
        <button
          id="tpl-streams-add"
          type="button"
          className="tpl-btn"
          disabled={isReadOnly || streams.length >= MAX_STREAMS_PER_TEMPLATE}
          aria-describedby={streamsGroupError ? groupErrorId : undefined}
          onClick={onAddStream}
        >
          Thêm datastream
        </button>
      </div>
      {streamsGroupError ? <p id={groupErrorId} className="tpl-field-error">{streamsGroupError}</p> : null}
      {streams.length === 0 ? (
        <div className="tpl-state-box">
          <p>Chưa có datastream nào trong bản nháp này. Nhấn &ldquo;Thêm datastream&rdquo; để khai báo kênh cảm biến hoặc actuator.</p>
        </div>
      ) : (
        <div className="tpl-editor-main">
          {streams.map(renderStreamCard)}
        </div>
      )}
    </section>
  );
}

/**
 * Kết xuất một option cho dropdown `safeValue` của kênh `ENUM`.
 * Input
 * Param: val — chuỗi giá trị enum hợp lệ trong kênh đích.
 * Param: valIdx — chỉ số thứ tự để phân biệt key khi người dùng tạm gõ trùng.
 * Output: phần tử `<option>` hoặc null nếu giá trị rỗng.
 */
function renderEnumSafeOption(val: string, valIdx: number) {
  if (!val) return null;
  return (
    <option key={`${valIdx}-${val}`} value={val}>
      {val}
    </option>
  );
}

/**
 * Thẻ nhập một mục capability `SET_VALUE` và `safeValue` theo kiểu dữ liệu của kênh đích.
 * Input
 * Param: index — chỉ số capability trong `commands[]`.
 * Param: command — dữ liệu capability đang chỉnh sửa.
 * Param: streams — danh sách kênh hiện có để dựng dropdown đích và kiểu nhập `safeValue`.
 * Param: isReadOnly — khóa thay đổi khi xem bản PUBLISHED.
 * Param: errorMap — bảng lỗi validation theo JSON Pointer.
 * Param: onUpdateCommand — cập nhật trường thay đổi tại index.
 * Param: onRemoveCommand — xóa capability tại index.
 * Output: thẻ article chỉnh sửa một capability `SET_VALUE`.
 */
function CapabilityItemFields({
  index,
  command,
  streams,
  isReadOnly,
  errorMap,
  onUpdateCommand,
  onRemoveCommand,
}: {
  index: number;
  command: TemplateCommandDraft;
  streams: TemplateStreamDraft[];
  isReadOnly: boolean;
  errorMap: ReadonlyMap<string, string>;
  onUpdateCommand: (index: number, patch: Partial<TemplateCommandDraft>) => void;
  onRemoveCommand: (index: number) => void;
}) {
  /** Đối chiếu khóa kênh hiện tại để xác định kiểu dữ liệu cho control safeValue. */
  function isMatchingStream(item: TemplateStreamDraft): boolean {
    const trimmedTarget = command.stream.trim();
    return trimmedTarget !== '' && item.key.trim() === trimmedTarget;
  }

  const targetStream = streams.find(isMatchingStream);
  const streamError = errorMap.get(`/commands/${index}/stream`);
  const safeError = errorMap.get(`/commands/${index}/safeValue`);
  const streamSelectId = `tpl-command-${index}-stream`;
  const safeInputId = `tpl-command-${index}-safeValue`;
  const safeDescribedBy = safeError ? `${safeInputId}-hint ${safeInputId}-error` : `${safeInputId}-hint`;
  const hasOrphanTarget = Boolean(command.stream.trim()) && !targetStream;
  const hasInvalidBooleanSafe =
    targetStream?.type === 'BOOLEAN'
    && command.safeValueText !== ''
    && command.safeValueText !== 'false'
    && command.safeValueText !== 'true';
  const hasInvalidEnumSafe =
    targetStream?.type === 'ENUM'
    && command.safeValueText !== ''
    && !targetStream.enumValues.includes(command.safeValueText);

  /** Đổi target stream và đặt lại safeValue để người dùng chủ động xác nhận lại giá trị an toàn. */
  function handleStreamChange(event: ChangeEvent<HTMLSelectElement>): void {
    onUpdateCommand(index, { stream: event.target.value, safeValueText: '' });
  }

  /** Cập nhật chuỗi `safeValue` từ ô nhập hoặc dropdown theo kiểu dữ liệu. */
  function handleSafeValueChange(event: ChangeEvent<HTMLInputElement | HTMLSelectElement>): void {
    onUpdateCommand(index, { safeValueText: event.target.value });
  }

  /** Xóa capability tại vị trí hiện tại. */
  function handleRemoveClick(): void {
    onRemoveCommand(index);
  }

  return (
    <article className="tpl-cap-card" aria-labelledby={`tpl-cap-head-${index}`}>
      <div className="tpl-stream-card-head">
        <h3 id={`tpl-cap-head-${index}`}>Capability #{index + 1}: SET_VALUE</h3>
        <button
          type="button"
          className="tpl-btn tpl-btn-danger"
          disabled={isReadOnly}
          aria-label={`Xóa capability SET_VALUE ${index + 1}`}
          onClick={handleRemoveClick}
        >
          <EditorIcon name="x" />
          <span>Xóa capability</span>
        </button>
      </div>

      <div className="tpl-form-grid">
        <div className="tpl-field">
          <label htmlFor={streamSelectId}>
            Kênh đích (stream)<span className="tpl-required-mark" aria-hidden="true">*</span>
          </label>
          <select
            id={streamSelectId}
            name={`commands[${index}].stream`}
            autoComplete="off"
            className="tpl-select"
            value={command.stream}
            disabled={isReadOnly}
            aria-disabled={isReadOnly}
            aria-required="true"
            aria-invalid={Boolean(streamError)}
            aria-describedby={streamError ? `${streamSelectId}-error` : undefined}
            onChange={handleStreamChange}
          >
            <option value="">-- Chọn datastream --</option>
            {hasOrphanTarget ? (
              <option value={command.stream}>{command.stream} (không còn trong danh sách kênh — sẽ bị từ chối)</option>
            ) : null}
            {streams.map(renderTargetStreamOption)}
          </select>
          {streamError ? <p id={`${streamSelectId}-error`} className="tpl-field-error">{streamError}</p> : null}
        </div>

        <div className="tpl-field">
          <label htmlFor={safeInputId}>
            Giá trị an toàn (safeValue)<span className="tpl-required-mark" aria-hidden="true">*</span>
          </label>
          {targetStream?.type === 'BOOLEAN' ? (
            <select
              id={safeInputId}
              name={`commands[${index}].safeValue`}
              autoComplete="off"
              className="tpl-select"
              value={command.safeValueText}
              disabled={isReadOnly}
              aria-disabled={isReadOnly}
              aria-required="true"
              aria-invalid={Boolean(safeError)}
              aria-describedby={safeDescribedBy}
              onChange={handleSafeValueChange}
            >
              <option value="">-- Chọn boolean an toàn --</option>
              {hasInvalidBooleanSafe ? (
                <option value={command.safeValueText}>
                  {command.safeValueText} (không hợp lệ cho BOOLEAN — sẽ bị từ chối)
                </option>
              ) : null}
              <option value="false">false (mức logic thấp / tắt tùy driver)</option>
              <option value="true">true (mức logic cao / bật tùy driver)</option>
            </select>
          ) : targetStream?.type === 'ENUM' ? (
            <select
              id={safeInputId}
              name={`commands[${index}].safeValue`}
              autoComplete="off"
              className="tpl-select"
              value={command.safeValueText}
              disabled={isReadOnly}
              aria-disabled={isReadOnly}
              aria-required="true"
              aria-invalid={Boolean(safeError)}
              aria-describedby={safeDescribedBy}
              onChange={handleSafeValueChange}
            >
              <option value="">-- Chọn giá trị enum an toàn --</option>
              {hasInvalidEnumSafe ? (
                <option value={command.safeValueText}>
                  {command.safeValueText} (không có trong enumValues — sẽ bị từ chối)
                </option>
              ) : null}
              {targetStream.enumValues.map(renderEnumSafeOption)}
            </select>
          ) : (
            <input
              id={safeInputId}
              name={`commands[${index}].safeValue`}
              autoComplete="off"
              className="tpl-input tpl-mono"
              type="text"
              inputMode={targetStream?.type === 'NUMBER' ? 'decimal' : 'text'}
              value={command.safeValueText}
              readOnly={isReadOnly}
              aria-required="true"
              aria-invalid={Boolean(safeError)}
              aria-describedby={safeDescribedBy}
              placeholder={targetStream?.type === 'NUMBER' ? 'Ví dụ: 0' : 'Chọn kênh hợp lệ trước'}
              onChange={handleSafeValueChange}
            />
          )}
          <p id={`${safeInputId}-hint`} className="tpl-hint">
            {targetStream?.type === 'NUMBER'
              ? `Phải nằm trong khoảng [${targetStream.minText || '?'}, ${targetStream.maxText || '?'}].`
              : 'Giá trị an toàn phải khớp kiểu dữ liệu của kênh đích.'}
          </p>
          {safeError ? <p id={`${safeInputId}-error`} className="tpl-field-error">{safeError}</p> : null}
        </div>
      </div>
    </article>
  );
}

/**
 * Vùng cấu hình capability đầu ra `SET_VALUE` và `safeValue` trong `commands[]` theo đề xuất OQ-TEMPLATE-001/005.
 * Input
 * Param: streams — danh sách kênh hiện có để gợi ý kênh ghi được còn thiếu capability.
 * Param: commands — mảng capability SET_VALUE hiện tại.
 * Param: isReadOnly — khóa sửa đổi khi xem bản PUBLISHED.
 * Param: errorMap — bảng lỗi validation gắn từ phản hồi 422.
 * Param: onAddCommand — thêm capability SET_VALUE mới (có thể chọn sẵn `streamKey`).
 * Param: onUpdateCommand — cập nhật `stream` hoặc `safeValueText` tại vị trí index.
 * Param: onRemoveCommand — xóa capability tại index.
 * Output: khối cấu hình capability kèm cảnh báo an toàn phần cứng và danh sách kênh thiếu capability.
 */
function CapabilityEditor({
  streams,
  commands,
  isReadOnly,
  errorMap,
  onAddCommand,
  onUpdateCommand,
  onRemoveCommand,
}: {
  streams: TemplateStreamDraft[];
  commands: TemplateCommandDraft[];
  isReadOnly: boolean;
  errorMap: ReadonlyMap<string, string>;
  onAddCommand: (streamKey?: string) => void;
  onUpdateCommand: (index: number, patch: Partial<TemplateCommandDraft>) => void;
  onRemoveCommand: (index: number) => void;
}) {
  const groupError = errorMap.get('/commands');
  const addButtonId = 'tpl-commands-add';
  const groupErrorId = `${addButtonId}-error`;

  /** Trích xuất khóa kênh đích của capability để xác định các kênh chưa gắn lệnh. */
  function readCommandStreamKey(cmd: TemplateCommandDraft): string {
    return cmd.stream.trim();
  }

  const configuredTargets = new Set(commands.map(readCommandStreamKey));

  /** Xác định kênh ghi được nhưng chưa có capability SET_VALUE để hiển thị nút tạo nhanh. */
  function isMissingCapabilityStream(stream: TemplateStreamDraft): boolean {
    const key = stream.key.trim();
    const isWritable = (stream.direction === 'WRITE' || stream.direction === 'READ_WRITE') && stream.type !== 'STRING';
    return Boolean(key) && isWritable && !configuredTargets.has(key);
  }

  const missingWritableStreams = streams.filter(isMissingCapabilityStream);

  /** Thêm một dòng capability SET_VALUE trống để người dùng chọn kênh đích và safeValue. */
  function handleAddBlankCommand(): void {
    onAddCommand('');
  }

  /** Gắn nhanh capability SET_VALUE cho một kênh ghi được chưa có cấu hình. */
  function handleQuickAddForStream(event: MouseEvent<HTMLButtonElement>): void {
    const key = event.currentTarget.dataset.streamKey ?? '';
    onAddCommand(key);
  }

  /** Hiển thị nút tạo nhanh đúng cho kênh ghi được còn thiếu capability. */
  function renderQuickAddButton(stream: TemplateStreamDraft) {
    const trimmedKey = stream.key.trim();
    return (
      <button
        key={stream.localId}
        type="button"
        className="tpl-btn"
        data-stream-key={trimmedKey}
        onClick={handleQuickAddForStream}
      >
        Tạo SET_VALUE cho &ldquo;{trimmedKey}&rdquo;
      </button>
    );
  }

  /** Hiển thị từng capability kèm kiểm tra kiểu safeValue theo stream đích tương ứng. */
  function renderCapabilityCard(command: TemplateCommandDraft, index: number) {
    return (
      <CapabilityItemFields
        key={command.localId}
        index={index}
        command={command}
        streams={streams}
        isReadOnly={isReadOnly}
        errorMap={errorMap}
        onUpdateCommand={onUpdateCommand}
        onRemoveCommand={onRemoveCommand}
      />
    );
  }

  return (
    <section className="tpl-card" aria-labelledby="tpl-commands-heading">
      <div className="tpl-section-head">
        <div>
          <h2 id="tpl-commands-heading">3. Capability đầu ra SET_VALUE ({commands.length}/{MAX_COMMANDS_PER_TEMPLATE})</h2>
          <p className="tpl-hint">
            Đặt <code>safeValue</code> trong <code>commands[]</code> theo OQ-TEMPLATE-001/005. Không tự giả định <code>false</code> hoặc <code>0</code> là tắt an toàn khi chưa có PoC phần cứng.
          </p>
        </div>
        <button
          id={addButtonId}
          type="button"
          className="tpl-btn"
          disabled={isReadOnly || commands.length >= MAX_COMMANDS_PER_TEMPLATE}
          aria-describedby={groupError ? groupErrorId : undefined}
          onClick={handleAddBlankCommand}
        >
          Thêm capability SET_VALUE
        </button>
      </div>

      {groupError ? <p id={groupErrorId} className="tpl-field-error">{groupError}</p> : null}

      {missingWritableStreams.length > 0 && !isReadOnly ? (
        <div className="tpl-notice tpl-notice-warning" role="status">
          <EditorIcon name="bolt" />
          <div className="tpl-notice-body">
            <p>Các kênh ghi được sau chưa có capability <code>SET_VALUE</code>:</p>
            <div className="tpl-actions-row">
              {missingWritableStreams.map(renderQuickAddButton)}
            </div>
          </div>
        </div>
      ) : null}

      {commands.length === 0 ? (
        <div className="tpl-state-box">
          <p>Chưa có capability <code>SET_VALUE</code> nào. Chỉ các kênh hướng WRITE hoặc READ_WRITE (không phải STRING) mới được điều khiển.</p>
        </div>
      ) : (
        <div className="tpl-editor-main">
          {commands.map(renderCapabilityCard)}
        </div>
      )}
    </section>
  );
}

/**
 * Khung xem trước schema ở chế độ chỉ đọc: phân biệt rõ kênh Read-only và kênh điều khiển được, kèm JSON preview.
 * Input
 * Param: workspaceId — mã workspace tổng hợp hiện hành.
 * Param: form — cấu trúc nháp hiện tại đang hiển thị.
 * Param: lastServerTemplate — DTO phản hồi gần nhất từ mock API để đối chiếu đồng bộ.
 * Param: isDirty — cho biết preview đang phản ánh chỉnh sửa cục bộ chưa gửi lưu.
 * Output: thẻ preview read-only hiển thị bên phải ở màn hình rộng hoặc dưới cùng ở màn hình hẹp.
 */
function SchemaPreview({
  workspaceId,
  form,
  lastServerTemplate,
  isDirty,
}: {
  workspaceId: string;
  form: TemplateDraftForm;
  lastServerTemplate: TemplateDto | null;
  isDirty: boolean;
}) {
  /** Tuần tự hóa payload JSON preview chỉ khi dữ liệu biểu mẫu hoặc workspaceId thay đổi. */
  function computePreviewJson(): string {
    return JSON.stringify(buildPreviewJsonPayload(form, workspaceId), null, 2);
  }

  const previewJson = useMemo(computePreviewJson, [form, workspaceId]);

  /** Hiển thị từng kênh với badge chữ + icon riêng biệt cho READ-only và Controllable. */
  function renderPreviewRow(stream: TemplateStreamDraft) {
    const streamKey = stream.key.trim();

    /** Đối chiếu command SET_VALUE gắn đúng khóa kênh hiện hành. */
    function isCommandForStream(cmd: TemplateCommandDraft): boolean {
      return streamKey !== '' && cmd.stream.trim() === streamKey;
    }

    const matchingCmd = form.commands.find(isCommandForStream);
    const isControllable =
      stream.direction !== 'READ'
      && stream.type !== 'STRING'
      && Boolean(matchingCmd)
      && matchingCmd?.safeValueText !== '';

    return (
      <li key={stream.localId} className="tpl-preview-row">
        <div className="tpl-list-item-title">
          <strong className="tpl-mono">{streamKey || '(chưa đặt key)'}</strong>
          <span className={`tpl-badge ${isControllable ? 'tpl-badge-control' : 'tpl-badge-readonly'}`}>
            <EditorIcon name={isControllable ? 'bolt' : 'pulse'} />
            <span>{isControllable ? 'Điều khiển (SET_VALUE)' : 'Chỉ hiển thị (Read-only)'}</span>
          </span>
        </div>
        <div className="tpl-meta-line">
          <span>Loại: {stream.type}</span>
          <span>channelKind: {stream.channelKind}</span>
          <span>direction: {stream.direction}</span>
          {stream.type === 'NUMBER' ? (
            <span>
              Khoảng: {stream.minText || '—'}..{stream.maxText || '—'} {stream.unit ? `(${stream.unit})` : ''}
            </span>
          ) : null}
          {stream.type === 'ENUM' ? (
            <span>Enum: [{stream.enumValues.join(', ')}]</span>
          ) : null}
          {matchingCmd ? (
            <span>safeValue: <code className="tpl-mono">{matchingCmd.safeValueText || '(chưa chọn)'}</code></span>
          ) : null}
        </div>
      </li>
    );
  }

  return (
    <aside className="tpl-card tpl-preview-col" aria-labelledby="tpl-preview-heading">
      <div className="tpl-section-head">
        <h2 id="tpl-preview-heading">Xem trước schema (Chỉ đọc)</h2>
        <span className={`tpl-badge ${isDirty || !lastServerTemplate ? 'tpl-badge-published' : 'tpl-badge-draft'}`}>
          {isDirty || !lastServerTemplate
            ? 'Nháp cục bộ chưa áp dụng'
            : `Khớp preview #${lastServerTemplate.revision}`}
        </span>
      </div>
      <p className="tpl-hint">
        Chế độ chỉ đọc phục vụ kiểm tra cấu trúc: không đăng ký thiết bị, không sinh credential MQTT và không gửi lệnh điều khiển.
      </p>

      <div className="tpl-preview-stack">
        <div>
          <h3 className="tpl-preview-subheading">Phân biệt hiển thị và điều khiển</h3>
          {form.streams.length === 0 ? (
            <p className="tpl-hint">Chưa có datastream để xem trước.</p>
          ) : (
            <ul className="tpl-preview-list">
              {form.streams.map(renderPreviewRow)}
            </ul>
          )}
        </div>

        <div>
          <h3 className="tpl-preview-subheading">Cấu trúc JSON preview (TemplateDraft)</h3>
          <pre className="tpl-preview-code">
            <code>{previewJson}</code>
          </pre>
        </div>

        <details className="tpl-subcard">
          <summary>Ghi chú hợp đồng G1 đang chờ khóa ({UNRESOLVED_WIRE_ASSUMPTIONS.length} điểm)</summary>
          <ul className="tpl-hint tpl-g1-notes">
            {UNRESOLVED_WIRE_ASSUMPTIONS.map(renderWireAssumptionItem)}
          </ul>
        </details>
      </div>
    </aside>
  );
}

/**
 * Thanh hành động cuối biểu mẫu tạo/sửa draft, nhắc phạm vi mô phỏng trong tab và hiển thị nút submit.
 * Input
 * Param: isExistingDraft — xác định nhãn nút tạo mới hay cập nhật bản nháp.
 * Param: isSubmitting — khóa nút gửi trong lúc xử lý yêu cầu mô phỏng.
 * Output: thẻ chứa chú thích phạm vi preview và nút submit chính.
 */
function EditorSubmitCard({
  isExistingDraft,
  isSubmitting,
}: {
  isExistingDraft: boolean;
  isSubmitting: boolean;
}) {
  return (
    <div className="tpl-card">
      <div className="tpl-section-head tpl-section-head-flush">
        <p className="tpl-hint">
          Mọi thao tác chỉ kiểm tra và mô phỏng trong bộ nhớ tab; không có nút publish, đăng ký thiết bị hay gửi lệnh thật ở WB-03.
        </p>
        <button type="submit" className="tpl-btn tpl-btn-primary" disabled={isSubmitting}>
          <EditorIcon name="check" />
          <span>
            {isSubmitting
              ? 'Đang kiểm tra schema…'
              : isExistingDraft
                ? 'Lưu cập nhật nháp (chỉ preview)'
                : 'Tạo bản nháp (chỉ preview)'}
          </span>
        </button>
      </div>
    </div>
  );
}

/**
 * Màn hình chỉnh sửa và xem trước một Template DRAFT hoặc xem chỉ đọc bản PUBLISHED theo bố cục WB-03.
 * Input
 * Param: props — toàn bộ trạng thái workspace, form, lỗi, ứng viên phục hồi và các handler điều phối.
 * Output: giao diện hai cột trên màn hình rộng và xếp dọc dưới 1024px / 768px.
 */
export function TemplateEditor({
  workspaceId,
  workspaceName,
  form,
  lastServerTemplate,
  saveOutcome,
  pendingCandidates,
  isDirty,
  isSubmitting,
  errorFocusNonce,
  headingRef,
  onChangeForm,
  onSubmit,
  onBackToList,
  onApplyServerRevision,
  onSelectCandidate,
  onCreateNewAfterUnknown,
}: TemplateEditorProps) {
  const errorSummaryRef = useRef<HTMLDivElement>(null);
  const localCounterRef = useRef(0);
  const isPublished = form.status === 'PUBLISHED';

  /** Lấy danh sách lỗi trường khi kết quả lưu trả về 422 STREAM_INVALID. */
  function readValidationFieldErrors(): FieldErrorItem[] {
    return saveOutcome && !saveOutcome.ok && saveOutcome.kind === 'validation' ? saveOutcome.fieldErrors : [];
  }

  const fieldErrors = useMemo(readValidationFieldErrors, [saveOutcome]);

  /** Chuyển danh sách fieldErrors sang Map theo JSON Pointer để tra cứu nhanh ở từng ô nhập. */
  function buildFieldErrorMap(): Map<string, string> {
    const map = new Map<string, string>();
    for (const item of fieldErrors) {
      if (!map.has(item.path)) map.set(item.path, item.message);
    }
    return map;
  }

  const errorMap = useMemo(buildFieldErrorMap, [fieldErrors]);

  /** Đưa tiêu điểm lên hộp tóm tắt lỗi sau mỗi lần submit thất bại có lỗi field để hỗ trợ bàn phím. */
  function focusErrorSummaryEffect(): void {
    if (errorFocusNonce > 0 && fieldErrors.length > 0) {
      errorSummaryRef.current?.focus();
    }
  }

  useEffect(focusErrorSummaryEffect, [errorFocusNonce, fieldErrors.length]);

  /** Tạo ID cục bộ tăng dần trong phiên cho stream hoặc capability mới thêm. */
  function nextLocalId(prefix: string): string {
    localCounterRef.current += 1;
    return `${prefix}-${Date.now()}-${localCounterRef.current}`;
  }

  /** Cập nhật tên template trong state form. */
  function handleNameChange(value: string): void {
    onChangeForm({ ...form, name: value });
  }

  /** Cập nhật mã model chuẩn trong state form. */
  function handleModelChange(value: string): void {
    onChangeForm({ ...form, model: value });
  }

  /** Thêm một datastream rỗng mới vào cuối danh sách. */
  function handleAddStream(): void {
    if (form.streams.length >= MAX_STREAMS_PER_TEMPLATE) return;
    onChangeForm({
      ...form,
      streams: [...form.streams, createEmptyStreamDraft(nextLocalId('stream-new'))],
    });
  }

  /** Cập nhật một datastream tại vị trí index. */
  function handleUpdateStream(index: number, patch: Partial<TemplateStreamDraft>): void {
    /** Thay thế bất biến phần tử stream tại đúng chỉ số đang chỉnh sửa. */
    function patchStreamAtIndex(item: TemplateStreamDraft, idx: number): TemplateStreamDraft {
      return idx === index ? { ...item, ...patch } : item;
    }
    onChangeForm({ ...form, streams: form.streams.map(patchStreamAtIndex) });
  }

  /** Xóa datastream và dọn capability gắn trực tiếp với khóa kênh vừa xóa theo OQ-TEMPLATE-004. */
  function handleRemoveStream(index: number): void {
    const removedKey = form.streams[index]?.key.trim() ?? '';
    /** Giữ các kênh khác vị trí đang xóa. */
    function keepOtherStream(_item: TemplateStreamDraft, idx: number): boolean {
      return idx !== index;
    }
    /** Gỡ command gắn đúng stream vừa xóa trong cùng thao tác chỉnh sửa. */
    function keepUnrelatedCommand(cmd: TemplateCommandDraft): boolean {
      return cmd.stream.trim() !== removedKey;
    }
    const nextStreams = form.streams.filter(keepOtherStream);
    const nextCommands = removedKey ? form.commands.filter(keepUnrelatedCommand) : form.commands;
    onChangeForm({ ...form, streams: nextStreams, commands: nextCommands });
  }

  /** Thêm capability SET_VALUE mới vào `commands[]`. */
  function handleAddCommand(streamKey = ''): void {
    if (form.commands.length >= MAX_COMMANDS_PER_TEMPLATE) return;
    onChangeForm({
      ...form,
      commands: [...form.commands, createEmptyCommandDraft(nextLocalId('cmd-new'), streamKey)],
    });
  }

  /** Cập nhật capability SET_VALUE tại vị trí index. */
  function handleUpdateCommand(index: number, patch: Partial<TemplateCommandDraft>): void {
    /** Giữ bất biến mảng commands khi sửa stream đích hoặc safeValue. */
    function patchCommandAtIndex(item: TemplateCommandDraft, idx: number): TemplateCommandDraft {
      return idx === index ? { ...item, ...patch } : item;
    }
    onChangeForm({ ...form, commands: form.commands.map(patchCommandAtIndex) });
  }

  /** Xóa capability SET_VALUE tại vị trí index. */
  function handleRemoveCommand(index: number): void {
    /** Giữ lại mọi capability khác vị trí đang xóa. */
    function keepOtherCommand(_item: TemplateCommandDraft, idx: number): boolean {
      return idx !== index;
    }
    onChangeForm({ ...form, commands: form.commands.filter(keepOtherCommand) });
  }

  /** Gửi biểu mẫu qua mock API preview khi người dùng nhấn nút Lưu bản nháp. */
  function handleFormSubmit(event: FormEvent<HTMLFormElement>): void {
    event.preventDefault();
    onSubmit();
  }

  return (
    <div className="tpl-editor-main">
      <EditorHeaderCard
        form={form}
        workspaceName={workspaceName}
        isPublished={isPublished}
        isSubmitting={isSubmitting}
        headingRef={headingRef}
        onBackToList={onBackToList}
      />

      <SaveStateNotice
        saveOutcome={saveOutcome}
        isPublished={isPublished}
        isDirty={isDirty}
        isSubmitting={isSubmitting}
        form={form}
        pendingCandidates={pendingCandidates}
        onApplyServerRevision={onApplyServerRevision}
        onSelectCandidate={onSelectCandidate}
        onRetryManualSave={onSubmit}
        onSimulatePublishedPatch={onSubmit}
        onCreateNewAfterUnknown={onCreateNewAfterUnknown}
      />

      <FieldErrorSummary errors={fieldErrors} summaryRef={errorSummaryRef} />

      <div className="tpl-editor-grid">
        <form onSubmit={handleFormSubmit} noValidate className="tpl-editor-main" aria-busy={isSubmitting}>
          <TemplateMetadataFields
            name={form.name}
            model={form.model}
            isReadOnly={isPublished}
            errorMap={errorMap}
            onChangeName={handleNameChange}
            onChangeModel={handleModelChange}
          />

          <StreamDefinitionList
            streams={form.streams}
            isReadOnly={isPublished}
            errorMap={errorMap}
            onAddStream={handleAddStream}
            onUpdateStream={handleUpdateStream}
            onRemoveStream={handleRemoveStream}
          />

          <CapabilityEditor
            streams={form.streams}
            commands={form.commands}
            isReadOnly={isPublished}
            errorMap={errorMap}
            onAddCommand={handleAddCommand}
            onUpdateCommand={handleUpdateCommand}
            onRemoveCommand={handleRemoveCommand}
          />

          {!isPublished ? (
            <EditorSubmitCard isExistingDraft={Boolean(form.id)} isSubmitting={isSubmitting} />
          ) : null}
        </form>

        <SchemaPreview
          workspaceId={workspaceId}
          form={form}
          lastServerTemplate={lastServerTemplate}
          isDirty={isDirty}
        />
      </div>
    </div>
  );
}
