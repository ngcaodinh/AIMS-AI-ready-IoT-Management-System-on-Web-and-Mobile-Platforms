//! Template unit of work dùng cùng IAM fences qua delegation, không sao chép auth policy hoặc auto-grant DB.

use crate::{PgIdentityStore, PgUnitOfWork, commit_error, storage_error};
use chrono::{DateTime, Utc};
use iot_application::{
    error::ApplicationError,
    ports::{IdentityTransaction, LockedSession, WorkspaceTransaction},
    template_ports::{NewTemplateVersion, TemplateStore, TemplateTransaction},
};
use iot_domain::{
    identity::{AuditRecord, SessionProof},
    template::{TemplateDraft, ValidatedTemplate},
    template_snapshot::{PublishedTemplate, TemplateSnapshot, TemplateStatus},
    workspace::WorkspaceSnapshot,
};
use sqlx::{Row, postgres::PgRow};
use uuid::Uuid;

/**
 * Restore root metadata finite; không dùng description mutable để tái dựng published digest.
 * Input
 * Param: row — projection root đã khóa cùng tenant.
 * Param: draft — full normalized schema đã validate.
 * Output: root snapshot hoặc Unavailable nếu persisted state/storage sai.
 */
fn snapshot(row: &PgRow, draft: ValidatedTemplate) -> Result<TemplateSnapshot, ApplicationError> {
    let status = match row
        .try_get::<String, _>("lifecycle_status")
        .map_err(storage_error)?
        .as_str()
    {
        "DRAFT" => TemplateStatus::Draft,
        "PUBLISHED" => TemplateStatus::Published,
        "ARCHIVED" => TemplateStatus::Archived,
        _ => return Err(ApplicationError::Unavailable),
    };
    Ok(TemplateSnapshot {
        workspace_id: row.try_get("workspace_id").map_err(storage_error)?,
        template_id: row.try_get("template_id").map_err(storage_error)?,
        revision: row.try_get("revision").map_err(storage_error)?,
        status,
        draft,
        created_at: row.try_get("created_at").map_err(storage_error)?,
        updated_at: row.try_get("updated_at").map_err(storage_error)?,
    })
}

impl TemplateStore for PgIdentityStore {
    type Transaction = PgUnitOfWork;
    /// Mở transaction cùng pool đã được composition cấp quyền; không dùng owner hoặc auto-migrate.
    async fn begin_template(&self) -> Result<PgUnitOfWork, ApplicationError> {
        Ok(PgUnitOfWork {
            transaction: self.pool.begin().await.map_err(storage_error)?,
        })
    }
}

impl TemplateTransaction for PgUnitOfWork {
    /// Đọc immutable snapshot scoped; header/name/model lấy từ version, không join root metadata hiện hành.
    async fn load_published_version(
        &mut self,
        workspace_id: Uuid,
        version_id: Uuid,
    ) -> Result<iot_domain::template_snapshot::TemplateVersionSnapshot, ApplicationError> {
        self.read_template_version(workspace_id, version_id).await
    }
    /// Delegate IAM resolver trong cùng physical transaction, không tách lock hoặc commit.
    async fn lock_actor(
        &mut self,
        proof: &SessionProof,
    ) -> Result<LockedSession, ApplicationError> {
        IdentityTransaction::lock_session(self, proof).await
    }
    /// Delegate workspace/member/grant fences hiện hành sau User lock, không giữ quyền cache.
    async fn lock_scope(
        &mut self,
        workspace_id: Uuid,
        user_id: Uuid,
    ) -> Result<WorkspaceSnapshot, ApplicationError> {
        WorkspaceTransaction::lock_workspace(self, workspace_id, user_id).await
    }
    /// Clock riêng sau root lock wait, không dùng `transaction_timestamp` đã cũ cho session admission.
    async fn template_now(&mut self) -> Result<DateTime<Utc>, ApplicationError> {
        sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *self.transaction)
            .await
            .map_err(storage_error)
    }
    /// Khóa root bằng cả tenant/key rồi load normalized children; không SELECT definition của version khác.
    async fn lock_template(
        &mut self,
        workspace_id: Uuid,
        template_id: Uuid,
    ) -> Result<TemplateSnapshot, ApplicationError> {
        let row=sqlx::query("SELECT workspace_id,template_id,name,model,description,lifecycle_status,revision,created_at,updated_at FROM templates WHERE workspace_id=$1 AND template_id=$2 FOR UPDATE")
            .bind(workspace_id).bind(template_id).fetch_optional(&mut *self.transaction).await.map_err(storage_error)?.ok_or(ApplicationError::ResourceNotFound)?;
        let draft = TemplateDraft {
            name: row.try_get("name").map_err(storage_error)?,
            model: row.try_get("model").map_err(storage_error)?,
            description: row.try_get("description").map_err(storage_error)?,
            streams: vec![],
        };
        let draft = self
            .load_template_content(
                workspace_id,
                template_id,
                draft,
                crate::template_draft::TemplateContentSource::Draft,
            )
            .await?;
        snapshot(&row, draft)
    }
    /// Root/children atomic, actor/W do service đã authorize; timestamps lấy từ clock admission server.
    async fn insert_template(
        &mut self,
        workspace_id: Uuid,
        template_id: Uuid,
        actor_id: Uuid,
        draft: &ValidatedTemplate,
        now: DateTime<Utc>,
    ) -> Result<TemplateSnapshot, ApplicationError> {
        sqlx::query("INSERT INTO templates(workspace_id,template_id,name,model,description,created_by_user_id,created_at,updated_at) VALUES($1,$2,$3,$4,$5,$6,$7,$7)")
            .bind(workspace_id).bind(template_id).bind(&draft.draft().name).bind(&draft.draft().model).bind(&draft.draft().description).bind(actor_id).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        self.save_template_draft(workspace_id, template_id, draft)
            .await?;
        self.lock_template(workspace_id, template_id).await
    }
    /// CAS root trước children, giữ immutable versions và pin cũ; không reset revision stream cũ.
    async fn replace_draft(
        &mut self,
        before: &TemplateSnapshot,
        draft: &ValidatedTemplate,
        next_revision: i64,
        now: DateTime<Utc>,
    ) -> Result<TemplateSnapshot, ApplicationError> {
        let changed=sqlx::query("UPDATE templates SET name=$4,model=$5,description=$6,lifecycle_status='DRAFT',revision=$7,updated_at=$8 WHERE workspace_id=$1 AND template_id=$2 AND revision=$3 AND lifecycle_status<>'ARCHIVED'")
            .bind(before.workspace_id).bind(before.template_id).bind(before.revision).bind(&draft.draft().name).bind(&draft.draft().model).bind(&draft.draft().description).bind(next_revision).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?.rows_affected();
        if changed != 1 {
            return Err(ApplicationError::StaleRevision);
        }
        self.save_template_draft(before.workspace_id, before.template_id, draft)
            .await?;
        self.lock_template(before.workspace_id, before.template_id)
            .await
    }
    /// Version sequence serialize bởi root lock; scoped unique là phòng vệ thứ hai, không dùng MAX ngoài transaction.
    async fn latest_version_number(
        &mut self,
        workspace_id: Uuid,
        template_id: Uuid,
    ) -> Result<i32, ApplicationError> {
        sqlx::query_scalar("SELECT coalesce(max(version_number),0) FROM template_versions WHERE workspace_id=$1 AND template_id=$2").bind(workspace_id).bind(template_id).fetch_one(&mut *self.transaction).await.map_err(storage_error)
    }
    /// Publish helper giữ marker/version/children/root trong cùng physical transaction, không commit giữa snapshot.
    async fn publish_template(
        &mut self,
        before: &TemplateSnapshot,
        version: &NewTemplateVersion,
    ) -> Result<PublishedTemplate, ApplicationError> {
        self.persist_template_publication(before, version).await
    }
    /// Required audit dùng writer chuẩn để giữ actor/scope/manifest, không bypass fault metric hoặc sink guard.
    async fn append_template_audit(&mut self, audit: AuditRecord) -> Result<(), ApplicationError> {
        IdentityTransaction::append_audit(self, audit).await
    }
    /// Commit qua classifier chung, không coi mất ACK là rollback hoặc tự publish version tiếp.
    async fn commit_template(self) -> Result<(), ApplicationError> {
        self.transaction.commit().await.map_err(commit_error)
    }
}
