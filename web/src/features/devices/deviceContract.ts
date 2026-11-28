import {
  assertAllowedKeys,
  countCodePoints,
  isContractUuid,
  isJsonRecord,
  isNonNegativeInt,
  isPositiveInt,
  isUtcTimestamp,
  WorkspaceApiError,
} from '../workspace/workspaceApi.ts';
import {
  parseTemplateCommand,
  type TemplateCommandDto,
} from '../templates/templateContract.ts';

export type DeviceLifecycle = 'REGISTERED' | 'ACTIVE' | 'SUSPENDED' | 'ARCHIVED';
export type DeviceConnectivity = 'UNKNOWN' | 'ONLINE' | 'OFFLINE';
export type CredentialStatus = 'PROVISIONING' | 'ACTIVE' | 'REVOCATION_PENDING' | 'REVOKED';
export type DeviceMaintenance = 'NONE' | 'OTA';
export type SetupMethod = 'USB' | 'QR_BLE';

export type CredentialDeliveryMode = 'USB_ONE_TIME' | 'ENROLLMENT_BLE';
export type CredentialOpStatus = 'PENDING' | 'READY' | 'FAILED';
export type CredentialDeliveryStatus = 'PENDING' | 'AVAILABLE' | 'CLAIMED' | 'EXPIRED' | 'UNAVAILABLE';

export interface DeviceCreateInput {
  serial: string;
  name: string;
  model: string;
  templateVersionId: string;
  ownerId: string;
}

export interface DeviceDto {
  id: string;
  workspaceId: string;
  ownerId: string;
  templateVersionId: string;
  serial: string;
  name: string;
  model: string;
  room: string | null;
  tags: string[];
  lifecycle: DeviceLifecycle;
  connectivity: DeviceConnectivity;
  lastSeen: string | null;
  firmwareVersion: string | null;
  firmwareDigest: string | null;
  hardwareRevision: string | null;
  credentialStatus: CredentialStatus;
  maintenance: DeviceMaintenance;
  capabilities: TemplateCommandDto[];
  revision: number;
  createdAt: string;
  updatedAt: string;
}

export interface DeviceRegisteredDto extends DeviceDto {
  lifecycle: 'REGISTERED';
  connectivity: 'UNKNOWN';
  credentialStatus: 'PROVISIONING';
  maintenance: 'NONE';
  room: null;
  tags: [];
  lastSeen: null;
  firmwareVersion: null;
  firmwareDigest: null;
  hardwareRevision: null;
  revision: 1;
  nextStep: {
    type: 'SELECT_SETUP_METHOD';
    methods: ['USB', 'QR_BLE'];
  };
}

export interface DeviceRecoveryPageDto {
  items: DeviceDto[];
  nextCursor: null;
}

export interface WorkspaceActiveMemberDto {
  workspaceId: string;
  userId: string;
  email: string;
  alias: string | null;
  role: 'ADMIN' | 'USER';
  status: 'ACTIVE';
}

export interface CredentialOperationDto {
  kind: 'CREDENTIAL';
  operationId: string;
  deviceId: string;
  deliveryMode: CredentialDeliveryMode;
  status: CredentialOpStatus;
  deliveryStatus: CredentialDeliveryStatus;
  secretAvailable: boolean;
  escrowExpiresAt: string | null;
  claimedAt: string | null;
  errorCode: string | null;
  retryCount: number;
}

export interface DeviceLifecycleOperationDto {
  kind: 'DEVICE_LIFECYCLE';
  operationId: string;
  deviceId: string;
  type: 'SUSPEND' | 'RESUME';
  status: 'PENDING' | 'SUCCEEDED' | 'FAILED' | 'CANCELLED';
  lifecycle: DeviceLifecycle;
  connectivity: DeviceConnectivity;
  credentialStatus: CredentialStatus;
  brokerStatus: 'PENDING' | 'CONFIRMED' | 'FAILED' | 'NOT_REQUIRED';
  revision: number;
  createdAt?: string;
  deadline?: string | null;
  errorCode?: string | null;
  credentialOperationId?: string | null;
}

export interface EnrollmentCleanupOperationDto {
  kind: 'ENROLLMENT_CLEANUP';
  id: string;
  enrollmentId: string;
  state: 'PENDING' | 'SUCCEEDED' | 'FAILED';
  reason: string;
  applicationBlocked: boolean;
  escrowPurged: boolean;
  brokerRevocation: 'NOT_REQUIRED' | 'PENDING' | 'CONFIRMED';
  boardCleanup: 'UNKNOWN' | 'CONFIRMED';
  attempts: number;
  nextAttemptAt: string | null;
  lastError: string | null;
}

export type ProvisioningOperationDto =
  | CredentialOperationDto
  | DeviceLifecycleOperationDto
  | EnrollmentCleanupOperationDto;

export interface CredentialBundleDto {
  deviceId: string;
  credentialId: string;
  brokerHost: string;
  brokerPort: number;
  clientId: string;
  username: string;
  password: string;
  templateVersion: string;
  expiresAt: string;
}

export type CreateCredentialResponse =
  | { kind: 'BUNDLE'; operation: CredentialOperationDto; credential: CredentialBundleDto }
  | { kind: 'PENDING'; operation: CredentialOperationDto }
  | { kind: 'STATUS'; operation: ProvisioningOperationDto };

export type ProvisioningPollResponse = {
  kind: 'STATUS';
  operation: ProvisioningOperationDto;
};

export type ClaimCredentialResponse =
  | { kind: 'BUNDLE'; operation: CredentialOperationDto; credential: CredentialBundleDto }
  | { kind: 'STATUS'; operation: ProvisioningOperationDto };

const CANONICAL_SERIAL_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/;
const UPPER_CODE_PATTERN = /^[A-Z][A-Z0-9_]*$/;

const DEVICE_LIFECYCLES = new Set<string>(['REGISTERED', 'ACTIVE', 'SUSPENDED', 'ARCHIVED']);
const DEVICE_CONNECTIVITIES = new Set<string>(['UNKNOWN', 'ONLINE', 'OFFLINE']);
const CREDENTIAL_STATUSES = new Set<string>(['PROVISIONING', 'ACTIVE', 'REVOCATION_PENDING', 'REVOKED']);
const DEVICE_MAINTENANCES = new Set<string>(['NONE', 'OTA']);

const DEVICE_KEYS = new Set<string>([
  'id', 'workspaceId', 'ownerId', 'templateVersionId', 'serial', 'name', 'model',
  'room', 'tags', 'lifecycle', 'connectivity', 'lastSeen', 'firmwareVersion',
  'firmwareDigest', 'hardwareRevision', 'credentialStatus', 'maintenance',
  'capabilities', 'revision', 'createdAt', 'updatedAt',
]);
const DEVICE_REGISTERED_KEYS = new Set<string>([...DEVICE_KEYS, 'nextStep']);
const NEXT_STEP_KEYS = new Set<string>(['type', 'methods']);
const DEVICE_RECOVERY_PAGE_KEYS = new Set<string>(['items', 'nextCursor']);

const CREDENTIAL_OP_KEYS = new Set<string>([
  'kind', 'operationId', 'deviceId', 'deliveryMode', 'status', 'deliveryStatus',
  'secretAvailable', 'escrowExpiresAt', 'claimedAt', 'errorCode', 'retryCount',
]);
const LIFECYCLE_OP_KEYS = new Set<string>([
  'kind', 'operationId', 'deviceId', 'type', 'status', 'lifecycle', 'connectivity',
  'credentialStatus', 'brokerStatus', 'revision', 'createdAt', 'deadline', 'errorCode', 'credentialOperationId',
]);
const CLEANUP_OP_KEYS = new Set<string>([
  'kind', 'id', 'enrollmentId', 'state', 'reason', 'applicationBlocked', 'escrowPurged',
  'brokerRevocation', 'boardCleanup', 'attempts', 'nextAttemptAt', 'lastError',
]);
const CREDENTIAL_BUNDLE_KEYS = new Set<string>([
  'deviceId', 'credentialId', 'brokerHost', 'brokerPort', 'clientId',
  'username', 'password', 'templateVersion', 'expiresAt',
]);
const POLL_WRAPPER_KEYS = new Set<string>(['kind', 'operation']);
const BUNDLE_WRAPPER_KEYS = new Set<string>(['kind', 'operation', 'credential']);

/**
 * Kiểm tra serial theo đúng định dạng ASCII case-sensitive của OQ-DEVICE-001; không tự trim hoặc đổi hoa thường.
 * Input
 * Param: serial — chuỗi serial nguyên trạng từ người dùng hoặc URL query.
 * Output: true khi hợp lệ; false nếu có khoảng trắng, Unicode hoặc vượt 64 ký tự.
 */
export function validateCanonicalSerial(serial: string): boolean {
  return CANONICAL_SERIAL_PATTERN.test(serial);
}

/**
 * Chuẩn hóa tên thiết bị bằng NFC + trim và kiểm tra giới hạn 1–100 code points.
 * Input
 * Param: rawName — chuỗi tên thiết bị từ biểu mẫu.
 * Output: tên đã chuẩn hóa hoặc null nếu rỗng / vượt 100 code points.
 */
export function normalizeDeviceName(rawName: string): string | null {
  const normalized = rawName.normalize('NFC').trim();
  const len = countCodePoints(normalized);
  if (len < 1 || len > 100) return null;
  return normalized;
}

/**
 * Tạo payload `DeviceCreate` chuẩn G1; từ chối thiếu UUID pin, serial sai mẫu hoặc chứa trường cấm.
 * Input
 * Param: input — dữ liệu đăng ký thiết bị từ form D4.
 * Output: `DeviceCreateInput` sạch không chứa `workspaceId` hoặc metadata runtime giả.
 * Errors: ném `WorkspaceApiError(422)` kèm JSON Pointer fieldErrors khi không hợp lệ.
 */
export function buildDeviceCreatePayload(input: DeviceCreateInput): DeviceCreateInput {
  if (!validateCanonicalSerial(input.serial)) {
    throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: '/serial', code: 'FORMAT' }]);
  }
  const normalizedName = normalizeDeviceName(input.name);
  if (!normalizedName) {
    throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: '/name', code: 'LENGTH' }]);
  }
  const trimmedModel = input.model.trim();
  if (countCodePoints(trimmedModel) < 1 || countCodePoints(trimmedModel) > 64) {
    throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: '/model', code: 'LENGTH' }]);
  }
  if (!isContractUuid(input.templateVersionId)) {
    throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: '/templateVersionId', code: 'FORMAT' }]);
  }
  if (!isContractUuid(input.ownerId)) {
    throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: '/ownerId', code: 'FORMAT' }]);
  }
  return {
    serial: input.serial,
    name: normalizedName,
    model: trimmedModel,
    templateVersionId: input.templateVersionId,
    ownerId: input.ownerId,
  };
}

/**
 * Parse các trường chung của `Device` từ response server; từ chối `lastSeenAt` và trường lạ.
 * Input
 * Param: raw — object JSON thiết bị.
 * Param: allowedKeys — danh sách key cho phép (`DEVICE_KEYS` hoặc `DEVICE_REGISTERED_KEYS`).
 * Output: `DeviceDto` đã xác thực pin `templateVersionId` UUID và mọi enum.
 * Errors: ném `WorkspaceApiError('PROTOCOL_ERROR')` nếu sai schema hoặc chứa trường secret.
 */
function parseBaseDevice(raw: unknown, allowedKeys: ReadonlySet<string>): DeviceDto {
  if (!isJsonRecord(raw)) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  assertAllowedKeys(raw, allowedKeys);
  if (
    !isContractUuid(raw.id)
    || !isContractUuid(raw.workspaceId)
    || !isContractUuid(raw.ownerId)
    || !isContractUuid(raw.templateVersionId)
    || typeof raw.serial !== 'string' || !validateCanonicalSerial(raw.serial)
    || typeof raw.name !== 'string' || countCodePoints(raw.name) < 1 || countCodePoints(raw.name) > 100
    || typeof raw.model !== 'string' || countCodePoints(raw.model) < 1 || countCodePoints(raw.model) > 64
    || !(raw.room === null || typeof raw.room === 'string')
    || !Array.isArray(raw.tags) || !raw.tags.every((t) => typeof t === 'string')
    || typeof raw.lifecycle !== 'string' || !DEVICE_LIFECYCLES.has(raw.lifecycle)
    || typeof raw.connectivity !== 'string' || !DEVICE_CONNECTIVITIES.has(raw.connectivity)
    || !(raw.lastSeen === null || isUtcTimestamp(raw.lastSeen))
    || !(raw.firmwareVersion === null || typeof raw.firmwareVersion === 'string')
    || !(raw.firmwareDigest === null || typeof raw.firmwareDigest === 'string')
    || !(raw.hardwareRevision === null || typeof raw.hardwareRevision === 'string')
    || typeof raw.credentialStatus !== 'string' || !CREDENTIAL_STATUSES.has(raw.credentialStatus)
    || typeof raw.maintenance !== 'string' || !DEVICE_MAINTENANCES.has(raw.maintenance)
    || !Array.isArray(raw.capabilities)
    || !isPositiveInt(raw.revision)
    || !isUtcTimestamp(raw.createdAt)
    || !isUtcTimestamp(raw.updatedAt)
  ) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }

  return {
    id: raw.id,
    workspaceId: raw.workspaceId,
    ownerId: raw.ownerId,
    templateVersionId: raw.templateVersionId,
    serial: raw.serial,
    name: raw.name,
    model: raw.model,
    room: raw.room,
    tags: [...raw.tags],
    lifecycle: raw.lifecycle as DeviceLifecycle,
    connectivity: raw.connectivity as DeviceConnectivity,
    lastSeen: raw.lastSeen,
    firmwareVersion: raw.firmwareVersion,
    firmwareDigest: raw.firmwareDigest,
    hardwareRevision: raw.hardwareRevision,
    credentialStatus: raw.credentialStatus as CredentialStatus,
    maintenance: raw.maintenance as DeviceMaintenance,
    capabilities: raw.capabilities.map(parseTemplateCommand),
    revision: raw.revision,
    createdAt: raw.createdAt,
    updatedAt: raw.updatedAt,
  };
}

/**
 * Parse `Device` chuẩn từ response recovery hoặc chi tiết.
 * Input
 * Param: raw — đối tượng thiết bị JSON chưa tin cậy.
 * Output: `DeviceDto` đã xác thực nghiêm ngặt.
 */
export function parseDeviceDto(raw: unknown): DeviceDto {
  return parseBaseDevice(raw, DEVICE_KEYS);
}

/**
 * Parse response 201 `DeviceRegistered` từ `POST /api/v1/devices`.
 * Khẳng định thiết bị mới tạo phải ở trạng thái `REGISTERED`, `UNKNOWN`, `PROVISIONING` và chưa có telemetry/secret.
 * Input
 * Param: raw — body JSON phản hồi 201.
 * Output: `DeviceRegisteredDto` kèm `nextStep: SELECT_SETUP_METHOD`.
 * Errors: ném `WorkspaceApiError('PROTOCOL_ERROR')` nếu thiếu `nextStep` hoặc báo trạng thái sai.
 */
export function parseDeviceRegisteredDto(raw: unknown): DeviceRegisteredDto {
  const base = parseBaseDevice(raw, DEVICE_REGISTERED_KEYS);
  if (!isJsonRecord(raw)) throw new WorkspaceApiError('PROTOCOL_ERROR');
  if (
    base.room !== null
    || base.tags.length !== 0
    || base.lifecycle !== 'REGISTERED'
    || base.connectivity !== 'UNKNOWN'
    || base.lastSeen !== null
    || base.firmwareVersion !== null
    || base.firmwareDigest !== null
    || base.hardwareRevision !== null
    || base.credentialStatus !== 'PROVISIONING'
    || base.maintenance !== 'NONE'
    || base.revision !== 1
    || !isJsonRecord(raw.nextStep)
  ) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  assertAllowedKeys(raw.nextStep, NEXT_STEP_KEYS);
  const methods = raw.nextStep.methods;
  if (
    raw.nextStep.type !== 'SELECT_SETUP_METHOD'
    || !Array.isArray(methods)
    || methods.length !== 2
    || methods[0] !== 'USB'
    || methods[1] !== 'QR_BLE'
  ) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  return {
    ...base,
    room: null,
    tags: [],
    lifecycle: 'REGISTERED',
    connectivity: 'UNKNOWN',
    lastSeen: null,
    firmwareVersion: null,
    firmwareDigest: null,
    hardwareRevision: null,
    credentialStatus: 'PROVISIONING',
    maintenance: 'NONE',
    revision: 1,
    nextStep: {
      type: 'SELECT_SETUP_METHOD',
      methods: ['USB', 'QR_BLE'],
    },
  };
}

/**
 * Parse phản hồi tra cứu `GET /api/v1/devices?serial=...` (tối đa 1 bản ghi trong workspace, `nextCursor: null`).
 * Input
 * Param: raw — payload JSON từ API recovery.
 * Output: `DeviceRecoveryPageDto`.
 * Errors: ném `WorkspaceApiError('PROTOCOL_ERROR')` nếu vượt 1 item hoặc sai cấu trúc.
 */
export function parseDeviceRecoveryPageDto(raw: unknown): DeviceRecoveryPageDto {
  if (!isJsonRecord(raw)) throw new WorkspaceApiError('PROTOCOL_ERROR');
  assertAllowedKeys(raw, DEVICE_RECOVERY_PAGE_KEYS);
  if (!Array.isArray(raw.items) || raw.items.length > 1 || raw.nextCursor !== null) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  return {
    items: raw.items.map(parseDeviceDto),
    nextCursor: null,
  };
}

/**
 * Đối chiếu thiết bị tìm được qua `GET /devices?serial=` với ý định đăng ký vừa gửi (WEB-DEVICE-004).
 * Input
 * Param: intent — cấu hình đã gửi ở POST tạo thiết bị trước khi mất phản hồi.
 * Param: found — bản ghi thiết bị đang tồn tại trong workspace hiện hành.
 * Output: `'MATCHES_INTENT'` nếu khớp `ownerId`, `model` và `templateVersionId`; ngược lại `'CONFLICTS_WITH_INTENT'`.
 */
export function assessSerialRecoveryOutcome(
  intent: Pick<DeviceCreateInput, 'ownerId' | 'model' | 'templateVersionId'>,
  found: Pick<DeviceDto, 'ownerId' | 'model' | 'templateVersionId'>,
): 'MATCHES_INTENT' | 'CONFLICTS_WITH_INTENT' {
  if (
    found.ownerId === intent.ownerId
    && found.model === intent.model
    && found.templateVersionId === intent.templateVersionId
  ) {
    return 'MATCHES_INTENT';
  }
  return 'CONFLICTS_WITH_INTENT';
}

/**
 * Parse danh sách thành viên ACTIVE từ `GET /api/v1/workspaces/{id}/members?status=ACTIVE` để chọn `ownerId`.
 * Input
 * Param: raw — payload JSON phản hồi từ endpoint membership hiện có.
 * Output: danh sách thành viên ACTIVE cùng `nextCursor`.
 * Errors: ném `WorkspaceApiError('PROTOCOL_ERROR')` nếu sai kiểu dữ liệu.
 */
export function parseActiveMembersPageDto(raw: unknown): {
  items: WorkspaceActiveMemberDto[];
  nextCursor: string | null;
} {
  if (!isJsonRecord(raw) || !Array.isArray(raw.items)
    || !(raw.nextCursor === null || typeof raw.nextCursor === 'string')) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  const items: WorkspaceActiveMemberDto[] = [];
  for (const row of raw.items) {
    if (
      !isJsonRecord(row)
      || !isContractUuid(row.workspaceId)
      || !isContractUuid(row.userId)
      || typeof row.email !== 'string'
      || !(row.alias === null || typeof row.alias === 'string')
      || (row.role !== 'ADMIN' && row.role !== 'USER')
      || row.status !== 'ACTIVE'
    ) {
      throw new WorkspaceApiError('PROTOCOL_ERROR');
    }
    items.push({
      workspaceId: row.workspaceId,
      userId: row.userId,
      email: row.email,
      alias: row.alias,
      role: row.role,
      status: 'ACTIVE',
    });
  }
  return { items, nextCursor: raw.nextCursor };
}

/**
 * Tạo `Idempotency-Key` ngẫu nhiên 36 ký tự ASCII in được cho mỗi lần chủ động cấp/claim credential.
 * Output: chuỗi UUID ASCII hợp lệ trong biên 16–128 ký tự.
 */
export function generateIdempotencyKey(): string {
  return crypto.randomUUID();
}

/**
 * Parse `CredentialOperation` (kind `CREDENTIAL`) theo schema G1; không bao giờ chứa secret.
 * Input
 * Param: raw — object operation từ JSON response.
 * Output: `CredentialOperationDto` đã xác thực tách biệt `status` và `deliveryStatus`.
 */
function parseCredentialOperation(raw: Record<string, unknown>): CredentialOperationDto {
  assertAllowedKeys(raw, CREDENTIAL_OP_KEYS);
  if (
    raw.kind !== 'CREDENTIAL'
    || !isContractUuid(raw.operationId)
    || !isContractUuid(raw.deviceId)
    || (raw.deliveryMode !== 'USB_ONE_TIME' && raw.deliveryMode !== 'ENROLLMENT_BLE')
    || (raw.status !== 'PENDING' && raw.status !== 'READY' && raw.status !== 'FAILED')
    || (raw.deliveryStatus !== 'PENDING' && raw.deliveryStatus !== 'AVAILABLE'
      && raw.deliveryStatus !== 'CLAIMED' && raw.deliveryStatus !== 'EXPIRED'
      && raw.deliveryStatus !== 'UNAVAILABLE')
    || typeof raw.secretAvailable !== 'boolean'
    || !(raw.escrowExpiresAt === null || isUtcTimestamp(raw.escrowExpiresAt))
    || !(raw.claimedAt === null || isUtcTimestamp(raw.claimedAt))
    || !(raw.errorCode === null || (typeof raw.errorCode === 'string' && UPPER_CODE_PATTERN.test(raw.errorCode)))
    || !isNonNegativeInt(raw.retryCount)
  ) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  return {
    kind: 'CREDENTIAL',
    operationId: raw.operationId,
    deviceId: raw.deviceId,
    deliveryMode: raw.deliveryMode,
    status: raw.status,
    deliveryStatus: raw.deliveryStatus,
    secretAvailable: raw.secretAvailable,
    escrowExpiresAt: raw.escrowExpiresAt,
    claimedAt: raw.claimedAt,
    errorCode: raw.errorCode,
    retryCount: raw.retryCount,
  };
}

/**
 * Parse biến thể `DEVICE_LIFECYCLE` trong phản hồi poll operation (FEAT-TN-039) theo discriminator tường minh.
 * Input
 * Param: raw — object operation có `kind: 'DEVICE_LIFECYCLE'`.
 * Output: `DeviceLifecycleOperationDto` chỉ đọc metadata.
 */
function parseDeviceLifecycleOperation(raw: Record<string, unknown>): DeviceLifecycleOperationDto {
  assertAllowedKeys(raw, LIFECYCLE_OP_KEYS);
  if (
    raw.kind !== 'DEVICE_LIFECYCLE'
    || !isContractUuid(raw.operationId)
    || !isContractUuid(raw.deviceId)
    || (raw.type !== 'SUSPEND' && raw.type !== 'RESUME')
    || (raw.status !== 'PENDING' && raw.status !== 'SUCCEEDED' && raw.status !== 'FAILED' && raw.status !== 'CANCELLED')
    || typeof raw.lifecycle !== 'string' || !DEVICE_LIFECYCLES.has(raw.lifecycle)
    || typeof raw.connectivity !== 'string' || !DEVICE_CONNECTIVITIES.has(raw.connectivity)
    || typeof raw.credentialStatus !== 'string' || !CREDENTIAL_STATUSES.has(raw.credentialStatus)
    || (raw.brokerStatus !== 'PENDING' && raw.brokerStatus !== 'CONFIRMED'
      && raw.brokerStatus !== 'FAILED' && raw.brokerStatus !== 'NOT_REQUIRED')
    || !isPositiveInt(raw.revision)
  ) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  if (raw.createdAt !== undefined && !isUtcTimestamp(raw.createdAt)) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  if (raw.deadline !== undefined && raw.deadline !== null && !isUtcTimestamp(raw.deadline)) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  if (raw.errorCode !== undefined && raw.errorCode !== null
    && (typeof raw.errorCode !== 'string' || !UPPER_CODE_PATTERN.test(raw.errorCode))) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  if (raw.credentialOperationId !== undefined && raw.credentialOperationId !== null
    && !isContractUuid(raw.credentialOperationId)) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  return {
    kind: 'DEVICE_LIFECYCLE',
    operationId: raw.operationId,
    deviceId: raw.deviceId,
    type: raw.type,
    status: raw.status,
    lifecycle: raw.lifecycle as DeviceLifecycle,
    connectivity: raw.connectivity as DeviceConnectivity,
    credentialStatus: raw.credentialStatus as CredentialStatus,
    brokerStatus: raw.brokerStatus,
    revision: raw.revision,
    createdAt: raw.createdAt as string | undefined,
    deadline: raw.deadline as string | null | undefined,
    errorCode: raw.errorCode as string | null | undefined,
    credentialOperationId: raw.credentialOperationId as string | null | undefined,
  };
}

/**
 * Parse biến thể `ENROLLMENT_CLEANUP` trong phản hồi poll operation (FEAT-TN-052) theo discriminator tường minh.
 * Input
 * Param: raw — object operation có `kind: 'ENROLLMENT_CLEANUP'`.
 * Output: `EnrollmentCleanupOperationDto` chỉ đọc metadata.
 */
function parseEnrollmentCleanupOperation(raw: Record<string, unknown>): EnrollmentCleanupOperationDto {
  assertAllowedKeys(raw, CLEANUP_OP_KEYS);
  if (
    raw.kind !== 'ENROLLMENT_CLEANUP'
    || !isContractUuid(raw.id)
    || !isContractUuid(raw.enrollmentId)
    || (raw.state !== 'PENDING' && raw.state !== 'SUCCEEDED' && raw.state !== 'FAILED')
    || typeof raw.reason !== 'string' || !UPPER_CODE_PATTERN.test(raw.reason)
    || typeof raw.applicationBlocked !== 'boolean'
    || typeof raw.escrowPurged !== 'boolean'
    || (raw.brokerRevocation !== 'NOT_REQUIRED' && raw.brokerRevocation !== 'PENDING' && raw.brokerRevocation !== 'CONFIRMED')
    || (raw.boardCleanup !== 'UNKNOWN' && raw.boardCleanup !== 'CONFIRMED')
    || !isNonNegativeInt(raw.attempts)
    || !(raw.nextAttemptAt === null || isUtcTimestamp(raw.nextAttemptAt))
    || !(raw.lastError === null || (typeof raw.lastError === 'string' && UPPER_CODE_PATTERN.test(raw.lastError)))
  ) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  return {
    kind: 'ENROLLMENT_CLEANUP',
    id: raw.id,
    enrollmentId: raw.enrollmentId,
    state: raw.state,
    reason: raw.reason,
    applicationBlocked: raw.applicationBlocked,
    escrowPurged: raw.escrowPurged,
    brokerRevocation: raw.brokerRevocation,
    boardCleanup: raw.boardCleanup,
    attempts: raw.attempts,
    nextAttemptAt: raw.nextAttemptAt,
    lastError: raw.lastError,
  };
}

/**
 * Điều phối parse `ProvisioningOperation` bắt buộc theo discriminator `kind` tường minh;
 * thất bại đóng (fail closed) với mọi `kind` lạ hoặc thiếu.
 * Input
 * Param: raw — object operation chưa tin cậy.
 * Output: một trong ba union variant đã kiểm tra.
 * Errors: ném `WorkspaceApiError('PROTOCOL_ERROR')` nếu `kind` không hợp lệ hoặc chứa field secret lạ.
 */
export function parseProvisioningOperation(raw: unknown): ProvisioningOperationDto {
  if (!isJsonRecord(raw) || typeof raw.kind !== 'string') {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  switch (raw.kind) {
    case 'CREDENTIAL':
      return parseCredentialOperation(raw);
    case 'DEVICE_LIFECYCLE':
      return parseDeviceLifecycleOperation(raw);
    case 'ENROLLMENT_CLEANUP':
      return parseEnrollmentCleanupOperation(raw);
    default:
      // Fail closed đối với mọi discriminator lạ như FUTURE_OPERATION.
      throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
}

/**
 * Parse gói bí mật cấp một lần (`CredentialBundle`) trả về duy nhất ở 201 hoặc 200 claim.
 * Input
 * Param: raw — đối tượng credential bundle từ API.
 * Output: `CredentialBundleDto` với `templateVersion` là UUID pin chính xác.
 * Errors: ném `WorkspaceApiError('PROTOCOL_ERROR')` nếu thiếu field, port sai hoặc `templateVersion` không phải UUID.
 */
export function parseCredentialBundle(raw: unknown): CredentialBundleDto {
  if (!isJsonRecord(raw)) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  assertAllowedKeys(raw, CREDENTIAL_BUNDLE_KEYS);
  if (
    !isContractUuid(raw.deviceId)
    || !isContractUuid(raw.credentialId)
    || typeof raw.brokerHost !== 'string' || raw.brokerHost.length < 1
    || typeof raw.brokerPort !== 'number' || !Number.isSafeInteger(raw.brokerPort)
    || raw.brokerPort < 1 || raw.brokerPort > 65535
    || typeof raw.clientId !== 'string' || raw.clientId.length < 1
    || typeof raw.username !== 'string' || raw.username.length < 1
    || typeof raw.password !== 'string' || raw.password.length < 1
    || !isContractUuid(raw.templateVersion)
    || !isUtcTimestamp(raw.expiresAt)
  ) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  return {
    deviceId: raw.deviceId,
    credentialId: raw.credentialId,
    brokerHost: raw.brokerHost,
    brokerPort: raw.brokerPort,
    clientId: raw.clientId,
    username: raw.username,
    password: raw.password,
    templateVersion: raw.templateVersion,
    expiresAt: raw.expiresAt,
  };
}

/**
 * Parse phản hồi `GET /api/v1/provisioning-operations/{id}`; từ chối mọi bundle/secret hoặc discriminator lạ.
 * Input
 * Param: raw — body JSON phản hồi từ endpoint poll.
 * Output: `{ kind: 'STATUS', operation }` chỉ chứa metadata.
 * Errors: ném `WorkspaceApiError('PROTOCOL_ERROR')` nếu `kind !== 'STATUS'`, có `credential` hoặc secret lồng bên trong.
 */
export function parseProvisioningPollResponse(raw: unknown): ProvisioningPollResponse {
  if (!isJsonRecord(raw)) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  assertAllowedKeys(raw, POLL_WRAPPER_KEYS);
  if (raw.kind !== 'STATUS') {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  return {
    kind: 'STATUS',
    operation: parseProvisioningOperation(raw.operation),
  };
}

/**
 * Parse phản hồi của `POST /api/v1/devices/{id}/credentials` theo đúng HTTP status (201 bundle, 202 pending, 200 status replay).
 * Input
 * Param: status — HTTP status code thực tế từ server.
 * Param: raw — JSON body đã parse.
 * Output: `CreateCredentialResponse` phân biệt rạch ròi bundle một lần và metadata replay.
 * Errors: ném `WorkspaceApiError('PROTOCOL_ERROR')` nếu status và `kind` không khớp hợp đồng.
 */
export function parseCreateCredentialResponse(status: number, raw: unknown): CreateCredentialResponse {
  if (!isJsonRecord(raw)) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  if (status === 201) {
    assertAllowedKeys(raw, BUNDLE_WRAPPER_KEYS);
    if (raw.kind !== 'BUNDLE') throw new WorkspaceApiError('PROTOCOL_ERROR');
    const op = parseProvisioningOperation(raw.operation);
    if (op.kind !== 'CREDENTIAL') throw new WorkspaceApiError('PROTOCOL_ERROR');
    return {
      kind: 'BUNDLE',
      operation: op,
      credential: parseCredentialBundle(raw.credential),
    };
  }
  if (status === 202) {
    assertAllowedKeys(raw, POLL_WRAPPER_KEYS);
    if (raw.kind !== 'PENDING') throw new WorkspaceApiError('PROTOCOL_ERROR');
    const op = parseProvisioningOperation(raw.operation);
    if (op.kind !== 'CREDENTIAL') throw new WorkspaceApiError('PROTOCOL_ERROR');
    return { kind: 'PENDING', operation: op };
  }
  if (status === 200) {
    return parseProvisioningPollResponse(raw);
  }
  throw new WorkspaceApiError('PROTOCOL_ERROR');
}

/**
 * Parse phản hồi 200 của `POST /api/v1/provisioning-operations/{id}/claim-credential`.
 * Hỗ trợ `kind: 'BUNDLE'` (nhận một lần) và `kind: 'STATUS'` (replay chỉ metadata).
 * Input
 * Param: raw — body JSON phản hồi 200 từ endpoint claim.
 * Output: `ClaimCredentialResponse`.
 * Errors: ném `WorkspaceApiError('PROTOCOL_ERROR')` nếu `kind` lạ hoặc thiếu field.
 */
export function parseClaimCredentialResponse(raw: unknown): ClaimCredentialResponse {
  if (!isJsonRecord(raw)) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  if (raw.kind === 'BUNDLE') {
    assertAllowedKeys(raw, BUNDLE_WRAPPER_KEYS);
    const op = parseProvisioningOperation(raw.operation);
    if (op.kind !== 'CREDENTIAL') throw new WorkspaceApiError('PROTOCOL_ERROR');
    return {
      kind: 'BUNDLE',
      operation: op,
      credential: parseCredentialBundle(raw.credential),
    };
  }
  if (raw.kind === 'STATUS') {
    return parseProvisioningPollResponse(raw);
  }
  throw new WorkspaceApiError('PROTOCOL_ERROR');
}

/**
 * Kiểm tra điều kiện cho phép nút Claim USB hiển thị/kích hoạt trên giao diện Web (CRED-4).
 * Chỉ mở khi `kind === 'CREDENTIAL'`, `deliveryMode === 'USB_ONE_TIME'`, `status === 'READY'`,
 * `deliveryStatus === 'AVAILABLE'` và `secretAvailable === true`.
 * Input
 * Param: op — thông tin operation vừa nhận từ API poll hoặc create.
 * Output: true khi hợp lệ để Admin khởi tạo claim USB một lần.
 */
export function canClaimUsbCredential(op: ProvisioningOperationDto | null): boolean {
  if (!op || op.kind !== 'CREDENTIAL') return false;
  return (
    op.deliveryMode === 'USB_ONE_TIME'
    && op.status === 'READY'
    && op.deliveryStatus === 'AVAILABLE'
    && op.secretAvailable === true
  );
}
