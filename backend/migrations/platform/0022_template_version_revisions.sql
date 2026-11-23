/* Tách revision draft trước publish khỏi revision root sau publish.
 * Row cũ được giữ unknown; CHECK NOT VALID bảo vệ mọi row mới mà không bịa provenance
 * lịch sử từ root mutable hoặc thứ tự version.
 */
ALTER TABLE public.template_versions
    ADD COLUMN source_revision bigint,
    ADD COLUMN published_root_revision bigint;

ALTER TABLE public.template_versions
    ADD CONSTRAINT template_versions_revision_provenance
    CHECK (
        source_revision IS NOT NULL
        AND source_revision > 0
        AND published_root_revision IS NOT NULL
        AND published_root_revision > source_revision
        AND published_root_revision - source_revision = 1
    ) NOT VALID;

COMMENT ON COLUMN public.template_versions.source_revision IS
    'Revision draft root trước publication; NULL trên version cũ khi chưa lưu provenance đáng tin cậy.';
COMMENT ON COLUMN public.template_versions.published_root_revision IS
    'Revision root được publication commit; NULL trên version cũ khi không chứng minh được trạng thái root lịch sử.';
