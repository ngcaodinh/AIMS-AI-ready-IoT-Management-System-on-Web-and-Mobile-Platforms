import type { SessionMetadata } from '../auth/api.ts';
import { isContractUuid, isPositiveInt, workspaceRequest, WorkspaceApiError } from '../workspace/workspaceApi.ts';
import {
  buildTemplateCreatePayload,
  parseTemplateDto,
  parseTemplateJsonText,
  parseTemplatePageDto,
  parseTemplatePublishedDto,
  parseTemplateVersionDto,
  parseTemplateVersionPageDto,
  serializeTemplateRequestJson,
  type TemplateCreateInput,
  type TemplateDto,
  type TemplatePageDto,
  type TemplatePatchInput,
  type TemplatePublishedDto,
  type TemplateStatus,
  type TemplateVersionDto,
  type TemplateVersionPageDto,
} from './templateContract.ts';

export interface LiveTemplateContext {
  workspaceId: string;
  session: SessionMetadata;
}

/**
 * Tải một trang template trong phạm vi workspace hiện tại theo filter status và con trỏ cursor tùy chọn.
 * Input
 * Param: ctx — ngữ cảnh workspace và metadata phiên từ `AuthCoordinator`.
 * Param: options — bộ lọc `status`, `cursor`, `limit` và tín hiệu `AbortSignal`.
 * Output: trang danh sách `TemplatePageDto` đã kiểm chứng hợp đồng G1.
 * Errors: ném `WorkspaceApiError` khi thiếu quyền/workspace, cursor không hợp lệ hoặc lỗi mạng.
 */
export async function listTemplatesApi(
  ctx: LiveTemplateContext,
  options: { status?: TemplateStatus; cursor?: string | null; limit?: number; signal?: AbortSignal } = {},
): Promise<TemplatePageDto> {
  const params = new URLSearchParams();
  if (options.status) params.set('status', options.status);
  if (options.cursor) params.set('cursor', options.cursor);
  if (options.limit !== undefined) params.set('limit', String(options.limit));
  const query = params.toString();
  const { body } = await workspaceRequest(`/templates${query ? `?${query}` : ''}`, {
    method: 'GET',
    workspaceId: ctx.workspaceId,
    session: ctx.session,
    parseResponseText: parseTemplateJsonText,
    signal: options.signal,
  });
  return parseTemplatePageDto(body);
}

/**
 * Đọc thông tin root template hiện hành theo ID và workspace scope.
 * Input
 * Param: ctx — ngữ cảnh workspace và metadata phiên.
 * Param: templateId — UUID template thuộc workspace hiện hành.
 * Param: signal — tín hiệu hủy khi người dùng chuyển workspace.
 * Output: `TemplateDto` hiện hành (trạng thái `DRAFT`, `PUBLISHED` hoặc `ARCHIVED`).
 * Errors: `404 RESOURCE_NOT_FOUND` nếu ngoài scope, hoặc `WorkspaceApiError`.
 */
export async function getTemplateApi(
  ctx: LiveTemplateContext,
  templateId: string,
  signal?: AbortSignal,
): Promise<TemplateDto> {
  if (!isContractUuid(templateId)) {
    throw new WorkspaceApiError('RESOURCE_NOT_FOUND', 404);
  }
  const { body } = await workspaceRequest(`/templates/${encodeURIComponent(templateId)}`, {
    method: 'GET',
    workspaceId: ctx.workspaceId,
    session: ctx.session,
    parseResponseText: parseTemplateJsonText,
    signal,
  });
  return parseTemplateDto(body);
}

/**
 * Tạo bản nháp template mới (`POST /api/v1/templates`); không gửi `workspaceId` trong body và không tự replay.
 * Input
 * Param: ctx — ngữ cảnh workspace và metadata phiên.
 * Param: input — dữ liệu draft đã chuẩn hóa `channelKind` và `direction`.
 * Param: signal — tín hiệu hủy khi đổi ngữ cảnh.
 * Output: `TemplateDto` vừa tạo với `status: 'DRAFT'` và `revision: 1`.
 * Errors: `422 STREAM_INVALID/VALIDATION_ERROR`, `413`, `403`, `404`, hoặc `NETWORK_ERROR` (kết quả unknown).
 */
export async function createTemplateDraftApi(
  ctx: LiveTemplateContext,
  input: TemplateCreateInput,
  signal?: AbortSignal,
): Promise<TemplateDto> {
  const payload = buildTemplateCreatePayload(input);
  const { body } = await workspaceRequest('/templates', {
    method: 'POST',
    workspaceId: ctx.workspaceId,
    session: ctx.session,
    rawJsonBody: serializeTemplateRequestJson(payload),
    parseResponseText: parseTemplateJsonText,
    signal,
  });
  return parseTemplateDto(body);
}

/**
 * Cập nhật bản nháp template hiện hành theo `If-Match` CAS; mảng `streams`/`commands` thay thế toàn phần.
 * Input
 * Param: ctx — ngữ cảnh workspace và metadata phiên.
 * Param: templateId — UUID template cần cập nhật.
 * Param: revision — số revision hiện hành cho header `If-Match`.
 * Param: patch — các trường cần thay đổi (ít nhất 1 trường).
 * Param: signal — tín hiệu hủy khi chuyển workspace.
 * Output: `TemplateDto` với revision mới sau commit.
 * Errors: `412 VERSION_CONFLICT`, `409 IMMUTABLE_SCHEMA`, `422 STREAM_INVALID`, `428 PRECONDITION_REQUIRED`.
 */
export async function patchTemplateDraftApi(
  ctx: LiveTemplateContext,
  templateId: string,
  revision: number,
  patch: TemplatePatchInput,
  signal?: AbortSignal,
): Promise<TemplateDto> {
  if (!isContractUuid(templateId)) {
    throw new WorkspaceApiError('RESOURCE_NOT_FOUND', 404);
  }
  const normalizedBody: Record<string, unknown> = {};
  if (patch.name !== undefined) normalizedBody.name = patch.name.normalize('NFC').trim();
  if (patch.model !== undefined) normalizedBody.model = patch.model.trim();
  if (patch.streams !== undefined) {
    normalizedBody.streams = patch.streams.map(
      /** Đảm bảo patch luôn dùng cặp canonical `channelKind` và `direction`, không gửi `mode`. */
      (stream, index) => buildTemplateCreatePayload({
        name: 'patch',
        model: 'patch',
        streams: [stream],
        commands: [],
      }).streams[0] ?? (() => { throw new WorkspaceApiError('STREAM_INVALID', 422, [{ path: `/streams/${index}`, code: 'FORMAT' }]); })(),
    );
  }
  if (patch.commands !== undefined) {
    normalizedBody.commands = patch.commands;
  }

  const { body } = await workspaceRequest(`/templates/${encodeURIComponent(templateId)}`, {
    method: 'PATCH',
    workspaceId: ctx.workspaceId,
    session: ctx.session,
    ifMatchRevision: revision,
    rawJsonBody: serializeTemplateRequestJson(normalizedBody),
    parseResponseText: parseTemplateJsonText,
    signal,
  });
  return parseTemplateDto(body);
}

/**
 * Công bố snapshot bất biến (`POST /api/v1/templates/{id}/publish`) với body rỗng hoàn toàn và `If-Match`.
 * Input
 * Param: ctx — ngữ cảnh workspace và metadata phiên.
 * Param: templateId — UUID template nguồn.
 * Param: revision — revision của draft đang xác nhận công bố.
 * Param: signal — tín hiệu hủy khi chuyển workspace.
 * Output: `TemplatePublishedDto` chứa `templateId`, `revision` mới và `version` snapshot bất biến.
 * Errors: `412 VERSION_CONFLICT` (đối thủ thắng hoặc stale), `409 IMMUTABLE_SCHEMA`, `422 STREAM_INVALID`, `428`.
 */
export async function publishTemplateApi(
  ctx: LiveTemplateContext,
  templateId: string,
  revision: number,
  signal?: AbortSignal,
): Promise<TemplatePublishedDto> {
  if (!isContractUuid(templateId)) {
    throw new WorkspaceApiError('RESOURCE_NOT_FOUND', 404);
  }
  // Hợp đồng G1 (OQ-PUBLISH-001) cấm gửi body hoặc `{}` trong POST publish.
  const { body } = await workspaceRequest(`/templates/${encodeURIComponent(templateId)}/publish`, {
    method: 'POST',
    workspaceId: ctx.workspaceId,
    session: ctx.session,
    ifMatchRevision: revision,
    parseResponseText: parseTemplateJsonText,
    signal,
  });
  return parseTemplatePublishedDto(body);
}

/**
 * Liệt kê các phiên bản đã công bố hoặc tra cứu chính xác phiên bản theo `sourceRevision` khi mất response 200.
 * Input
 * Param: ctx — ngữ cảnh workspace và metadata phiên.
 * Param: templateId — UUID family template.
 * Param: options — bộ lọc `sourceRevision`, `cursor`, `limit` và `signal`.
 * Output: `TemplateVersionPageDto` chứa các bản snapshot bất biến trong family.
 * Errors: `404 RESOURCE_NOT_FOUND`, `422 CURSOR_INVALID`, hoặc `WorkspaceApiError`.
 */
export async function listTemplateVersionsApi(
  ctx: LiveTemplateContext,
  templateId: string,
  options: { sourceRevision?: number; cursor?: string | null; limit?: number; signal?: AbortSignal } = {},
): Promise<TemplateVersionPageDto> {
  if (!isContractUuid(templateId)) {
    throw new WorkspaceApiError('RESOURCE_NOT_FOUND', 404);
  }
  const params = new URLSearchParams();
  if (options.sourceRevision !== undefined) {
    if (!isPositiveInt(options.sourceRevision)) {
      throw new WorkspaceApiError('VALIDATION_ERROR', 422);
    }
    params.set('sourceRevision', String(options.sourceRevision));
  }
  if (options.cursor) params.set('cursor', options.cursor);
  if (options.limit !== undefined) params.set('limit', String(options.limit));
  const query = params.toString();
  const { body } = await workspaceRequest(
    `/templates/${encodeURIComponent(templateId)}/versions${query ? `?${query}` : ''}`,
    {
      method: 'GET',
      workspaceId: ctx.workspaceId,
      session: ctx.session,
      parseResponseText: parseTemplateJsonText,
      signal: options.signal,
    },
  );
  return parseTemplateVersionPageDto(body);
}

/**
 * Đọc chính xác một snapshot `TemplateVersion` bất biến theo `versionId` (không dùng latest để thay thế).
 * Input
 * Param: ctx — ngữ cảnh workspace và metadata phiên.
 * Param: templateId — UUID family template.
 * Param: versionId — UUID snapshot bất biến cần đọc.
 * Param: signal — tín hiệu hủy khi chuyển workspace.
 * Output: `TemplateVersionDto` bất biến.
 */
export async function getTemplateVersionApi(
  ctx: LiveTemplateContext,
  templateId: string,
  versionId: string,
  signal?: AbortSignal,
): Promise<TemplateVersionDto> {
  if (!isContractUuid(templateId) || !isContractUuid(versionId)) {
    throw new WorkspaceApiError('RESOURCE_NOT_FOUND', 404);
  }
  const { body } = await workspaceRequest(
    `/templates/${encodeURIComponent(templateId)}/versions/${encodeURIComponent(versionId)}`,
    {
      method: 'GET',
      workspaceId: ctx.workspaceId,
      session: ctx.session,
      parseResponseText: parseTemplateJsonText,
      signal,
    },
  );
  return parseTemplateVersionDto(body);
}

/**
 * Mở draft mới từ một phiên bản đã công bố (`POST /api/v1/templates/{id}/draft`) dưới khóa `If-Match`.
 * Input
 * Param: ctx — ngữ cảnh workspace và metadata phiên.
 * Param: templateId — UUID family template.
 * Param: revision — revision hiện hành của template root.
 * Param: sourceVersionId — UUID snapshot nguồn để nhân bản thành draft hiện tại.
 * Param: signal — tín hiệu hủy khi đổi ngữ cảnh.
 * Output: `TemplateDto` với `status: 'DRAFT'` và `revision` tăng mới.
 * Errors: `409 DRAFT_EXISTS` nếu đã có draft, `412 VERSION_CONFLICT`, `409 IMMUTABLE_SCHEMA`, `404`.
 */
export async function cloneTemplateDraftApi(
  ctx: LiveTemplateContext,
  templateId: string,
  revision: number,
  sourceVersionId: string,
  signal?: AbortSignal,
): Promise<TemplateDto> {
  if (!isContractUuid(templateId) || !isContractUuid(sourceVersionId)) {
    throw new WorkspaceApiError('RESOURCE_NOT_FOUND', 404);
  }
  const { body } = await workspaceRequest(`/templates/${encodeURIComponent(templateId)}/draft`, {
    method: 'POST',
    workspaceId: ctx.workspaceId,
    session: ctx.session,
    ifMatchRevision: revision,
    body: { sourceVersionId },
    parseResponseText: parseTemplateJsonText,
    signal,
  });
  return parseTemplateDto(body);
}

/**
 * Đối soát kết quả sau khi mất phản hồi `POST /publish` bằng đúng `sourceRevision` đã gửi (WEB-PUBLISH-005).
 * Không dùng `latest` hoặc tự động publish lại khi revision gốc đã thay đổi.
 * Input
 * Param: ctx — ngữ cảnh workspace và metadata phiên.
 * Param: templateId — UUID template vừa gửi publish.
 * Param: submittedSourceRevision — revision draft đã dùng trong `If-Match` của lần publish bị mất ACK.
 * Param: signal — tín hiệu hủy khi chuyển workspace.
 * Output: bản snapshot đã công bố từ `submittedSourceRevision` (nếu có) và trạng thái root mới nhất.
 */
export async function recoverPublishBySourceRevisionApi(
  ctx: LiveTemplateContext,
  templateId: string,
  submittedSourceRevision: number,
  signal?: AbortSignal,
): Promise<{ matchedVersion: TemplateVersionDto | null; rootTemplate: TemplateDto }> {
  if (!isPositiveInt(submittedSourceRevision)) {
    throw new WorkspaceApiError('VALIDATION_ERROR', 422);
  }
  const [versionsPage, rootTemplate] = await Promise.all([
    listTemplateVersionsApi(ctx, templateId, { sourceRevision: submittedSourceRevision, limit: 1, signal }),
    getTemplateApi(ctx, templateId, signal),
  ]);
  const matchedVersion = versionsPage.items.find(
    /** Chỉ khớp snapshot có đúng `sourceRevision` dương đã gửi; loại trừ snapshot lịch sử (`null`) hoặc lệch revision. */
    (item) =>
      item.templateId === templateId
      && typeof item.sourceRevision === 'number'
      && item.sourceRevision === submittedSourceRevision,
  ) ?? null;
  return {
    matchedVersion,
    rootTemplate,
  };
}
