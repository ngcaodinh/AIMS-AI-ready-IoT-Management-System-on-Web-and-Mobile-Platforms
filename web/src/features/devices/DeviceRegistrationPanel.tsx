import { useEffect, useRef, useState, type ChangeEvent, type FormEvent, type MouseEvent } from 'react';
import type { ApiFieldError } from '../workspace/workspaceApi.ts';
import type { TemplateVersionDto } from '../templates/templateContract.ts';
import {
  assessSerialRecoveryOutcome,
  validateCanonicalSerial,
  type DeviceCreateInput,
  type DeviceDto,
  type DeviceRegisteredDto,
  type SetupMethod,
  type WorkspaceActiveMemberDto,
} from './deviceContract.ts';

export type RegistrationOutcome =
  | { kind: 'created'; device: DeviceRegisteredDto }
  | { kind: 'duplicate_409'; message: string }
  | { kind: 'validation_422'; message: string; fieldErrors: ApiFieldError[] }
  | { kind: 'not_found_404'; message: string }
  | {
    kind: 'unknown_recovery';
    intent: DeviceCreateInput;
    status: 'MATCHES_INTENT' | 'CONFLICTS_WITH_INTENT' | 'NOT_FOUND_IN_SCOPE' | 'PENDING';
    recoveredDevice: DeviceDto | null;
    message: string;
  }
  | { kind: 'error'; message: string }
  | null;

interface DeviceRegistrationPanelProps {
  publishedVersions: TemplateVersionDto[];
  activeMembers: WorkspaceActiveMemberDto[];
  isLoadingDeps: boolean;
  isSubmitting: boolean;
  outcome: RegistrationOutcome;
  selectedDevice: DeviceDto | null;
  selectedSetupMethod: SetupMethod | null;
  errorFocusNonce: number;
  onSubmitRegister: (input: DeviceCreateInput) => void;
  onLookupBySerial: (serial: string) => void;
  onSelectSetupMethod: (method: SetupMethod) => void;
}

/**
 * Ánh xạ đường dẫn lỗi JSON Pointer sang ID input tương ứng trong form đăng ký thiết bị D4.
 * Input
 * Param: path — JSON Pointer từ `details.fieldErrors[].path`.
 * Output: ID phần tử DOM để đưa tiêu điểm bàn phím khi người dùng nhấn liên kết lỗi.
 */
function deviceFieldPathToId(path: string): string {
  if (path === '/serial') return 'dev-field-serial';
  if (path === '/name') return 'dev-field-name';
  if (path === '/templateVersionId') return 'dev-field-version';
  if (path === '/model') return 'dev-field-model';
  if (path === '/ownerId') return 'dev-field-owner';
  return 'dev-error-summary';
}

/**
 * Giao diện WB-04 cho FEAT-TN-007 D4: đăng ký thiết bị mới pin đúng `templateVersionId` UUID,
 * chọn chủ sở hữu ACTIVE, đối soát mất ACK theo exact serial và chọn phương thức setup USB / QR_BLE.
 * Input
 * Param: props — danh sách version đã công bố, thành viên ACTIVE, kết quả đăng ký và các handler.
 * Output: thẻ đăng ký, trạng thái `REGISTERED/UNKNOWN/PROVISIONING` và chọn bước setup tiếp theo.
 */
export function DeviceRegistrationPanel({
  publishedVersions,
  activeMembers,
  isLoadingDeps,
  isSubmitting,
  outcome,
  selectedDevice,
  selectedSetupMethod,
  errorFocusNonce,
  onSubmitRegister,
  onLookupBySerial,
  onSelectSetupMethod,
}: DeviceRegistrationPanelProps) {
  const [serial, setSerial] = useState('');
  const [name, setName] = useState('');
  const [templateVersionId, setTemplateVersionId] = useState('');
  const [model, setModel] = useState('');
  const [ownerId, setOwnerId] = useState('');
  const [lookupSerial, setLookupSerial] = useState('');
  const [localErrors, setLocalErrors] = useState<ApiFieldError[]>([]);
  const errorSummaryRef = useRef<HTMLDivElement>(null);

  const serverFieldErrors = outcome?.kind === 'validation_422' ? outcome.fieldErrors : [];
  const allFieldErrors = localErrors.length > 0 ? localErrors : serverFieldErrors;
  const errorMap = new Map<string, string>();
  for (const item of allFieldErrors) {
    if (!errorMap.has(item.path)) {
      errorMap.set(item.path, `Lỗi hợp lệ (${item.code}) tại ${item.path}`);
    }
  }

  /** Đưa tiêu điểm vào tóm tắt lỗi khi có lỗi validation phát sinh từ local hoặc server 422. */
  useEffect(() => {
    if (errorFocusNonce > 0 && allFieldErrors.length > 0) {
      errorSummaryRef.current?.focus();
    }
  }, [errorFocusNonce, allFieldErrors.length]);

  /** Đồng bộ mã `model` chính xác từ snapshot `TemplateVersion` đã công bố khi người dùng chọn pin. */
  function handleVersionChange(event: ChangeEvent<HTMLSelectElement>): void {
    const nextVersionId = event.target.value;
    setTemplateVersionId(nextVersionId);
    const matched = publishedVersions.find(
      /** Khớp đúng UUID snapshot đã công bố để lấy mã model tương ứng. */
      (v) => v.id === nextVersionId,
    );
    setModel(matched ? matched.model : '');
  }

  /** Kiểm tra cơ bản phía UI và gửi `POST /api/v1/devices` với đúng `templateVersionId` UUID pin. */
  function handleFormSubmit(event: FormEvent<HTMLFormElement>): void {
    event.preventDefault();
    const nextErrors: ApiFieldError[] = [];
    if (!validateCanonicalSerial(serial)) {
      nextErrors.push({ path: '/serial', code: 'FORMAT' });
    }
    if (name.normalize('NFC').trim().length < 1) {
      nextErrors.push({ path: '/name', code: 'REQUIRED' });
    }
    if (!templateVersionId) {
      nextErrors.push({ path: '/templateVersionId', code: 'REQUIRED' });
    }
    if (!model.trim()) {
      nextErrors.push({ path: '/model', code: 'REQUIRED' });
    }
    if (!ownerId) {
      nextErrors.push({ path: '/ownerId', code: 'REQUIRED' });
    }
    setLocalErrors(nextErrors);
    if (nextErrors.length > 0) {
      errorSummaryRef.current?.focus();
      return;
    }
    onSubmitRegister({
      serial,
      name,
      model,
      templateVersionId,
      ownerId,
    });
  }

  /** Gửi tra cứu exact canonical serial qua `GET /api/v1/devices?serial=...`. */
  function handleLookupSubmit(event: FormEvent<HTMLFormElement>): void {
    event.preventDefault();
    if (!validateCanonicalSerial(lookupSerial)) {
      setLocalErrors([{ path: '/serial', code: 'FORMAT' }]);
      return;
    }
    setLocalErrors([]);
    onLookupBySerial(lookupSerial);
  }

  /** Chuyển tiêu điểm bàn phím thẳng tới control bị lỗi từ hộp tóm tắt. */
  function handleErrorLinkClick(event: MouseEvent<HTMLAnchorElement>): void {
    event.preventDefault();
    const targetId = event.currentTarget.dataset.targetId;
    if (!targetId) return;
    document.getElementById(targetId)?.focus();
  }

  /** Cập nhật phương thức setup tiếp theo (`USB` hoặc `QR_BLE`) mà không tự động kích hoạt cấp secret. */
  function handleSetupChoiceClick(event: MouseEvent<HTMLButtonElement>): void {
    const method = event.currentTarget.dataset.method as SetupMethod | undefined;
    if (method) onSelectSetupMethod(method);
  }

  const recoveryComparison = outcome?.kind === 'unknown_recovery' && outcome.recoveredDevice
    ? assessSerialRecoveryOutcome(outcome.intent, outcome.recoveredDevice)
    : null;

  return (
    <div className="dev-stack">
      <section className="dev-card" aria-labelledby="dev-reg-heading">
        <div className="dev-head">
          <div>
            <h2 id="dev-reg-heading">1. Đăng ký thiết bị mới (WB-04 · FEAT-TN-007)</h2>
            <p className="dev-hint">
              Pin chính xác <code>templateVersionId</code> UUID đã công bố và chọn owner <code>ACTIVE</code> trong cùng workspace.
              Đăng ký thành công chỉ tạo trạng thái <code>REGISTERED</code> / <code>UNKNOWN</code>, chưa cấp credential hay báo trực tuyến.
            </p>
          </div>
        </div>

        {allFieldErrors.length > 0 ? (
          <div id="dev-error-summary" ref={errorSummaryRef} tabIndex={-1} role="alert" className="dev-error-summary">
            <strong>Không thể đăng ký thiết bị: có {allFieldErrors.length} lỗi cần kiểm tra</strong>
            <ul>
              {allFieldErrors.map(
                /** Liên kết lỗi về đúng control nhập liệu trong form D4. */
                (item, idx) => {
                  const targetId = deviceFieldPathToId(item.path);
                  return (
                    <li key={`${item.path}-${item.code}-${idx}`}>
                      <a href={`#${targetId}`} data-target-id={targetId} onClick={handleErrorLinkClick}>
                        <span className="dev-mono">{item.path}</span> ({item.code})
                      </a>
                    </li>
                  );
                },
              )}
            </ul>
          </div>
        ) : null}

        {outcome?.kind === 'duplicate_409' ? (
          <div className="dev-notice dev-notice-error" role="alert">
            <p><strong>{outcome.message}</strong></p>
          </div>
        ) : null}

        {outcome?.kind === 'not_found_404' || outcome?.kind === 'error' ? (
          <div className="dev-notice dev-notice-error" role="alert">
            <p><strong>{outcome.message}</strong></p>
          </div>
        ) : null}

        {outcome?.kind === 'unknown_recovery' ? (
          <div className="dev-notice dev-notice-warning" role="alert">
            <p><strong>{outcome.message}</strong></p>
            {recoveryComparison === 'MATCHES_INTENT' && outcome.recoveredDevice ? (
              <p className="dev-hint">
                Đã có registry khớp cấu hình cho serial <span className="dev-mono">{outcome.recoveredDevice.serial}</span>{' '}
                (Device ID: <span className="dev-mono">{outcome.recoveredDevice.id}</span>). Bạn có thể chọn bước thiết lập bên dưới.
              </p>
            ) : recoveryComparison === 'CONFLICTS_WITH_INTENT' && outcome.recoveredDevice ? (
              <p className="dev-hint">
                Cảnh báo xung đột: serial <span className="dev-mono">{outcome.recoveredDevice.serial}</span> đã tồn tại trong workspace với owner/model/templateVersionId khác ý định vừa gửi. Không tự động ghi đè hoặc khởi tạo setup.
              </p>
            ) : (
              <p className="dev-hint">
                Không tìm thấy serial này trong workspace hiện hành (hoặc serial đang thuộc workspace khác). Bạn có thể chủ động kiểm tra lại và gửi lại nếu cần.
              </p>
            )}
          </div>
        ) : null}

        <form onSubmit={handleFormSubmit} noValidate className="dev-form-grid" aria-busy={isSubmitting}>
          <div className="dev-field">
            <label htmlFor="dev-field-serial">Serial thiết bị (Canonical ASCII, phân biệt hoa thường)*</label>
            <input
              id="dev-field-serial"
              name="serial"
              autoComplete="off"
              className="dev-input dev-mono"
              type="text"
              value={serial}
              disabled={isSubmitting}
              aria-required="true"
              aria-invalid={Boolean(errorMap.get('/serial'))}
              aria-describedby={errorMap.get('/serial') ? 'dev-field-serial-hint dev-field-serial-error' : 'dev-field-serial-hint'}
              placeholder="synthetic-room-001"
              onChange={
                /** Giữ nguyên từng ký tự serial theo policy OQ-DEVICE-001, không trim/casefold. */
                (e) => setSerial(e.target.value)
              }
            />
            <p id="dev-field-serial-hint" className="dev-hint">1–64 ký tự ASCII <code>[A-Za-z0-9._:-]</code>, bắt đầu bằng chữ/số, không khoảng trắng.</p>
            {errorMap.get('/serial') ? <p id="dev-field-serial-error" className="dev-field-error">{errorMap.get('/serial')}</p> : null}
          </div>

          <div className="dev-field">
            <label htmlFor="dev-field-name">Tên thiết bị*</label>
            <input
              id="dev-field-name"
              name="name"
              autoComplete="off"
              className="dev-input"
              type="text"
              value={name}
              disabled={isSubmitting}
              aria-required="true"
              aria-invalid={Boolean(errorMap.get('/name'))}
              aria-describedby={errorMap.get('/name') ? 'dev-field-name-error' : undefined}
              placeholder="Quạt phòng lab A"
              onChange={
                /** Cập nhật tên thiết bị đang nhập trong bộ nhớ form. */
                (e) => setName(e.target.value)
              }
            />
            {errorMap.get('/name') ? <p id="dev-field-name-error" className="dev-field-error">{errorMap.get('/name')}</p> : null}
          </div>

          <div className="dev-field">
            <label htmlFor="dev-field-version">TemplateVersion đã công bố (UUID pin)*</label>
            <select
              id="dev-field-version"
              name="templateVersionId"
              autoComplete="off"
              className="dev-select dev-mono"
              value={templateVersionId}
              disabled={isLoadingDeps || isSubmitting}
              aria-required="true"
              aria-invalid={Boolean(errorMap.get('/templateVersionId'))}
              aria-describedby={errorMap.get('/templateVersionId') ? 'dev-field-version-error' : undefined}
              onChange={handleVersionChange}
            >
              <option value="">
                {isLoadingDeps ? 'Đang tải phiên bản đã công bố…' : '-- Chọn phiên bản PUBLISHED (chính xác UUID) --'}
              </option>
              {publishedVersions.map(
                /** Chỉ hiển thị các bản đã PUBLISHED để tránh pin nhầm bản DRAFT. */
                (version) => (
                  <option key={version.id} value={version.id}>
                    {version.name} ({version.model}) · v{version.version} · {version.id}
                  </option>
                ),
              )}
            </select>
            {errorMap.get('/templateVersionId') ? (
              <p id="dev-field-version-error" className="dev-field-error">{errorMap.get('/templateVersionId')}</p>
            ) : null}
          </div>

          <div className="dev-field">
            <label htmlFor="dev-field-model">Mã model khớp phiên bản*</label>
            <input
              id="dev-field-model"
              name="model"
              autoComplete="off"
              className="dev-input dev-mono"
              type="text"
              value={model}
              readOnly
              aria-required="true"
              aria-invalid={Boolean(errorMap.get('/model'))}
              aria-describedby={errorMap.get('/model') ? 'dev-field-model-hint dev-field-model-error' : 'dev-field-model-hint'}
              placeholder="Tự điền theo phiên bản đã chọn"
            />
            <p id="dev-field-model-hint" className="dev-hint">Khớp chính xác mã model của TemplateVersion đã pin (OQ-DEVICE-003).</p>
            {errorMap.get('/model') ? <p id="dev-field-model-error" className="dev-field-error">{errorMap.get('/model')}</p> : null}
          </div>

          <div className="dev-field dev-field-full">
            <label htmlFor="dev-field-owner">Chủ sở hữu thiết bị (Thành viên ACTIVE trong workspace)*</label>
            <select
              id="dev-field-owner"
              name="ownerId"
              autoComplete="off"
              className="dev-select"
              value={ownerId}
              disabled={isLoadingDeps || isSubmitting}
              aria-required="true"
              aria-invalid={Boolean(errorMap.get('/ownerId'))}
              aria-describedby={errorMap.get('/ownerId') ? 'dev-field-owner-error' : undefined}
              onChange={
                /** Cập nhật UUID ownerId của thành viên ACTIVE được chọn. */
                (e) => setOwnerId(e.target.value)
              }
            >
              <option value="">
                {isLoadingDeps ? 'Đang tải danh sách thành viên ACTIVE…' : '-- Chọn chủ sở hữu ACTIVE --'}
              </option>
              {activeMembers.map(
                /** Liệt kê chỉ thành viên ACTIVE thuộc đúng workspace hiện tại. */
                (member) => (
                  <option key={member.userId} value={member.userId}>
                    {member.alias ? `${member.alias} (${member.email})` : member.email} — {member.role} · {member.userId}
                  </option>
                ),
              )}
            </select>
            {errorMap.get('/ownerId') ? <p id="dev-field-owner-error" className="dev-field-error">{errorMap.get('/ownerId')}</p> : null}
          </div>

          <div className="dev-actions-row dev-field-full">
            <button type="submit" className="dev-btn dev-btn-primary" disabled={isLoadingDeps || isSubmitting}>
              {isSubmitting ? 'Đang đăng ký thiết bị…' : 'Đăng ký thiết bị'}
            </button>
          </div>
        </form>
      </section>

      <section className="dev-card" aria-labelledby="dev-lookup-heading">
        <div className="dev-head">
          <div>
            <h2 id="dev-lookup-heading">2. Tra cứu / Phục hồi theo exact Serial</h2>
            <p className="dev-hint">
              Truy vấn phạm vi workspace hiện hành bằng <code>GET /api/v1/devices?serial=...</code> để đối soát sau mất phản hồi hoặc mở thiết bị <code>REGISTERED</code> nạp credential.
            </p>
          </div>
        </div>
        <form onSubmit={handleLookupSubmit} noValidate className="dev-lookup-row">
          <div className="dev-field">
            <label htmlFor="dev-lookup-serial">Serial cần tra cứu chính xác</label>
            <input
              id="dev-lookup-serial"
              name="lookupSerial"
              autoComplete="off"
              className="dev-input dev-mono"
              type="text"
              value={lookupSerial}
              disabled={isSubmitting}
              placeholder="synthetic-room-001"
              onChange={
                /** Giữ nguyên chuỗi serial cần tìm kiếm theo đúng chữ hoa/thường. */
                (e) => setLookupSerial(e.target.value)
              }
            />
          </div>
          <button type="submit" className="dev-btn" disabled={isSubmitting}>
            Tra cứu theo serial
          </button>
        </form>
      </section>

      {selectedDevice ? (
        <section className="dev-card" aria-labelledby="dev-status-heading">
          <div className="dev-head">
            <div>
              <h2 id="dev-status-heading">3. Trạng thái Registry &amp; Lựa chọn thiết lập (D4)</h2>
              <p className="dev-hint">
                Device ID: <span className="dev-mono">{selectedDevice.id}</span> · Serial:{' '}
                <span className="dev-mono">{selectedDevice.serial}</span>
              </p>
            </div>
            <div className="dev-badge-row">
              <span className="dev-badge dev-badge-info">Lifecycle: {selectedDevice.lifecycle}</span>
              <span className="dev-badge dev-badge-neutral">Connectivity: {selectedDevice.connectivity}</span>
              <span className="dev-badge dev-badge-warn">
                Credential: {selectedDevice.credentialStatus} (Chưa cấp credential)
              </span>
            </div>
          </div>

          <dl className="dev-meta-grid">
            <div>
              <dt>Pinned templateVersionId (UUID)</dt>
              <dd className="dev-mono">{selectedDevice.templateVersionId}</dd>
            </div>
            <div>
              <dt>Model</dt>
              <dd className="dev-mono">{selectedDevice.model}</dd>
            </div>
            <div>
              <dt>Owner ID</dt>
              <dd className="dev-mono">{selectedDevice.ownerId}</dd>
            </div>
            <div>
              <dt>Bảo trì / Last seen</dt>
              <dd>{selectedDevice.maintenance} · {selectedDevice.lastSeen ?? 'Chưa có hello'}</dd>
            </div>
          </dl>

          <div className="dev-subcard">
            <strong>Chọn phương thức nạp thiết lập (không tự động phát credential):</strong>
            <div className="dev-actions-row">
              <button
                type="button"
                className={`dev-btn ${selectedSetupMethod === 'USB' ? 'dev-btn-primary' : ''}`}
                data-method="USB"
                aria-pressed={selectedSetupMethod === 'USB'}
                onClick={handleSetupChoiceClick}
              >
                Nạp qua Web USB (FEAT-TN-008)
              </button>
              <button
                type="button"
                className={`dev-btn ${selectedSetupMethod === 'QR_BLE' ? 'dev-btn-primary' : ''}`}
                data-method="QR_BLE"
                aria-pressed={selectedSetupMethod === 'QR_BLE'}
                onClick={handleSetupChoiceClick}
              >
                Onboarding QR / BLE (Android FEAT-TN-049–052)
              </button>
            </div>

            {selectedSetupMethod === 'QR_BLE' ? (
              <div className="dev-notice dev-notice-info" role="status">
                <p>
                  <strong>Hướng dẫn QR / BLE:</strong> Quét QR hoặc kết nối BLE trên ứng dụng Android đã đăng nhập để ghép nối thiết bị{' '}
                  <span className="dev-mono">{selectedDevice.id}</span>. Web không cấp hoặc hiển thị mã BLE escrow/installation proof.
                </p>
              </div>
            ) : null}
          </div>
        </section>
      ) : null}
    </div>
  );
}
