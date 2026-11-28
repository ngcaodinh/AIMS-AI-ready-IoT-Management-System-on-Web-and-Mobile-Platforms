//! Template use cases tách khỏi IAM orchestration; current auth, CAS, snapshot và required audit cùng commit.

use crate::{
    error::ApplicationError,
    ports::LockedSession,
    template_ports::{NewTemplateVersion, TemplateDigest, TemplateStore, TemplateTransaction},
};
use iot_domain::{
    audit_write::AuditDetail,
    identity::{AuditRecord, Principal, SessionProof},
    template::{
        TemplateDraft, TemplateField, TemplateIssueReason, TemplateValidation, ValidatedTemplate,
    },
    template_snapshot::{
        PublishedTemplate, TemplateMutation, TemplateSnapshot, TemplateStatus,
        TemplateTransitionFailure, TemplateVersionSnapshot,
    },
};
use uuid::Uuid;

/// Use case không có SQL/crypto implementation và không sửa schema pin của device khi publish.
#[derive(Clone)]
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
        self.read_version(proof, workspace_id, None, version_id)
            .await
    }

    /**
     * Đọc pin bất biến và kiểm family trước khi xác minh nội dung trả cho Admin.
     * Input
     * Param: proof — phiên hiện hành.
     * Param: workspace_id — workspace đích phải ACTIVE và có grant Admin.
     * Param: template_id — family bắt buộc nếu đọc qua route version có parent.
     * Param: version_id — UUID snapshot bất biến.
     * Output: snapshot scoped có digest đúng hoặc lỗi quyền, not-found, storage.
     */
    async fn read_version(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        template_id: Option<Uuid>,
        version_id: Uuid,
    ) -> Result<TemplateVersionSnapshot, ApplicationError> {
        let (mut transaction, locked) = self.open(proof, workspace_id).await?;
        let result = transaction
            .load_published_version(workspace_id, version_id)
            .await?;
        Self::current(&mut transaction, &locked, proof).await?;
        if template_id.is_some_and(|parent| parent != result.template_id) {
            return Err(ApplicationError::ResourceNotFound);
        }
        self.verify_version(&result)?;
        transaction.commit_template().await?;
        Ok(result)
    }

    /**
     * Từ chối snapshot có digest sai trước khi trả cho API hoặc dùng để clone/pin.
     *
     * # Input
     * Param: snapshot — immutable content và digest do repository resolve theo tenant.
     *
     * # Output
     * Thành công khi digest canonical khớp.
     *
     * # Errors
     * `Unavailable` khi dữ liệu persisted không khớp integrity check.
     */
    fn verify_version(&self, snapshot: &TemplateVersionSnapshot) -> Result<(), ApplicationError> {
        if self
            .digest
            .content_digest(&snapshot.content.canonical_bytes())
            != snapshot.content_digest
        {
            return Err(ApplicationError::Unavailable);
        }
        Ok(())
    }

    /**
     * Đọc một trang root của current Admin bằng keyset giới hạn và recheck session trước commit.
     *
     * # Input
     * Param: proof — session/context đã parse, phải còn hiệu lực sau database wait.
     * Param: workspace_id — tenant cần current Admin admission.
     * Param: status — bộ lọc trạng thái tùy chọn.
     * Param: after — UUID keyset cuối trang trước.
     * Param: page_size — số hàng bounded do adapter tính sentinel.
     *
     * # Output
     * Root snapshots trong đúng workspace.
     *
     * # Errors
     * Authority, not-found/inconsistent rows hoặc storage.
     */
    pub async fn list(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        status: Option<TemplateStatus>,
        after: Option<Uuid>,
        page_size: i64,
    ) -> Result<Vec<TemplateSnapshot>, ApplicationError> {
        let (mut transaction, locked) = self.open(proof, workspace_id).await?;
        let ids = transaction
            .list_template_ids(workspace_id, status, after, page_size)
            .await?;
        let mut results = Vec::with_capacity(ids.len());
        for template_id in ids {
            results.push(transaction.lock_template(workspace_id, template_id).await?);
        }
        Self::current(&mut transaction, &locked, proof).await?;
        transaction.commit_template().await?;
        Ok(results)
    }

    /**
     * Đọc exact version UUID và kiểm nó thuộc family mà current Admin yêu cầu.
     *
     * # Input
     * Param: proof — session/context hiện hành.
     * Param: workspace_id — tenant cần current Admin admission.
     * Param: template_id — family root đã được chỉ định.
     * Param: version_id — immutable snapshot selector, không phải authority.
     *
     * # Output
     * Snapshot đúng family sau kiểm digest.
     *
     * # Errors
     * Foreign/missing family/version cùng not-found, authority hoặc integrity/storage.
     */
    pub async fn version_in_family(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        template_id: Uuid,
        version_id: Uuid,
    ) -> Result<TemplateVersionSnapshot, ApplicationError> {
        self.read_version(proof, workspace_id, Some(template_id), version_id)
            .await
    }

    /**
     * Liệt kê immutable versions trong family, không giả kết quả provenance chưa được lưu.
     *
     * # Input
     * Param: proof — session/context hiện hành.
     * Param: workspace_id — tenant cần current Admin admission.
     * Param: template_id — family root đã được resolve scoped.
     * Param: source_revision — provenance filter; chỉ hỗ trợ khi schema có nguồn đó.
     * Param: after — UUID keyset cuối trang trước.
     * Param: page_size — giới hạn lấy thêm sentinel.
     *
     * # Output
     * Trang immutable snapshots đúng family; legacy source revision giữ null.
     *
     * # Errors
     * `Unavailable` cho provenance chưa hỗ trợ, authority, integrity hoặc storage.
     */
    pub async fn versions(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        template_id: Uuid,
        source_revision: Option<i64>,
        after: Option<Uuid>,
        page_size: i64,
    ) -> Result<Vec<TemplateVersionSnapshot>, ApplicationError> {
        let (mut transaction, locked) = self.open(proof, workspace_id).await?;
        transaction.lock_template(workspace_id, template_id).await?;
        // Schema hiện hành chưa có provenance, trả unavailable thay vì giả kết quả lookup rỗng.
        if source_revision.is_some() {
            Self::current(&mut transaction, &locked, proof).await?;
            return Err(ApplicationError::Unavailable);
        }
        let ids = transaction
            .list_version_ids(workspace_id, template_id, after, page_size)
            .await?;
        let mut results = Vec::with_capacity(ids.len());
        for id in ids {
            let result = transaction.load_published_version(workspace_id, id).await?;
            self.verify_version(&result)?;
            results.push(result);
        }
        Self::current(&mut transaction, &locked, proof).await?;
        transaction.commit_template().await?;
        Ok(results)
    }

    /**
     * Resolve full session và current Admin trong workspace ACTIVE trước khi tiếp cận template trực tiếp.
     * Input
     * Param: proof — session/context chưa được tin cậy.
     * Param: `workspace_id` — selector scope phải được current membership authorize.
     * Output: transaction đang giữ User→Workspace fence cùng snapshot actor; Errors: quyền/storage.
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
        transaction
            .lock_scope(workspace_id, principal.user_id())
            .await?
            .authorize(&principal, true)?;
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
            .validate()
            .map_err(ApplicationError::TemplateInvalid)?;
        self.create_checked(proof, workspace_id, draft, correlation_id, |_| Ok(()))
            .await
    }

    /**
     * Tạo draft sau current Admin admission và policy callback từ composition.
     *
     * # Input
     * Param: proof — session/context cần kiểm lại dưới lock.
     * Param: workspace_id — tenant đích.
     * Param: draft — aggregate đã validate toàn bộ.
     * Param: correlation_id — trace required audit.
     * Param: approve — policy external chỉ chạy sau current Admin admission.
     *
     * # Output
     * Root draft sau insert, audit và commit xác nhận.
     *
     * # Errors
     * Authority, policy, storage hoặc `CommitUnknown`; lỗi audit rollback insert.
     */
    pub async fn create_checked(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        draft: ValidatedTemplate,
        correlation_id: Uuid,
        approve: impl FnOnce(&ValidatedTemplate) -> Result<(), ApplicationError> + Send,
    ) -> Result<TemplateSnapshot, ApplicationError> {
        let (mut transaction, locked) = self.open(proof, workspace_id).await?;
        let (principal, now) = Self::current(&mut transaction, &locked, proof).await?;
        approve(&draft)?;
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
     * Chặn đổi model của family sau publication dù writer mở draft bằng đường cũ hay HTTP PATCH.
     * Input
     * Param: before — root đã khóa cùng thông tin latest published.
     * Param: draft — candidate đã validate.
     * Output: lỗi model scoped khi candidate đổi model đã được pin theo family.
     */
    fn require_family_model(
        before: &TemplateSnapshot,
        draft: &ValidatedTemplate,
    ) -> Result<(), ApplicationError> {
        if before.latest_published_version_id.is_some()
            && draft.draft().model != before.draft.draft().model
        {
            return Err(ApplicationError::TemplateInvalid(TemplateValidation {
                stream_index: None,
                field: TemplateField::Model,
                reason: TemplateIssueReason::Incompatible,
            }));
        }
        Ok(())
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
            .validate()
            .map_err(ApplicationError::TemplateInvalid)?;
        let (mut transaction, locked) = self.open(proof, workspace_id).await?;
        let before = transaction.lock_template(workspace_id, template_id).await?;
        let (principal, now) = Self::current(&mut transaction, &locked, proof).await?;
        let revision = before.next_revision(expected_revision, TemplateMutation::ReplaceDraft)?;
        Self::require_family_model(&before, &draft)?;
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
     * Áp PATCH lên draft dưới current Admin/CAS fence để candidate không dựa vào snapshot đã cũ.
     * Input
     * Param: proof — session/context hiện hành cần giữ tới commit.
     * Param: workspace_id — tenant đã chọn và phải còn active.
     * Param: template_id — root draft dưới lock.
     * Param: expected_revision — CAS revision từ `If-Match`; stale không tự refresh.
     * Param: correlation_id — trace cho audit change.
     * Param: candidate — phép biến đổi thuần đã lọc wire, không I/O hoặc dùng authority từ body.
     * Output: draft revision mới sau required audit và commit xác nhận.
     * Errors: precondition/CAS, validation, quyền, storage hoặc `CommitUnknown`; audit failure rollback.
     */
    pub async fn patch<E: From<ApplicationError>>(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        template_id: Uuid,
        expected_revision: i64,
        correlation_id: Uuid,
        candidate: impl FnOnce(&TemplateSnapshot) -> Result<ValidatedTemplate, E> + Send,
    ) -> Result<TemplateSnapshot, E> {
        let (mut transaction, locked) = self.open(proof, workspace_id).await?;
        let before = transaction.lock_template(workspace_id, template_id).await?;
        let (principal, now) = Self::current(&mut transaction, &locked, proof).await?;
        let revision = before
            .next_revision(expected_revision, TemplateMutation::PatchDraft)
            .map_err(ApplicationError::from)?;
        let draft = candidate(&before)?;
        Self::require_family_model(&before, &draft)?;
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
     * Clone một version đúng family thành draft dưới CAS mà không sửa snapshot hay device pin cũ.
     *
     * # Input
     * Param: proof — session/context hiện hành của current Admin.
     * Param: workspace_id — tenant đích.
     * Param: template_id — family root đã authorize.
     * Param: expected_revision — CAS revision của root hiện hành.
     * Param: source_version_id — exact published UUID trong chính family đó.
     * Param: correlation_id — trace required audit.
     *
     * # Output
     * Draft root mới từ content version sau audit/commit xác nhận.
     *
     * # Errors
     * Draft đã tồn tại, stale, foreign version, immutable model, quyền hoặc storage.
     */
    pub async fn clone_draft(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        template_id: Uuid,
        expected_revision: i64,
        source_version_id: Uuid,
        correlation_id: Uuid,
    ) -> Result<TemplateSnapshot, ApplicationError> {
        let (mut transaction, locked) = self.open(proof, workspace_id).await?;
        let before = transaction.lock_template(workspace_id, template_id).await?;
        Self::current(&mut transaction, &locked, proof).await?;
        let revision = before.next_revision(expected_revision, TemplateMutation::ReplaceDraft)?;
        if before.status == TemplateStatus::Draft {
            return Err(ApplicationError::TemplateDraftExists);
        }
        let source = transaction
            .load_published_version(workspace_id, source_version_id)
            .await?;
        if source.template_id != template_id {
            return Err(ApplicationError::ResourceNotFound);
        }
        self.verify_version(&source)?;
        if source.content.draft().model != before.draft.draft().model {
            return Err(ApplicationError::ImmutableSchema);
        }
        let (principal, now) = Self::current(&mut transaction, &locked, proof).await?;
        let result = transaction
            .replace_draft(&before, &source.content, revision, now)
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
        let version_number = transaction
            .latest_version_number(workspace_id, template_id)
            .await?
            .checked_add(1)
            .ok_or(ApplicationError::Unavailable)?;
        let intent = NewTemplateVersion {
            template_version_id: Uuid::new_v4(),
            version_number,
            template_revision: revision,
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
