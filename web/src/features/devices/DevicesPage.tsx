import { useEffect, useMemo, useRef, useState } from 'react';
import type { SessionMetadata } from '../auth/api.ts';
import type { TemplateVersionDto } from '../templates/templateContract.ts';
import { WorkspaceApiError } from '../workspace/workspaceApi.ts';
import {
  listActiveOwnersForRegistrationApi,
  listPublishedVersionsForRegistrationApi,
  recoverDeviceBySerialApi,
  registerDeviceApi,
} from './deviceApi.ts';
import {
  assessSerialRecoveryOutcome,
  type DeviceCreateInput,
  type DeviceDto,
  type SetupMethod,
  type WorkspaceActiveMemberDto,
} from './deviceContract.ts';
import { DeviceRegistrationPanel, type RegistrationOutcome } from './DeviceRegistrationPanel.tsx';
import { UsbCredentialPanel } from './UsbCredentialPanel.tsx';
import './devices.css';

interface DevicesPageProps {
  workspaceId: string;
  workspaceName: string;
  workspaceRole: 'ADMIN' | 'USER';
  session: SessionMetadata;
  onAuthError: (code: string) => void;
}

/**
 * Trang điều phối WB-04 cho FEAT-TN-007 D4 (đăng ký/khôi phục/chọn setup) và FEAT-TN-008 CRED-4 (Web USB credential),
 * bảo đảm hủy toàn bộ request và xóa mọi state/secret thiết bị khi đổi workspace.
 * Input
 * Param: props — workspace đang chọn, vai trò hiện tại và metadata phiên trong RAM.
 * Output: màn hình nghiệp vụ WB-04 hoàn chỉnh theo hợp đồng G1.
 */
export function DevicesPage({
  workspaceId,
  workspaceName,
  workspaceRole,
  session,
  onAuthError,
}: DevicesPageProps) {
  const [publishedVersions, setPublishedVersions] = useState<TemplateVersionDto[]>([]);
  const [activeMembers, setActiveMembers] = useState<WorkspaceActiveMemberDto[]>([]);
  const [isLoadingDeps, setIsLoadingDeps] = useState<boolean>(true);
  const [isSubmitting, setIsSubmitting] = useState<boolean>(false);
  const [outcome, setOutcome] = useState<RegistrationOutcome>(null);
  const [selectedDevice, setSelectedDevice] = useState<DeviceDto | null>(null);
  const [selectedSetupMethod, setSelectedSetupMethod] = useState<SetupMethod | null>(null);
  const [errorFocusNonce, setErrorFocusNonce] = useState<number>(0);

  const generationRef = useRef<number>(0);
  // Tách riêng controller tải phụ thuộc ban đầu với controller thao tác người dùng để tra cứu serial không hủy việc nạp dropdown.
  const depsAbortRef = useRef<AbortController | null>(null);
  const actionAbortRef = useRef<AbortController | null>(null);
  const ctx = useMemo(
    /** Gói ngữ cảnh workspace và phiên hiện hành để dùng cho mọi API thiết bị/credential. */
    () => ({ workspaceId, session }),
    [workspaceId, session],
  );

  /** Kiểm tra lỗi phiên/CSRF/context để trả quyền xử lý lại cho `AuthCoordinator`. */
  function forwardAuthBoundary(error: unknown): boolean {
    if (error instanceof WorkspaceApiError && [401, 409].includes(error.status)
      && ['SESSION_EXPIRED', 'SESSION_REVOKED', 'AUTH_CONTEXT_MISMATCH', 'CSRF_INVALID'].includes(error.code)) {
      onAuthError(error.code);
      return true;
    }
    return false;
  }

  /** Hủy request cũ và xóa sạch mọi dữ liệu phụ thuộc khi chuyển sang workspace khác. */
  useEffect(() => {
    generationRef.current += 1;
    depsAbortRef.current?.abort();
    actionAbortRef.current?.abort();
    const controller = new AbortController();
    depsAbortRef.current = controller;
    const generation = generationRef.current;

    setPublishedVersions([]);
    setActiveMembers([]);
    setOutcome(null);
    setSelectedDevice(null);
    setSelectedSetupMethod(null);

    if (workspaceRole !== 'ADMIN') {
      setIsLoadingDeps(false);
      /** Hủy toàn bộ request tải phụ thuộc và thao tác khi rời workspace hoặc unmount. */
      return () => {
        controller.abort();
        actionAbortRef.current?.abort();
      };
    }

    setIsLoadingDeps(true);
    /** Nạp danh sách phiên bản đã công bố và thành viên ACTIVE trong đúng workspace hiện tại. */
    async function loadDependencies(): Promise<void> {
      try {
        const [versions, members] = await Promise.all([
          listPublishedVersionsForRegistrationApi(ctx, controller.signal),
          listActiveOwnersForRegistrationApi(ctx, controller.signal),
        ]);
        if (generation !== generationRef.current || controller.signal.aborted) return;
        setPublishedVersions(versions);
        setActiveMembers(members);
      } catch (error) {
        if (error instanceof DOMException && error.name === 'AbortError') return;
        if (generation !== generationRef.current) return;
        if (forwardAuthBoundary(error)) return;
        setOutcome({
          kind: 'error',
          message: `Chưa thể tải danh sách phiên bản/chủ sở hữu (${error instanceof WorkspaceApiError ? error.code : 'NETWORK_ERROR'}).`,
        });
      } finally {
        if (generation === generationRef.current && !controller.signal.aborted) {
          setIsLoadingDeps(false);
        }
      }
    }
    void loadDependencies();
    /** Hủy toàn bộ request tải phụ thuộc và thao tác khi đổi workspace hoặc unmount. */
    return () => {
      controller.abort();
      actionAbortRef.current?.abort();
    };
  }, [ctx, workspaceRole]);

  /** Gửi đăng ký thiết bị mới (`POST /api/v1/devices`) và đối soát `GET /devices?serial=` khi mất ACK 201. */
  async function handleSubmitRegister(input: DeviceCreateInput): Promise<void> {
    if (isSubmitting) return;
    const generation = generationRef.current;
    actionAbortRef.current?.abort();
    const controller = new AbortController();
    actionAbortRef.current = controller;
    setIsSubmitting(true);
    setOutcome(null);
    setSelectedSetupMethod(null);

    try {
      const created = await registerDeviceApi(ctx, input, controller.signal);
      if (generation !== generationRef.current || controller.signal.aborted) return;
      setSelectedDevice(created);
      setOutcome({ kind: 'created', device: created });
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') return;
      if (generation !== generationRef.current) return;
      if (forwardAuthBoundary(error)) return;
      if (error instanceof WorkspaceApiError) {
        if (error.status === 409 && error.code === 'DEVICE_EXISTS') {
          setOutcome({
            kind: 'duplicate_409',
            message: 'Serial này đã được đăng ký trong hệ thống (409 DEVICE_EXISTS). Hãy kiểm tra lại serial trên thiết bị.',
          });
          return;
        }
        if (error.status === 422) {
          setOutcome({
            kind: 'validation_422',
            message: `Đăng ký bị từ chối (${error.code}).`,
            fieldErrors: error.fieldErrors,
          });
          setErrorFocusNonce((n) => n + 1);
          return;
        }
        if (error.status === 404) {
          setOutcome({
            kind: 'not_found_404',
            message: 'Không tìm thấy phiên bản template hoặc tài nguyên trong workspace hiện hành (404).',
          });
          return;
        }
        if (error.status === 0 || error.status >= 500) {
          // Mất phản hồi 201: đối soát bằng exact serial trong workspace hiện tại (WEB-DEVICE-004).
          try {
            const page = await recoverDeviceBySerialApi(ctx, input.serial, controller.signal);
            if (generation !== generationRef.current || controller.signal.aborted) return;
            const found = page.items[0] ?? null;
            const status = found ? assessSerialRecoveryOutcome(input, found) : 'NOT_FOUND_IN_SCOPE';
            if (found && status === 'MATCHES_INTENT') {
              setSelectedDevice(found);
            }
            setOutcome({
              kind: 'unknown_recovery',
              intent: input,
              status,
              recoveredDevice: found,
              message: 'Chưa nhận được phản hồi tạo thiết bị; đã đối soát bằng exact serial trong workspace hiện tại.',
            });
            return;
          } catch {
            setOutcome({
              kind: 'unknown_recovery',
              intent: input,
              status: 'PENDING',
              recoveredDevice: null,
              message: 'Mất kết nối trong lúc đăng ký và chưa thể tra cứu serial. Hãy thử tra cứu serial trước khi gửi lại.',
            });
            return;
          }
        }
        setOutcome({ kind: 'error', message: `Đăng ký thất bại (${error.code}).` });
      }
    } finally {
      if (generation === generationRef.current && !controller.signal.aborted) {
        setIsSubmitting(false);
      }
    }
  }

  /** Tra cứu trực tiếp thiết bị theo exact canonical `serial` để tiếp tục cài đặt USB/QR_BLE. */
  async function handleLookupBySerial(serialQuery: string): Promise<void> {
    if (isSubmitting) return;
    const generation = generationRef.current;
    actionAbortRef.current?.abort();
    const controller = new AbortController();
    actionAbortRef.current = controller;
    setIsSubmitting(true);
    setOutcome(null);
    setSelectedSetupMethod(null);

    try {
      const page = await recoverDeviceBySerialApi(ctx, serialQuery, controller.signal);
      if (generation !== generationRef.current || controller.signal.aborted) return;
      const found = page.items[0] ?? null;
      if (!found) {
        setSelectedDevice(null);
        setOutcome({
          kind: 'not_found_404',
          message: 'Không tìm thấy thiết bị có serial này trong workspace hiện tại.',
        });
        return;
      }
      setSelectedDevice(found);
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') return;
      if (generation !== generationRef.current) return;
      if (!forwardAuthBoundary(error)) {
        setOutcome({
          kind: 'error',
          message: `Không thể tra cứu serial (${error instanceof WorkspaceApiError ? error.code : 'NETWORK_ERROR'}).`,
        });
      }
    } finally {
      if (generation === generationRef.current && !controller.signal.aborted) {
        setIsSubmitting(false);
      }
    }
  }

  if (workspaceRole !== 'ADMIN') {
    return (
      <section className="dev-card" aria-labelledby="dev-denied-heading">
        <h2 id="dev-denied-heading">Đăng ký &amp; Credential thiết bị (WB-04)</h2>
        <div className="dev-notice dev-notice-warning" role="alert">
          <p>Vai trò <strong>USER</strong> trong workspace <strong>{workspaceName}</strong> không có quyền đăng ký thiết bị hoặc cấp credential MQTT.</p>
        </div>
      </section>
    );
  }

  return (
    <div className="dev-workbench">
      <DeviceRegistrationPanel
        publishedVersions={publishedVersions}
        activeMembers={activeMembers}
        isLoadingDeps={isLoadingDeps}
        isSubmitting={isSubmitting}
        outcome={outcome}
        selectedDevice={selectedDevice}
        selectedSetupMethod={selectedSetupMethod}
        errorFocusNonce={errorFocusNonce}
        onSubmitRegister={handleSubmitRegister}
        onLookupBySerial={handleLookupBySerial}
        onSelectSetupMethod={setSelectedSetupMethod}
      />

      <UsbCredentialPanel ctx={ctx} device={selectedDevice} setupMethod={selectedSetupMethod} onAuthError={onAuthError} />
    </div>
  );
}
