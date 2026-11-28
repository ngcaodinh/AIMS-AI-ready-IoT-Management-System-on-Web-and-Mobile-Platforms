import type { SessionMetadata } from '../auth/api.ts';
import { isContractUuid, workspaceRequest, WorkspaceApiError } from '../workspace/workspaceApi.ts';
import { listTemplatesApi, listTemplateVersionsApi } from '../templates/templateApi.ts';
import type { TemplateVersionDto } from '../templates/templateContract.ts';
import {
  buildDeviceCreatePayload,
  parseActiveMembersPageDto,
  parseClaimCredentialResponse,
  parseCreateCredentialResponse,
  parseDeviceRecoveryPageDto,
  parseDeviceRegisteredDto,
  parseProvisioningPollResponse,
  validateCanonicalSerial,
  type ClaimCredentialResponse,
  type CreateCredentialResponse,
  type DeviceCreateInput,
  type DeviceRecoveryPageDto,
  type DeviceRegisteredDto,
  type ProvisioningPollResponse,
  type WorkspaceActiveMemberDto,
} from './deviceContract.ts';

export interface LiveDeviceContext {
  workspaceId: string;
  session: SessionMetadata;
}

/**
 * Tải toàn bộ danh sách phiên bản template đã công bố (`PUBLISHED`) trong workspace hiện tại
 * để form đăng ký thiết bị D4 chỉ chọn được đúng `templateVersionId` UUID bất biến, không bao giờ chọn draft.
 * Input
 * Param: ctx — ngữ cảnh workspace và metadata phiên.
 * Param: signal — tín hiệu hủy khi người dùng đổi workspace.
 * Output: danh sách `TemplateVersionDto` đã công bố kèm tên template cha.
 */
export async function listPublishedVersionsForRegistrationApi(
  ctx: LiveDeviceContext,
  signal?: AbortSignal,
): Promise<TemplateVersionDto[]> {
  const templatesPage = await listTemplatesApi(ctx, { limit: 100, signal });
  const versionPages = await Promise.all(
    templatesPage.items
      .filter(
        /** Chỉ truy vấn version cho các template đã từng công bố để giảm request thừa. */
        (tpl) => tpl.latestPublishedVersionId !== null,
      )
      .map(
        /** Tải các phiên bản đã công bố của từng template family trong phạm vi workspace. */
        (tpl) => listTemplateVersionsApi(ctx, tpl.id, { limit: 100, signal }),
      ),
  );
  const collected: TemplateVersionDto[] = [];
  for (const page of versionPages) {
    for (const version of page.items) {
      collected.push(version);
    }
  }
  return collected;
}

/**
 * Tải danh sách thành viên `ACTIVE` trong workspace hiện hành (`GET /api/v1/workspaces/{id}/members?status=ACTIVE`)
 * phục vụ chọn `ownerId` khi đăng ký thiết bị.
 * Input
 * Param: ctx — ngữ cảnh workspace và metadata phiên.
 * Param: signal — tín hiệu hủy khi đổi ngữ cảnh.
 * Output: mảng `WorkspaceActiveMemberDto` có trạng thái `ACTIVE`.
 */
export async function listActiveOwnersForRegistrationApi(
  ctx: LiveDeviceContext,
  signal?: AbortSignal,
): Promise<WorkspaceActiveMemberDto[]> {
  const { body } = await workspaceRequest(
    `/workspaces/${encodeURIComponent(ctx.workspaceId)}/members?status=ACTIVE&limit=100`,
    {
      method: 'GET',
      workspaceId: ctx.workspaceId,
      session: ctx.session,
      signal,
    },
  );
  return parseActiveMembersPageDto(body).items;
}

/**
 * Đăng ký thiết bị mới và pin chính xác `templateVersionId` UUID (`POST /api/v1/devices`).
 * Input
 * Param: ctx — ngữ cảnh workspace và metadata phiên.
 * Param: input — dữ liệu `serial`, `name`, `model`, `templateVersionId`, `ownerId`.
 * Param: signal — tín hiệu hủy khi đổi workspace.
 * Output: `DeviceRegisteredDto` ở trạng thái `REGISTERED`, `UNKNOWN`, `PROVISIONING` kèm `nextStep`.
 * Errors: `409 DEVICE_EXISTS`, `422 OWNER_INVALID/TEMPLATE_NOT_PUBLISHED/MODEL_MISMATCH/VALIDATION_ERROR`, `404`, `503`.
 */
export async function registerDeviceApi(
  ctx: LiveDeviceContext,
  input: DeviceCreateInput,
  signal?: AbortSignal,
): Promise<DeviceRegisteredDto> {
  const payload = buildDeviceCreatePayload(input);
  const { body } = await workspaceRequest('/devices', {
    method: 'POST',
    workspaceId: ctx.workspaceId,
    session: ctx.session,
    body: payload,
    signal,
  });
  return parseDeviceRegisteredDto(body);
}

/**
 * Tra cứu thiết bị theo exact canonical `serial` (`GET /api/v1/devices?serial=...`) trong workspace hiện tại
 * để đối soát khi mất phản hồi 201 (WEB-DEVICE-004).
 * Input
 * Param: ctx — ngữ cảnh workspace và metadata phiên.
 * Param: serial — chuỗi serial nguyên trạng (case-sensitive, không trim).
 * Param: signal — tín hiệu hủy khi đổi workspace.
 * Output: `DeviceRecoveryPageDto` chứa tối đa 1 thiết bị khớp hoặc rỗng nếu chưa tồn tại trong workspace.
 */
export async function recoverDeviceBySerialApi(
  ctx: LiveDeviceContext,
  serial: string,
  signal?: AbortSignal,
): Promise<DeviceRecoveryPageDto> {
  if (!validateCanonicalSerial(serial)) {
    throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: '/serial', code: 'FORMAT' }]);
  }
  const { body } = await workspaceRequest(`/devices?serial=${encodeURIComponent(serial)}`, {
    method: 'GET',
    workspaceId: ctx.workspaceId,
    session: ctx.session,
    signal,
  });
  return parseDeviceRecoveryPageDto(body);
}

/**
 * Yêu cầu cấp credential USB cho thiết bị (`POST /api/v1/devices/{id}/credentials`);
 * gửi body rỗng hoàn toàn kèm `Idempotency-Key` bắt buộc.
 * Input
 * Param: ctx — ngữ cảnh workspace và metadata phiên.
 * Param: deviceId — UUID thiết bị cần cấp credential.
 * Param: idempotencyKey — khóa 16–128 ký tự ASCII in được.
 * Param: signal — tín hiệu hủy khi đổi workspace.
 * Output: `CreateCredentialResponse` (201 bundle một lần, 202 pending, hoặc 200 status replay).
 */
export async function issueDeviceCredentialApi(
  ctx: LiveDeviceContext,
  deviceId: string,
  idempotencyKey: string,
  signal?: AbortSignal,
): Promise<CreateCredentialResponse> {
  if (!isContractUuid(deviceId)) {
    throw new WorkspaceApiError('RESOURCE_NOT_FOUND', 404);
  }
  const { status, body } = await workspaceRequest(`/devices/${encodeURIComponent(deviceId)}/credentials`, {
    method: 'POST',
    workspaceId: ctx.workspaceId,
    session: ctx.session,
    idempotencyKey,
    signal,
  });
  return parseCreateCredentialResponse(status, body);
}

/**
 * Thăm dò trạng thái operation (`GET /api/v1/provisioning-operations/{id}`) theo discriminator `kind` tường minh.
 * Chỉ trả metadata; từ chối mọi secret nếu server/proxy trả sai.
 * Input
 * Param: ctx — ngữ cảnh workspace và metadata phiên.
 * Param: operationId — UUID operation cần kiểm tra.
 * Param: signal — tín hiệu hủy khi đổi workspace hoặc dừng polling.
 * Output: `ProvisioningPollResponse` chỉ chứa metadata an toàn.
 */
export async function pollProvisioningOperationApi(
  ctx: LiveDeviceContext,
  operationId: string,
  signal?: AbortSignal,
): Promise<ProvisioningPollResponse> {
  if (!isContractUuid(operationId)) {
    throw new WorkspaceApiError('RESOURCE_NOT_FOUND', 404);
  }
  const { body } = await workspaceRequest(`/provisioning-operations/${encodeURIComponent(operationId)}`, {
    method: 'GET',
    workspaceId: ctx.workspaceId,
    session: ctx.session,
    signal,
  });
  return parseProvisioningPollResponse(body);
}

/**
 * Tiêu thụ credential USB một lần từ escrow (`POST /api/v1/provisioning-operations/{id}/claim-credential`);
 * gửi body rỗng kèm `Idempotency-Key` mới cho intent claim.
 * Input
 * Param: ctx — ngữ cảnh workspace và metadata phiên.
 * Param: operationId — UUID operation đang READY + AVAILABLE.
 * Param: idempotencyKey — khóa 16–128 ký tự ASCII in được.
 * Param: signal — tín hiệu hủy khi đổi workspace.
 * Output: `ClaimCredentialResponse` (200 `BUNDLE` một lần hoặc `STATUS` khi replay).
 * Errors: `409 CREDENTIAL_NOT_READY / CREDENTIAL_ALREADY_CLAIMED`, `410 CREDENTIAL_ESCROW_EXPIRED`, `404`.
 */
export async function claimUsbCredentialApi(
  ctx: LiveDeviceContext,
  operationId: string,
  idempotencyKey: string,
  signal?: AbortSignal,
): Promise<ClaimCredentialResponse> {
  if (!isContractUuid(operationId)) {
    throw new WorkspaceApiError('RESOURCE_NOT_FOUND', 404);
  }
  const { body } = await workspaceRequest(
    `/provisioning-operations/${encodeURIComponent(operationId)}/claim-credential`,
    {
      method: 'POST',
      workspaceId: ctx.workspaceId,
      session: ctx.session,
      idempotencyKey,
      signal,
    },
  );
  return parseClaimCredentialResponse(body);
}
