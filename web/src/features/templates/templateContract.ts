import {
  assertAllowedKeys,
  countCodePoints,
  isContractUuid,
  isJsonRecord,
  isPositiveInt,
  isUtcTimestamp,
  WorkspaceApiError,
} from '../workspace/workspaceApi.ts';

export type DatastreamType = 'NUMBER' | 'BOOLEAN' | 'STRING' | 'ENUM';
export type ChannelKind = 'TELEMETRY' | 'STATE';
export type StreamDirection = 'READ' | 'WRITE' | 'READ_WRITE';
export type LegacyStreamMode = StreamDirection | ChannelKind;
export type TemplateStatus = 'DRAFT' | 'PUBLISHED' | 'ARCHIVED';
export type StreamScalarValue = number | boolean | string;

export interface StreamOutputDto {
  key: string;
  type: DatastreamType;
  channelKind: ChannelKind;
  direction: StreamDirection;
  unit?: string | null;
  min?: number;
  max?: number;
  enumValues?: Array<string | number>;
  default?: StreamScalarValue;
}

export interface StreamInputDto {
  key: string;
  type: DatastreamType;
  channelKind: ChannelKind;
  direction: StreamDirection;
  unit?: string | null;
  min?: number;
  max?: number;
  enumValues?: string[];
  default?: StreamScalarValue;
}

export interface TemplateCommandDto {
  type: 'SET_VALUE';
  stream: string;
  safeValue: StreamScalarValue;
}

export interface TemplateDto {
  id: string;
  workspaceId: string;
  status: TemplateStatus;
  schemaVersion: 1;
  revision: number;
  latestPublishedVersionId: string | null;
  name: string;
  model: string;
  streams: StreamOutputDto[];
  commands: TemplateCommandDto[];
  createdAt: string;
  updatedAt: string;
}

export interface TemplatePageDto {
  items: TemplateDto[];
  nextCursor: string | null;
}

export interface TemplateVersionDto {
  id: string;
  workspaceId: string;
  templateId: string;
  version: number;
  schemaVersion: 1;
  status: 'PUBLISHED';
  name: string;
  model: string;
  streams: StreamOutputDto[];
  commands: TemplateCommandDto[];
  sourceRevision: number | null;
  publishedAt: string;
}

export interface TemplateVersionPageDto {
  items: TemplateVersionDto[];
  nextCursor: string | null;
}

export interface TemplatePublishedDto {
  templateId: string;
  revision: number;
  version: TemplateVersionDto & { sourceRevision: number };
}

export interface TemplateCreateInput {
  name: string;
  model: string;
  streams: StreamInputDto[];
  commands: TemplateCommandDto[];
}

export interface TemplatePatchInput {
  name?: string;
  model?: string;
  streams?: StreamInputDto[];
  commands?: TemplateCommandDto[];
}

export interface SchemaDiffEntry {
  key: string;
  change: 'added' | 'removed' | 'modified';
  details: string[];
}

export interface TemplateSchemaDiff {
  metadataChanges: string[];
  streamChanges: SchemaDiffEntry[];
  commandChanges: SchemaDiffEntry[];
  hasChanges: boolean;
}

const STREAM_KEY_PATTERN = /^[a-z][a-z0-9_]{0,63}$/;
const STREAM_TYPES = new Set<string>(['NUMBER', 'BOOLEAN', 'STRING', 'ENUM']);
const CHANNEL_KINDS = new Set<string>(['TELEMETRY', 'STATE']);
const STREAM_DIRECTIONS = new Set<string>(['READ', 'WRITE', 'READ_WRITE']);
const TEMPLATE_STATUSES = new Set<string>(['DRAFT', 'PUBLISHED', 'ARCHIVED']);

const STREAM_INPUT_KEYS = new Set<string>([
  'key', 'type', 'channelKind', 'direction', 'unit', 'min', 'max', 'enumValues', 'default', 'mode',
]);
const STREAM_OUTPUT_KEYS = new Set<string>([
  'key', 'type', 'channelKind', 'direction', 'unit', 'min', 'max', 'enumValues', 'default',
]);
const COMMAND_KEYS = new Set<string>(['type', 'stream', 'safeValue']);
const TEMPLATE_KEYS = new Set<string>([
  'id', 'workspaceId', 'status', 'schemaVersion', 'revision', 'latestPublishedVersionId',
  'name', 'model', 'streams', 'commands', 'createdAt', 'updatedAt',
]);
const TEMPLATE_PAGE_KEYS = new Set<string>(['items', 'nextCursor']);
const TEMPLATE_VERSION_KEYS = new Set<string>([
  'id', 'workspaceId', 'templateId', 'version', 'schemaVersion', 'status',
  'name', 'model', 'streams', 'commands', 'sourceRevision', 'publishedAt',
]);
const TEMPLATE_VERSION_PAGE_KEYS = new Set<string>(['items', 'nextCursor']);
const TEMPLATE_PUBLISHED_KEYS = new Set<string>(['templateId', 'revision', 'version']);

/**
 * Kiểm tra giá trị scalar có thuộc số hữu hạn, boolean hoặc chuỗi hay không.
 * Input
 * Param: value — giá trị cần kiểm kiểu scalar cho `default` hoặc `safeValue`.
 * Output: true nếu là boolean, chuỗi hoặc số hữu hạn (không NaN/Infinity).
 */
function isValidScalarValue(value: unknown): value is StreamScalarValue {
  if (typeof value === 'boolean' || typeof value === 'string') return true;
  return typeof value === 'number' && Number.isFinite(value);
}

/**
 * Kiểm tra xem giá trị scalar `default` trên stream có khớp kiểu dữ liệu và ràng buộc hiện hành không.
 * Input
 * Param: type — kiểu dữ liệu datastream.
 * Param: value — giá trị default tùy chọn.
 * Param: min — cận dưới hữu hạn nếu có.
 * Param: max — cận trên hữu hạn nếu có.
 * Param: enumValues — tập giá trị enum nếu là kênh ENUM.
 * Param: index — chỉ số stream dùng tạo fieldError path.
 * Errors: ném `WorkspaceApiError` với path `/streams/{i}/default` nếu sai kiểu hoặc vượt biên.
 */
function assertValidStreamDefault(
  type: DatastreamType,
  value: unknown,
  min: number | undefined,
  max: number | undefined,
  enumValues: ReadonlyArray<string | number> | undefined,
  index: number,
): StreamScalarValue {
  const path = `/streams/${index}/default`;
  if (!isValidScalarValue(value)) {
    throw new WorkspaceApiError('STREAM_INVALID', 422, [{ path, code: 'INVALID_VALUE' }]);
  }
  if (type === 'NUMBER') {
    if (typeof value !== 'number') {
      throw new WorkspaceApiError('STREAM_INVALID', 422, [{ path, code: 'TYPE' }]);
    }
    if ((min !== undefined && value < min) || (max !== undefined && value > max)) {
      throw new WorkspaceApiError('STREAM_INVALID', 422, [{ path, code: 'INVALID_VALUE' }]);
    }
    return value;
  }
  if (type === 'BOOLEAN') {
    if (typeof value !== 'boolean') {
      throw new WorkspaceApiError('STREAM_INVALID', 422, [{ path, code: 'TYPE' }]);
    }
    return value;
  }
  if (type === 'STRING') {
    if (typeof value !== 'string' || countCodePoints(value) > 256) {
      throw new WorkspaceApiError('STREAM_INVALID', 422, [{ path, code: 'INVALID_VALUE' }]);
    }
    return value;
  }
  if (!enumValues || !enumValues.includes(value as string | number)) {
    throw new WorkspaceApiError('STREAM_INVALID', 422, [{ path, code: 'INVALID_VALUE' }]);
  }
  return value;
}

/**
 * Chuẩn hóa một stream đầu vào (hỗ trợ kiểm định hợp đồng G1 cho legacy `mode` và từ chối cấu trúc mơ hồ/trùng lặp).
 * Input
 * Param: raw — đối tượng stream chưa tin cậy (có thể dùng `channelKind`/`direction` chuẩn hoặc `mode` tương thích).
 * Param: index — vị trí stream trong mảng để gắn đường dẫn lỗi chính xác.
 * Output: đối tượng `StreamInputDto` chuẩn chỉ giữ `channelKind` và `direction` độc lập.
 * Errors: ném `WorkspaceApiError(422)` khi thiếu trục, `mode` trùng/xung đột trục, `safeValue` đặt trên stream, hoặc sai kiểu.
 */
export function normalizeStreamInput(raw: unknown, index: number): StreamInputDto {
  if (!isJsonRecord(raw)) {
    throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: `/streams/${index}`, code: 'TYPE' }]);
  }
  if ('safeValue' in raw) {
    // Theo quyết định G1 (CT-TEMPLATE-006), safeValue chỉ thuộc commands[], không đặt trên stream.
    throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: `/streams/${index}/safeValue`, code: 'UNKNOWN' }]);
  }
  for (const key of Object.keys(raw)) {
    if (!STREAM_INPUT_KEYS.has(key)) {
      throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: `/streams/${index}/${key}`, code: 'UNKNOWN_FIELD' }]);
    }
  }

  if (typeof raw.key !== 'string' || !STREAM_KEY_PATTERN.test(raw.key)) {
    throw new WorkspaceApiError('STREAM_INVALID', 422, [{ path: `/streams/${index}/key`, code: 'FORMAT' }]);
  }
  if (typeof raw.type !== 'string' || !STREAM_TYPES.has(raw.type)) {
    throw new WorkspaceApiError('STREAM_INVALID', 422, [{ path: `/streams/${index}/type`, code: 'ENUM' }]);
  }
  const type = raw.type as DatastreamType;

  const hasChannelKind = 'channelKind' in raw && raw.channelKind !== undefined;
  const hasDirection = 'direction' in raw && raw.direction !== undefined;
  const hasMode = 'mode' in raw && raw.mode !== undefined;

  let channelKind: ChannelKind;
  let direction: StreamDirection;

  if (hasMode) {
    if (typeof raw.mode !== 'string') {
      throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: `/streams/${index}/mode`, code: 'FORMAT' }]);
    }
    if (STREAM_DIRECTIONS.has(raw.mode)) {
      // Legacy mode mang nghĩa hướng đọc/ghi: bắt buộc cung cấp channelKind và cấm khai báo lặp direction.
      if (hasDirection || !hasChannelKind) {
        throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: `/streams/${index}/mode`, code: 'FORMAT' }]);
      }
      if (typeof raw.channelKind !== 'string' || !CHANNEL_KINDS.has(raw.channelKind)) {
        throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: `/streams/${index}/channelKind`, code: 'ENUM' }]);
      }
      channelKind = raw.channelKind as ChannelKind;
      direction = raw.mode as StreamDirection;
    } else if (CHANNEL_KINDS.has(raw.mode)) {
      // Legacy mode mang nghĩa loại kênh: bắt buộc cung cấp direction và cấm khai báo lặp channelKind.
      if (hasChannelKind || !hasDirection) {
        throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: `/streams/${index}/mode`, code: 'FORMAT' }]);
      }
      if (typeof raw.direction !== 'string' || !STREAM_DIRECTIONS.has(raw.direction)) {
        throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: `/streams/${index}/direction`, code: 'ENUM' }]);
      }
      channelKind = raw.mode as ChannelKind;
      direction = raw.direction as StreamDirection;
    } else {
      throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: `/streams/${index}/mode`, code: 'FORMAT' }]);
    }
  } else {
    if (!hasChannelKind) {
      throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: `/streams/${index}/channelKind`, code: 'REQUIRED' }]);
    }
    if (!hasDirection) {
      throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: `/streams/${index}/direction`, code: 'REQUIRED' }]);
    }
    if (typeof raw.channelKind !== 'string' || !CHANNEL_KINDS.has(raw.channelKind)) {
      throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: `/streams/${index}/channelKind`, code: 'ENUM' }]);
    }
    if (typeof raw.direction !== 'string' || !STREAM_DIRECTIONS.has(raw.direction)) {
      throw new WorkspaceApiError('VALIDATION_ERROR', 422, [{ path: `/streams/${index}/direction`, code: 'ENUM' }]);
    }
    channelKind = raw.channelKind as ChannelKind;
    direction = raw.direction as StreamDirection;
  }

  const normalized: StreamInputDto = {
    key: raw.key,
    type,
    channelKind,
    direction,
  };

  if ('unit' in raw && raw.unit !== undefined) {
    if (raw.unit === null) {
      normalized.unit = null;
    } else if (typeof raw.unit === 'string' && countCodePoints(raw.unit) >= 1 && countCodePoints(raw.unit) <= 32) {
      if (type !== 'NUMBER') {
        throw new WorkspaceApiError('STREAM_INVALID', 422, [{ path: `/streams/${index}/unit`, code: 'INCOMPATIBLE' }]);
      }
      normalized.unit = raw.unit;
    } else {
      throw new WorkspaceApiError('STREAM_INVALID', 422, [{ path: `/streams/${index}/unit`, code: 'FORMAT' }]);
    }
  }

  if ('min' in raw && raw.min !== undefined) {
    if (type !== 'NUMBER' || typeof raw.min !== 'number' || !Number.isFinite(raw.min)) {
      throw new WorkspaceApiError('STREAM_INVALID', 422, [{ path: `/streams/${index}/min`, code: 'INVALID_VALUE' }]);
    }
    normalized.min = raw.min;
  }
  if ('max' in raw && raw.max !== undefined) {
    if (type !== 'NUMBER' || typeof raw.max !== 'number' || !Number.isFinite(raw.max)) {
      throw new WorkspaceApiError('STREAM_INVALID', 422, [{ path: `/streams/${index}/max`, code: 'INVALID_VALUE' }]);
    }
    normalized.max = raw.max;
  }
  if (normalized.min !== undefined && normalized.max !== undefined && normalized.min > normalized.max) {
    throw new WorkspaceApiError('STREAM_INVALID', 422, [{ path: `/streams/${index}/max`, code: 'INVALID_BOUNDS' }]);
  }

  if ('enumValues' in raw && raw.enumValues !== undefined) {
    if (type !== 'ENUM' || !Array.isArray(raw.enumValues) || raw.enumValues.length < 1 || raw.enumValues.length > 64) {
      throw new WorkspaceApiError('STREAM_INVALID', 422, [{ path: `/streams/${index}/enumValues`, code: 'INVALID_VALUE' }]);
    }
    const seen = new Set<string>();
    const values: string[] = [];
    for (let j = 0; j < raw.enumValues.length; j += 1) {
      const val = raw.enumValues[j];
      if (typeof val !== 'string' || val.length < 1 || countCodePoints(val) > 64 || seen.has(val)) {
        throw new WorkspaceApiError('STREAM_INVALID', 422, [{ path: `/streams/${index}/enumValues/${j}`, code: 'INVALID_VALUE' }]);
      }
      seen.add(val);
      values.push(val);
    }
    normalized.enumValues = values;
  }

  if ('default' in raw && raw.default !== undefined) {
    normalized.default = assertValidStreamDefault(
      type,
      raw.default,
      normalized.min,
      normalized.max,
      normalized.enumValues,
      index,
    );
  }

  return normalized;
}

/**
 * Parse StreamOutput từ API theo đúng schema G1 (bắt buộc `channelKind`/`direction`, cho phép enum số lịch sử khi đọc).
 * Input
 * Param: raw — đối tượng stream từ JSON response server.
 * Output: `StreamOutputDto` đã kiểm chứng nghiêm ngặt.
 * Errors: ném `WorkspaceApiError('PROTOCOL_ERROR')` nếu thiếu trường bắt buộc, chứa key lạ hoặc sai kiểu.
 */
export function parseStreamOutput(raw: unknown): StreamOutputDto {
  if (!isJsonRecord(raw)) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  assertAllowedKeys(raw, STREAM_OUTPUT_KEYS);
  if (
    typeof raw.key !== 'string' || !STREAM_KEY_PATTERN.test(raw.key)
    || typeof raw.type !== 'string' || !STREAM_TYPES.has(raw.type)
    || typeof raw.channelKind !== 'string' || !CHANNEL_KINDS.has(raw.channelKind)
    || typeof raw.direction !== 'string' || !STREAM_DIRECTIONS.has(raw.direction)
  ) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }

  const parsed: StreamOutputDto = {
    key: raw.key,
    type: raw.type as DatastreamType,
    channelKind: raw.channelKind as ChannelKind,
    direction: raw.direction as StreamDirection,
  };

  if ('unit' in raw && raw.unit !== undefined) {
    if (raw.unit !== null && (typeof raw.unit !== 'string' || countCodePoints(raw.unit) < 1 || countCodePoints(raw.unit) > 32)) {
      throw new WorkspaceApiError('PROTOCOL_ERROR');
    }
    parsed.unit = raw.unit;
  }
  if ('min' in raw && raw.min !== undefined) {
    if (typeof raw.min !== 'number' || !Number.isFinite(raw.min)) {
      throw new WorkspaceApiError('PROTOCOL_ERROR');
    }
    parsed.min = raw.min;
  }
  if ('max' in raw && raw.max !== undefined) {
    if (typeof raw.max !== 'number' || !Number.isFinite(raw.max)) {
      throw new WorkspaceApiError('PROTOCOL_ERROR');
    }
    parsed.max = raw.max;
  }
  if ('enumValues' in raw && raw.enumValues !== undefined) {
    if (!Array.isArray(raw.enumValues) || raw.enumValues.length < 1) {
      throw new WorkspaceApiError('PROTOCOL_ERROR');
    }
    const seen = new Set<string>();
    const values: Array<string | number> = [];
    for (const item of raw.enumValues) {
      if (typeof item !== 'string' && (typeof item !== 'number' || !Number.isFinite(item))) {
        throw new WorkspaceApiError('PROTOCOL_ERROR');
      }
      const typedKey = `${typeof item}:${String(item)}`;
      if (seen.has(typedKey)) throw new WorkspaceApiError('PROTOCOL_ERROR');
      seen.add(typedKey);
      values.push(item);
    }
    parsed.enumValues = values;
  }
  if ('default' in raw && raw.default !== undefined) {
    if (!isValidScalarValue(raw.default)) {
      throw new WorkspaceApiError('PROTOCOL_ERROR');
    }
    parsed.default = raw.default;
  }

  return parsed;
}

/**
 * Parse một phần tử `Command` từ response hoặc fixture G1.
 * Input
 * Param: raw — đối tượng capability đầu ra `SET_VALUE`.
 * Output: `TemplateCommandDto` đã xác thực schema đóng.
 * Errors: ném `WorkspaceApiError('PROTOCOL_ERROR')` khi sai type, thiếu safeValue hoặc chứa key lạ.
 */
export function parseTemplateCommand(raw: unknown): TemplateCommandDto {
  if (!isJsonRecord(raw)) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  assertAllowedKeys(raw, COMMAND_KEYS);
  if (
    raw.type !== 'SET_VALUE'
    || typeof raw.stream !== 'string'
    || !STREAM_KEY_PATTERN.test(raw.stream)
    || !isValidScalarValue(raw.safeValue)
  ) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  return {
    type: 'SET_VALUE',
    stream: raw.stream,
    safeValue: raw.safeValue,
  };
}

/**
 * Parse DTO `Template` root từ response `/templates` hoặc `/templates/{id}`.
 * Input
 * Param: raw — payload JSON chưa tin cậy.
 * Output: `TemplateDto` đã xác thực đầy đủ field, UUID, timestamps và mảng streams/commands.
 * Errors: ném `WorkspaceApiError('PROTOCOL_ERROR')` nếu bất kỳ field nào lệch schema G1.
 */
export function parseTemplateDto(raw: unknown): TemplateDto {
  if (!isJsonRecord(raw)) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  assertAllowedKeys(raw, TEMPLATE_KEYS);
  if (
    !isContractUuid(raw.id)
    || !isContractUuid(raw.workspaceId)
    || typeof raw.status !== 'string' || !TEMPLATE_STATUSES.has(raw.status)
    || raw.schemaVersion !== 1
    || !isPositiveInt(raw.revision)
    || !(raw.latestPublishedVersionId === null || isContractUuid(raw.latestPublishedVersionId))
    || typeof raw.name !== 'string' || countCodePoints(raw.name) < 1 || countCodePoints(raw.name) > 100
    || typeof raw.model !== 'string' || countCodePoints(raw.model) < 1 || countCodePoints(raw.model) > 64
    || !Array.isArray(raw.streams) || raw.streams.length > 64
    || !Array.isArray(raw.commands) || raw.commands.length > 64
    || !isUtcTimestamp(raw.createdAt)
    || !isUtcTimestamp(raw.updatedAt)
  ) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  return {
    id: raw.id,
    workspaceId: raw.workspaceId,
    status: raw.status as TemplateStatus,
    schemaVersion: 1,
    revision: raw.revision,
    latestPublishedVersionId: raw.latestPublishedVersionId,
    name: raw.name,
    model: raw.model,
    streams: raw.streams.map(parseStreamOutput),
    commands: raw.commands.map(parseTemplateCommand),
    createdAt: raw.createdAt,
    updatedAt: raw.updatedAt,
  };
}

/**
 * Parse danh sách phân trang `TemplatePage` từ `GET /api/v1/templates`.
 * Input
 * Param: raw — payload JSON phản hồi từ server.
 * Output: `TemplatePageDto` chứa danh sách template và con trỏ kế tiếp.
 * Errors: ném `WorkspaceApiError('PROTOCOL_ERROR')` nếu sai cấu trúc page.
 */
export function parseTemplatePageDto(raw: unknown): TemplatePageDto {
  if (!isJsonRecord(raw)) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  assertAllowedKeys(raw, TEMPLATE_PAGE_KEYS);
  if (
    !Array.isArray(raw.items) || raw.items.length > 100
    || !(raw.nextCursor === null || (typeof raw.nextCursor === 'string' && raw.nextCursor.length >= 1))
  ) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  return {
    items: raw.items.map(parseTemplateDto),
    nextCursor: raw.nextCursor,
  };
}

/**
 * Parse snapshot bất biến `TemplateVersion` từ API FEAT-TN-006.
 * Input
 * Param: raw — đối tượng version JSON chưa tin cậy.
 * Output: `TemplateVersionDto` đã xác thực UUID pin, version >= 1, sourceRevision (>= 1 hoặc null lịch sử) và minItems >= 1.
 * Errors: ném `WorkspaceApiError('PROTOCOL_ERROR')` nếu thiếu trường, status khác PUBLISHED, sourceRevision sai kiểu hoặc mảng streams rỗng.
 */
export function parseTemplateVersionDto(raw: unknown): TemplateVersionDto {
  if (!isJsonRecord(raw)) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  assertAllowedKeys(raw, TEMPLATE_VERSION_KEYS);
  if (
    !isContractUuid(raw.id)
    || !isContractUuid(raw.workspaceId)
    || !isContractUuid(raw.templateId)
    || !isPositiveInt(raw.version)
    || raw.schemaVersion !== 1
    || raw.status !== 'PUBLISHED'
    || typeof raw.name !== 'string' || countCodePoints(raw.name) < 1 || countCodePoints(raw.name) > 100
    || typeof raw.model !== 'string' || countCodePoints(raw.model) < 1 || countCodePoints(raw.model) > 64
    || !Array.isArray(raw.streams) || raw.streams.length < 1 || raw.streams.length > 64
    || !Array.isArray(raw.commands) || raw.commands.length > 64
    || !(raw.sourceRevision === null || isPositiveInt(raw.sourceRevision))
    || !isUtcTimestamp(raw.publishedAt)
  ) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  return {
    id: raw.id,
    workspaceId: raw.workspaceId,
    templateId: raw.templateId,
    version: raw.version,
    schemaVersion: 1,
    status: 'PUBLISHED',
    name: raw.name,
    model: raw.model,
    streams: raw.streams.map(parseStreamOutput),
    commands: raw.commands.map(parseTemplateCommand),
    sourceRevision: raw.sourceRevision,
    publishedAt: raw.publishedAt,
  };
}

/**
 * Parse danh sách phân trang `TemplateVersionPage` dùng cho lịch sử phiên bản và recovery theo `sourceRevision`.
 * Input
 * Param: raw — payload JSON phản hồi từ server.
 * Output: `TemplateVersionPageDto` chứa mảng version bất biến và con trỏ cursor.
 * Errors: ném `WorkspaceApiError('PROTOCOL_ERROR')` khi schema không hợp lệ.
 */
export function parseTemplateVersionPageDto(raw: unknown): TemplateVersionPageDto {
  if (!isJsonRecord(raw)) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  assertAllowedKeys(raw, TEMPLATE_VERSION_PAGE_KEYS);
  if (
    !Array.isArray(raw.items) || raw.items.length > 100
    || !(raw.nextCursor === null || (typeof raw.nextCursor === 'string' && raw.nextCursor.length >= 1))
  ) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  return {
    items: raw.items.map(parseTemplateVersionDto),
    nextCursor: raw.nextCursor,
  };
}

/**
 * Parse phản hồi 200 của `POST /api/v1/templates/{id}/publish` theo đúng envelope `TemplatePublished`.
 * Input
 * Param: raw — JSON từ endpoint publish.
 * Output: `{ templateId, revision, version }` đã xác thực đồng nhất `templateId` và `version.sourceRevision` nguyên dương.
 * Errors: ném `WorkspaceApiError('PROTOCOL_ERROR')` nếu thiếu revision root, `sourceRevision` là `null` hoặc lệch `templateId`.
 */
export function parseTemplatePublishedDto(raw: unknown): TemplatePublishedDto {
  if (!isJsonRecord(raw)) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  assertAllowedKeys(raw, TEMPLATE_PUBLISHED_KEYS);
  if (!isContractUuid(raw.templateId) || !isPositiveInt(raw.revision)) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  const version = parseTemplateVersionDto(raw.version);
  if (version.templateId !== raw.templateId || !isPositiveInt(version.sourceRevision)) {
    throw new WorkspaceApiError('PROTOCOL_ERROR');
  }
  return {
    templateId: raw.templateId,
    revision: raw.revision,
    version: {
      ...version,
      sourceRevision: version.sourceRevision,
    },
  };
}

/**
 * Tạo payload chuẩn cho request tạo/cập nhật template, luôn xuất `channelKind` và `direction` chuẩn hóa (không xuất `mode`).
 * Input
 * Param: input — dữ liệu draft từ editor hoặc caller.
 * Output: đối tượng tuần tự hóa khớp `TemplateCreate` trong G1.
 * Errors: ném `WorkspaceApiError(422)` nếu stream/command vi phạm invariant cơ bản.
 */
export function buildTemplateCreatePayload(input: TemplateCreateInput): TemplateCreateInput {
  const streams = input.streams.map(
    /** Chuẩn hóa từng stream sang cặp `channelKind` và `direction` độc lập. */
    (stream, index) => normalizeStreamInput(stream, index),
  );
  const commands = input.commands.map(
    /** Kiểm tra cấu trúc capability `SET_VALUE` trước khi gửi lên server. */
    (command) => parseTemplateCommand(command),
  );
  return {
    name: input.name.normalize('NFC').trim(),
    model: input.model.trim(),
    streams,
    commands,
  };
}

/**
 * Định dạng giá trị trường tùy chọn thành chuỗi ổn định phục vụ so sánh diff.
 * Input
 * Param: value — giá trị cần trình bày trong mô tả thay đổi.
 * Output: chuỗi hiển thị đọc được cho người dùng.
 */
function formatDiffValue(value: unknown): string {
  if (value === undefined) return '(bỏ qua)';
  if (value === null) return 'null';
  if (Array.isArray(value)) return `[${value.map(String).join(', ')}]`;
  return String(value);
}

/**
 * Tính khác biệt schema có cấu trúc giữa bản gốc (baseline) và bản đích (target) cho UI V4.
 * Input
 * Param: baseline — bản template/version làm mốc so sánh (ví dụ v1 đã công bố).
 * Param: target — bản nháp hiện hành hoặc version mới cần đối chiếu (ví dụ draft v2).
 * Output: danh sách thay đổi metadata, stream và capability kèm cờ `hasChanges`.
 */
export function computeTemplateSchemaDiff(
  baseline: Pick<TemplateVersionDto, 'name' | 'model' | 'streams' | 'commands'>,
  target: Pick<TemplateDto | TemplateVersionDto, 'name' | 'model' | 'streams' | 'commands'>,
): TemplateSchemaDiff {
  const metadataChanges: string[] = [];
  if (baseline.name !== target.name) {
    metadataChanges.push(`Tên: "${baseline.name}" → "${target.name}"`);
  }
  if (baseline.model !== target.model) {
    metadataChanges.push(`Model: ${baseline.model} → ${target.model}`);
  }

  const baseStreams = new Map<string, StreamOutputDto>();
  for (const s of baseline.streams) baseStreams.set(s.key, s);
  const targetStreams = new Map<string, StreamOutputDto>();
  for (const s of target.streams) targetStreams.set(s.key, s);

  const streamKeys = Array.from(new Set([...baseStreams.keys(), ...targetStreams.keys()])).sort();
  const streamChanges: SchemaDiffEntry[] = [];

  for (const key of streamKeys) {
    const prev = baseStreams.get(key);
    const next = targetStreams.get(key);
    if (!prev && next) {
      streamChanges.push({
        key,
        change: 'added',
        details: [`Thêm kênh ${next.type} · ${next.channelKind} · ${next.direction}`],
      });
      continue;
    }
    if (prev && !next) {
      streamChanges.push({
        key,
        change: 'removed',
        details: [`Gỡ bỏ kênh ${prev.type} · ${prev.channelKind} · ${prev.direction}`],
      });
      continue;
    }
    if (prev && next) {
      const diffs: string[] = [];
      if (prev.type !== next.type) diffs.push(`type: ${prev.type} → ${next.type}`);
      if (prev.channelKind !== next.channelKind) diffs.push(`channelKind: ${prev.channelKind} → ${next.channelKind}`);
      if (prev.direction !== next.direction) diffs.push(`direction: ${prev.direction} → ${next.direction}`);
      if ((prev.unit ?? null) !== (next.unit ?? null)) diffs.push(`unit: ${formatDiffValue(prev.unit ?? null)} → ${formatDiffValue(next.unit ?? null)}`);
      if (prev.min !== next.min) diffs.push(`min: ${formatDiffValue(prev.min)} → ${formatDiffValue(next.min)}`);
      if (prev.max !== next.max) diffs.push(`max: ${formatDiffValue(prev.max)} → ${formatDiffValue(next.max)}`);
      if (JSON.stringify(prev.enumValues ?? []) !== JSON.stringify(next.enumValues ?? [])) {
        diffs.push(`enumValues: ${formatDiffValue(prev.enumValues ?? [])} → ${formatDiffValue(next.enumValues ?? [])}`);
      }
      if (prev.default !== next.default) {
        diffs.push(`default: ${formatDiffValue(prev.default)} → ${formatDiffValue(next.default)}`);
      }
      if (diffs.length > 0) {
        streamChanges.push({ key, change: 'modified', details: diffs });
      }
    }
  }

  const baseCmds = new Map<string, TemplateCommandDto>();
  for (const c of baseline.commands) baseCmds.set(c.stream, c);
  const targetCmds = new Map<string, TemplateCommandDto>();
  for (const c of target.commands) targetCmds.set(c.stream, c);

  const cmdKeys = Array.from(new Set([...baseCmds.keys(), ...targetCmds.keys()])).sort();
  const commandChanges: SchemaDiffEntry[] = [];

  for (const stream of cmdKeys) {
    const prev = baseCmds.get(stream);
    const next = targetCmds.get(stream);
    if (!prev && next) {
      commandChanges.push({
        key: stream,
        change: 'added',
        details: [`Thêm SET_VALUE (safeValue: ${formatDiffValue(next.safeValue)})`],
      });
    } else if (prev && !next) {
      commandChanges.push({
        key: stream,
        change: 'removed',
        details: [`Gỡ bỏ SET_VALUE (safeValue cũ: ${formatDiffValue(prev.safeValue)})`],
      });
    } else if (prev && next && prev.safeValue !== next.safeValue) {
      commandChanges.push({
        key: stream,
        change: 'modified',
        details: [`safeValue: ${formatDiffValue(prev.safeValue)} → ${formatDiffValue(next.safeValue)}`],
      });
    }
  }

  return {
    metadataChanges,
    streamChanges,
    commandChanges,
    hasChanges: metadataChanges.length > 0 || streamChanges.length > 0 || commandChanges.length > 0,
  };
}
