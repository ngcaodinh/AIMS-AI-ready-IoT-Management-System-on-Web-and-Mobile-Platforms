//! Adapter member: sorted User fences, parent workspace và scoped CAS; policy thuộc domain/application.

use crate::{PgUnitOfWork, storage_error};
use chrono::{DateTime, Utc};
use iot_application::{
    error::ApplicationError,
    membership::{LockedMembership, MembershipTransaction},
};
use iot_domain::{
    identity::SessionProof,
    membership::{MembershipSnapshot, MembershipStatus},
    workspace::WorkspaceRole,
};
use sqlx::Row;
use uuid::Uuid;

/**
 * Encode trạng thái từ enum hữu hạn, không nhận literal hoặc SQL fragment từ request.
 * Input
 * Param: status — trạng thái domain đã được transition policy kiểm.
 * Output: literal bind cho cột membership.status.
 */
pub(crate) fn status_value(status: MembershipStatus) -> &'static str {
    match status {
        MembershipStatus::Active => "ACTIVE",
        MembershipStatus::Suspended => "SUSPENDED",
        MembershipStatus::Removed => "REMOVED",
    }
}

impl MembershipTransaction for PgUnitOfWork {
    /**
     * Lấy cùng protocol User pair với invitation/reset trước parent Workspace.
     * Input
     * Param: proof — session hint cần current resolver kiểm lại.
     * Param: `target_id` — account thành viên đích, chưa tự cấp quyền truy cập.
     * Output: hoàn thành hoặc session/storage error, giữ fence đến cuối transaction.
     */
    async fn lock_member_subjects(
        &mut self,
        proof: &SessionProof,
        target_id: Uuid,
    ) -> Result<(), ApplicationError> {
        self.lock_session_subjects(proof, target_id).await
    }

    /**
     * Đọc member hiện hành và other capable Admin trong đúng tenant để bảo vệ last Admin.
     * Input
     * Param: `workspace_id` — parent đang được khóa và đã current Admin admission.
     * Param: `target_id` — User đã khóa trước parent để tránh write skew/cross-user deadlock.
     * Output: snapshot/email cho domain và HMAC fence; forbidden khi thiếu membership.
     */
    async fn lock_member(
        &mut self,
        workspace_id: Uuid,
        target_id: Uuid,
    ) -> Result<LockedMembership, ApplicationError> {
        // Parent fence serialize mọi member/global-account mutation ảnh hưởng Admin, không khóa User khác sau Workspace.
        let row=sqlx::query("SELECT membership.*,account.email_normalized,(account.account_status='ACTIVE' AND NOT account.must_change_password) AS account_capable,(SELECT count(*) FROM memberships other_member JOIN users other_account USING(user_id) WHERE other_member.workspace_id=$1 AND other_member.user_id<>$2 AND other_member.status='ACTIVE' AND other_member.role='ADMIN' AND other_account.account_status='ACTIVE' AND NOT other_account.must_change_password) AS other_admin_count FROM memberships membership JOIN users account USING(user_id) WHERE membership.workspace_id=$1 AND membership.user_id=$2 FOR UPDATE OF membership")
            .bind(workspace_id).bind(target_id).fetch_optional(&mut *self.transaction).await.map_err(storage_error)?.ok_or(ApplicationError::Forbidden)?;
        let role = match row
            .try_get::<String, _>("role")
            .map_err(storage_error)?
            .as_str()
        {
            "ADMIN" => WorkspaceRole::Admin,
            "USER" => WorkspaceRole::User,
            _ => return Err(ApplicationError::Unavailable),
        };
        let status = match row
            .try_get::<String, _>("status")
            .map_err(storage_error)?
            .as_str()
        {
            "ACTIVE" => MembershipStatus::Active,
            "SUSPENDED" => MembershipStatus::Suspended,
            "REMOVED" => MembershipStatus::Removed,
            _ => return Err(ApplicationError::Unavailable),
        };
        Ok(LockedMembership {
            snapshot: MembershipSnapshot {
                workspace_id,
                user_id: target_id,
                role,
                status,
                alias: row.try_get("alias").map_err(storage_error)?,
                revision: row.try_get("revision").map_err(storage_error)?,
                authorization_version: row
                    .try_get("authorization_version")
                    .map_err(storage_error)?,
                grant_generation: row
                    .try_get("current_grant_generation")
                    .map_err(storage_error)?,
                account_capable: row.try_get("account_capable").map_err(storage_error)?,
                other_capable_admin_count: row
                    .try_get("other_admin_count")
                    .map_err(storage_error)?,
            },
            email_normalized: row.try_get("email_normalized").map_err(storage_error)?,
        })
    }

    /// Trả clock mới bằng statement riêng sau khóa, không dùng transaction start cho session expiry.
    async fn membership_now(&mut self) -> Result<DateTime<Utc>, ApplicationError> {
        sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *self.transaction)
            .await
            .map_err(storage_error)
    }

    /**
     * Persist đúng composite scope bằng CAS; chỉ status REMOVED có removed instant.
     * Input
     * Param: before — snapshot/revision đã khóa, không dùng revision tự khai khác.
     * Param: after — transition domain đã kiểm last Admin và counter overflow.
     * Param: now — clock dùng chung scoped effects/audit admission.
     * Output: hoàn thành hoặc stale/storage error; native deferred last Admin kiểm lần nữa khi commit.
     */
    async fn save_member(
        &mut self,
        before: &MembershipSnapshot,
        after: &MembershipSnapshot,
        now: DateTime<Utc>,
    ) -> Result<(), ApplicationError> {
        // Các cột quyền bind từ enum/domain; User identity và current grant không thay qua PATCH.
        let changed=sqlx::query("UPDATE memberships SET role=$4,status=$5,alias=$6,revision=$7,authorization_version=$8,removed_at=CASE WHEN $5='REMOVED' THEN $9::timestamptz ELSE NULL END WHERE workspace_id=$1 AND user_id=$2 AND revision=$3")
            .bind(before.workspace_id).bind(before.user_id).bind(before.revision).bind(if after.role==WorkspaceRole::Admin {"ADMIN"} else {"USER"}).bind(status_value(after.status)).bind(&after.alias).bind(after.revision).bind(after.authorization_version).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?.rows_affected();
        if changed != 1 {
            return Err(ApplicationError::StaleRevision);
        }
        Ok(())
    }

    /**
     * Duy trì scoped capability/pending-work obligations trong cùng transaction với auth version mới.
     * Input
     * Param: before — tenant/user/grant identity trước transition.
     * Param: after — current status/role/version đã được persist bằng CAS.
     * Param: `email_digest` — HMAC target email để vô hiệu admission cũ khi mất membership.
     * Param: now — instant revocation/close intent, không gửi side effect ngoài DB.
     * Output: hoàn thành hoặc storage error; failure phải rollback cả member mutation.
     */
    async fn invalidate_member_authority(
        &mut self,
        before: &MembershipSnapshot,
        after: &MembershipSnapshot,
        email_digest: [u8; 32],
        now: DateTime<Utc>,
    ) -> Result<(), ApplicationError> {
        self.invalidate_workspace_member(before, after, email_digest, now)
            .await
    }
}
