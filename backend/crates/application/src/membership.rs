//! Member mutation chỉ đổi authority trong một workspace, không revoke global account/session.

use crate::{
    error::ApplicationError,
    identity::IdentityService,
    ports::{IdentitySecurity, IdentityStore, IdentityTransaction, WorkspaceTransaction},
};
use chrono::{DateTime, Utc};
use iot_domain::audit_write::AuditDetail;
use iot_domain::{
    identity::{AuditRecord, SessionProof},
    membership::{MembershipFailure, MembershipPatch, MembershipSnapshot, MembershipStatus},
    workspace::{WorkspaceAdmission, WorkspaceRole},
};
use std::future::Future;
use uuid::Uuid;

/// Email dùng HMAC admission fence nội bộ; caller transport chỉ nhận projection snapshot riêng.
pub struct LockedMembership {
    pub snapshot: MembershipSnapshot,
    pub email_normalized: String,
}

/// Projection allowlist cho danh sách member; không mang dữ liệu credential hoặc trạng thái account global.
pub struct MembershipListItem {
    pub workspace_id: Uuid,
    pub user_id: Uuid,
    pub email: String,
    pub alias: Option<String>,
    pub role: WorkspaceRole,
    pub status: MembershipStatus,
    pub authorization_version: i64,
    pub revision: i64,
}

/// Trang member có fingerprint current authority và dấu hiệu còn trang kế tiếp.
pub struct MembershipPage {
    pub authority_fingerprint: String,
    pub has_more: bool,
    pub items: Vec<MembershipListItem>,
}

/// Unit of work member giữ current Admin/CAS/scoped cleanup/audit trong cùng physical transaction.
pub trait MembershipTransaction: WorkspaceTransaction {
    /**
     * Đọc page membership trong scope đã admission, không trả toàn bộ account toàn cục.
     * Input
     * Param: `workspace_id` — tenant đã được xác minh bởi use case trong cùng transaction.
     * Param: status — trạng thái enum domain cần lọc.
     * Param: `after_user_id` — UUID cuối trang trước hoặc None cho trang đầu.
     * Param: limit — số hàng cần đọc, gồm tối đa một sentinel để phát hiện trang kế.
     * Output: projection member allowlist theo keyset UUID.
     * # Errors
     * Lỗi storage hoặc dữ liệu enum không hợp lệ.
     */
    fn list_members(
        &mut self,
        workspace_id: Uuid,
        status: MembershipStatus,
        after_user_id: Option<Uuid>,
        limit: i64,
    ) -> impl Future<Output = Result<Vec<MembershipListItem>, ApplicationError>> + Send;
    /// Khóa actor/target User theo UUID tăng dần trước Workspace; resolver phải kiểm proof lại.
    fn lock_member_subjects(
        &mut self,
        proof: &SessionProof,
        target_id: Uuid,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// Khóa target membership đúng tenant và đếm other capable Admin dưới parent fence.
    fn lock_member(
        &mut self,
        workspace_id: Uuid,
        target_id: Uuid,
    ) -> impl Future<Output = Result<LockedMembership, ApplicationError>> + Send;
    /// Lấy admission clock mới sau khóa để session đã hết hạn trong lock wait không được ghi.
    fn membership_now(
        &mut self,
    ) -> impl Future<Output = Result<DateTime<Utc>, ApplicationError>> + Send;
    /// Persist state/revision/auth version bằng CAS, không thay grant hoặc global account.
    fn save_member(
        &mut self,
        before: &MembershipSnapshot,
        after: &MembershipSnapshot,
        now: DateTime<Utc>,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// Vô hiệu capability/pending work đúng scope; dispatched/unknown giữ cho reconciliation.
    fn invalidate_member_authority(
        &mut self,
        before: &MembershipSnapshot,
        after: &MembershipSnapshot,
        email_digest: [u8; 32],
        now: DateTime<Utc>,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
}

impl From<MembershipFailure> for ApplicationError {
    /// Giữ nguyên lý do last Admin/CAS/rejoin cho transport, không lộ storage metadata.
    fn from(failure: MembershipFailure) -> Self {
        match failure {
            MembershipFailure::InvalidPatch => Self::InvalidInput,
            MembershipFailure::StaleRevision => Self::StaleRevision,
            MembershipFailure::LastAdminRequired => Self::LastAdminRequired,
            MembershipFailure::RejoinRequired => Self::InvalidTransition,
            MembershipFailure::RevisionExhausted => Self::Unavailable,
        }
    }
}

impl<S: IdentityStore, C: IdentitySecurity> IdentityService<S, C>
where
    S::Transaction: MembershipTransaction,
{
    /**
     * Liệt kê membership sau khi kiểm current Admin và khóa scope tới lúc query hoàn tất.
     * Input
     * Param: proof — credential/context cần resolver và domain policy kiểm lại.
     * Param: `workspace_id` — tenant selector chưa đáng tin, chỉ dùng sau Admin admission.
     * Param: status — trạng thái membership cần lọc; mọi trạng thái lịch sử vẫn thuộc tenant này.
     * Param: `after_user_id` — khóa trang đã được HTTP adapter xác minh chữ ký.
     * Param: limit — cận trang1–100; use case lấy thêm một hàng để xác định còn trang.
     * Output: projection allowlist cùng fingerprint quyền hiện hành, không phải capability cache.
     * # Errors
     * Sai session, limited session, thiếu Admin/workspace, input hoặc lỗi lưu trữ.
     */
    pub async fn list_members(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        status: MembershipStatus,
        after_user_id: Option<Uuid>,
        limit: i64,
    ) -> Result<MembershipPage, ApplicationError> {
        if !(1..=100).contains(&limit) {
            return Err(ApplicationError::InvalidInput);
        }
        let mut transaction = self.store.begin().await?;
        let locked = transaction.lock_session(proof).await?;
        let principal =
            locked
                .session
                .authorize(&locked.account, proof, locked.observed_at, false)?;
        let admission = transaction
            .lock_workspace(workspace_id, principal.user_id())
            .await?
            .authorize(&principal, true)?;
        let mut items = transaction
            .list_members(workspace_id, status, after_user_id, limit + 1)
            .await?;
        let page_size = usize::try_from(limit).map_err(|_| ApplicationError::InvalidInput)?;
        let has_more = items.len() > page_size;
        if has_more {
            items.truncate(page_size);
        }
        let now = transaction.membership_now().await?;
        locked
            .session
            .authorize(&locked.account, proof, now, false)?;
        let authority_fingerprint = admission_fingerprint(&admission);
        transaction.commit().await?;
        Ok(MembershipPage {
            authority_fingerprint,
            has_more,
            items,
        })
    }

    /**
     * Đổi role/status/alias bằng current Admin và CAS, giữ global session và quyền tenant khác.
     * Input
     * Param: proof — full session/context phải còn current Admin trong workspace đích.
     * Param: `workspace_id` — tenant selector cần authorize trước mọi mutation.
     * Param: `target_id` — thành viên thuộc đúng tenant, không là account global patch.
     * Param: `expected_revision` — If-Match hiện hành của membership.
     * Param: patch — tối thiểu một trường; alias null có nghĩa xóa alias.
     * Param: `correlation_id` — identity audit/outbox không chứa secret.
     * Output: snapshot nội bộ sau commit; HTTP adapter phải dùng DTO allowlist.
     * # Errors
     * Current authority, stale revision, last Admin, rejoin trái workflow hoặc storage/unknown commit.
     */
    pub async fn update_member(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        target_id: Uuid,
        expected_revision: i64,
        patch: &MembershipPatch,
        correlation_id: Uuid,
    ) -> Result<MembershipSnapshot, ApplicationError> {
        self.update_member_inner(
            proof,
            workspace_id,
            target_id,
            expected_revision,
            patch,
            correlation_id,
        )
        .await
        .map(|(snapshot, _)| snapshot)
    }

    /**
     * Trả MembershipDTO sau khi PATCH đã commit mà không đọc lại quyền ngoài transaction.
     * Input
     * Param: proof — full session/context cần recheck trước khi cập nhật.
     * Param: `workspace_id` — workspace selector cần authorize ở server.
     * Param: `target_id` — thành viên thuộc scope cần thay đổi.
     * Param: `expected_revision` — revision membership từ If-Match.
     * Param: patch — các trường role/status/alias đã validate ở HTTP boundary.
     * Param: `correlation_id` — mã audit cho mutation này.
     * Output: projection allowlist gồm email membership và trạng thái sau commit.
     * # Errors
     * Giữ nguyên lỗi auth, CAS, last Admin, transition và storage từ transaction.
     */
    pub async fn patch_member(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        target_id: Uuid,
        expected_revision: i64,
        patch: &MembershipPatch,
        correlation_id: Uuid,
    ) -> Result<MembershipListItem, ApplicationError> {
        let (snapshot, email) = self
            .update_member_inner(
                proof,
                workspace_id,
                target_id,
                expected_revision,
                patch,
                correlation_id,
            )
            .await?;
        Ok(MembershipListItem {
            workspace_id: snapshot.workspace_id,
            user_id: snapshot.user_id,
            email,
            alias: snapshot.alias,
            role: snapshot.role,
            status: snapshot.status,
            authorization_version: snapshot.authorization_version,
            revision: snapshot.revision,
        })
    }

    /**
     * Thực hiện CAS và cập nhật audit/fence trong một transaction để response phản ánh cùng snapshot.
     * Input
     * Param: proof — full session/context cần recheck dưới các khóa liên quan.
     * Param: `workspace_id` — workspace phải được authorize trước khi đọc target.
     * Param: `target_id` — User và Membership cần khóa theo lock graph hiện hành.
     * Param: `expected_revision` — revision client đã đọc, so sánh dưới row lock.
     * Param: patch — thay đổi đã được parse thành kiểu domain.
     * Param: `correlation_id` — identity audit/outbox không chứa secret.
     * Output: snapshot membership sau commit và email đã lấy dưới cùng transaction.
     * # Errors
     * Current authority, stale CAS, last Admin, transition không hợp lệ hoặc storage/unknown commit.
     */
    async fn update_member_inner(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        target_id: Uuid,
        expected_revision: i64,
        patch: &MembershipPatch,
        correlation_id: Uuid,
    ) -> Result<(MembershipSnapshot, String), ApplicationError> {
        if expected_revision <= 0 {
            return Err(ApplicationError::InvalidInput);
        }
        let mut transaction = self.store.begin().await?;
        transaction.lock_member_subjects(proof, target_id).await?;
        let locked = transaction.lock_session(proof).await?;
        let principal =
            locked
                .session
                .authorize(&locked.account, proof, locked.observed_at, false)?;
        transaction
            .lock_workspace(workspace_id, principal.user_id())
            .await?
            .authorize(&principal, true)?;
        let member = transaction.lock_member(workspace_id, target_id).await?;
        let email = member.email_normalized.clone();
        let next = match member.snapshot.apply(patch, expected_revision) {
            Ok(next) => next,
            Err(MembershipFailure::LastAdminRequired) => {
                let now = transaction.membership_now().await?;
                locked
                    .session
                    .authorize(&locked.account, proof, now, false)?;
                // Lưu denial cùng scope/correlation; nếu audit lỗi thì transaction rollback và không giả nhận 409 đã ghi nhận.
                transaction
                    .append_audit(AuditRecord {
                        workspace_id: Some(workspace_id),
                        actor_user_id: Some(principal.user_id()),
                        session_id: Some(principal.session_id()),
                        detail: AuditDetail::MembershipLastAdminDenied { user_id: target_id },
                        client_type: principal.client_type(),
                        correlation_id,
                    })
                    .await?;
                transaction.commit().await?;
                return Err(ApplicationError::LastAdminRequired);
            }
            Err(failure) => return Err(failure.into()),
        };
        let now = transaction.membership_now().await?;
        locked
            .session
            .authorize(&locked.account, proof, now, false)?;
        let digest = self.security.bucket_digest(&member.email_normalized)?;
        transaction
            .save_member(&member.snapshot, &next, now)
            .await?;
        // Alias-only không đổi authority; không đóng socket hoặc hủy tác vụ khi chỉ đổi tên hiển thị.
        if next.authorization_version != member.snapshot.authorization_version {
            transaction
                .invalidate_member_authority(&member.snapshot, &next, digest, now)
                .await?;
        }
        transaction
            .append_audit(AuditRecord {
                workspace_id: Some(workspace_id),
                actor_user_id: Some(principal.user_id()),
                session_id: Some(principal.session_id()),
                detail: AuditDetail::MembershipChanged(
                    iot_domain::audit_write::MembershipAudit::between(&member.snapshot, &next),
                ),
                client_type: principal.client_type(),
                correlation_id,
            })
            .await?;
        transaction.commit().await?;
        Ok((next, email))
    }
}

/**
 * Tạo fingerprint từ epoch quyền tenant để cursor mất hiệu lực sau thay đổi admission.
 * Input
 * Param: admission — workspace/user cùng các generation và authorization version do DB xác minh.
 * Output: chuỗi ổn định trong scope hiện tại, không phải chữ ký hay capability độc lập.
 */
fn admission_fingerprint(admission: &WorkspaceAdmission) -> String {
    format!(
        "{}:{}:{}:{}:{}",
        admission.workspace_id,
        admission.user_id,
        admission.grant_generation,
        admission.workspace_authorization_version,
        admission.membership_authorization_version,
    )
}
