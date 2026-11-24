//! Template use cases tách khỏi IAM orchestration; current auth, CAS, snapshot và required audit cùng commit.

use crate::{
    error::ApplicationError,
    ports::LockedSession,
    template_ports::{NewTemplateVersion, TemplateDigest, TemplateStore, TemplateTransaction},
};
use iot_domain::{
    audit_write::AuditDetail,
    identity::{AuditRecord, Principal, SessionProof},
    template::TemplateDraft,
    template_snapshot::{
        PublishedTemplate, TemplateMutation, TemplateSnapshot, TemplateTransitionFailure,
    },
};
use uuid::Uuid;

/// Use case không có SQL/crypto implementation và không sửa schema pin của device khi publish.
pub struct TemplateService<S, C> {
    store: S,
    digest: C,
}

impl From<TemplateTransitionFailure> for ApplicationError {
    /// Giữ stale/immutable/storage overflow riêng cho mapping412/409/503 ở transport tương lai.
    fn from(failure: TemplateTransitionFailure) -> Self {
        match failure {
            TemplateTransitionFailure::StaleRevision => Self::StaleRevision,
            TemplateTransitionFailure::Immutable => Self::ImmutableSchema,
            TemplateTransitionFailure::RevisionExhausted => Self::Unavailable,
        }
    }
}

impl<S: TemplateStore, C: TemplateDigest> TemplateService<S, C> {
    /**
     * Nhận store và SHA256 adapter đã cấu hình tại composition, không tự tạo pool hoặc đọc secret.
     * Input
     * Param: store — unit-of-work factory giữ auth/mutation/audit cùng transaction.
     * Param: digest — adapter băm canonical content không I/O.
     * Output: service template độc lập với `IdentityService`.
     */
    #[must_use]
    pub const fn new(store: S, digest: C) -> Self {
        Self { store, digest }
    }

    /**
     * Admin đọc published content và tái dựng digest chỉ từ immutable version rows.
     * Input
     * Param: proof — full session/context của current Admin.
     * Param: `workspace_id` — tenant ACTIVE có current grant.
     * Param: `version_id` — published version trong tenant, không dùng UUID để lookup global.
     * Output: immutable schema có digest khớp; USER phải đọc qua device owner/pin policy ở use case riêng.
     * # Errors
     * Quyền, `ResourceNotFound` hoặc Unavailable nếu content/digest không khớp; `CommitUnknown` khi kết thúc read.
     */
    pub async fn get_version(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        version_id: Uuid,
    ) -> Result<iot_domain::template_snapshot::TemplateVersionSnapshot, ApplicationError> {
        let (mut transaction, locked) = self.open(proof, workspace_id).await?;
        let result = transaction
            .load_published_version(workspace_id, version_id)
            .await?;
        Self::current(&mut transaction, &locked, proof).await?;
        if self
            .digest
            .content_digest(&result.content.canonical_bytes())
            != result.content_digest
        {
            return Err(ApplicationError::Unavailable);
        }
        transaction.commit_template().await?;
        Ok(result)
    }

    /**
     * Resolve full session và current Admin trong workspace ACTIVE trước khi tiếp cận template trực tiếp.
     * Input
     * Param: proof — session/context chưa được tin cậy.
     * Param: `workspace_id` — selector scope phải được current membership authorize.
     * Output: transaction giữ User→Workspace fence; scope vắng mặt thành ResourceNotFound, member không đủ quyền thành Forbidden.
     */
    async fn open(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
    ) -> Result<(S::Transaction, LockedSession), ApplicationError> {
        let mut transaction = self.store.begin_template().await?;
        let locked = transaction.lock_actor(proof).await?;
        let principal =
            locked
                .session
                .authorize(&locked.account, proof, locked.observed_at, false)?;
        let scope = transaction
            .lock_scope(workspace_id, principal.user_id())
            .await
            .map_err(|error| match error {
                // Workspace/member vắng mặt trả cùng kết quả đã che scope như template thuộc tenant khác.
                ApplicationError::Forbidden => ApplicationError::ResourceNotFound,
                other => other,
            })?;
        scope.authorize(&principal, true)?;
        Ok((transaction, locked))
    }

    /**
     * Đọc clock mới sau root lock để session hết hạn trong lúc chờ không được admit.
     * Input
     * Param: transaction — cùng unit of work đã khóa User/Workspace/template.
     * Param: locked — account/session snapshot được fence giữ ổn định.
     * Param: proof — context gốc, không tự đổi context khi retry.
     * Output: principal còn hiệu lực và thời điểm admission; Errors: session/storage.
     */
    async fn current(
        transaction: &mut S::Transaction,
        locked: &LockedSession,
        proof: &SessionProof,
    ) -> Result<(Principal, chrono::DateTime<chrono::Utc>), ApplicationError> {
        let now = transaction.template_now().await?;
        Ok((
            locked
                .session
                .authorize(&locked.account, proof, now, false)?,
            now,
        ))
    }

    /**
     * Ghi audit typed từ principal đã authorize, không copy schema/name/description vào metadata.
     * Input
     * Param: transaction — mutation và audit chung unit of work.
     * Param: principal — actor/session/client từ resolver, không body client.
     * Param: `workspace_id` — scope đã kiểm quyền.
     * Param: `correlation_id` — identity trace của request.
     * Param: detail — variant template hữu hạn với identity/revision/version.
     * Output: thành công khi audit được ghi; Errors: sink failure rollback mutation.
     */
    async fn audit(
        transaction: &mut S::Transaction,
        principal: &Principal,
        workspace_id: Uuid,
        correlation_id: Uuid,
        detail: AuditDetail,
    ) -> Result<(), ApplicationError> {
        transaction
            .append_template_audit(AuditRecord {
                workspace_id: Some(workspace_id),
                actor_user_id: Some(principal.user_id()),
                session_id: Some(principal.session_id()),
                detail,
                client_type: principal.client_type(),
                correlation_id,
            })
            .await
    }

    /**
     * Tạo draft normalized sau kiểm toàn schema, current Admin và required audit; chỉ trả sau commit.
     * Input
     * Param: proof — full session/context hiện hành.
     * Param: `workspace_id` — tenant ACTIVE của template mới.
     * Param: draft — metadata/streams typed chưa tin cậy, có cả channel kind và direction.
     * Param: `correlation_id` — trace không chứa schema.
     * Output: draft root/revision1 sau commit.
     * # Errors
     * `TemplateInvalid`, quyền/storage hoặc `CommitUnknown`; không tự retry create bằng ID mới khi mất ACK.
     */
    pub async fn create(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        draft: TemplateDraft,
        correlation_id: Uuid,
    ) -> Result<TemplateSnapshot, ApplicationError> {
        let draft = draft
            .validate_canonical_write()
            .map_err(ApplicationError::TemplateInvalid)?;
        let (mut transaction, locked) = self.open(proof, workspace_id).await?;
        let (principal, now) = Self::current(&mut transaction, &locked, proof).await?;
        let template_id = Uuid::new_v4();
        let result = transaction
            .insert_template(workspace_id, template_id, principal.user_id(), &draft, now)
            .await?;
        Self::audit(
            &mut transaction,
            &principal,
            workspace_id,
            correlation_id,
            AuditDetail::TemplateCreated { template_id },
        )
        .await?;
        transaction.commit_template().await?;
        Ok(result)
    }

    /**
     * Đọc draft cho current Admin của đúng tenant; không dùng resource UUID để bỏ qua scope.
     * Input
     * Param: proof — full session/context cần kiểm lại sau root lock wait.
     * Param: `workspace_id` — tenant phải ACTIVE và actor là Admin.
     * Param: `template_id` — selector root trong tenant đó.
     * Output: snapshot hiện hành sau read transaction commit.
     * # Errors
     * Quyền, `ResourceNotFound` hoặc storage/`CommitUnknown`; không trả row của workspace khác.
     */
    pub async fn get(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        template_id: Uuid,
    ) -> Result<TemplateSnapshot, ApplicationError> {
        let (mut transaction, locked) = self.open(proof, workspace_id).await?;
        let result = transaction.lock_template(workspace_id, template_id).await?;
        Self::current(&mut transaction, &locked, proof).await?;
        transaction.commit_template().await?;
        Ok(result)
    }

    /**
     * Thay toàn bộ draft atomically theo revision; published snapshots và device pin giữ nguyên.
     * Input
     * Param: proof — full session/context của current Admin.
     * Param: `workspace_id` — tenant đã chọn, không suy từ template UUID.
     * Param: `template_id` — root cần sửa draft.
     * Param: `expected_revision` — revision dương bắt buộc, không refresh tự động khi stale.
     * Param: draft — aggregate mới phải validate toàn bộ trước ghi.
     * Param: `correlation_id` — trace của mutation/audit.
     * Output: root DRAFT với revision tăng một sau commit.
     * # Errors
     * `TemplateInvalid`, stale/immutable, quyền/not-found hoặc storage/`CommitUnknown`; audit failure rollback cả replace.
     */
    pub async fn replace(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        template_id: Uuid,
        expected_revision: i64,
        draft: TemplateDraft,
        correlation_id: Uuid,
    ) -> Result<TemplateSnapshot, ApplicationError> {
        if expected_revision <= 0 {
            return Err(ApplicationError::InvalidInput);
        }
        let draft = draft
            .validate_canonical_write()
            .map_err(ApplicationError::TemplateInvalid)?;
        let (mut transaction, locked) = self.open(proof, workspace_id).await?;
        let before = transaction.lock_template(workspace_id, template_id).await?;
        let (principal, now) = Self::current(&mut transaction, &locked, proof).await?;
        let revision = before.next_revision(expected_revision, TemplateMutation::ReplaceDraft)?;
        let result = transaction
            .replace_draft(&before, &draft, revision, now)
            .await?;
        Self::audit(
            &mut transaction,
            &principal,
            workspace_id,
            correlation_id,
            AuditDetail::TemplateDraftChanged {
                template_id,
                revision_before: before.revision,
                revision_after: revision,
            },
        )
        .await?;
        transaction.commit_template().await?;
        Ok(result)
    }

    /**
     * Publish một snapshot immutable từ draft đã kiểm dưới CAS; server cấp version ID/số, không đổi pin cũ.
     * Input
     * Param: proof — full session/context của current Admin.
     * Param: `workspace_id` — tenant ACTIVE đã authorize.
     * Param: `template_id` — root DRAFT cần publish.
     * Param: `expected_revision` — revision admission; hai request cùng revision chỉ một winner.
     * Param: `correlation_id` — trace required audit.
     * Output: version identity/digest sau commit xác nhận.
     * # Errors
     * Stale/`ImmutableSchema`, quyền/not-found, overflow hoặc storage/`CommitUnknown`; không tự republish sau mất ACK.
     */
    pub async fn publish(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        template_id: Uuid,
        expected_revision: i64,
        correlation_id: Uuid,
    ) -> Result<PublishedTemplate, ApplicationError> {
        if expected_revision <= 0 {
            return Err(ApplicationError::InvalidInput);
        }
        let (mut transaction, locked) = self.open(proof, workspace_id).await?;
        let before = transaction.lock_template(workspace_id, template_id).await?;
        let (principal, now) = Self::current(&mut transaction, &locked, proof).await?;
        let revision = before.next_revision(expected_revision, TemplateMutation::Publish)?;
        before
            .draft
            .validate_publication_v1()
            .map_err(ApplicationError::TemplateInvalid)?;
        let version_number = transaction
            .latest_version_number(workspace_id, template_id)
            .await?
            .checked_add(1)
            .ok_or(ApplicationError::Unavailable)?;
        let intent = NewTemplateVersion {
            template_version_id: Uuid::new_v4(),
            version_number,
            source_revision: before.revision,
            published_root_revision: revision,
            content_digest: self.digest.content_digest(&before.draft.canonical_bytes()),
            published_by_user_id: principal.user_id(),
            published_at: now,
        };
        let result = transaction.publish_template(&before, &intent).await?;
        Self::audit(
            &mut transaction,
            &principal,
            workspace_id,
            correlation_id,
            AuditDetail::TemplatePublished {
                template_id,
                template_version_id: intent.template_version_id,
                version_number,
                revision_before: before.revision,
                revision_after: revision,
            },
        )
        .await?;
        transaction.commit_template().await?;
        Ok(result)
    }
}
