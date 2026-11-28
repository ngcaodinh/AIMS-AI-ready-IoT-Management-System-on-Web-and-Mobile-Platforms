import { useEffect, useRef, useState, type FormEvent } from 'react';
import { isContractUuid, WorkspaceApiError } from '../workspace/workspaceApi.ts';
import {
  canClaimUsbCredential,
  type DeviceDto,
  type ProvisioningOperationDto,
  type SetupMethod,
} from './deviceContract.ts';
import {
  pollProvisioningOperationApi,
  type LiveDeviceContext,
} from './deviceApi.ts';

interface UsbCredentialPanelProps {
  ctx: LiveDeviceContext;
  device: DeviceDto | null;
  setupMethod: SetupMethod | null;
  onAuthError: (code: string) => void;
}

// Chu kỳ poll metadata tối đa khi broker adapter đang PENDING (ms) và số lần poll tự động giới hạn.
const POLL_INTERVAL_MS = 1_500;
const MAX_AUTO_POLLS = 12;

/**
 * Giao diện thăm dò metadata Web USB cho FEAT-TN-008 CRED-4:
 * kích hoạt đầy đủ `GET /api/v1/provisioning-operations/{id}` cho mọi discriminator
 * (`CREDENTIAL`, `DEVICE_LIFECYCLE`, `ENROLLMENT_CLEANUP`), đồng thời vô hiệu hóa rõ ràng
 * các thao tác cấp mới (`POST /devices/{id}/credentials`) và claim (`POST /claim-credential`)
 * cho tới khi provider escrow/broker thật được nạp vào runtime.
 * Input
 * Param: props — ngữ cảnh API workspace, thiết bị đang chọn (nếu có), phương thức nạp và callback hết hạn phiên.
 * Output: thẻ điều phối thăm dò metadata operation không lưu bí mật bền vững.
 */
export function UsbCredentialPanel({ ctx, device, setupMethod, onAuthError }: UsbCredentialPanelProps) {
  const [operationIdInput, setOperationIdInput] = useState<string>('');
  const [inputError, setInputError] = useState<string>('');
  const [operation, setOperation] = useState<ProvisioningOperationDto | null>(null);
  const [isBusy, setIsBusy] = useState<boolean>(false);
  const [isPolling, setIsPolling] = useState<boolean>(false);
  const [statusMessage, setStatusMessage] = useState<string>('');
  const [errorBanner, setErrorBanner] = useState<{ code: string; message: string } | null>(null);

  const generationRef = useRef<number>(0);
  const abortRef = useRef<AbortController | null>(null);

  /** Xóa trạng thái operation cục bộ và hủy mọi poll đang chạy khi đổi thiết bị hoặc workspace. */
  useEffect(() => {
    generationRef.current += 1;
    abortRef.current?.abort();
    setOperationIdInput('');
    setInputError('');
    setOperation(null);
    setIsBusy(false);
    setIsPolling(false);
    setStatusMessage('');
    setErrorBanner(null);

    /** Hủy toàn bộ timer và request đang chạy khi component unmount. */
    return () => {
      generationRef.current += 1;
      abortRef.current?.abort();
    };
  }, [ctx.workspaceId, device?.id]);

  /** Đẩy lỗi auth/context mismatch về `AuthCoordinator` để khóa giao diện an toàn. */
  function handleBoundaryError(error: unknown): boolean {
    if (error instanceof WorkspaceApiError && [401, 409].includes(error.status)
      && ['SESSION_EXPIRED', 'SESSION_REVOKED', 'AUTH_CONTEXT_MISMATCH', 'CSRF_INVALID'].includes(error.code)) {
      onAuthError(error.code);
      return true;
    }
    return false;
  }

  /**
   * Thăm dò có giới hạn trạng thái operation bằng `GET /provisioning-operations/{id}`; không đọc hay lưu bí mật.
   * Input
   * Param: targetOpId — UUID của `ProvisioningOperation` cần thăm dò.
   * Side effects: cập nhật `operation`, dừng ngay khi rời trạng thái `CREDENTIAL + PENDING`, đạt trần `MAX_AUTO_POLLS` hoặc abort.
   */
  async function pollOperationOnceAndAutoContinue(targetOpId: string): Promise<void> {
    const generation = generationRef.current;
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;

    setIsBusy(true);
    setIsPolling(false);
    setErrorBanner(null);
    setStatusMessage('');

    try {
      const first = await pollProvisioningOperationApi(ctx, targetOpId, controller.signal);
      if (generation !== generationRef.current || controller.signal.aborted) return;
      setOperation(first.operation);

      if (first.operation.kind !== 'CREDENTIAL' || first.operation.status !== 'PENDING') {
        setStatusMessage('Đã tải metadata operation mới nhất (không chứa mật khẩu hoặc secret).');
        return;
      }

      setIsBusy(false);
      setIsPolling(true);
      setStatusMessage('Operation đang ở trạng thái PENDING. Đang tự động thăm dò metadata có giới hạn…');

      let attempts = 1;
      while (attempts < MAX_AUTO_POLLS && generation === generationRef.current && !controller.signal.aborted) {
        await new Promise<void>((resolve) => {
          const timer = window.setTimeout(resolve, POLL_INTERVAL_MS);
          controller.signal.addEventListener(
            'abort',
            /** Hủy timer chờ poll ngay khi đổi thiết bị/workspace hoặc unmount. */
            () => {
              window.clearTimeout(timer);
              resolve();
            },
            { once: true },
          );
        });
        if (generation !== generationRef.current || controller.signal.aborted) return;

        attempts += 1;
        const nextPoll = await pollProvisioningOperationApi(ctx, targetOpId, controller.signal);
        if (generation !== generationRef.current || controller.signal.aborted) return;
        setOperation(nextPoll.operation);
        if (nextPoll.operation.kind !== 'CREDENTIAL' || nextPoll.operation.status !== 'PENDING') {
          setStatusMessage('Operation đã rời trạng thái PENDING.');
          break;
        }
      }
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') return;
      if (generation !== generationRef.current) return;
      if (handleBoundaryError(error)) return;
      setErrorBanner({
        code: error instanceof WorkspaceApiError ? error.code : 'NETWORK_ERROR',
        message: error instanceof WorkspaceApiError
          ? `Không thể thăm dò operation (${error.code}).`
          : 'Không thể thăm dò trạng thái operation do lỗi mạng.',
      });
    } finally {
      if (generation === generationRef.current && !controller.signal.aborted) {
        setIsBusy(false);
        setIsPolling(false);
      }
    }
  }

  /**
   * Kiểm tra UUID hợp lệ và kích hoạt `GET /provisioning-operations/{id}` theo form người dùng nhập.
   * Input
   * Param: event — sự kiện submit form thăm dò operation.
   */
  async function handlePollFormSubmit(event: FormEvent<HTMLFormElement>): Promise<void> {
    event.preventDefault();
    if (isBusy) return;
    const trimmed = operationIdInput.trim();
    if (!isContractUuid(trimmed)) {
      setInputError('Cần nhập Operation ID dạng UUID hợp lệ.');
      return;
    }
    setInputError('');
    await pollOperationOnceAndAutoContinue(trimmed);
  }

  /** Làm mới metadata một lần cho `operation` đang hiển thị trên màn hình. */
  async function handleRefreshOperation(): Promise<void> {
    if (!operation || isBusy) return;
    const opId = operation.kind === 'ENROLLMENT_CLEANUP' ? operation.id : operation.operationId;
    await pollOperationOnceAndAutoContinue(opId);
  }

  return (
    <section className="dev-card" aria-labelledby="dev-usb-heading">
      <div className="dev-head">
        <div>
          <h2 id="dev-usb-heading">4. Thăm dò Operation &amp; Credential USB (FEAT-TN-008)</h2>
          <p className="dev-hint">
            Chỉ lộ metadata qua <code>GET /provisioning-operations/{'{id}'}</code>; không đọc hoặc lưu secret vào
            bộ nhớ trình duyệt bền vững hay URL.
            {device
              ? ` Thiết bị đang chọn: ${device.serial} (${device.lifecycle}${setupMethod ? ` · ${setupMethod}` : ''}).`
              : ' Bạn có thể tra cứu trực tiếp metadata theo UUID operation trong workspace hiện hành.'}
          </p>
        </div>
        <div className="dev-actions-row">
          <button
            type="button"
            className="dev-btn dev-btn-primary"
            disabled
            aria-disabled="true"
            aria-describedby="dev-usb-issue-unavailable"
          >
            Cấp credential USB (Chưa khả dụng)
          </button>
          {operation ? (
            <button type="button" className="dev-btn" disabled={isBusy} onClick={handleRefreshOperation}>
              Kiểm tra lại trạng thái
            </button>
          ) : null}
        </div>
      </div>

      <p id="dev-usb-issue-unavailable" className="dev-hint">
        Thao tác phát hành mới (<code>POST /devices/{'{id}'}/credentials</code>) và nhận một lần (<code>POST /provisioning-operations/{'{id}'}/claim-credential</code>) chưa khả dụng cho tới khi provider escrow và broker adapter hoàn tất.
      </p>

      <form className="dev-subcard" onSubmit={handlePollFormSubmit} noValidate>
        <div className="dev-form-grid">
          <div className="dev-field dev-field-full">
            <label htmlFor="dev-poll-op-id">Operation ID cần thăm dò (UUID)</label>
            <div className="dev-actions-row">
              <input
                id="dev-poll-op-id"
                name="operationId"
                type="text"
                autoComplete="off"
                className="dev-input dev-mono"
                value={operationIdInput}
                onChange={
                  /** Cập nhật UUID operation người dùng nhập và xóa thông báo lỗi định dạng cũ. */
                  (e) => {
                    setOperationIdInput(e.target.value);
                    if (inputError) setInputError('');
                  }
                }
                aria-invalid={Boolean(inputError)}
                aria-describedby={inputError ? 'dev-poll-op-error' : undefined}
                placeholder="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
                disabled={isBusy}
              />
              <button type="submit" className="dev-btn" disabled={isBusy || isPolling}>
                {isBusy || isPolling ? 'Đang thăm dò…' : 'Thăm dò metadata operation'}
              </button>
            </div>
            {inputError ? <p id="dev-poll-op-error" className="dev-field-error">{inputError}</p> : null}
          </div>
        </div>
      </form>

      {statusMessage ? (
        <div className="dev-notice dev-notice-info" role="status">
          <p>{statusMessage}</p>
        </div>
      ) : null}

      {errorBanner ? (
        <div className="dev-notice dev-notice-error" role="alert">
          <p><strong>{errorBanner.message}</strong></p>
        </div>
      ) : null}

      {operation ? (
        <div className="dev-subcard">
          {operation.kind === 'CREDENTIAL' ? (
            <>
              <div className="dev-badge-row">
                <span className="dev-badge dev-badge-info">Kind: CREDENTIAL</span>
                <span className="dev-badge dev-badge-neutral">DeliveryMode: {operation.deliveryMode}</span>
                <span className={`dev-badge ${operation.status === 'READY' ? 'dev-badge-ok' : operation.status === 'FAILED' ? 'dev-badge-error' : 'dev-badge-warn'}`}>
                  Operation: {operation.status}
                </span>
                <span className="dev-badge dev-badge-neutral">Delivery: {operation.deliveryStatus}</span>
                <span className="dev-badge dev-badge-neutral">Retry: {operation.retryCount}</span>
              </div>

              <div className="dev-meta-line">
                <span>Operation ID: <span className="dev-mono">{operation.operationId}</span></span>
                {operation.escrowExpiresAt ? <span>Hạn escrow: {operation.escrowExpiresAt}</span> : null}
                {operation.claimedAt ? <span>Đã claim lúc: {operation.claimedAt}</span> : null}
                {operation.errorCode ? <span>Mã lỗi: <span className="dev-mono">{operation.errorCode}</span></span> : null}
              </div>

              {operation.deliveryMode !== 'USB_ONE_TIME' ? (
                <div className="dev-notice dev-notice-warning" role="status">
                  <p>Operation thuộc kênh <code>{operation.deliveryMode}</code> nên chỉ hiển thị metadata ở chế độ chỉ đọc trên Web.</p>
                </div>
              ) : null}

              {canClaimUsbCredential(operation) ? (
                <div className="dev-actions-row">
                  <button
                    type="button"
                    className="dev-btn dev-btn-primary"
                    disabled
                    aria-disabled="true"
                    aria-describedby="dev-usb-claim-unavailable"
                  >
                    Nhận gói credential một lần / Claim (Chưa khả dụng)
                  </button>
                  <span id="dev-usb-claim-unavailable" className="dev-hint">
                    Claim secret một lần chưa khả dụng trên batch hiện tại; trạng thái escrow chỉ hiển thị dưới dạng metadata.
                  </span>
                </div>
              ) : null}

              {operation.deliveryStatus === 'CLAIMED' || operation.deliveryStatus === 'EXPIRED' || operation.status === 'FAILED' ? (
                <p className="dev-hint">
                  Bí mật không còn khả dụng qua poll hoặc replay. Nếu thất lạc gói cấu hình trước khi nạp USB, cần thu hồi và cấp mới khi provider sẵn sàng.
                </p>
              ) : null}
            </>
          ) : operation.kind === 'DEVICE_LIFECYCLE' ? (
            <div className="dev-notice dev-notice-info" role="status">
              <p>
                <strong>Operation vòng đời ({operation.type}):</strong> Trạng thái {operation.status} · Lifecycle {operation.lifecycle} · Broker {operation.brokerStatus}. Không có thao tác lấy bí mật ở loại operation này.
              </p>
            </div>
          ) : (
            <div className="dev-notice dev-notice-info" role="status">
              <p>
                <strong>Operation dọn dẹp enrollment:</strong> State {operation.state} · Lý do {operation.reason} · Broker revocation {operation.brokerRevocation}. Chỉ hiển thị metadata.
              </p>
            </div>
          )}
        </div>
      ) : null}
    </section>
  );
}
