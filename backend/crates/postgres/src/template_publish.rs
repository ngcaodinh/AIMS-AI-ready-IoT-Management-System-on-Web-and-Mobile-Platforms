//! Immutable publication cùng origin marker native0013; không đọc root metadata mutable để sửa version đã pin.

use crate::{PgUnitOfWork, storage_error, template_values};
use iot_application::{error::ApplicationError, template_ports::NewTemplateVersion};
use iot_domain::template_snapshot::{PublishedTemplate, TemplateSnapshot};

impl PgUnitOfWork {
    /**
     * Persist exact validated snapshot và tăng root revision atomically trước required audit của service.
     * Input
     * Param: before — root/draft dưới User→Workspace→Template lock đã current authorize/CAS.
     * Param: version — ID/version/digest/actor/clock do server cấp, không là authority từ client.
     * Output: metadata publication; Errors: storage/CAS rollback parent và mọi child chưa commit.
     */
    pub(super) async fn persist_template_publication(
        &mut self,
        before: &TemplateSnapshot,
        version: &NewTemplateVersion,
    ) -> Result<PublishedTemplate, ApplicationError> {
        // Parent INSERT tạo native transaction marker trước children; mọi value được bind, không sửa marker theo caller.
        sqlx::query("INSERT INTO template_versions(workspace_id,template_version_id,template_id,version_number,name,model,published_at,published_by_user_id,content_digest) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)")
            .bind(before.workspace_id).bind(version.template_version_id).bind(before.template_id).bind(version.version_number).bind(&before.draft.draft().name).bind(&before.draft.draft().model).bind(version.published_at).bind(version.published_by_user_id).bind(version.content_digest.as_slice())
            .execute(&mut *self.transaction).await.map_err(storage_error)?;
        for stream in &before.draft.draft().streams {
            // Snapshot từ validated memory dưới root fence, gồm cả loại kênh/direction, không lấy scope từ payload.
            sqlx::query("INSERT INTO datastream_definitions(workspace_id,template_version_id,stream_key,display_name,data_type,direction,channel_kind,unit,min_value,max_value,string_max_length) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)")
                .bind(before.workspace_id).bind(version.template_version_id).bind(&stream.key).bind(&stream.display_name).bind(template_values::stream_type_code(stream.data_type)).bind(template_values::direction_code(stream.direction)).bind(template_values::channel_kind_code(stream.channel_kind))
                .bind(&stream.unit).bind(stream.minimum).bind(stream.maximum).bind(stream.string_max_length).execute(&mut *self.transaction).await.map_err(storage_error)?;
            for value in &stream.enum_values {
                let (kind, text) = template_values::scalar_parts(value);
                sqlx::query("INSERT INTO datastream_enum_values(workspace_id,template_version_id,stream_key,enum_value) VALUES($1,$2,$3,CASE $4::text WHEN 'NUMBER' THEN $5::jsonb ELSE to_jsonb($5::text) END)")
                    .bind(before.workspace_id).bind(version.template_version_id).bind(&stream.key).bind(kind).bind(text).execute(&mut *self.transaction).await.map_err(storage_error)?;
            }
            if let Some(value) = &stream.safe_value {
                let (kind, text) = template_values::scalar_parts(value);
                sqlx::query("INSERT INTO datastream_capabilities(workspace_id,template_version_id,stream_key,command_type,safe_value) VALUES($1,$2,$3,'SET_VALUE',CASE $4::text WHEN 'NUMBER' THEN $5::jsonb WHEN 'BOOLEAN' THEN to_jsonb($5::boolean) ELSE to_jsonb($5::text) END)")
                    .bind(before.workspace_id).bind(version.template_version_id).bind(&stream.key).bind(kind).bind(text).execute(&mut *self.transaction).await.map_err(storage_error)?;
            }
        }
        let changed=sqlx::query("UPDATE templates SET lifecycle_status='PUBLISHED',revision=$4,updated_at=$5 WHERE workspace_id=$1 AND template_id=$2 AND revision=$3 AND lifecycle_status='DRAFT'")
            .bind(before.workspace_id).bind(before.template_id).bind(before.revision).bind(version.template_revision).bind(version.published_at).execute(&mut *self.transaction).await.map_err(storage_error)?.rows_affected();
        if changed != 1 {
            return Err(ApplicationError::StaleRevision);
        }
        Ok(PublishedTemplate {
            workspace_id: before.workspace_id,
            template_id: before.template_id,
            template_version_id: version.template_version_id,
            version_number: version.version_number,
            template_revision: version.template_revision,
            published_at: version.published_at,
            content_digest: version.content_digest,
        })
    }
}
