/**
 * Bộ chuyển đổi mô phỏng trong bộ nhớ (in-memory) cho màn hình WB-03 Templates ở chế độ preview phát triển.
 * Không gọi mạng, không dùng storage bền vững và cô lập các giả định wire schema đang chờ G1 + FEAT-TN-065/067.
 */

export type WorkspaceRole = 'ADMIN' | 'USER';
export type WorkspaceStatus = 'ACTIVE' | 'SUSPENDED';
export type PreviewScenario =
  | 'normal'
  | 'offline'
  | 'stale_412'
  | 'not_found_404'
  | 'pending_post_unknown';

export type DatastreamType = 'NUMBER' | 'BOOLEAN' | 'STRING' | 'ENUM';
export type ChannelKind = 'TELEMETRY' | 'STATE';
export type StreamDirection = 'READ' | 'WRITE' | 'READ_WRITE';
export type TemplateStatus = 'DRAFT' | 'PUBLISHED';

export interface WorkspaceFixture {
  id: string;
  name: string;
  role: WorkspaceRole;
  status: WorkspaceStatus;
  description: string;
  isSyntheticPreview: true;
}

export interface TemplateStreamDto {
  key: string;
  type: DatastreamType;
  channelKind: ChannelKind;
  direction: StreamDirection;
  unit: string | null;
  min: number | null;
  max: number | null;
  enumValues: string[];
}

export interface TemplateCommandDto {
  type: 'SET_VALUE';
  stream: string;
  safeValue: number | boolean | string;
}

export interface TemplateDto {
  id: string;
  workspaceId: string;
  name: string;
  model: string;
  status: TemplateStatus;
  schemaVersion: 1;
  revision: number;
  publishedVersion: number | null;
  createdAt: string;
  updatedAt: string;
  streams: TemplateStreamDto[];
  commands: TemplateCommandDto[];
}

export interface TemplateStreamDraft {
  localId: string;
  key: string;
  type: DatastreamType;
  channelKind: ChannelKind;
  direction: StreamDirection;
  unit: string;
  minText: string;
  maxText: string;
  enumValues: string[];
}

export interface TemplateCommandDraft {
  localId: string;
  type: 'SET_VALUE';
  stream: string;
  safeValueText: string;
}

export interface TemplateDraftForm {
  id: string | null;
  name: string;
  model: string;
  status: TemplateStatus;
  schemaVersion: 1;
  revision: number | null;
  publishedVersion: number | null;
  updatedAt: string | null;
  streams: TemplateStreamDraft[];
  commands: TemplateCommandDraft[];
}

export interface FieldErrorItem {
  path: string;
  code: string;
  message: string;
}

export type TemplateListOutcome =
  | { ok: true; workspace: WorkspaceFixture; items: TemplateDto[]; nextCursor: string | null }
  | { ok: false; kind: 'permission' | 'network'; status: 403 | 404 | 0; code: string; message: string };

export type TemplateDetailOutcome =
  | { ok: true; template: TemplateDto }
  | { ok: false; kind: 'permission' | 'network' | 'not_found'; status: 403 | 404 | 0; code: string; message: string };

export type TemplateSaveOutcome =
  | { ok: true; template: TemplateDto; unresolvedWireNotes: readonly string[] }
  | { ok: false; kind: 'validation'; status: 422 | 413; code: string; message: string; fieldErrors: FieldErrorItem[] }
  | { ok: false; kind: 'conflict_412'; status: 412; code: 'VERSION_CONFLICT'; message: string; serverTemplate: TemplateDto }
  | { ok: false; kind: 'immutable_409'; status: 409; code: 'IMMUTABLE_SCHEMA'; message: string; serverTemplate: TemplateDto }
  | { ok: false; kind: 'precondition_428'; status: 428; code: 'PRECONDITION_REQUIRED'; message: string }
  | { ok: false; kind: 'permission' | 'not_found'; status: 403 | 404; code: string; message: string }
  | { ok: false; kind: 'network'; status: 0; code: 'NETWORK_ERROR'; message: string }
  | { ok: false; kind: 'unknown_outcome'; status: 0; code: 'CREATE_OUTCOME_UNKNOWN'; message: string };

export interface TemplatePreviewStore {
  listTemplates: (
    workspaceId: string,
    scenario: PreviewScenario,
    cursor?: string | null,
    signal?: AbortSignal,
  ) => Promise<TemplateListOutcome>;
  getTemplate: (
    workspaceId: string,
    templateId: string,
    scenario: PreviewScenario,
    signal?: AbortSignal,
  ) => Promise<TemplateDetailOutcome>;
  createDraft: (
    workspaceId: string,
    form: TemplateDraftForm,
    scenario: PreviewScenario,
    signal?: AbortSignal,
  ) => Promise<TemplateSaveOutcome>;
  updateDraft: (
    workspaceId: string,
    templateId: string,
    expectedRevision: number | null,
    form: TemplateDraftForm,
    scenario: PreviewScenario,
    signal?: AbortSignal,
  ) => Promise<TemplateSaveOutcome>;
}

// Giới hạn độ dài và kích thước theo OQ-TEMPLATE-001..003 trong kế hoạch FEAT-TN-005.
export const MAX_TEMPLATE_NAME_LENGTH = 100; // Ký tự Unicode (code points).
export const MAX_TEMPLATE_MODEL_LENGTH = 64; // Ký tự Unicode (code points).
export const MAX_STREAM_UNIT_LENGTH = 32; // Ký tự Unicode (code points).
export const MAX_ENUM_VALUE_LENGTH = 64; // Ký tự Unicode (code points).
export const MAX_STREAMS_PER_TEMPLATE = 64; // Số stream tối đa mỗi template.
export const MAX_COMMANDS_PER_TEMPLATE = 64; // Số command tối đa mỗi template.
export const MAX_DRAFT_PAYLOAD_BYTES = 65536; // Giới hạn JSON 64 KiB chung của API.

// Thời gian trễ mô phỏng (ms) đủ để thấy skeleton loading và kiểm tra hủy request khi đổi workspace.
const MOCK_LATENCY_MS = 140;
// Kích thước trang danh sách mẫu (item/trang) để minh họa phân trang cursor theo OQ-TEMPLATE-006.
const MOCK_PAGE_SIZE = 2;

const STREAM_KEY_PATTERN = /^[a-z][a-z0-9_]{0,63}$/;
const CANONICAL_MODEL_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const STRICT_FINITE_NUMBER_PATTERN = /^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/;

export const SYNTHETIC_MODEL_SUGGESTIONS: readonly string[] = [
  'ESP32_DEMO_ENV_V1',
  'ESP32_DEMO_RELAY_V1',
  'ESP32_DEMO_MIXED_V1',
];

/**
 * Danh sách giả định wire/contract đang chờ chốt ở gate G1 và PoC phần cứng T1,
 * được cô lập trong mock adapter để UI không tự đóng băng field transport chưa duyệt.
 */
export const UNRESOLVED_WIRE_ASSUMPTIONS: readonly string[] = [
  'Phân tách channelKind (TELEMETRY/STATE) và direction (READ/WRITE/READ_WRITE) trên UI; phép ánh xạ sang field mode của OpenAPI vẫn chờ gate G1.',
  'Capability SET_VALUE và safeValue giữ trong commands[] theo OQ-TEMPLATE-001/005; ánh xạ với safe_value trên domain Rust đang chờ G1.',
  'Trường default tùy chọn của stream (OQ-TEMPLATE-003) chưa được đưa vào DTO domain hiện tại nên chưa cố định trên wire preview.',
  'Endpoint danh sách phân trang GET /api/v1/templates (OQ-TEMPLATE-006) và danh sách model cho phép theo BOM PoC phần cứng (T1) vẫn chờ xác nhận.',
];

/**
 * Danh sách workspace tổng hợp dùng riêng cho chế độ preview WB-03;
 * không chứa workspaceId thật, credential hoặc dữ liệu người dùng thật.
 */
export const PREVIEW_WORKSPACES: readonly WorkspaceFixture[] = [
  {
    id: 'ws-preview-lab-a',
    name: 'Phòng thực hành A (Dữ liệu mẫu)',
    role: 'ADMIN',
    status: 'ACTIVE',
    description: 'Vai trò ADMIN tổng hợp: có sẵn template DRAFT và bản PUBLISHED chỉ đọc để thử nghiệm.',
    isSyntheticPreview: true,
  },
  {
    id: 'ws-preview-empty-c',
    name: 'Kho thiết bị trống (Dữ liệu mẫu)',
    role: 'ADMIN',
    status: 'ACTIVE',
    description: 'Vai trò ADMIN tổng hợp: chưa có template nào để minh họa trạng thái danh sách rỗng.',
    isSyntheticPreview: true,
  },
  {
    id: 'ws-preview-user-b',
    name: 'Phòng vận hành B (Dữ liệu mẫu)',
    role: 'USER',
    status: 'ACTIVE',
    description: 'Vai trò USER tổng hợp: không có quyền quản trị template nhằm minh họa chặn quyền 403/404.',
    isSyntheticPreview: true,
  },
];

/**
 * Đếm độ dài chuỗi theo Unicode code points để khớp quy tắc kiểm tra độ dài trong OQ-TEMPLATE-001..003.
 * Input
 * Param: value — chuỗi đầu vào cần đo độ dài code point.
 * Output: số lượng code point của chuỗi.
 */
function countCodePoints(value: string): number {
  return Array.from(value).length;
}

/**
 * Tạo bản sao sâu cho một TemplateDto nhằm bảo đảm state UI và kho in-memory không chia sẻ tham chiếu.
 * Input
 * Param: dto — bản ghi template cần sao chép.
 * Output: bản sao độc lập của TemplateDto.
 */
function cloneTemplateDto(dto: TemplateDto): TemplateDto {
  return {
    ...dto,
    streams: dto.streams.map(
      /** Sao chép từng stream và mảng enumValues để tránh đột biến chéo trong memory. */
      (stream) => ({ ...stream, enumValues: [...stream.enumValues] }),
    ),
    commands: dto.commands.map(
      /** Sao chép từng command SET_VALUE sang đối tượng mới. */
      (command) => ({ ...command }),
    ),
  };
}

/**
 * Khởi tạo dữ liệu mẫu ban đầu hoàn toàn tổng hợp cho các workspace preview trong tab hiện tại.
 * Output: bảng ánh xạ workspaceId tới danh sách TemplateDto mẫu.
 */
function createInitialMockDatabase(): Record<string, TemplateDto[]> {
  return {
    'ws-preview-lab-a': [
      {
        id: 'tpl-preview-room-01',
        workspaceId: 'ws-preview-lab-a',
        name: 'Cảm biến phòng thực hành (mẫu)',
        model: 'ESP32_DEMO_ENV_V1',
        status: 'DRAFT',
        schemaVersion: 1,
        revision: 3,
        publishedVersion: null,
        createdAt: '2026-11-18T08:15:00Z',
        updatedAt: '2026-11-20T09:30:00Z',
        streams: [
          {
            key: 'temperature',
            type: 'NUMBER',
            channelKind: 'TELEMETRY',
            direction: 'READ',
            unit: '°C',
            min: -20,
            max: 100,
            enumValues: [],
          },
          {
            key: 'humidity',
            type: 'NUMBER',
            channelKind: 'TELEMETRY',
            direction: 'READ',
            unit: '%',
            min: 0,
            max: 100,
            enumValues: [],
          },
          {
            key: 'fan',
            type: 'BOOLEAN',
            channelKind: 'STATE',
            direction: 'READ_WRITE',
            unit: null,
            min: null,
            max: null,
            enumValues: [],
          },
        ],
        commands: [
          {
            type: 'SET_VALUE',
            stream: 'fan',
            safeValue: false,
          },
        ],
      },
      {
        id: 'tpl-preview-relay-02',
        workspaceId: 'ws-preview-lab-a',
        name: 'Bộ điều khiển quạt 3 cấp (mẫu)',
        model: 'ESP32_DEMO_RELAY_V1',
        status: 'DRAFT',
        schemaVersion: 1,
        revision: 1,
        publishedVersion: null,
        createdAt: '2026-11-19T10:00:00Z',
        updatedAt: '2026-11-20T11:10:00Z',
        streams: [
          {
            key: 'fan_mode',
            type: 'ENUM',
            channelKind: 'STATE',
            direction: 'READ_WRITE',
            unit: null,
            min: null,
            max: null,
            enumValues: ['OFF', 'LOW', 'HIGH'],
          },
          {
            key: 'firmware_note',
            type: 'STRING',
            channelKind: 'STATE',
            direction: 'READ',
            unit: null,
            min: null,
            max: null,
            enumValues: [],
          },
        ],
        commands: [
          {
            type: 'SET_VALUE',
            stream: 'fan_mode',
            safeValue: 'OFF',
          },
        ],
      },
      {
        id: 'tpl-preview-published-03',
        workspaceId: 'ws-preview-lab-a',
        name: 'Cấu hình phòng đã công bố (mẫu)',
        model: 'ESP32_DEMO_MIXED_V1',
        status: 'PUBLISHED',
        schemaVersion: 1,
        revision: 4,
        publishedVersion: 1,
        createdAt: '2026-11-10T07:00:00Z',
        updatedAt: '2026-11-15T14:20:00Z',
        streams: [
          {
            key: 'temperature',
            type: 'NUMBER',
            channelKind: 'TELEMETRY',
            direction: 'READ',
            unit: '°C',
            min: -10,
            max: 85,
            enumValues: [],
          },
          {
            key: 'status_text',
            type: 'STRING',
            channelKind: 'STATE',
            direction: 'READ',
            unit: null,
            min: null,
            max: null,
            enumValues: [],
          },
          {
            key: 'led_indicator',
            type: 'BOOLEAN',
            channelKind: 'STATE',
            direction: 'READ_WRITE',
            unit: null,
            min: null,
            max: null,
            enumValues: [],
          },
        ],
        commands: [
          {
            type: 'SET_VALUE',
            stream: 'led_indicator',
            safeValue: false,
          },
        ],
      },
    ],
    'ws-preview-empty-c': [],
    // Dữ liệu nội bộ thuộc workspace B dùng để chứng minh cách ly: USER B không được đọc/sửa và A không bao giờ thấy.
    'ws-preview-user-b': [
      {
        id: 'tpl-preview-hidden-b',
        workspaceId: 'ws-preview-user-b',
        name: 'Template nội bộ workspace B (mẫu bị khóa)',
        model: 'ESP32_DEMO_ENV_V1',
        status: 'DRAFT',
        schemaVersion: 1,
        revision: 2,
        publishedVersion: null,
        createdAt: '2026-11-17T06:00:00Z',
        updatedAt: '2026-11-19T16:45:00Z',
        streams: [],
        commands: [],
      },
    ],
  };
}

/**
 * Chờ trễ mô phỏng bất đồng bộ nhưng hủy ngay khi AbortSignal kích hoạt,
 * giúp mô phỏng race condition khi người dùng chuyển workspace giữa lúc đang tải.
 * Input
 * Param: delayMs — độ trễ giả lập tính bằng mili-giây.
 * Param: signal — tín hiệu hủy từ bộ điều phối giao diện khi đổi ngữ cảnh workspace.
 * Errors: ném AbortError khi tín hiệu bị hủy trước khi hết thời gian chờ.
 */
function waitWithAbort(delayMs: number, signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) {
    return Promise.reject(new DOMException('Yêu cầu đã bị hủy do đổi ngữ cảnh.', 'AbortError'));
  }
  return new Promise(
    /**
     * Khởi tạo timer giả lập độ trễ và gắn listener AbortSignal để hủy promise kịp thời.
     * Input
     * Param: resolve — hoàn tất promise khi hết thời gian chờ mà chưa bị hủy.
     * Param: reject — từ chối promise bằng AbortError ngay khi tín hiệu hủy kích hoạt.
     */
    (resolve, reject) => {
      /** Dọn timer và listener sau khi hoàn tất hoặc bị hủy. */
      function cleanup(): void {
        signal?.removeEventListener('abort', handleAbort);
      }

      /** Hoàn tất promise khi hết độ trễ giả lập. */
      function handleTimerDone(): void {
        cleanup();
        resolve();
      }

      const timerId = window.setTimeout(handleTimerDone, delayMs);

      /** Hủy timeout ngay lập tức để không giữ closure sau khi đổi workspace. */
      function handleAbort(): void {
        window.clearTimeout(timerId);
        cleanup();
        reject(new DOMException('Yêu cầu đã bị hủy do đổi ngữ cảnh.', 'AbortError'));
      }

      signal?.addEventListener('abort', handleAbort, { once: true });
    },
  );
}

/**
 * Ánh xạ JSON Pointer từ lỗi validation (`details.fieldErrors[].path`) sang ID phần tử DOM trong biểu mẫu
 * để Error Summary liên kết và đưa tiêu điểm tới đúng ô nhập bị lỗi.
 * Input
 * Param: path — đường dẫn JSON Pointer theo quy ước mục 22 kế hoạch (ví dụ `/streams/0/key`).
 * Output: chuỗi ID DOM tương ứng trong TemplateEditor.
 */
export function fieldPathToElementId(path: string): string {
  if (path === '/name') return 'tpl-field-name';
  if (path === '/model') return 'tpl-field-model';
  if (path === '/streams') return 'tpl-streams-add';
  if (path === '/commands') return 'tpl-commands-add';

  const parts = path.split('/').filter(Boolean);
  if (parts[0] === 'streams' && parts.length >= 3) {
    const streamIndex = parts[1];
    const fieldName = parts[2];
    if (fieldName === 'enumValues' && parts.length === 4) {
      return `tpl-stream-${streamIndex}-enumValues-${parts[3]}`;
    }
    if (fieldName === 'enumValues') {
      return `tpl-stream-${streamIndex}-enumValues-add`;
    }
    return `tpl-stream-${streamIndex}-${fieldName}`;
  }
  if (parts[0] === 'commands' && parts.length >= 3) {
    return `tpl-command-${parts[1]}-${parts[2]}`;
  }
  return 'tpl-error-summary';
}

/**
 * Tạo một bản ghi datastream rỗng trong bộ nhớ form với `localId` ổn định cho React key.
 * Input
 * Param: localId — mã định danh cục bộ trong phiên chỉnh sửa để tránh mất focus khi sửa `key`.
 * Output: đối tượng TemplateStreamDraft mặc định.
 */
export function createEmptyStreamDraft(localId: string): TemplateStreamDraft {
  return {
    localId,
    key: '',
    type: 'NUMBER',
    channelKind: 'TELEMETRY',
    direction: 'READ',
    unit: '',
    minText: '',
    maxText: '',
    enumValues: [],
  };
}

/**
 * Tạo một bản ghi capability SET_VALUE rỗng; cố ý để `safeValueText` trống
 * nhằm không tự giả định `false` hay `0` là trạng thái an toàn phần cứng trước khi xác nhận PoC.
 * Input
 * Param: localId — mã cục bộ của dòng capability trong UI.
 * Param: streamKey — khóa stream đích nếu đã chọn sẵn từ gợi ý.
 * Output: đối tượng TemplateCommandDraft chưa điền giá trị an toàn.
 */
export function createEmptyCommandDraft(localId: string, streamKey = ''): TemplateCommandDraft {
  return {
    localId,
    type: 'SET_VALUE',
    stream: streamKey,
    safeValueText: '',
  };
}

/**
 * Tạo dữ liệu form ban đầu cho luồng tạo template DRAFT mới.
 * Output: đối tượng TemplateDraftForm trống, status DRAFT, schemaVersion = 1.
 */
export function createEmptyTemplateForm(): TemplateDraftForm {
  return {
    id: null,
    name: '',
    model: '',
    status: 'DRAFT',
    schemaVersion: 1,
    revision: null,
    publishedVersion: null,
    updatedAt: null,
    streams: [],
    commands: [],
  };
}

/**
 * Chuyển TemplateDto sang cấu trúc form chỉnh sửa UI mà giữ nguyên toàn bộ thuộc tính kiểu và ràng buộc.
 * Input
 * Param: dto — DTO mẫu nhận từ mock API.
 * Output: đối tượng TemplateDraftForm sẵn sàng cho trình chỉnh sửa.
 */
export function templateDtoToForm(dto: TemplateDto): TemplateDraftForm {
  return {
    id: dto.id,
    name: dto.name,
    model: dto.model,
    status: dto.status,
    schemaVersion: dto.schemaVersion,
    revision: dto.revision,
    publishedVersion: dto.publishedVersion,
    updatedAt: dto.updatedAt,
    streams: dto.streams.map(
      /** Gán localId ổn định theo chỉ số và key ban đầu để chỉnh sửa không làm mount lại input. */
      (stream, index) => ({
        localId: `stream-${index}-${stream.key}`,
        key: stream.key,
        type: stream.type,
        channelKind: stream.channelKind,
        direction: stream.direction,
        unit: stream.unit ?? '',
        minText: stream.min === null ? '' : String(stream.min),
        maxText: stream.max === null ? '' : String(stream.max),
        enumValues: [...stream.enumValues],
      }),
    ),
    commands: dto.commands.map(
      /** Giữ safeValue dạng chuỗi nhập liệu chính xác để tránh ép kiểu ngầm khi render control. */
      (command, index) => ({
        localId: `cmd-${index}-${command.stream}`,
        type: command.type,
        stream: command.stream,
        safeValueText: String(command.safeValue),
      }),
    ),
  };
}

/**
 * Tuần tự hóa dữ liệu người dùng nhập trong form (bỏ `localId` nội bộ) để phát hiện thay đổi chưa lưu.
 * Input
 * Param: form — trạng thái biểu mẫu hiện tại.
 * Output: chuỗi JSON chuẩn dùng so sánh dirty state trước khi rời trang hoặc đổi workspace.
 */
export function serializeFormForDirtyCheck(form: TemplateDraftForm): string {
  return JSON.stringify({
    name: form.name,
    model: form.model,
    streams: form.streams.map(
      /** Chỉ giữ các trường nghiệp vụ để so sánh dirty state chính xác. */
      (stream) => ({
        key: stream.key,
        type: stream.type,
        channelKind: stream.channelKind,
        direction: stream.direction,
        unit: stream.unit,
        minText: stream.minText,
        maxText: stream.maxText,
        enumValues: stream.enumValues,
      }),
    ),
    commands: form.commands.map(
      /** Chỉ giữ type, stream và safeValueText của từng capability. */
      (command) => ({
        type: command.type,
        stream: command.stream,
        safeValueText: command.safeValueText,
      }),
    ),
  });
}

/**
 * Phân tích chuỗi số hữu hạn nghiêm ngặt, từ chối NaN, Infinity hoặc chuỗi có ký tự thừa.
 * Input
 * Param: raw — chuỗi người dùng nhập vào ô số.
 * Output: kết quả hợp lệ kèm số hữu hạn hoặc null nếu rỗng.
 */
function parseStrictFiniteNumber(raw: string): { valid: boolean; value: number | null } {
  const trimmed = raw.trim();
  if (!trimmed) return { valid: true, value: null };
  if (!STRICT_FINITE_NUMBER_PATTERN.test(trimmed)) return { valid: false, value: null };
  const parsed = Number(trimmed);
  if (!Number.isFinite(parsed)) return { valid: false, value: null };
  return { valid: true, value: parsed };
}

/**
 * Kiểm tra toàn bộ schema ứng viên giống validator nguyên tử phía backend (OQ-TEMPLATE-001..005).
 * Không lưu từng phần nếu có bất kỳ lỗi nào; trả danh sách fieldErrors theo đường dẫn JSON Pointer.
 * Input
 * Param: form — dữ liệu biểu mẫu đang nhập.
 * Output: đối tượng chứa danh sách lỗi và DTO chuẩn hóa (nếu hợp lệ) hoặc mã lỗi kích thước 413.
 */
function validateCandidateSchema(form: TemplateDraftForm):
  | { ok: true; name: string; model: string; streams: TemplateStreamDto[]; commands: TemplateCommandDto[] }
  | { ok: false; status: 422 | 413; code: string; message: string; fieldErrors: FieldErrorItem[] } {
  const fieldErrors: FieldErrorItem[] = [];
  const normalizedName = form.name.normalize('NFC').trim();
  const normalizedModel = form.model.trim();

  if (countCodePoints(normalizedName) < 1) {
    fieldErrors.push({
      path: '/name',
      code: 'NAME_REQUIRED',
      message: 'Nhập tên template từ 1 đến 100 ký tự.',
    });
  } else if (countCodePoints(normalizedName) > MAX_TEMPLATE_NAME_LENGTH) {
    fieldErrors.push({
      path: '/name',
      code: 'NAME_TOO_LONG',
      message: 'Tên template không được vượt quá 100 ký tự.',
    });
  }

  if (countCodePoints(normalizedModel) < 1) {
    fieldErrors.push({
      path: '/model',
      code: 'MODEL_REQUIRED',
      message: 'Nhập mã model chuẩn (canonical model ID).',
    });
  } else if (
    countCodePoints(normalizedModel) > MAX_TEMPLATE_MODEL_LENGTH
    || !CANONICAL_MODEL_PATTERN.test(normalizedModel)
  ) {
    fieldErrors.push({
      path: '/model',
      code: 'MODEL_INVALID',
      message: 'Mã model chuẩn chỉ gồm 1–64 ký tự chữ không dấu, số, dấu chấm, gạch ngang hoặc gạch dưới.',
    });
  }

  if (form.streams.length > MAX_STREAMS_PER_TEMPLATE) {
    fieldErrors.push({
      path: '/streams',
      code: 'STREAM_LIMIT_EXCEEDED',
      message: 'Mỗi bản nháp tối đa 64 datastream.',
    });
  }

  if (form.commands.length > MAX_COMMANDS_PER_TEMPLATE) {
    fieldErrors.push({
      path: '/commands',
      code: 'COMMAND_LIMIT_EXCEEDED',
      message: 'Mỗi bản nháp tối đa 64 capability SET_VALUE.',
    });
  }

  const parsedStreams: TemplateStreamDto[] = [];
  const seenKeys = new Set<string>();
  const validStreamByKey = new Map<string, TemplateStreamDto>();

  for (let index = 0; index < form.streams.length; index += 1) {
    const rawStream = form.streams[index];
    const streamKey = rawStream.key.trim();
    const prefix = `/streams/${index}`;
    let streamKeyValid = true;

    if (!STREAM_KEY_PATTERN.test(streamKey)) {
      streamKeyValid = false;
      fieldErrors.push({
        path: `${prefix}/key`,
        code: 'STREAM_INVALID',
        message: 'Khóa kênh phải bắt đầu bằng chữ thường a–z, dài 1–64 ký tự và chỉ chứa a–z, 0–9, _.',
      });
    } else if (seenKeys.has(streamKey)) {
      streamKeyValid = false;
      fieldErrors.push({
        path: `${prefix}/key`,
        code: 'STREAM_DUPLICATE_KEY',
        message: `Khóa kênh "${streamKey}" bị trùng trong cùng phiên bản template.`,
      });
    } else {
      seenKeys.add(streamKey);
    }

    if (rawStream.type === 'STRING' && rawStream.direction !== 'READ') {
      fieldErrors.push({
        path: `${prefix}/direction`,
        code: 'STREAM_INVALID',
        message: 'Kênh kiểu STRING chỉ phục vụ hiển thị nên hướng phải là READ.',
      });
    }

    let unitValue: string | null = null;
    if (rawStream.type === 'NUMBER') {
      const trimmedUnit = rawStream.unit.trim();
      if (rawStream.unit.length > 0 && trimmedUnit.length === 0) {
        fieldErrors.push({
          path: `${prefix}/unit`,
          code: 'UNIT_INVALID',
          message: 'Để trống hoàn toàn khi không dùng đơn vị; không nhập khoảng trắng.',
        });
      } else if (countCodePoints(trimmedUnit) > MAX_STREAM_UNIT_LENGTH) {
        fieldErrors.push({
          path: `${prefix}/unit`,
          code: 'UNIT_TOO_LONG',
          message: 'Đơn vị hiển thị tối đa 32 ký tự.',
        });
      } else if (trimmedUnit.length > 0) {
        unitValue = trimmedUnit;
      }
    } else if (rawStream.unit.length > 0) {
      fieldErrors.push({
        path: `${prefix}/unit`,
        code: 'UNIT_FORBIDDEN',
        message: `Kiểu ${rawStream.type} không được khai báo unit.`,
      });
    }

    let minValue: number | null = null;
    let maxValue: number | null = null;
    if (rawStream.type === 'NUMBER') {
      const parsedMin = parseStrictFiniteNumber(rawStream.minText);
      const parsedMax = parseStrictFiniteNumber(rawStream.maxText);
      if (!parsedMin.valid) {
        fieldErrors.push({
          path: `${prefix}/min`,
          code: 'RANGE_NONFINITE',
          message: 'Giá trị tối thiểu phải là số hữu hạn hợp lệ.',
        });
      } else {
        minValue = parsedMin.value;
      }

      if (!parsedMax.valid) {
        fieldErrors.push({
          path: `${prefix}/max`,
          code: 'RANGE_NONFINITE',
          message: 'Giá trị tối đa phải là số hữu hạn hợp lệ.',
        });
      } else {
        maxValue = parsedMax.value;
      }

      const isWritable = rawStream.direction === 'WRITE' || rawStream.direction === 'READ_WRITE';
      if (isWritable) {
        if (parsedMin.valid && minValue === null) {
          fieldErrors.push({
            path: `${prefix}/min`,
            code: 'RANGE_REQUIRED',
            message: 'Kênh NUMBER ghi được bắt buộc khai báo giá trị tối thiểu.',
          });
        }
        if (parsedMax.valid && maxValue === null) {
          fieldErrors.push({
            path: `${prefix}/max`,
            code: 'RANGE_REQUIRED',
            message: 'Kênh NUMBER ghi được bắt buộc khai báo giá trị tối đa.',
          });
        }
      }

      if (minValue !== null && maxValue !== null && minValue > maxValue) {
        fieldErrors.push({
          path: `${prefix}/max`,
          code: 'RANGE_INVERTED',
          message: 'Giá trị tối đa phải lớn hơn hoặc bằng giá trị tối thiểu.',
        });
      }
    } else {
      if (rawStream.minText.trim() !== '') {
        fieldErrors.push({
          path: `${prefix}/min`,
          code: 'RANGE_FORBIDDEN',
          message: `Kiểu ${rawStream.type} không hỗ trợ min.`,
        });
      }
      if (rawStream.maxText.trim() !== '') {
        fieldErrors.push({
          path: `${prefix}/max`,
          code: 'RANGE_FORBIDDEN',
          message: `Kiểu ${rawStream.type} không hỗ trợ max.`,
        });
      }
    }

    const enumList: string[] = [];
    if (rawStream.type === 'ENUM') {
      if (rawStream.enumValues.length === 0) {
        fieldErrors.push({
          path: `${prefix}/enumValues`,
          code: 'ENUM_EMPTY',
          message: 'Kênh ENUM cần ít nhất 1 giá trị chuỗi hợp lệ.',
        });
      } else if (rawStream.enumValues.length > MAX_STREAMS_PER_TEMPLATE) {
        fieldErrors.push({
          path: `${prefix}/enumValues`,
          code: 'ENUM_LIMIT_EXCEEDED',
          message: 'Mỗi kênh ENUM tối đa 64 giá trị.',
        });
      }

      // So sánh enum theo đúng từng ký tự và phân biệt hoa thường theo OQ-TEMPLATE-003.
      const seenEnumValues = new Set<string>();
      for (let enumIndex = 0; enumIndex < rawStream.enumValues.length; enumIndex += 1) {
        const enumVal = rawStream.enumValues[enumIndex];
        if (enumVal.length === 0) {
          fieldErrors.push({
            path: `${prefix}/enumValues/${enumIndex}`,
            code: 'ENUM_VALUE_EMPTY',
            message: 'Giá trị enum không được để rỗng.',
          });
        } else if (countCodePoints(enumVal) > MAX_ENUM_VALUE_LENGTH) {
          fieldErrors.push({
            path: `${prefix}/enumValues/${enumIndex}`,
            code: 'ENUM_VALUE_TOO_LONG',
            message: 'Mỗi giá trị enum tối đa 64 ký tự.',
          });
        } else if (seenEnumValues.has(enumVal)) {
          fieldErrors.push({
            path: `${prefix}/enumValues/${enumIndex}`,
            code: 'ENUM_DUPLICATE',
            message: `Giá trị enum "${enumVal}" bị trùng (so sánh phân biệt hoa thường).`,
          });
        } else {
          seenEnumValues.add(enumVal);
          enumList.push(enumVal);
        }
      }
    } else if (rawStream.enumValues.length > 0) {
      fieldErrors.push({
        path: `${prefix}/enumValues`,
        code: 'ENUM_FORBIDDEN',
        message: `Kiểu ${rawStream.type} không dùng danh sách enumValues.`,
      });
    }

    const normalizedStream: TemplateStreamDto = {
      key: streamKey,
      type: rawStream.type,
      channelKind: rawStream.channelKind,
      direction: rawStream.direction,
      unit: unitValue,
      min: minValue,
      max: maxValue,
      enumValues: enumList,
    };
    parsedStreams.push(normalizedStream);
    if (streamKeyValid) {
      validStreamByKey.set(streamKey, normalizedStream);
    }
  }

  const parsedCommands: TemplateCommandDto[] = [];
  const commandTargets = new Set<string>();

  for (let cmdIndex = 0; cmdIndex < form.commands.length; cmdIndex += 1) {
    const rawCommand = form.commands[cmdIndex];
    const targetKey = rawCommand.stream.trim();
    const cmdPrefix = `/commands/${cmdIndex}`;

    if (!targetKey) {
      fieldErrors.push({
        path: `${cmdPrefix}/stream`,
        code: 'COMMAND_STREAM_REQUIRED',
        message: 'Chọn datastream đích cho capability SET_VALUE.',
      });
      continue;
    }

    const targetStream = validStreamByKey.get(targetKey);
    if (!targetStream) {
      fieldErrors.push({
        path: `${cmdPrefix}/stream`,
        code: 'COMMAND_DANGLING_STREAM',
        message: `Kênh "${targetKey}" không tồn tại trong danh sách datastream hiện hành.`,
      });
      continue;
    }

    if (targetStream.type === 'STRING') {
      fieldErrors.push({
        path: `${cmdPrefix}/stream`,
        code: 'COMMAND_STRING_FORBIDDEN',
        message: 'Kênh STRING chỉ hiển thị, không thể gắn capability điều khiển SET_VALUE.',
      });
      continue;
    }

    if (targetStream.direction === 'READ') {
      fieldErrors.push({
        path: `${cmdPrefix}/stream`,
        code: 'COMMAND_READ_ONLY_FORBIDDEN',
        message: 'Kênh hướng READ không được gắn capability SET_VALUE.',
      });
      continue;
    }

    if (commandTargets.has(targetKey)) {
      fieldErrors.push({
        path: `${cmdPrefix}/stream`,
        code: 'COMMAND_DUPLICATE_STREAM',
        message: `Mỗi kênh ghi được chỉ có tối đa một capability SET_VALUE ("${targetKey}").`,
      });
      continue;
    }
    commandTargets.add(targetKey);

    if (targetStream.type === 'NUMBER') {
      const parsedSafe = parseStrictFiniteNumber(rawCommand.safeValueText);
      if (!parsedSafe.valid || parsedSafe.value === null) {
        fieldErrors.push({
          path: `${cmdPrefix}/safeValue`,
          code: 'SAFE_VALUE_INVALID',
          message: 'safeValue của kênh NUMBER phải là số hữu hạn hợp lệ và không được để trống.',
        });
      } else if (
        (targetStream.min !== null && parsedSafe.value < targetStream.min)
        || (targetStream.max !== null && parsedSafe.value > targetStream.max)
      ) {
        fieldErrors.push({
          path: `${cmdPrefix}/safeValue`,
          code: 'SAFE_VALUE_OUT_OF_RANGE',
          message: 'safeValue phải nằm trong khoảng [min, max] đã khai báo cho kênh.',
        });
      } else {
        parsedCommands.push({ type: 'SET_VALUE', stream: targetKey, safeValue: parsedSafe.value });
      }
    } else if (targetStream.type === 'BOOLEAN') {
      if (rawCommand.safeValueText === 'true') {
        parsedCommands.push({ type: 'SET_VALUE', stream: targetKey, safeValue: true });
      } else if (rawCommand.safeValueText === 'false') {
        parsedCommands.push({ type: 'SET_VALUE', stream: targetKey, safeValue: false });
      } else {
        fieldErrors.push({
          path: `${cmdPrefix}/safeValue`,
          code: 'SAFE_VALUE_INVALID',
          message: 'Chọn rõ giá trị boolean true hoặc false cho safeValue.',
        });
      }
    } else if (targetStream.type === 'ENUM') {
      if (!rawCommand.safeValueText || !targetStream.enumValues.includes(rawCommand.safeValueText)) {
        fieldErrors.push({
          path: `${cmdPrefix}/safeValue`,
          code: 'SAFE_VALUE_INVALID',
          message: 'safeValue của kênh ENUM phải thuộc tập giá trị enumValues của kênh.',
        });
      } else {
        parsedCommands.push({ type: 'SET_VALUE', stream: targetKey, safeValue: rawCommand.safeValueText });
      }
    }
  }

  for (const stream of validStreamByKey.values()) {
    const requiresCommand =
      (stream.direction === 'WRITE' || stream.direction === 'READ_WRITE') && stream.type !== 'STRING';
    if (requiresCommand && !commandTargets.has(stream.key)) {
      fieldErrors.push({
        path: '/commands',
        code: 'COMMAND_REQUIRED',
        message: `Kênh ghi được "${stream.key}" cần đúng 1 capability SET_VALUE với safeValue hợp lệ.`,
      });
    }
  }

  if (fieldErrors.length > 0) {
    return {
      ok: false,
      status: 422,
      code: 'STREAM_INVALID',
      message: 'Dữ liệu schema chưa hợp lệ. Bản nháp chưa được ghi nhận; vui lòng sửa các trường được đánh dấu.',
      fieldErrors,
    };
  }

  const candidateJson = JSON.stringify({
    name: normalizedName,
    model: normalizedModel,
    streams: parsedStreams,
    commands: parsedCommands,
  });
  const payloadBytes = new TextEncoder().encode(candidateJson).length;
  if (payloadBytes > MAX_DRAFT_PAYLOAD_BYTES) {
    return {
      ok: false,
      status: 413,
      code: 'PAYLOAD_TOO_LARGE',
      message: 'Dung lượng cấu hình vượt ngưỡng 64 KiB của hợp đồng API.',
      fieldErrors: [],
    };
  }

  return {
    ok: true,
    name: normalizedName,
    model: normalizedModel,
    streams: parsedStreams,
    commands: parsedCommands,
  };
}

/**
 * Tạo JSON chỉ đọc hiển thị trong vùng SchemaPreview:
 * luôn cô lập ranh giới `TemplateDraft` hiện hành và ghi chú rõ các giả định chưa chốt ở gate G1.
 * Input
 * Param: form — dữ liệu biểu mẫu đang hiển thị.
 * Param: workspaceId — mã workspace tổng hợp hiện hành.
 * Output: đối tượng tuần tự hóa để hiển thị ở panel preview chỉ đọc.
 */
export function buildPreviewJsonPayload(
  form: TemplateDraftForm,
  workspaceId: string,
): Record<string, unknown> {
  return {
    previewOnlyNotice: 'CHỈ XEM TRƯỚC TRONG BỘ NHỚ TAB — CHƯA LƯU TRÊN MÁY CHỦ',
    templateId: form.id ?? '(chưa tạo trên server)',
    workspaceId,
    status: form.status,
    schemaVersion: form.schemaVersion,
    revision: form.revision ?? '(chưa cấp revision)',
    publishedVersion: form.publishedVersion,
    name: form.name.normalize('NFC').trim(),
    model: form.model.trim(),
    streams: form.streams.map(
      /** Biểu diễn stream tách rõ channelKind và direction theo ADR-004 và WF-TN-005. */
      (stream) => {
        const minParsed = parseStrictFiniteNumber(stream.minText);
        const maxParsed = parseStrictFiniteNumber(stream.maxText);
        return {
          key: stream.key.trim(),
          type: stream.type,
          channelKind: stream.channelKind,
          direction: stream.direction,
          unit: stream.type === 'NUMBER' ? stream.unit.trim() || null : null,
          min: stream.type === 'NUMBER' && minParsed.valid ? minParsed.value : null,
          max: stream.type === 'NUMBER' && maxParsed.valid ? maxParsed.value : null,
          enumValues: stream.type === 'ENUM' ? [...stream.enumValues] : [],
        };
      },
    ),
    commands: form.commands.map(
      /** Giữ cấu trúc commands[].safeValue theo đề xuất OQ-TEMPLATE-001/005. */
      (command) => ({
        type: command.type,
        stream: command.stream.trim(),
        safeValue: command.safeValueText === '' ? null : command.safeValueText,
      }),
    ),
  };
}

/**
 * Tạo kho dữ liệu mô phỏng trong bộ nhớ cho một phiên preview WB-03 trên tab trình duyệt hiện tại.
 * Output: đối tượng `TemplatePreviewStore` triển khai đọc danh sách, chi tiết, tạo và cập nhật bản nháp.
 */
export function createInMemoryTemplateStore(): TemplatePreviewStore {
  const db = createInitialMockDatabase();
  let createdSequence = 10;

  /**
   * Tra cứu workspace mẫu theo ID và kiểm tra quyền ADMIN ở lớp giả lập server-side.
   * Input
   * Param: workspaceId — mã workspace đang chọn.
   * Output: thông tin workspace nếu tồn tại.
   */
  function findWorkspace(workspaceId: string): WorkspaceFixture | undefined {
    return PREVIEW_WORKSPACES.find(
      /** So sánh đúng workspaceId đang chọn, không fallback sang workspace khác. */
      (workspace) => workspace.id === workspaceId,
    );
  }

  return {
    /**
     * Tải danh sách template theo đúng `workspaceId` hiện hành và phân trang cursor giả lập.
     * Input
     * Param: workspaceId — ID workspace tổng hợp đang chọn.
     * Param: scenario — chế độ mô phỏng lỗi mạng/404/bình thường.
     * Param: cursor — con trỏ phân trang tùy chọn cho lượt tải thêm.
     * Param: signal — tín hiệu hủy khi đổi workspace giữa lúc đang tải.
     * Output: danh sách template thuộc workspace hoặc lỗi quyền/mạng an toàn.
     */
    async listTemplates(workspaceId, scenario, cursor = null, signal) {
      await waitWithAbort(MOCK_LATENCY_MS, signal);
      if (scenario === 'offline') {
        return {
          ok: false,
          kind: 'network',
          status: 0,
          code: 'NETWORK_ERROR',
          message: 'Mất kết nối trong mô phỏng ngoại tuyến. Chưa tải được danh sách template.',
        };
      }

      const workspace = findWorkspace(workspaceId);
      if (!workspace) {
        return {
          ok: false,
          kind: 'permission',
          status: 404,
          code: 'RESOURCE_NOT_FOUND',
          message: 'Không tìm thấy workspace trong phạm vi hiện hành.',
        };
      }

      // Quyền USER chỉ đọc schema published qua device binding ở feature khác, không mở WB-03 editor/list quản trị.
      if (workspace.role !== 'ADMIN') {
        return {
          ok: false,
          kind: 'permission',
          status: 403,
          code: 'FORBIDDEN',
          message: 'Tài khoản vai trò USER không có quyền quản trị template trong workspace này.',
        };
      }

      const allItems = db[workspaceId] ?? [];
      const offset = cursor ? Number.parseInt(cursor, 10) : 0;
      const safeOffset = Number.isFinite(offset) && offset >= 0 ? offset : 0;
      const slice = allItems.slice(safeOffset, safeOffset + MOCK_PAGE_SIZE).map(cloneTemplateDto);
      const nextOffset = safeOffset + slice.length;
      const nextCursor = nextOffset < allItems.length ? String(nextOffset) : null;

      return { ok: true, workspace, items: slice, nextCursor };
    },

    /**
     * Đọc chi tiết một template theo scope workspace; trả 404 nếu ngoài scope hoặc ở kịch bản 404.
     * Input
     * Param: workspaceId — mã workspace hiện hành.
     * Param: templateId — mã template cần mở.
     * Param: scenario — kịch bản mô phỏng lỗi tùy chọn.
     * Param: signal — tín hiệu hủy khi chuyển workspace.
     * Output: TemplateDto nếu hợp lệ trong scope, hoặc lỗi 403/404/network an toàn.
     */
    async getTemplate(workspaceId, templateId, scenario, signal) {
      await waitWithAbort(MOCK_LATENCY_MS, signal);
      if (scenario === 'offline') {
        return {
          ok: false,
          kind: 'network',
          status: 0,
          code: 'NETWORK_ERROR',
          message: 'Ngoại tuyến: chưa thể tải chi tiết template từ bộ nhớ mô phỏng.',
        };
      }
      const workspace = findWorkspace(workspaceId);
      if (!workspace || scenario === 'not_found_404') {
        return {
          ok: false,
          kind: 'not_found',
          status: 404,
          code: 'RESOURCE_NOT_FOUND',
          message: 'Không tìm thấy template trong workspace hiện tại (404).',
        };
      }
      if (workspace.role !== 'ADMIN') {
        return {
          ok: false,
          kind: 'permission',
          status: 403,
          code: 'FORBIDDEN',
          message: 'Vai trò USER không được phép mở trình chỉnh sửa template.',
        };
      }

      const found = (db[workspaceId] ?? []).find(
        /** Chỉ tìm trong mảng dữ liệu thuộc đúng workspaceId hiện tại. */
        (item) => item.id === templateId,
      );
      if (!found) {
        return {
          ok: false,
          kind: 'not_found',
          status: 404,
          code: 'RESOURCE_NOT_FOUND',
          message: 'Template không tồn tại hoặc thuộc workspace khác (404).',
        };
      }
      return { ok: true, template: cloneTemplateDto(found) };
    },

    /**
     * Mô phỏng `POST /api/v1/templates` tạo draft mới trong bộ nhớ workspace hiện tại;
     * ở kịch bản `pending_post_unknown` vẫn ghi draft ứng viên để mô phỏng mất ACK 201 nhưng trả unknown.
     * Input
     * Param: workspaceId — workspace từ context đã chọn (không lấy từ body client).
     * Param: form — dữ liệu draft từ editor.
     * Param: scenario — kịch bản mô phỏng hiện hành.
     * Param: signal — tín hiệu hủy khi đổi workspace.
     * Output: kết quả tạo draft, lỗi validation 422/413, lỗi mạng hoặc trạng thái unknown_outcome.
     */
    async createDraft(workspaceId, form, scenario, signal) {
      await waitWithAbort(MOCK_LATENCY_MS, signal);
      if (scenario === 'offline') {
        return {
          ok: false,
          kind: 'network',
          status: 0,
          code: 'NETWORK_ERROR',
          message: 'Mất kết nối mạng. Bản nháp vẫn được giữ tại trình duyệt; chỉ gửi lại khi bạn nhấn lưu.',
        };
      }
      const workspace = findWorkspace(workspaceId);
      if (!workspace || scenario === 'not_found_404') {
        return {
          ok: false,
          kind: 'not_found',
          status: 404,
          code: 'RESOURCE_NOT_FOUND',
          message: 'Workspace không khả dụng hoặc không thuộc phạm vi hiện tại (404).',
        };
      }
      if (workspace.role !== 'ADMIN') {
        return {
          ok: false,
          kind: 'permission',
          status: 403,
          code: 'FORBIDDEN',
          message: 'Bạn không có quyền tạo template với vai trò USER.',
        };
      }

      const validated = validateCandidateSchema(form);
      if (!validated.ok) {
        return {
          ok: false,
          kind: 'validation',
          status: validated.status,
          code: validated.code,
          message: validated.message,
          fieldErrors: validated.fieldErrors,
        };
      }

      createdSequence += 1;
      const nowIso = new Date().toISOString();
      const created: TemplateDto = {
        id: `tpl-preview-draft-${createdSequence}`,
        workspaceId,
        name: validated.name,
        model: validated.model,
        status: 'DRAFT',
        schemaVersion: 1,
        revision: 1,
        publishedVersion: null,
        createdAt: nowIso,
        updatedAt: nowIso,
        streams: validated.streams,
        commands: validated.commands,
      };
      db[workspaceId] = [created, ...(db[workspaceId] ?? [])];

      if (scenario === 'pending_post_unknown') {
        // Giả lập mất phản hồi 201 sau khi đã ghi draft (OQ-TEMPLATE-006 / WEB-TEMPLATE-005): UI không tự POST lại.
        return {
          ok: false,
          kind: 'unknown_outcome',
          status: 0,
          code: 'CREATE_OUTCOME_UNKNOWN',
          message:
            'Chưa nhận được xác nhận phản hồi sau khi tạo template. Hệ thống không tự gửi lại POST; hãy kiểm tra danh sách bản nháp trong workspace để chọn bản phù hợp.',
        };
      }

      return {
        ok: true,
        template: cloneTemplateDto(created),
        unresolvedWireNotes: UNRESOLVED_WIRE_ASSUMPTIONS,
      };
    },

    /**
     * Mô phỏng `PATCH /api/v1/templates/{id}` với kiểm tra `If-Match`, trạng thái `PUBLISHED` bất biến
     * và toàn bộ schema ứng viên theo từng workspace.
     * Input
     * Param: workspaceId — workspace hiện hành.
     * Param: templateId — ID template cần cập nhật.
     * Param: expectedRevision — giá trị `If-Match` revision phía UI đang giữ.
     * Param: form — dữ liệu schema ứng viên thay thế toàn bộ.
     * Param: scenario — chế độ mô phỏng xung đột/lỗi mạng/404.
     * Param: signal — tín hiệu hủy khi đổi workspace.
     * Output: kết quả cập nhật preview hoặc lỗi 409/412/422/428/403/404/network.
     */
    async updateDraft(workspaceId, templateId, expectedRevision, form, scenario, signal) {
      await waitWithAbort(MOCK_LATENCY_MS, signal);
      if (scenario === 'offline') {
        return {
          ok: false,
          kind: 'network',
          status: 0,
          code: 'NETWORK_ERROR',
          message: 'Mất kết nối mạng. Thay đổi cục bộ vẫn giữ nguyên và chưa được lưu.',
        };
      }
      const workspace = findWorkspace(workspaceId);
      if (!workspace || scenario === 'not_found_404') {
        return {
          ok: false,
          kind: 'not_found',
          status: 404,
          code: 'RESOURCE_NOT_FOUND',
          message: 'Không tìm thấy template trong workspace hiện hành (404).',
        };
      }
      if (workspace.role !== 'ADMIN') {
        return {
          ok: false,
          kind: 'permission',
          status: 403,
          code: 'FORBIDDEN',
          message: 'Vai trò USER không được phép chỉnh sửa template.',
        };
      }

      const items = db[workspaceId] ?? [];
      const index = items.findIndex(
        /** Tìm chính xác template trong scope workspace hiện hành. */
        (item) => item.id === templateId,
      );
      if (index === -1) {
        return {
          ok: false,
          kind: 'not_found',
          status: 404,
          code: 'RESOURCE_NOT_FOUND',
          message: 'Template không tồn tại trong workspace này (404).',
        };
      }

      const current = items[index];
      if (current.status === 'PUBLISHED') {
        return {
          ok: false,
          kind: 'immutable_409',
          status: 409,
          code: 'IMMUTABLE_SCHEMA',
          message:
            'Phiên bản template đã công bố (PUBLISHED) là bất biến (409 IMMUTABLE_SCHEMA). Hãy giữ chế độ chỉ đọc và tạo draft mới qua luồng FEAT-TN-006 khi sẵn sàng.',
          serverTemplate: cloneTemplateDto(current),
        };
      }

      if (expectedRevision === null) {
        return {
          ok: false,
          kind: 'precondition_428',
          status: 428,
          code: 'PRECONDITION_REQUIRED',
          message: 'Thiếu header If-Match revision (428 PRECONDITION_REQUIRED). Vui lòng tải lại bản nháp.',
        };
      }

      if (scenario === 'stale_412' || expectedRevision !== current.revision) {
        // Khi mô phỏng 412, giả lập phiên bản mới hơn từ một phiên chỉnh sửa khác nhưng vẫn giữ bản nháp cục bộ.
        const serverSnapshot: TemplateDto = {
          ...cloneTemplateDto(current),
          revision: current.revision + (scenario === 'stale_412' ? 1 : 0),
          updatedAt: new Date().toISOString(),
          name:
            scenario === 'stale_412' && !current.name.endsWith(' [đã cập nhật từ phiên khác]')
              ? `${current.name} [đã cập nhật từ phiên khác]`
              : current.name,
        };
        if (scenario === 'stale_412') {
          items[index] = serverSnapshot;
        }
        return {
          ok: false,
          kind: 'conflict_412',
          status: 412,
          code: 'VERSION_CONFLICT',
          message:
            `Xung đột phiên bản (412 VERSION_CONFLICT): máy chủ đang ở revision #${serverSnapshot.revision}. Thay đổi của bạn được giữ riêng để bạn đối chiếu và áp dụng lại.`,
          serverTemplate: cloneTemplateDto(serverSnapshot),
        };
      }

      const validated = validateCandidateSchema(form);
      if (!validated.ok) {
        return {
          ok: false,
          kind: 'validation',
          status: validated.status,
          code: validated.code,
          message: validated.message,
          fieldErrors: validated.fieldErrors,
        };
      }

      const updated: TemplateDto = {
        ...current,
        name: validated.name,
        model: validated.model,
        revision: current.revision + 1,
        updatedAt: new Date().toISOString(),
        streams: validated.streams,
        commands: validated.commands,
      };
      items[index] = updated;

      return {
        ok: true,
        template: cloneTemplateDto(updated),
        unresolvedWireNotes: UNRESOLVED_WIRE_ASSUMPTIONS,
      };
    },
  };
}
