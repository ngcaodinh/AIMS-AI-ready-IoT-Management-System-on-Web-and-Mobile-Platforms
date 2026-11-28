import { useEffect, useMemo, useRef, useState, type MouseEvent } from 'react';
import type { SessionMetadata } from '../auth/api.ts';
import { WorkspaceApiError } from '../workspace/workspaceApi.ts';
import { TemplateEditor, type StreamDefaultInputState } from './TemplateEditor.tsx';
import { TemplatePublishPanel, type PublishOutcomeState } from './TemplatePublishPanel.tsx';
import {
  createTemplateDraftApi,
  getTemplateApi,
  getTemplateVersionApi,
  listTemplatesApi,
  listTemplateVersionsApi,
  patchTemplateDraftApi,
  recoverPublishBySourceRevisionApi,
  cloneTemplateDraftApi,
} from './templateApi.ts';
import {
  attachExactDefaultNumberToken,
  attachExactSafeValueNumberToken,
  canonicalDecimalIdentity,
  getCommandSafeValueDescriptor,
  getStreamDefaultDescriptor,
  getStreamEnumDescriptors,
  hasLegacyNumericEnum,
  type StreamInputDto,
  type TemplateCommandDto,
  type TemplateDto as LiveTemplateDto,
  type TemplatePatchInput,
  type TemplateVersionDto,
} from './templateContract.ts';
import {
  createEmptyTemplateForm,
  serializeFormForDirtyCheck,
  type FieldErrorItem,
  type TemplateCommandDraft,
  type TemplateDraftForm,
  type TemplateDto as EditorTemplateDto,
  type TemplateSaveOutcome,
  type TemplateStreamDraft,
} from './templateMockApi.ts';
import './templates.css';

interface TemplatesWorkbenchProps {
  workspaceId: string;
  workspaceName: string;
  workspaceRole: 'ADMIN' | 'USER';
  session: SessionMetadata;
  onAuthError: (code: string) => void;
}

/**
 * Chuyển `TemplateDto` chuẩn G1 sang cấu trúc `EditorTemplateDto` của trình chỉnh sửa WB-03
 * mà giữ nguyên kiểu trường, `channelKind`, `direction`, `safeValue` và revision.
 * Input
 * Param: dto — template nhận từ API thật theo hợp đồng G1.
 * Output: bản ghi tương thích với form state của `TemplateEditor`.
 */
function liveTemplateToEditorDto(dto: LiveTemplateDto): EditorTemplateDto {
  return {
    id: dto.id,
    workspaceId: dto.workspaceId,
    name: dto.name,
    model: dto.model,
    status: dto.status === 'ARCHIVED' ? 'PUBLISHED' : dto.status,
    schemaVersion: 1,
    revision: dto.revision,
    publishedVersion: null,
    createdAt: dto.createdAt,
    updatedAt: dto.updatedAt,
    streams: dto.streams.map(
      /** Ánh xạ StreamOutput chuẩn G1 sang dạng hiển thị của editor WB-03. */
      (stream) => ({
        key: stream.key,
        type: stream.type,
        channelKind: stream.channelKind,
        direction: stream.direction,
        unit: stream.unit ?? null,
        min: stream.min ?? null,
        max: stream.max ?? null,
        enumValues: getStreamEnumDescriptors(stream).map((desc) => desc.display),
      }),
    ),
    commands: dto.commands.map(
      /** Giữ nguyên capability `SET_VALUE` và `safeValue`. */
      (cmd) => ({ ...cmd }),
    ),
  };
}

/**
 * Chuyển dữ liệu đang nhập trong `TemplateDraftForm` và bảng `streamDefaults` sang payload
 * `StreamInputDto[]` và `TemplateCommandDto[]` theo đúng hợp đồng G1 (`channelKind` và `direction` độc lập, `default`, `safeValue`),
 * bảo toàn cả `default: ""` / toàn khoảng trắng lẫn token số nguyên thủy của trường ghi được.
 * Input
 * Param: form — dữ liệu biểu mẫu người dùng đang sửa.
 * Param: streamDefaults — bảng trạng thái `{ present, text }` của giá trị mặc định theo `localId`.
 * Output: danh sách streams và commands sẵn sàng gửi POST/PATCH lên backend.
 */
function editorFormToWirePayload(
  form: TemplateDraftForm,
  streamDefaults: Readonly<Record<string, StreamDefaultInputState>>,
): {
  name: string;
  model: string;
  streams: StreamInputDto[];
  commands: TemplateCommandDto[];
} {
  const streams: StreamInputDto[] = form.streams.map(
    /** Chuyển từng stream draft sang `StreamInputDto` chuẩn G1 kèm `default` nếu có. */
    (stream) => {
      const next: StreamInputDto = {
        key: stream.key.trim(),
        type: stream.type,
        channelKind: stream.channelKind,
        direction: stream.direction,
      };
      if (stream.type === 'NUMBER') {
        const trimmedUnit = stream.unit.trim();
        next.unit = trimmedUnit.length > 0 ? trimmedUnit : null;
        if (stream.minText.trim() !== '') next.min = Number(stream.minText.trim());
        if (stream.maxText.trim() !== '') next.max = Number(stream.maxText.trim());
      }
      if (stream.type === 'ENUM') {
        next.enumValues = [...stream.enumValues];
      }
      const defaultState = streamDefaults[stream.localId] ?? { present: false, text: '' };
      if (defaultState.present) {
        if (stream.type === 'STRING') {
          next.default = defaultState.text;
        } else if (stream.type === 'ENUM') {
          if (defaultState.text !== '') next.default = defaultState.text;
        } else if (stream.type === 'NUMBER') {
          const trimmedDefault = defaultState.text.trim();
          if (trimmedDefault !== '') {
            const parsed = Number(trimmedDefault);
            if (canonicalDecimalIdentity(trimmedDefault) !== null && Number.isFinite(parsed)) {
              next.default = Object.is(parsed, -0) ? 0 : parsed;
              attachExactDefaultNumberToken(next, trimmedDefault);
            } else {
              next.default = trimmedDefault;
            }
          }
        } else if (stream.type === 'BOOLEAN') {
          const trimmedBool = defaultState.text.trim();
          if (trimmedBool !== '') {
            if (trimmedBool === 'true') next.default = true;
            else if (trimmedBool === 'false') next.default = false;
            else next.default = trimmedBool;
          }
        }
      }
      return next;
    },
  );
  const streamTypeByKey = new Map(
    streams.map(
      /** Ghi nhận kiểu dữ liệu theo khóa kênh để tuần tự hóa `safeValue` đúng kiểu JSON. */
      (stream) => [stream.key, stream.type] as const,
    ),
  );
  const commands: TemplateCommandDto[] = form.commands.map(
    /** Chuyển `safeValueText` thành kiểu scalar JSON khớp kênh đích và giữ nguyên token số chính xác. */
    (cmd) => {
      const targetKey = cmd.stream.trim();
      const targetType = streamTypeByKey.get(targetKey);
      let safeValue: number | boolean | string = cmd.safeValueText;
      let exactNumToken: string | null = null;
      if (targetType === 'NUMBER' && cmd.safeValueText.trim() !== '') {
        const trimmedSafe = cmd.safeValueText.trim();
        const parsed = Number(trimmedSafe);
        if (canonicalDecimalIdentity(trimmedSafe) !== null && Number.isFinite(parsed)) {
          safeValue = Object.is(parsed, -0) ? 0 : parsed;
          exactNumToken = trimmedSafe;
        }
      } else if (targetType === 'BOOLEAN') {
        if (cmd.safeValueText === 'true') safeValue = true;
        else if (cmd.safeValueText === 'false') safeValue = false;
      }
      const nextCmd: TemplateCommandDto = {
        type: 'SET_VALUE',
        stream: targetKey,
        safeValue,
      };
      if (exactNumToken !== null) {
        attachExactSafeValueNumberToken(nextCmd, exactNumToken);
      }
      return nextCmd;
    },
  );
  return {
    name: form.name.normalize('NFC').trim(),
    model: form.model.trim(),
    streams,
    commands,
  };
}

/**
 * Chuyển `LiveTemplateDto` thành `TemplateDraftForm` để đưa vào `TemplateEditor`.
 * Input
 * Param: dto — bản ghi template G1 từ API thật.
 * Output: dữ liệu form khớp state của trình chỉnh sửa WB-03 (giữ nguyên chuỗi số decimal lớn từ token).
 */
function liveDtoToForm(dto: LiveTemplateDto): TemplateDraftForm {
  return {
    id: dto.id,
    name: dto.name,
    model: dto.model,
    status: dto.status === 'ARCHIVED' ? 'PUBLISHED' : dto.status,
    schemaVersion: 1,
    revision: dto.revision,
    publishedVersion: null,
    updatedAt: dto.updatedAt,
    streams: dto.streams.map(
      /** Giữ `localId` ổn định và lấy chuỗi hiển thị không làm tròn cho các thành viên enum. */
      (stream, index) => ({
        localId: `live-stream-${index}-${stream.key}`,
        key: stream.key,
        type: stream.type,
        channelKind: stream.channelKind,
        direction: stream.direction,
        unit: stream.unit ?? '',
        minText: stream.min === undefined ? '' : String(stream.min),
        maxText: stream.max === undefined ? '' : String(stream.max),
        enumValues: getStreamEnumDescriptors(stream).map((desc) => desc.display),
      }),
    ),
    commands: dto.commands.map(
      /** Chuyển capability `SET_VALUE` sang chuỗi điều khiển bảo toàn token số nguyên thủy. */
      (cmd, index) => ({
        localId: `live-cmd-${index}-${cmd.stream}`,
        type: 'SET_VALUE',
        stream: cmd.stream,
        safeValueText: getCommandSafeValueDescriptor(cmd).display,
      }),
    ),
  };
}

/**
 * Trích trạng thái `{ present, text }` của `default` theo `localId`,
 * phân biệt rõ trường vắng mặt (`present: false`) với chuỗi rỗng tường minh `""` (`present: true`).
 * Input
 * Param: dto — bản ghi template G1 từ API thật.
 * Output: bảng `StreamDefaultInputState` theo `localId`.
 */
function extractStreamDefaults(dto: LiveTemplateDto): Record<string, StreamDefaultInputState> {
  const next: Record<string, StreamDefaultInputState> = {};
  dto.streams.forEach(
    /** Ghi nhận cả trường hợp `default: ""` lẫn giá trị số lớn chính xác. */
    (stream, index) => {
      const desc = getStreamDefaultDescriptor(stream);
      if (desc !== undefined) {
        next[`live-stream-${index}-${stream.key}`] = {
          present: true,
          text: desc.display,
        };
      }
    },
  );
  return next;
}

/**
 * Tuần tự hóa trạng thái các kênh và giá trị `default` thô (kể cả cờ `present`) để phát hiện thay đổi phần `streams` khi lưu PATCH.
 * Input
 * Param: streams — mảng datastream trên form.
 * Param: defaults — bảng trạng thái `{ present, text }` theo `localId`.
 * Output: chuỗi chuẩn phản ánh nguyên trạng các kênh hiện có.
 */
function serializeStreamsState(
  streams: readonly TemplateStreamDraft[],
  defaults: Readonly<Record<string, StreamDefaultInputState>>,
): string {
  return JSON.stringify(
    streams.map(
      /** Gom toàn bộ thuộc tính cấu hình kênh kèm cờ tường minh và chuỗi `default` chưa bị trim. */
      (stream) => {
        const entry = defaults[stream.localId];
        return {
          key: stream.key,
          type: stream.type,
          channelKind: stream.channelKind,
          direction: stream.direction,
          unit: stream.unit,
          minText: stream.minText,
          maxText: stream.maxText,
          enumValues: stream.enumValues,
          defaultPresent: entry?.present ?? false,
          defaultText: entry?.text ?? '',
        };
      },
    ),
  );
}

/**
 * Tuần tự hóa danh sách capability `SET_VALUE` để phát hiện thay đổi phần `commands` khi lưu PATCH.
 * Input
 * Param: commands — mảng lệnh an toàn trên form.
 * Output: chuỗi phản ánh cấu hình `commands[]`.
 */
function serializeCommandsState(commands: readonly TemplateCommandDraft[]): string {
  return JSON.stringify(
    commands.map(
      /** Giữ nguyên khóa kênh đích và giá trị `safeValueText` để so sánh thay đổi. */
      (cmd) => ({
        type: cmd.type,
        stream: cmd.stream,
        safeValueText: cmd.safeValueText,
      }),
    ),
  );
}

/**
 * Tạo payload PATCH tối thiểu cho bản nháp đã tồn tại trên máy chủ:
 * chỉ gửi các phần (`name`, `model`, `streams`, `commands`) thực sự thay đổi so với `currentRoot`,
 * và luôn chỉ gửi `{ name }` đối với draft chứa ENUM số lịch sử.
 * Input
 * Param: currentRoot — bản ghi template gốc đã tải từ server.
 * Param: form — dữ liệu biểu mẫu đang sửa.
 * Param: streamDefaults — bảng trạng thái `{ present, text }` theo `localId`.
 * Output: `TemplatePatchInput` tối thiểu và an toàn dữ liệu.
 */
function buildLiveDraftPatchPayload(
  currentRoot: LiveTemplateDto,
  form: TemplateDraftForm,
  streamDefaults: Readonly<Record<string, StreamDefaultInputState>>,
): TemplatePatchInput {
  const full = editorFormToWirePayload(form, streamDefaults);
  if (hasLegacyNumericEnum(currentRoot)) {
    return { name: full.name };
  }
  const baselineForm = liveDtoToForm(currentRoot);
  const baselineDefaults = extractStreamDefaults(currentRoot);

  const patch: TemplatePatchInput = {};
  if (full.name !== currentRoot.name.normalize('NFC').trim()) {
    patch.name = full.name;
  }
  if (full.model !== currentRoot.model.trim()) {
    patch.model = full.model;
  }
  if (
    serializeStreamsState(form.streams, streamDefaults)
    !== serializeStreamsState(baselineForm.streams, baselineDefaults)
  ) {
    patch.streams = full.streams;
  }
  if (serializeCommandsState(form.commands) !== serializeCommandsState(baselineForm.commands)) {
    patch.commands = full.commands;
  }
  if (Object.keys(patch).length === 0) {
    patch.name = full.name;
  }
  return patch;
}

/**
 * Tạo khóa tuần tự hóa gồm `TemplateDraftForm` và `streamDefaults` để phát hiện `isDirty` chính xác.
 * Input
 * Param: form — dữ liệu form chính.
 * Param: streamDefaults — bảng trạng thái `{ present, text }` theo `localId`.
 * Output: chuỗi đại diện trạng thái hiện tại của biểu mẫu live.
 */
function serializeDraftStateKey(
  form: TemplateDraftForm,
  streamDefaults: Readonly<Record<string, StreamDefaultInputState>>,
): string {
  const defaultsList = form.streams.map(
    /** Gắn cờ `present` và chuỗi `default` hiện hành theo đúng thứ tự kênh để bắt mọi thay đổi. */
    (stream) => {
      const entry = streamDefaults[stream.localId];
      return [stream.localId, entry?.present ?? false, entry?.text ?? ''] as const;
    },
  );
  return JSON.stringify({
    formKey: serializeFormForDirtyCheck(form),
    defaultsList,
  });
}

/**
 * Ánh xạ lỗi field từ `ErrorEnvelope` sang mô tả an toàn trên UI theo JSON Pointer.
 * Input
 * Param: error — lỗi `WorkspaceApiError` trả về từ API thật.
 * Output: mảng `FieldErrorItem[]` dùng cho `FieldErrorSummary` và field errors.
 */
function toFieldErrors(error: WorkspaceApiError): FieldErrorItem[] {
  return error.fieldErrors.map(
    /** Giữ nguyên JSON Pointer `path` và mã `code` đã kiểm duyệt, không in payload thô. */
    (item) => ({
      path: item.path,
      code: item.code,
      message: `Lỗi hợp lệ (${item.code}) tại ${item.path}`,
    }),
  );
}

/**
 * Chuyển đổi workspace Workbench cho FEAT-TN-005 T4 (WB-03 draft editor) và FEAT-TN-006 V4 (publish/diff/clone/recovery),
 * nối trực tiếp các endpoint G1 thật và cô lập hoàn toàn dữ liệu khi đổi `workspaceId`.
 * Input
 * Param: props — workspace đang chọn, vai trò hiện hành và metadata phiên xác thực trong RAM.
 * Output: giao diện quản trị Template WB-03 + V4 có cô lập ngữ cảnh và khôi phục an toàn.
 */
export function TemplatesWorkbench({
  workspaceId,
  workspaceName,
  workspaceRole,
  session,
  onAuthError,
}: TemplatesWorkbenchProps) {
  const [view, setView] = useState<'list' | 'editor'>('list');
  const [templates, setTemplates] = useState<LiveTemplateDto[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [isLoadingList, setIsLoadingList] = useState<boolean>(true);
  const [listError, setListError] = useState<string>('');
  const [reloadNonce, setReloadNonce] = useState<number>(0);

  const [currentRoot, setCurrentRoot] = useState<LiveTemplateDto | null>(null);
  const [editorForm, setEditorForm] = useState<TemplateDraftForm>(createEmptyTemplateForm);
  const [streamDefaults, setStreamDefaults] = useState<Record<string, StreamDefaultInputState>>({});
  const [baselineKey, setBaselineKey] = useState<string>(
    () => serializeDraftStateKey(createEmptyTemplateForm(), {}),
  );
  const [saveOutcome, setSaveOutcome] = useState<TemplateSaveOutcome | null>(null);
  const [pendingCandidates, setPendingCandidates] = useState<LiveTemplateDto[]>([]);
  const [isSubmitting, setIsSubmitting] = useState<boolean>(false);
  const [errorFocusNonce, setErrorFocusNonce] = useState<number>(0);

  const [versions, setVersions] = useState<TemplateVersionDto[]>([]);
  const [versionsNextCursor, setVersionsNextCursor] = useState<string | null>(null);
  const [selectedVersion, setSelectedVersion] = useState<TemplateVersionDto | null>(null);
  const [isLoadingVersions, setIsLoadingVersions] = useState<boolean>(false);
  const [publishOutcome, setPublishOutcome] = useState<PublishOutcomeState>(null);

  const headingRef = useRef<HTMLHeadingElement | null>(null);
  const generationRef = useRef<number>(0);
  const abortRef = useRef<AbortController | null>(null);
  const ctx = useMemo(
    /** Gói cặp `workspaceId` và `session` hiện hành để truyền cho API client. */
    () => ({ workspaceId, session }),
    [workspaceId, session],
  );
  const isLegacyNumericEnumDraft = useMemo(
    /** Khóa sửa schema/capability trên draft có ENUM số lịch sử để không mất hoặc ép kiểu dữ liệu. */
    () => Boolean(currentRoot && currentRoot.status === 'DRAFT' && hasLegacyNumericEnum(currentRoot)),
    [currentRoot],
  );
  const isDirty = useMemo(
    /** Xác định form editor đang có chỉnh sửa cục bộ chưa lưu so với mốc đã tải. */
    () => view === 'editor' && serializeDraftStateKey(editorForm, streamDefaults) !== baselineKey,
    [view, editorForm, streamDefaults, baselineKey],
  );
  const editorPendingCandidates = useMemo(
    /** Chuyển danh sách ứng viên khôi phục `LiveTemplateDto[]` sang `EditorTemplateDto[]` tại ranh giới truyền props cho `TemplateEditor`. */
    () => pendingCandidates.map(liveTemplateToEditorDto),
    [pendingCandidates],
  );

  /** Kiểm tra lỗi xác thực hoặc context mismatch để trả quyền điều phối lại cho `AuthCoordinator`. */
  function forwardAuthBoundary(error: unknown): boolean {
    if (error instanceof WorkspaceApiError && [401, 409].includes(error.status)
      && ['SESSION_EXPIRED', 'SESSION_REVOKED', 'AUTH_CONTEXT_MISMATCH', 'CSRF_INVALID'].includes(error.code)) {
      onAuthError(error.code);
      return true;
    }
    return false;
  }

  /** Hủy mọi yêu cầu đang chờ và xóa toàn bộ dữ liệu workspace cũ ngay khi `workspaceId` thay đổi. */
  useEffect(() => {
    generationRef.current += 1;
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    const generation = generationRef.current;

    setView('list');
    setTemplates([]);
    setNextCursor(null);
    setListError('');
    setCurrentRoot(null);
    const empty = createEmptyTemplateForm();
    setEditorForm(empty);
    setStreamDefaults({});
    setBaselineKey(serializeDraftStateKey(empty, {}));
    setSaveOutcome(null);
    setPendingCandidates([]);
    setVersions([]);
    setVersionsNextCursor(null);
    setSelectedVersion(null);
    setPublishOutcome(null);

    if (workspaceRole !== 'ADMIN') {
      setIsLoadingList(false);
      setListError('Tài khoản vai trò USER không có quyền quản trị template (WB-03).');
      return () => controller.abort();
    }

    setIsLoadingList(true);
    /** Tải trang đầu danh sách template đúng scope workspace hiện hành. */
    async function loadInitial(): Promise<void> {
      try {
        const page = await listTemplatesApi(ctx, { signal: controller.signal });
        if (generation !== generationRef.current || controller.signal.aborted) return;
        setTemplates(page.items);
        setNextCursor(page.nextCursor);
        setListError('');
      } catch (error) {
        if (error instanceof DOMException && error.name === 'AbortError') return;
        if (generation !== generationRef.current) return;
        if (forwardAuthBoundary(error)) return;
        setListError(
          error instanceof WorkspaceApiError
            ? `Không thể tải danh sách template (${error.code}).`
            : 'Không thể kết nối API template.',
        );
      } finally {
        if (generation === generationRef.current && !controller.signal.aborted) {
          setIsLoadingList(false);
        }
      }
    }
    void loadInitial();
    return () => controller.abort();
  }, [ctx, workspaceRole, reloadNonce]);

  /** Nạp danh sách phiên bản bất biến cho template root đang mở ở màn editor. */
  async function loadVersionsForTemplate(templateId: string, preferredVersionId?: string | null): Promise<void> {
    const generation = generationRef.current;
    setIsLoadingVersions(true);
    try {
      const page = await listTemplateVersionsApi(ctx, templateId, { signal: abortRef.current?.signal });
      if (generation !== generationRef.current) return;
      setVersions(page.items);
      setVersionsNextCursor(page.nextCursor);
      const pickId = preferredVersionId ?? page.items[0]?.id;
      if (pickId) {
        const exact = await getTemplateVersionApi(ctx, templateId, pickId, abortRef.current?.signal);
        if (generation !== generationRef.current) return;
        setSelectedVersion(exact);
      } else {
        setSelectedVersion(null);
      }
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') return;
      if (generation === generationRef.current) forwardAuthBoundary(error);
    } finally {
      if (generation === generationRef.current) setIsLoadingVersions(false);
    }
  }

  /** Đưa bản ghi `LiveTemplateDto` vào state editor và làm mới danh sách version kèm snapshot. */
  function applyLiveRootToEditor(dto: LiveTemplateDto): void {
    const nextForm = liveDtoToForm(dto);
    const nextDefaults = extractStreamDefaults(dto);
    setCurrentRoot(dto);
    setEditorForm(nextForm);
    setStreamDefaults(nextDefaults);
    setBaselineKey(serializeDraftStateKey(nextForm, nextDefaults));
    setSaveOutcome(null);
    setPendingCandidates([]);
    setView('editor');
    void loadVersionsForTemplate(dto.id, dto.latestPublishedVersionId);
  }

  /** Mở trình soạn thảo bản nháp mới khi actor là ADMIN. */
  function handleCreateNew(): void {
    if (workspaceRole !== 'ADMIN') return;
    const empty = createEmptyTemplateForm();
    setCurrentRoot(null);
    setEditorForm(empty);
    setStreamDefaults({});
    setBaselineKey(serializeDraftStateKey(empty, {}));
    setSaveOutcome(null);
    setPendingCandidates([]);
    setVersions([]);
    setVersionsNextCursor(null);
    setSelectedVersion(null);
    setPublishOutcome(null);
    setView('editor');
  }

  /** Mở chi tiết template theo ID từ danh sách scope hiện hành. */
  async function handleOpenTemplate(event: MouseEvent<HTMLButtonElement>): Promise<void> {
    const templateId = event.currentTarget.dataset.templateId;
    if (!templateId) return;
    const generation = generationRef.current;
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    setIsLoadingList(true);
    try {
      const detail = await getTemplateApi(ctx, templateId, controller.signal);
      if (generation !== generationRef.current || controller.signal.aborted) return;
      setPublishOutcome(null);
      applyLiveRootToEditor(detail);
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') return;
      if (generation !== generationRef.current) return;
      if (!forwardAuthBoundary(error)) {
        setListError(
          error instanceof WorkspaceApiError
            ? `Không thể mở chi tiết template (${error.code}).`
            : 'Không thể kết nối API template.',
        );
      }
    } finally {
      if (generation === generationRef.current && !controller.signal.aborted) {
        setIsLoadingList(false);
      }
    }
  }

  /** Gửi POST/PATCH bản nháp lên API thật và xử lý 422, 412, 409 hoặc POST unknown theo hợp đồng G1. */
  async function handleSubmitDraft(): Promise<void> {
    if (isSubmitting) return;
    if (isLegacyNumericEnumDraft && currentRoot) {
      const baselineForm = liveDtoToForm(currentRoot);
      const baselineDefaults = extractStreamDefaults(currentRoot);
      const structuralChanged =
        editorForm.model.trim() !== currentRoot.model.trim()
        || serializeStreamsState(editorForm.streams, streamDefaults)
          !== serializeStreamsState(baselineForm.streams, baselineDefaults)
        || serializeCommandsState(editorForm.commands) !== serializeCommandsState(baselineForm.commands);
      if (structuralChanged) {
        // Ngăn tuyệt đối gửi PATCH mang mảng khi draft chứa ENUM số lịch sử.
        setSaveOutcome({
          ok: false,
          kind: 'validation',
          status: 422,
          code: 'LEGACY_NUMERIC_ENUM_READONLY',
          message: 'Bản nháp chứa ENUM số lịch sử chỉ cho phép đổi tên; thay đổi schema/capability bị chặn để tránh mất kiểu dữ liệu.',
          fieldErrors: [],
        });
        return;
      }
    }

    const generation = generationRef.current;
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    setIsSubmitting(true);
    setPublishOutcome(null);

    try {
      const saved = editorForm.id && editorForm.revision !== null
        ? await patchTemplateDraftApi(
          ctx,
          editorForm.id,
          editorForm.revision,
          currentRoot
            ? buildLiveDraftPatchPayload(currentRoot, editorForm, streamDefaults)
            : editorFormToWirePayload(editorForm, streamDefaults),
          controller.signal,
        )
        : await createTemplateDraftApi(ctx, editorFormToWirePayload(editorForm, streamDefaults), controller.signal);
      if (generation !== generationRef.current || controller.signal.aborted) return;
      const syncedForm = liveDtoToForm(saved);
      const syncedDefaults = extractStreamDefaults(saved);
      setCurrentRoot(saved);
      setEditorForm(syncedForm);
      setStreamDefaults(syncedDefaults);
      setBaselineKey(serializeDraftStateKey(syncedForm, syncedDefaults));
      setPendingCandidates([]);
      setSaveOutcome({
        ok: true,
        template: liveTemplateToEditorDto(saved),
        unresolvedWireNotes: [],
      });
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') return;
      if (generation !== generationRef.current) return;
      if (forwardAuthBoundary(error)) return;
      if (error instanceof WorkspaceApiError) {
        if (error.status === 422 || error.status === 413) {
          setSaveOutcome({
            ok: false,
            kind: 'validation',
            status: error.status === 413 ? 413 : 422,
            code: error.code,
            message: 'Dữ liệu schema chưa hợp lệ. Hãy kiểm tra các trường được đánh dấu.',
            fieldErrors: toFieldErrors(error),
          });
          setErrorFocusNonce((prev) => prev + 1);
          return;
        }
        if (error.status === 412 && editorForm.id) {
          try {
            const latest = await getTemplateApi(ctx, editorForm.id, controller.signal);
            if (generation !== generationRef.current) return;
            setSaveOutcome({
              ok: false,
              kind: 'conflict_412',
              status: 412,
              code: 'VERSION_CONFLICT',
              message: `Xung đột phiên bản (412 VERSION_CONFLICT): máy chủ đang ở revision #${latest.revision}.`,
              serverTemplate: liveTemplateToEditorDto(latest),
            });
            return;
          } catch {
            // Tiếp tục rơi xuống thông báo lỗi chung nếu không tải được bản mới nhất.
          }
        }
        if (error.status === 409 && error.code === 'IMMUTABLE_SCHEMA' && currentRoot) {
          setSaveOutcome({
            ok: false,
            kind: 'immutable_409',
            status: 409,
            code: 'IMMUTABLE_SCHEMA',
            message: 'Phiên bản đã công bố là bất biến (409 IMMUTABLE_SCHEMA). Hãy mở bản nháp mới từ phiên bản đã công bố.',
            serverTemplate: liveTemplateToEditorDto(currentRoot),
          });
          return;
        }
        if (!editorForm.id && (error.status === 0 || error.status >= 500)) {
          // Không tự POST lại khi response create bị mất; truy vấn danh sách scoped để người dùng tự đối chiếu.
          setPendingCandidates([]);
          setSaveOutcome({
            ok: false,
            kind: 'unknown_outcome',
            status: 0,
            code: 'CREATE_OUTCOME_UNKNOWN',
            message: 'Chưa nhận được xác nhận sau khi tạo template. Không tự gửi lại POST; chọn bản nháp phù hợp hoặc chủ động tạo mới.',
          });
          try {
            const listPage = await listTemplatesApi(ctx, { status: 'DRAFT', signal: controller.signal });
            if (generation === generationRef.current && !controller.signal.aborted) {
              setPendingCandidates(
                listPage.items.filter(
                  /** Chỉ giữ ứng viên ở trạng thái DRAFT thuộc đúng workspace hiện hành. */
                  (item) => item.status === 'DRAFT' && item.workspaceId === workspaceId,
                ),
              );
            }
          } catch (listError) {
            if (listError instanceof DOMException && listError.name === 'AbortError') return;
            if (generation !== generationRef.current || controller.signal.aborted) return;
            if (forwardAuthBoundary(listError)) return;
            // Bỏ qua lỗi phụ khi list candidate không tải được ngay lập tức.
          }
          return;
        }
        if (error.status === 404) {
          setSaveOutcome({
            ok: false,
            kind: 'not_found',
            status: 404,
            code: error.code,
            message: `Không tìm thấy template (${error.code}).`,
          });
        } else if (error.status === 403) {
          setSaveOutcome({
            ok: false,
            kind: 'permission',
            status: 403,
            code: error.code,
            message: `Bạn không có quyền chỉnh sửa template (${error.code}).`,
          });
        } else {
          setSaveOutcome({
            ok: false,
            kind: 'network',
            status: 0,
            code: 'NETWORK_ERROR',
            message: `Không thể lưu bản nháp (${error.code}).`,
          });
        }
      }
    } finally {
      if (generation === generationRef.current && !controller.signal.aborted) {
        setIsSubmitting(false);
      }
    }
  }

  /** Đối soát kết quả công bố bằng `sourceRevision` khi HTTP 200 bị mất (WEB-PUBLISH-005). */
  async function handleRecoverUnknownPublish(submittedRevision: number): Promise<void> {
    if (!currentRoot) return;
    const generation = generationRef.current;
    try {
      const recovery = await recoverPublishBySourceRevisionApi(
        ctx,
        currentRoot.id,
        submittedRevision,
        abortRef.current?.signal,
      );
      if (generation !== generationRef.current) return;
      const syncedForm = liveDtoToForm(recovery.rootTemplate);
      const syncedDefaults = extractStreamDefaults(recovery.rootTemplate);
      setCurrentRoot(recovery.rootTemplate);
      setEditorForm(syncedForm);
      setStreamDefaults(syncedDefaults);
      setBaselineKey(serializeDraftStateKey(syncedForm, syncedDefaults));
      if (recovery.matchedVersion) {
        setSelectedVersion(recovery.matchedVersion);
      }
      setPublishOutcome({
        kind: 'unknown_publish',
        submittedRevision,
        matchedVersion: recovery.matchedVersion,
        rootTemplate: recovery.rootTemplate,
        message: 'Chưa xác nhận phản hồi công bố. Đã đối soát theo sourceRevision trên máy chủ.',
      });
    } catch (error) {
      if (generation !== generationRef.current || forwardAuthBoundary(error)) return;
      setPublishOutcome({
        kind: 'unknown_publish',
        submittedRevision,
        matchedVersion: null,
        rootTemplate: null,
        message: 'Chưa thể đối soát theo sourceRevision. Không tự gửi lại công bố; hãy kiểm tra lại khi mạng ổn định.',
      });
    }
  }

  /** Nạp lại snapshot gốc từ máy chủ cho template hiện hành. */
  async function handleReloadRoot(): Promise<void> {
    if (!currentRoot) return;
    const generation = generationRef.current;
    setIsSubmitting(true);
    try {
      const fresh = await getTemplateApi(ctx, currentRoot.id, abortRef.current?.signal);
      if (generation !== generationRef.current) return;
      setPublishOutcome(null);
      applyLiveRootToEditor(fresh);
    } catch (error) {
      if (generation !== generationRef.current || forwardAuthBoundary(error)) return;
      setPublishOutcome({ kind: 'error', message: 'Không thể tải lại template từ máy chủ.' });
    } finally {
      if (generation === generationRef.current) setIsSubmitting(false);
    }
  }

  /** Tải chính xác một snapshot `TemplateVersion` theo UUID khi người dùng chọn trong lịch sử. */
  async function handleSelectVersion(versionId: string): Promise<void> {
    if (!currentRoot) return;
    const generation = generationRef.current;
    setIsLoadingVersions(true);
    try {
      const detail = await getTemplateVersionApi(ctx, currentRoot.id, versionId, abortRef.current?.signal);
      if (generation !== generationRef.current) return;
      setSelectedVersion(detail);
    } catch (error) {
      if (generation !== generationRef.current || forwardAuthBoundary(error)) return;
      setPublishOutcome({ kind: 'error', message: 'Không thể tải chi tiết phiên bản đã công bố.' });
    } finally {
      if (generation === generationRef.current) setIsLoadingVersions(false);
    }
  }

  /** Tải thêm các phiên bản đã công bố cũ hơn theo cursor. */
  async function handleLoadMoreVersions(): Promise<void> {
    if (!currentRoot || !versionsNextCursor || isLoadingVersions) return;
    const generation = generationRef.current;
    setIsLoadingVersions(true);
    try {
      const page = await listTemplateVersionsApi(ctx, currentRoot.id, {
        cursor: versionsNextCursor,
        signal: abortRef.current?.signal,
      });
      if (generation !== generationRef.current) return;
      setVersions((prev) => [...prev, ...page.items]);
      setVersionsNextCursor(page.nextCursor);
    } catch (error) {
      if (generation !== generationRef.current || forwardAuthBoundary(error)) return;
    } finally {
      if (generation === generationRef.current) setIsLoadingVersions(false);
    }
  }

  /** Mở bản nháp mới từ `sourceVersionId` thông qua `POST /templates/{id}/draft` với `If-Match`. */
  async function handleCloneFromVersion(sourceVersionId: string): Promise<void> {
    if (!currentRoot || isSubmitting) return;
    const generation = generationRef.current;
    setIsSubmitting(true);
    setPublishOutcome(null);
    try {
      const cloned = await cloneTemplateDraftApi(
        ctx,
        currentRoot.id,
        currentRoot.revision,
        sourceVersionId,
        abortRef.current?.signal,
      );
      if (generation !== generationRef.current) return;
      applyLiveRootToEditor(cloned);
    } catch (error) {
      if (generation !== generationRef.current || forwardAuthBoundary(error)) return;
      if (error instanceof WorkspaceApiError) {
        if (error.status === 409 && error.code === 'DRAFT_EXISTS') {
          setPublishOutcome({
            kind: 'draft_exists_409',
            message: 'Template này đã có bản nháp hiện hành (409 DRAFT_EXISTS). Hãy tải lại để tiếp tục chỉnh sửa.',
          });
          return;
        }
        if (error.status === 412) {
          setPublishOutcome({
            kind: 'conflict_412',
            currentRevision: error.currentRevision,
            message: 'Revision thay đổi trước khi nhân bản nháp (412 VERSION_CONFLICT).',
          });
          return;
        }
        setPublishOutcome({ kind: 'error', message: `Không thể mở bản nháp mới (${error.code}).` });
      }
    } finally {
      if (generation === generationRef.current) setIsSubmitting(false);
    }
  }

  /** Áp dụng hòa giải 412 khi sửa bản nháp. */
  function handleApplyServerRevision(serverTemplate: EditorTemplateDto, keepLocalChanges: boolean): void {
    if (!keepLocalChanges) {
      void handleReloadRoot();
      return;
    }
    setEditorForm({
      ...editorForm,
      revision: serverTemplate.revision,
      updatedAt: serverTemplate.updatedAt,
    });
    setSaveOutcome(null);
  }

  /**
   * Mở lại đúng bản nháp ứng viên từ trạng thái khôi phục hiện hành sau sự cố POST unknown.
   * Input
   * Param: candidate — bản ghi ứng viên được chọn theo UUID từ danh sách đối chiếu.
   */
  function handleSelectCandidate(candidate: EditorTemplateDto): void {
    if (isSubmitting || workspaceRole !== 'ADMIN') return;
    const match = pendingCandidates.find(
      /** Tìm chính xác UUID trong `pendingCandidates` hiện hành và xác minh DRAFT thuộc đúng workspace. */
      (item) =>
        item.id === candidate.id
        && item.status === 'DRAFT'
        && item.workspaceId === workspaceId,
    );
    if (!match) return;
    setPublishOutcome(null);
    applyLiveRootToEditor(match);
  }

  /**
   * Cập nhật form editor và dọn giá trị `default` mồ côi khi một datastream bị xóa khỏi form;
   * khóa mọi thay đổi ngoài `name` nếu bản nháp mang ENUM số lịch sử.
   * Input
   * Param: nextForm — trạng thái biểu mẫu mới từ `TemplateEditor`.
   */
  function handleChangeEditorForm(nextForm: TemplateDraftForm): void {
    if (isLegacyNumericEnumDraft) {
      setEditorForm((prev) => ({ ...prev, name: nextForm.name }));
      return;
    }
    setEditorForm(nextForm);
    const activeIds = new Set(nextForm.streams.map(
      /** Thu thập `localId` còn tồn tại trên form. */
      (item) => item.localId,
    ));
    setStreamDefaults((prev) => {
      let removed = false;
      const next: Record<string, StreamDefaultInputState> = {};
      for (const [id, value] of Object.entries(prev)) {
        if (activeIds.has(id)) next[id] = value;
        else removed = true;
      }
      return removed ? next : prev;
    });
  }

  /**
   * Cập nhật trạng thái giá trị mặc định scalar (`default`) của một datastream theo `localId`.
   * Input
   * Param: localId — mã định danh cục bộ của kênh.
   * Param: nextState — trạng thái `{ present, text }` cho `default`.
   */
  function handleChangeStreamDefault(localId: string, nextState: StreamDefaultInputState): void {
    if (isLegacyNumericEnumDraft) return;
    setStreamDefaults((prev) => ({ ...prev, [localId]: nextState }));
  }

  return (
    <div className="tpl-workbench">
      {view === 'list' ? (
        <section className="tpl-card" aria-labelledby="tpl-live-heading">
          <div className="tpl-page-head">
            <div>
              <h2 id="tpl-live-heading" ref={headingRef} tabIndex={-1}>
                Templates (WB-03 · FEAT-TN-005 / 006)
              </h2>
              <p className="tpl-lead">
                Workspace: <strong>{workspaceName}</strong> · Vai trò <strong>{workspaceRole}</strong>
              </p>
            </div>
            <div className="tpl-actions-row">
              <button
                type="button"
                className="tpl-btn"
                disabled={isLoadingList}
                onClick={
                  /** Kích hoạt tải lại danh sách template thuộc workspace hiện tại. */
                  () => setReloadNonce((n) => n + 1)
                }
              >
                Tải lại danh sách
              </button>
              {workspaceRole === 'ADMIN' ? (
                <button
                  type="button"
                  className="tpl-btn tpl-btn-primary"
                  disabled={isLoadingList}
                  onClick={handleCreateNew}
                >
                  Tạo template
                </button>
              ) : null}
            </div>
          </div>

          {isLoadingList ? (
            <div className="tpl-skeleton-list" aria-busy="true" aria-label="Đang tải danh sách template">
              <div className="tpl-skeleton-row" aria-hidden="true" />
              <p className="tpl-hint" role="status">Đang tải danh sách template từ API…</p>
            </div>
          ) : listError ? (
            <div className="tpl-notice tpl-notice-error" role="alert">
              <div className="tpl-notice-body">
                <p><strong>{listError}</strong></p>
              </div>
            </div>
          ) : templates.length === 0 ? (
            <div className="tpl-state-box" role="status">
              <h3>Workspace này chưa có template nào</h3>
              <p>Tạo bản nháp template để khai báo datastream chuẩn G1 và công bố snapshot bất biến.</p>
            </div>
          ) : (
            <ul className="tpl-list-grid">
              {templates.map(
                /** Hiển thị từng dòng template với trạng thái root, model và revision hiện hành. */
                (item) => (
                  <li key={item.id} className="tpl-list-item">
                    <div className="tpl-list-item-main">
                      <div className="tpl-list-item-title">
                        <h3>{item.name}</h3>
                        <span className={`tpl-badge ${item.status === 'PUBLISHED' ? 'tpl-badge-published' : 'tpl-badge-draft'}`}>
                          {item.status}
                        </span>
                      </div>
                      <div className="tpl-meta-line">
                        <span>Model: <span className="tpl-mono">{item.model}</span></span>
                        <span>{item.streams.length} datastream</span>
                        <span>Revision #{item.revision}</span>
                        {item.latestPublishedVersionId ? (
                          <span>PIN: <span className="tpl-mono">{item.latestPublishedVersionId}</span></span>
                        ) : null}
                      </div>
                    </div>
                    <button
                      type="button"
                      className="tpl-btn"
                      data-template-id={item.id}
                      onClick={handleOpenTemplate}
                    >
                      {item.status === 'PUBLISHED' ? 'Xem & Công bố / Tạo draft' : 'Mở bản nháp'}
                    </button>
                  </li>
                ),
              )}
            </ul>
          )}

          {nextCursor ? (
            <div className="tpl-actions-row">
              <button
                type="button"
                className="tpl-btn"
                disabled={isLoadingList}
                onClick={
                  /** Tải trang template kế tiếp theo cursor hiện tại. */
                  async () => {
                    if (!nextCursor) return;
                    const page = await listTemplatesApi(ctx, { cursor: nextCursor, signal: abortRef.current?.signal });
                    setTemplates((prev) => [...prev, ...page.items]);
                    setNextCursor(page.nextCursor);
                  }
                }
              >
                Tải thêm template
              </button>
            </div>
          ) : null}
        </section>
      ) : (
        <TemplateEditor
          workspaceId={workspaceId}
          workspaceName={workspaceName}
          form={editorForm}
          lastServerTemplate={currentRoot ? liveTemplateToEditorDto(currentRoot) : null}
          saveOutcome={saveOutcome}
          pendingCandidates={editorPendingCandidates}
          isDirty={isDirty}
          isSubmitting={isSubmitting}
          errorFocusNonce={errorFocusNonce}
          headingRef={headingRef}
          mode="live"
          isSchemaLocked={isLegacyNumericEnumDraft}
          streamDefaults={streamDefaults}
          onChangeStreamDefault={handleChangeStreamDefault}
          onChangeForm={handleChangeEditorForm}
          onSubmit={handleSubmitDraft}
          onBackToList={
            /** Quay lại danh sách template và tải lại trạng thái mới nhất. */
            () => {
              setView('list');
              setReloadNonce((n) => n + 1);
            }
          }
          onApplyServerRevision={handleApplyServerRevision}
          onSelectCandidate={handleSelectCandidate}
          onCreateNewAfterUnknown={handleSubmitDraft}
          publishPanel={currentRoot ? (
            <TemplatePublishPanel
              template={currentRoot}
              isBusy={isSubmitting}
              versions={versions}
              versionsNextCursor={versionsNextCursor}
              selectedVersion={selectedVersion}
              isLoadingVersions={isLoadingVersions}
              publishOutcome={publishOutcome}
              onReloadRoot={handleReloadRoot}
              onSelectVersion={handleSelectVersion}
              onLoadMoreVersions={handleLoadMoreVersions}
              onCloneFromVersion={handleCloneFromVersion}
              onRecoverUnknownPublish={handleRecoverUnknownPublish}
            />
          ) : null}
        />
      )}
    </div>
  );
}
