//! Đọc snapshot published độc lập root hiện hành để kiểm digest và binding theo pin cũ.

use crate::{PgUnitOfWork, storage_error, template_draft::TemplateContentSource};
use iot_application::error::ApplicationError;
use iot_domain::{template::TemplateDraft, template_snapshot::TemplateVersionSnapshot};
use sqlx::Row;
use uuid::Uuid;

impl PgUnitOfWork {
    /**
     * Đọc version theo W/id và tái dựng toàn bộ content từ các relation immutable cùng version.
     * Input
     * Param: `workspace_id` — tenant current member đã được service authorize.
     * Param: `version_id` — identity published, không root/draft selector.
     * Output: content/digest gốc để application kiểm SHA256; Errors: not-found hoặc persisted shape/storage sai.
     */
    pub(super) async fn read_template_version(
        &mut self,
        workspace_id: Uuid,
        version_id: Uuid,
    ) -> Result<TemplateVersionSnapshot, ApplicationError> {
        // Không join templates: root metadata/revision có thể đổi sau khi version này đã được pin.
        let row=sqlx::query("SELECT workspace_id,template_id,template_version_id,version_number,name,model,published_at,published_by_user_id,content_digest,source_revision,published_root_revision FROM template_versions WHERE workspace_id=$1 AND template_version_id=$2")
            .bind(workspace_id).bind(version_id).fetch_optional(&mut *self.transaction).await.map_err(storage_error)?.ok_or(ApplicationError::ResourceNotFound)?;
        let metadata = TemplateDraft {
            name: row.try_get("name").map_err(storage_error)?,
            model: row.try_get("model").map_err(storage_error)?,
            description: None,
            streams: vec![],
        };
        let content = self
            .load_template_content(
                workspace_id,
                version_id,
                metadata,
                TemplateContentSource::Published,
            )
            .await?;
        let digest: Vec<u8> = row.try_get("content_digest").map_err(storage_error)?;
        Ok(TemplateVersionSnapshot {
            workspace_id,
            template_id: row.try_get("template_id").map_err(storage_error)?,
            template_version_id: version_id,
            version_number: row.try_get("version_number").map_err(storage_error)?,
            source_revision: row.try_get("source_revision").map_err(storage_error)?,
            published_root_revision: row
                .try_get("published_root_revision")
                .map_err(storage_error)?,
            published_at: row.try_get("published_at").map_err(storage_error)?,
            published_by_user_id: row.try_get("published_by_user_id").map_err(storage_error)?,
            content_digest: digest
                .try_into()
                .map_err(|_| ApplicationError::Unavailable)?,
            content,
        })
    }
}
