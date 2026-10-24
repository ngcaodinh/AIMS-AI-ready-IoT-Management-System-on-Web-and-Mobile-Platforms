//! PostgreSQL reset tạm: giữ target User fence qua protection/quota/PHC/revocation/audit commit.

use crate::{PgUnitOfWork, storage_error};
use chrono::{DateTime, Utc};
use iot_application::{error::ApplicationError, password_reset::PasswordResetTransaction};
use iot_domain::{
    identity::{AccountStatus, SecretString, SessionProof},
    password_reset::{PasswordResetTarget, TEMPORARY_ACCOUNT_ORIGIN},
};
use sqlx::Row;
use uuid::Uuid;

impl PasswordResetTransaction for PgUnitOfWork {
    /**
     * Dùng chung protocol User pair để reset đối xứng không đảo khóa với invitation/member mutation.
     * Input
     * Param: proof — session identity hint, chưa thay current authorization.
     * Param: `target_id` — account cần bảo vệ trước mọi credential mutation.
     * Output: hoàn thành hoặc session/storage error, giữ khóa tới commit/rollback.
     */
    async fn lock_reset_subjects(
        &mut self,
        proof: &SessionProof,
        target_id: Uuid,
    ) -> Result<(), ApplicationError> {
        self.lock_session_subjects(proof, target_id).await
    }

    /**
     * Đọc current target và mọi membership scope để legacy/multi-workspace không bị reset bởi tenant Admin.
     * Input
     * Param: `workspace_id` — tenant đã khóa và admit Admin.
     * Param: `target_id` — User đã lấy fence trước Workspace.
     * Output: snapshot không PHC; forbidden nếu thiếu target, storage error được lọc.
     */
    async fn password_reset_target(
        &mut self,
        workspace_id: Uuid,
        target_id: Uuid,
    ) -> Result<PasswordResetTarget, ApplicationError> {
        // User fence serialize cả INSERT membership (trigger); tính cả membership lịch sử ở tenant khác.
        let account=sqlx::query("SELECT user_id,account_status,must_change_password,activated_at,activation_provenance=$3 AS known_origin,CASE WHEN NOT EXISTS(SELECT 1 FROM memberships other_membership WHERE other_membership.user_id=$1 AND other_membership.workspace_id<>$2) THEN $2::uuid ELSE NULL END AS only_workspace_id FROM users WHERE user_id=$1")
            .bind(target_id).bind(workspace_id).bind(TEMPORARY_ACCOUNT_ORIGIN).fetch_optional(&mut *self.transaction).await.map_err(storage_error)?.ok_or(ApplicationError::Forbidden)?;
        let membership=sqlx::query("SELECT status,revision FROM memberships WHERE workspace_id=$1 AND user_id=$2 FOR UPDATE")
            .bind(workspace_id).bind(target_id).fetch_optional(&mut *self.transaction).await.map_err(storage_error)?;
        let (membership_present, membership_revision) = match membership {
            Some(row) => (
                row.try_get::<String, _>("status").map_err(storage_error)? != "REMOVED",
                row.try_get("revision").map_err(storage_error)?,
            ),
            None => (false, 0),
        };
        Ok(PasswordResetTarget {
            user_id: account.try_get("user_id").map_err(storage_error)?,
            account_status: match account
                .try_get::<String, _>("account_status")
                .map_err(storage_error)?
                .as_str()
            {
                "ACTIVE" => AccountStatus::Active,
                "DISABLED" => AccountStatus::Disabled,
                _ => return Err(ApplicationError::Unavailable),
            },
            must_change_password: account
                .try_get("must_change_password")
                .map_err(storage_error)?,
            activated_at: account.try_get("activated_at").map_err(storage_error)?,
            known_temporary_origin: account.try_get("known_origin").map_err(storage_error)?,
            only_workspace_id: account
                .try_get("only_workspace_id")
                .map_err(storage_error)?,
            membership_present,
            membership_revision,
        })
    }

    /// Trả clock bằng statement riêng sau khóa để expiry/quota không dựa thời điểm BEGIN cũ.
    async fn password_reset_now(&mut self) -> Result<DateTime<Utc>, ApplicationError> {
        sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *self.transaction)
            .await
            .map_err(storage_error)
    }

    /**
     * Đọc admissions đúng bộ khóa của quota5/15 phút, không gom reset của người khác hoặc tenant khác.
     * Input
     * Param: `workspace_id` — scope admission.
     * Param: `actor_id` — Admin hiện hành chịu budget.
     * Param: `target_id` — account tạm được reset trong budget này.
     * Param: now — clock sau User/Workspace fence, cửa sổ trái exclusive.
     * Output: tối đa5 instant để domain xét admission/retry-after; lỗi storage được lọc.
     */
    async fn recent_password_resets(
        &mut self,
        workspace_id: Uuid,
        actor_id: Uuid,
        target_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<Vec<DateTime<Utc>>, ApplicationError> {
        // Index W/actor/target/time khớp predicate; limit5 đủ quyết định vì policy không admit lần6.
        sqlx::query_scalar("SELECT admitted_at FROM password_reset_admissions WHERE workspace_id=$1 AND actor_user_id=$2 AND target_user_id=$3 AND admitted_at>$4-interval '15 minutes' ORDER BY admitted_at LIMIT 5")
            .bind(workspace_id).bind(actor_id).bind(target_id).bind(now).fetch_all(&mut *self.transaction).await.map_err(storage_error)
    }

    /**
     * Thay PHC và tăng membership revision cùng transaction, không ghi activation hoặc nâng full session.
     * Input
     * Param: `workspace_id` — tenant scope của membership đã kiểm.
     * Param: `target_id` — account tạm đủ domain protection.
     * Param: `expected_revision` — revision đọc từ If-Match, không tự retry CAS cũ.
     * Param: verifier — PHC đã hash ở crypto port; không nhận raw password.
     * Output: revision mới hoặc stale/storage error; chưa commit và phải có required audit tiếp theo.
     */
    async fn replace_temporary_password(
        &mut self,
        workspace_id: Uuid,
        target_id: Uuid,
        expected_revision: i64,
        verifier: &SecretString,
    ) -> Result<i64, ApplicationError> {
        // Trigger membership lấy lại cùng User/Workspace đã giữ, không phát sinh thứ tự khóa mới.
        let revision=sqlx::query_scalar("UPDATE memberships SET revision=revision+1 WHERE workspace_id=$1 AND user_id=$2 AND revision=$3 AND status<>'REMOVED' RETURNING revision")
            .bind(workspace_id).bind(target_id).bind(expected_revision).fetch_optional(&mut *self.transaction).await.map_err(storage_error)?.ok_or(ApplicationError::StaleRevision)?;
        sqlx::query("UPDATE users SET password_hash=$2,must_change_password=true WHERE user_id=$1")
            .bind(target_id)
            .bind(verifier.expose())
            .execute(&mut *self.transaction)
            .await
            .map_err(storage_error)?;
        Ok(revision)
    }

    /**
     * Ghi admission thành công cùng credential/audit để rollback không tiêu tốn quota hoặc giữ nửa reset.
     * Input
     * Param: `workspace_id` — tenant của Admin và target membership.
     * Param: `actor_id` — Admin đã authorize server-side.
     * Param: `target_id` — account tạm đã thay PHC trong transaction này.
     * Param: now — instant admission dùng cùng revision/password/revocation.
     * Output: hoàn thành trong transaction hoặc storage error; không có password trong ledger.
     */
    async fn record_password_reset(
        &mut self,
        workspace_id: Uuid,
        actor_id: Uuid,
        target_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<(), ApplicationError> {
        sqlx::query("INSERT INTO password_reset_admissions(admission_id,workspace_id,actor_user_id,target_user_id,admitted_at) VALUES($1,$2,$3,$4,$5)")
            .bind(Uuid::new_v4()).bind(workspace_id).bind(actor_id).bind(target_id).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(())
    }
}
