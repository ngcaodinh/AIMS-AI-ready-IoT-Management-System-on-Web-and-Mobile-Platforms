import type { ChangeEvent, MouseEvent } from 'react';
import {
  computeTemplateSchemaDiff,
  getStreamDefaultDescriptor,
  getStreamEnumDescriptors,
  type TemplateDto,
  type TemplatePublishedDto,
  type TemplateSchemaDiff,
  type TemplateVersionDto,
} from './templateContract.ts';

export type PublishOutcomeState =
  | { kind: 'published'; result: TemplatePublishedDto }
  | { kind: 'conflict_412'; currentRevision?: number; message: string }
  | { kind: 'immutable_409'; message: string }
  | { kind: 'draft_exists_409'; message: string }
  | { kind: 'validation_422'; message: string }
  | {
    kind: 'unknown_publish';
    submittedRevision: number;
    matchedVersion: TemplateVersionDto | null;
    rootTemplate: TemplateDto | null;
    message: string;
  }
  | { kind: 'error'; message: string }
  | null;

interface TemplatePublishPanelProps {
  template: TemplateDto;
  isBusy: boolean;
  versions: TemplateVersionDto[];
  versionsNextCursor: string | null;
  selectedVersion: TemplateVersionDto | null;
  isLoadingVersions: boolean;
  publishOutcome: PublishOutcomeState;
  onReloadRoot: () => void;
  onSelectVersion: (versionId: string) => void;
  onLoadMoreVersions: () => void;
  onCloneFromVersion: (sourceVersionId: string) => void;
  onRecoverUnknownPublish: (submittedRevision: number) => void;
}

/**
 * Hiển thị hộp xác nhận công bố, đối chiếu diff schema, danh sách phiên bản bất biến,
 * thao tác tạo draft từ snapshot và phục hồi theo `sourceRevision` cho FEAT-TN-006 V4.
 * Input
 * Param: props — state root template hiện hành, danh sách version đã công bố và các handler API thật.
 * Output: khối panel V4 đặt trong workbench WB-03 đã xác thực.
 */
export function TemplatePublishPanel({
  template,
  isBusy,
  versions,
  versionsNextCursor,
  selectedVersion,
  isLoadingVersions,
  publishOutcome,
  onReloadRoot,
  onSelectVersion,
  onLoadMoreVersions,
  onCloneFromVersion,
  onRecoverUnknownPublish,
}: TemplatePublishPanelProps) {
  const diff: TemplateSchemaDiff | null = selectedVersion
    ? computeTemplateSchemaDiff(selectedVersion, template)
    : null;

  /** Nạp chi tiết một snapshot bất biến khi người dùng đổi lựa chọn version. */
  function handleVersionSelectChange(event: ChangeEvent<HTMLSelectElement>): void {
    const versionId = event.target.value;
    if (versionId) onSelectVersion(versionId);
  }

  /** Nhân bản một snapshot đã công bố thành bản nháp mới thông qua `POST /draft`. */
  function handleCloneClick(event: MouseEvent<HTMLButtonElement>): void {
    const versionId = event.currentTarget.dataset.versionId;
    if (versionId) onCloneFromVersion(versionId);
  }

  /** Gửi truy vấn đối soát theo `sourceRevision` sau khi mất phản hồi publish. */
  function handleRetryRecoveryLookup(): void {
    if (publishOutcome?.kind === 'unknown_publish') {
      onRecoverUnknownPublish(publishOutcome.submittedRevision);
    }
  }

  /** Kết xuất một tùy chọn trong dropdown chọn phiên bản snapshot đã công bố. */
  function renderVersionOption(item: TemplateVersionDto) {
    const provenanceText = item.sourceRevision !== null
      ? `từ revision #${item.sourceRevision}`
      : 'chưa rõ revision gốc';
    return (
      <option key={item.id} value={item.id}>
        v{item.version} · {item.id} ({provenanceText})
      </option>
    );
  }

  /** Kết xuất một dòng thay đổi trong bảng diff schema theo từng stream hoặc capability. */
  function renderDiffItem(entry: TemplateSchemaDiff['streamChanges'][number]) {
    const badgeLabel = entry.change === 'added'
      ? 'Thêm mới'
      : entry.change === 'removed'
        ? 'Gỡ bỏ'
        : 'Thay đổi';
    return (
      <li key={`${entry.change}-${entry.key}`} className="tpl-diff-item">
        <div>
          <strong className="tpl-mono">{entry.key}</strong>{' '}
          <span className="tpl-badge">{badgeLabel}</span>
        </div>
        <p className="tpl-hint">{entry.details.join(' · ')}</p>
      </li>
    );
  }

  return (
    <section className="tpl-card tpl-publish-card" aria-labelledby="tpl-publish-heading">
      <div className="tpl-section-head">
        <div>
          <h2 id="tpl-publish-heading">4. Lịch sử phiên bản, Đối chiếu &amp; Tạo draft (FEAT-TN-006 V4)</h2>
          <p className="tpl-hint">
            Snapshot đã công bố có UUID riêng bất biến cho đăng ký thiết bị và firmware OTA; sửa đổi phải mở bản nháp mới.
          </p>
        </div>
        {template.latestPublishedVersionId ? (
          <span className="tpl-badge tpl-badge-published">
            Latest PIN: <span className="tpl-mono">{template.latestPublishedVersionId}</span>
          </span>
        ) : (
          <span className="tpl-badge">Chưa có phiên bản công bố</span>
        )}
      </div>

      {publishOutcome?.kind === 'published' ? (
        <div className="tpl-notice tpl-notice-success" role="status">
          <div className="tpl-notice-body">
            <p>
              <strong>Đã công bố phiên bản v{publishOutcome.result.version.version} thành công.</strong>{' '}
              Pin UUID: <span className="tpl-mono">{publishOutcome.result.version.id}</span> ·
              sourceRevision #{publishOutcome.result.version.sourceRevision} · Root revision #{publishOutcome.result.revision}.
            </p>
          </div>
        </div>
      ) : null}

      {publishOutcome?.kind === 'conflict_412' ? (
        <div className="tpl-notice tpl-notice-error" role="alert">
          <div className="tpl-notice-body">
            <p><strong>{publishOutcome.message}</strong></p>
            <div className="tpl-actions-row">
              <button type="button" className="tpl-btn" disabled={isBusy} onClick={onReloadRoot}>
                Tải lại bản nháp mới nhất từ máy chủ
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {publishOutcome && (publishOutcome.kind === 'immutable_409' || publishOutcome.kind === 'draft_exists_409') ? (
        <div className="tpl-notice tpl-notice-warning" role="alert">
          <div className="tpl-notice-body">
            <p><strong>{publishOutcome.message}</strong></p>
          </div>
        </div>
      ) : null}

      {publishOutcome && (publishOutcome.kind === 'validation_422' || publishOutcome.kind === 'error') ? (
        <div className="tpl-notice tpl-notice-error" role="alert">
          <div className="tpl-notice-body">
            <p><strong>{publishOutcome.message}</strong></p>
          </div>
        </div>
      ) : null}

      {publishOutcome?.kind === 'unknown_publish' ? (
        <div className="tpl-notice tpl-notice-warning" role="alert">
          <div className="tpl-notice-body">
            <p><strong>{publishOutcome.message}</strong></p>
            {publishOutcome.matchedVersion ? (
              <p className="tpl-hint">
                Kết quả đối soát theo <code>sourceRevision={publishOutcome.submittedRevision}</code>: phiên bản{' '}
                <strong>v{publishOutcome.matchedVersion.version}</strong> (UUID:{' '}
                <span className="tpl-mono">{publishOutcome.matchedVersion.id}</span>) đã được công bố.
              </p>
            ) : publishOutcome.rootTemplate ? (
              <p className="tpl-hint">
                Chưa tìm thấy phiên bản cho <code>sourceRevision={publishOutcome.submittedRevision}</code>. Revision hiện hành trên máy chủ là #{publishOutcome.rootTemplate.revision} ({publishOutcome.rootTemplate.status}).
                {publishOutcome.rootTemplate.revision === publishOutcome.submittedRevision && publishOutcome.rootTemplate.status === 'DRAFT'
                  ? ' Bạn có thể chủ động thử công bố lại với đúng revision này.'
                  : ' Không tự gửi lại công bố với revision mới; hãy tải lại bản mới nhất để đối chiếu.'}
              </p>
            ) : null}
            <div className="tpl-actions-row">
              <button type="button" className="tpl-btn" disabled={isBusy} onClick={handleRetryRecoveryLookup}>
                Kiểm tra lại theo sourceRevision #{publishOutcome.submittedRevision}
              </button>
              <button type="button" className="tpl-btn" disabled={isBusy} onClick={onReloadRoot}>
                Tải lại trạng thái hiện hành
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {template.status === 'DRAFT' ? (
        <div className="tpl-subcard tpl-publish-box">
          <div className="tpl-section-head tpl-section-head-flush">
            <div>
              <strong>Công bố bản nháp hiện hành (Revision #{template.revision})</strong>
              <p id="tpl-publish-unavailable-note" className="tpl-hint">
                Thao tác công bố phiên bản (<code>POST /templates/{'{id}'}/publish</code>) và đối soát{' '}
                <code>sourceRevision</code> hiện chưa khả dụng cho tới khi provider backend và migration nguồn gốc hoàn tất.
              </p>
            </div>
            <button
              type="button"
              className="tpl-btn tpl-btn-primary"
              disabled
              aria-disabled="true"
              aria-describedby="tpl-publish-unavailable-note"
            >
              Công bố phiên bản (Chưa khả dụng)
            </button>
          </div>
        </div>
      ) : null}

      <div className="tpl-subcard tpl-publish-box">
        <div className="tpl-section-head">
          <strong>Phiên bản đã công bố &amp; Đối chiếu khác biệt (Diff)</strong>
          {isLoadingVersions ? <span className="tpl-hint" role="status">Đang tải phiên bản…</span> : null}
        </div>

        {versions.length === 0 ? (
          <p className="tpl-hint">Template này chưa có snapshot nào được công bố.</p>
        ) : (
          <div className="tpl-editor-main">
            <div className="tpl-form-grid">
              <div className="tpl-field tpl-field-full">
                <label htmlFor="tpl-version-select">Chọn phiên bản bất biến để xem / đối chiếu</label>
                <select
                  id="tpl-version-select"
                  name="selectedPublishedVersion"
                  autoComplete="off"
                  className="tpl-select tpl-mono"
                  value={selectedVersion?.id ?? ''}
                  disabled={isBusy}
                  onChange={handleVersionSelectChange}
                >
                  <option value="">-- Chọn một TemplateVersion --</option>
                  {versions.map(renderVersionOption)}
                </select>
              </div>
            </div>

            {versionsNextCursor ? (
              <div className="tpl-actions-row">
                <button type="button" className="tpl-btn" disabled={isBusy} onClick={onLoadMoreVersions}>
                  Tải thêm phiên bản cũ hơn
                </button>
              </div>
            ) : null}

            {selectedVersion ? (
              <div className="tpl-version-detail">
                <div className="tpl-meta-line">
                  <span>Phiên bản: <strong>v{selectedVersion.version}</strong></span>
                  <span>UUID pin: <span className="tpl-mono">{selectedVersion.id}</span></span>
                  <span>
                    sourceRevision:{' '}
                    {selectedVersion.sourceRevision !== null
                      ? `#${selectedVersion.sourceRevision}`
                      : 'Chưa ghi (bản lịch sử)'}
                  </span>
                  <span>Công bố lúc: {selectedVersion.publishedAt}</span>
                </div>

                <ul className="tpl-hint tpl-g1-notes" aria-label="Chi tiết datastream của phiên bản đã chọn">
                  {selectedVersion.streams.map(
                    /** Hiển thị exact token của enumValues và default trên snapshot đã chọn. */
                    (stream) => {
                      const enumLabels = getStreamEnumDescriptors(stream).map(
                        /** Phản ánh rõ kiểu chuỗi vs số và giữ nguyên token decimal lớn. */
                        (d) => (d.kind === 'string' ? JSON.stringify(d.value) : d.display),
                      );
                      const defaultDesc = getStreamDefaultDescriptor(stream);
                      return (
                        <li key={stream.key}>
                          <span className="tpl-mono">{stream.key}</span> ({stream.type} · {stream.channelKind}/{stream.direction})
                          {enumLabels.length > 0 ? <> · enum=[<span className="tpl-mono">{enumLabels.join(', ')}</span>]</> : null}
                          {defaultDesc !== undefined ? <> · default=<span className="tpl-mono">{defaultDesc.kind === 'string' ? JSON.stringify(defaultDesc.value) : defaultDesc.display}</span></> : null}
                        </li>
                      );
                    },
                  )}
                </ul>

                {template.status === 'PUBLISHED' ? (
                  <div className="tpl-actions-row">
                    <button
                      type="button"
                      className="tpl-btn"
                      data-version-id={selectedVersion.id}
                      disabled={isBusy}
                      onClick={handleCloneClick}
                    >
                      Mở bản nháp mới từ v{selectedVersion.version}
                    </button>
                  </div>
                ) : null}

                {diff ? (
                  <div className="tpl-diff-box" aria-label="Đối chiếu schema với bản hiện hành">
                    <strong>So sánh v{selectedVersion.version} (đã công bố) với bản hiện hành (#{template.revision} · {template.status})</strong>
                    {!diff.hasChanges ? (
                      <p className="tpl-hint">Không có khác biệt schema giữa phiên bản này và bản hiện hành.</p>
                    ) : (
                      <ul className="tpl-diff-list">
                        {diff.metadataChanges.map(
                          /** Hiển thị thay đổi tên hoặc mã model giữa hai phiên bản. */
                          (line, idx) => <li key={`meta-${idx}`} className="tpl-diff-item">{line}</li>,
                        )}
                        {diff.streamChanges.map(renderDiffItem)}
                        {diff.commandChanges.map(renderDiffItem)}
                      </ul>
                    )}
                  </div>
                ) : null}
              </div>
            ) : null}
          </div>
        )}
      </div>
    </section>
  );
}
