//! Normalized draft persistence; parent fence giữ toàn bộ enum/capability/schema cùng revision CAS.

use crate::{PgUnitOfWork, storage_error, template_values};
use iot_application::error::ApplicationError;
use iot_domain::template::{StreamDraft, TemplateDraft, ValidatedTemplate};
use sqlx::Row;
use std::collections::BTreeMap;
use uuid::Uuid;

/// Nguồn schema chỉ chọn SQL literal allowlist; UUID/scope luôn bind và không trở thành identifier động.
pub(super) enum TemplateContentSource {
    Draft,
    Published,
}

impl PgUnitOfWork {
    /**
     * Load normalized content theo nguồn draft hoặc published trong đúng tenant đã authorize.
     * Input
     * Param: `workspace_id` — tenant đã authorize và khóa.
     * Param: `template_id` — identity root hoặc version tương ứng source, không lookup global.
     * Param: draft — metadata từ đúng root/version có streams rỗng; published không lấy description root.
     * Param: source — enum nội bộ chọn relation, không giá trị client.
     * Output: schema đã domain validate; Errors: persisted shape lỗi hoặc storage đều fail-closed.
     */
    pub(super) async fn load_template_content(
        &mut self,
        workspace_id: Uuid,
        template_id: Uuid,
        mut draft: TemplateDraft,
        source: TemplateContentSource,
    ) -> Result<ValidatedTemplate, ApplicationError> {
        // Ba projection đều bind scope/key; FK và root lock giữ schema read nhất quán với controlled writers.
        let (stream_sql, enum_sql, capability_sql) = match source {
            TemplateContentSource::Draft => (
                "SELECT stream_key,display_name,data_type,direction,channel_kind,unit,min_value,max_value,string_max_length,jsonb_typeof(default_value) AS default_type,default_value#>>'{}' AS default_text FROM template_draft_streams WHERE workspace_id=$1 AND template_id=$2 ORDER BY stream_key",
                "SELECT stream_key,jsonb_typeof(enum_value) AS value_type,enum_value#>>'{}' AS value_text FROM template_draft_enum_values WHERE workspace_id=$1 AND template_id=$2 ORDER BY stream_key,enum_value",
                "SELECT stream_key,jsonb_typeof(safe_value) AS value_type,safe_value#>>'{}' AS value_text FROM template_draft_capabilities WHERE workspace_id=$1 AND template_id=$2 AND command_type='SET_VALUE'",
            ),
            TemplateContentSource::Published => (
                "SELECT stream_key,display_name,data_type,direction,channel_kind,unit,min_value,max_value,string_max_length,jsonb_typeof(default_value) AS default_type,default_value#>>'{}' AS default_text FROM datastream_definitions WHERE workspace_id=$1 AND template_version_id=$2 ORDER BY stream_key",
                "SELECT stream_key,jsonb_typeof(enum_value) AS value_type,enum_value#>>'{}' AS value_text FROM datastream_enum_values WHERE workspace_id=$1 AND template_version_id=$2 ORDER BY stream_key,enum_value",
                "SELECT stream_key,jsonb_typeof(safe_value) AS value_type,safe_value#>>'{}' AS value_text FROM datastream_capabilities WHERE workspace_id=$1 AND template_version_id=$2 AND command_type='SET_VALUE'",
            ),
        };
        let rows = sqlx::query(stream_sql)
            .bind(workspace_id)
            .bind(template_id)
            .fetch_all(&mut *self.transaction)
            .await
            .map_err(storage_error)?;
        let enum_rows = sqlx::query(enum_sql)
            .bind(workspace_id)
            .bind(template_id)
            .fetch_all(&mut *self.transaction)
            .await
            .map_err(storage_error)?;
        let capability_rows = sqlx::query(capability_sql)
            .bind(workspace_id)
            .bind(template_id)
            .fetch_all(&mut *self.transaction)
            .await
            .map_err(storage_error)?;
        let mut enumerations = BTreeMap::<String, Vec<_>>::new();
        for row in enum_rows {
            enumerations
                .entry(row.try_get("stream_key").map_err(storage_error)?)
                .or_default()
                .push(template_values::scalar(&row)?);
        }
        let mut capabilities = BTreeMap::new();
        for row in capability_rows {
            capabilities.insert(
                row.try_get::<String, _>("stream_key")
                    .map_err(storage_error)?,
                template_values::scalar(&row)?,
            );
        }
        for row in rows {
            let key: String = row.try_get("stream_key").map_err(storage_error)?;
            draft.streams.push(StreamDraft {
                enum_values: enumerations.remove(&key).unwrap_or_default(),
                safe_value: capabilities.remove(&key),
                key,
                display_name: row.try_get("display_name").map_err(storage_error)?,
                data_type: template_values::stream_type(
                    &row.try_get::<String, _>("data_type")
                        .map_err(storage_error)?,
                )?,
                direction: template_values::direction(
                    &row.try_get::<String, _>("direction")
                        .map_err(storage_error)?,
                )?,
                channel_kind: template_values::channel_kind(
                    &row.try_get::<String, _>("channel_kind")
                        .map_err(storage_error)?,
                )?,
                unit: row.try_get("unit").map_err(storage_error)?,
                minimum: row.try_get("min_value").map_err(storage_error)?,
                maximum: row.try_get("max_value").map_err(storage_error)?,
                string_max_length: row.try_get("string_max_length").map_err(storage_error)?,
                default_value: template_values::default_scalar(&row)?,
            });
        }
        draft.validate().map_err(|_| ApplicationError::Unavailable)
    }

    /**
     * Replace children theo thứ tự FK sau root CAS; upsert giữ revision stream hiện có tăng thay vì reset về1.
     * Input
     * Param: `workspace_id` — scope đã khóa.
     * Param: `template_id` — root mutation cùng transaction.
     * Param: draft — toàn aggregate đã validate, không nhận JSON tùy ý vào SQL.
     * Output: thành công khi mọi child ghi xong; Errors: storage rollback toàn draft/root CAS.
     */
    pub(super) async fn save_template_draft(
        &mut self,
        workspace_id: Uuid,
        template_id: Uuid,
        draft: &ValidatedTemplate,
    ) -> Result<(), ApplicationError> {
        // Xóa dependent enum/cap trước đổi datatype hoặc bỏ stream, tất cả vẫn nằm trong cùng unit of work.
        sqlx::query(
            "DELETE FROM template_draft_capabilities WHERE workspace_id=$1 AND template_id=$2",
        )
        .bind(workspace_id)
        .bind(template_id)
        .execute(&mut *self.transaction)
        .await
        .map_err(storage_error)?;
        sqlx::query(
            "DELETE FROM template_draft_enum_values WHERE workspace_id=$1 AND template_id=$2",
        )
        .bind(workspace_id)
        .bind(template_id)
        .execute(&mut *self.transaction)
        .await
        .map_err(storage_error)?;
        let keys = draft
            .draft()
            .streams
            .iter()
            .map(|stream| stream.key.as_str())
            .collect::<Vec<_>>();
        sqlx::query("DELETE FROM template_draft_streams WHERE workspace_id=$1 AND template_id=$2 AND NOT(stream_key=ANY($3::text[]))").bind(workspace_id).bind(template_id).bind(keys).execute(&mut *self.transaction).await.map_err(storage_error)?;
        for stream in &draft.draft().streams {
            let (default_kind, default_text) =
                template_values::optional_scalar_parts(stream.default_value.as_ref());
            // Chỉ value được bind; ON CONFLICT giữ identity scoped và tăng child revision dưới parent fence.
            sqlx::query("INSERT INTO template_draft_streams(workspace_id,template_id,stream_key,display_name,data_type,direction,channel_kind,unit,min_value,max_value,string_max_length,default_value) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,CASE $12::text WHEN 'NUMBER' THEN $13::jsonb WHEN 'BOOLEAN' THEN to_jsonb($13::boolean) WHEN 'STRING' THEN to_jsonb($13::text) END) ON CONFLICT(workspace_id,template_id,stream_key) DO UPDATE SET display_name=excluded.display_name,data_type=excluded.data_type,direction=excluded.direction,channel_kind=excluded.channel_kind,unit=excluded.unit,min_value=excluded.min_value,max_value=excluded.max_value,string_max_length=excluded.string_max_length,default_value=excluded.default_value,revision=template_draft_streams.revision+1")
                .bind(workspace_id).bind(template_id).bind(&stream.key).bind(&stream.display_name).bind(template_values::stream_type_code(stream.data_type)).bind(template_values::direction_code(stream.direction)).bind(template_values::channel_kind_code(stream.channel_kind))
                .bind(&stream.unit).bind(stream.minimum).bind(stream.maximum).bind(stream.string_max_length)
                .bind(default_kind).bind(default_text).execute(&mut *self.transaction).await.map_err(storage_error)?;
            for value in &stream.enum_values {
                let (kind, text) = template_values::scalar_parts(value);
                sqlx::query("INSERT INTO template_draft_enum_values(workspace_id,template_id,stream_key,enum_value) VALUES($1,$2,$3,CASE $4::text WHEN 'NUMBER' THEN $5::jsonb ELSE to_jsonb($5::text) END)")
                    .bind(workspace_id).bind(template_id).bind(&stream.key).bind(kind).bind(text).execute(&mut *self.transaction).await.map_err(storage_error)?;
            }
            if let Some(value) = &stream.safe_value {
                let (kind, text) = template_values::scalar_parts(value);
                sqlx::query("INSERT INTO template_draft_capabilities(workspace_id,template_id,stream_key,command_type,safe_value) VALUES($1,$2,$3,'SET_VALUE',CASE $4::text WHEN 'NUMBER' THEN $5::jsonb WHEN 'BOOLEAN' THEN to_jsonb($5::boolean) ELSE to_jsonb($5::text) END)")
                    .bind(workspace_id).bind(template_id).bind(&stream.key).bind(kind).bind(text).execute(&mut *self.transaction).await.map_err(storage_error)?;
            }
        }
        Ok(())
    }
}
