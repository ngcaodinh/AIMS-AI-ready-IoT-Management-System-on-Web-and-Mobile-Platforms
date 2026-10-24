//! SQL lời mời: hint không cấp quyền; User fences được lấy trước parent workspace.

use crate::{PgUnitOfWork, storage_error};
use chrono::{DateTime, Utc};
use iot_application::{
    error::ApplicationError,
    invitation_ports::{
        InvitationClaim, InvitationReceipt, InvitationReceiptScope, InvitationTransaction,
        LockedInvitation,
    },
};
use iot_domain::{
    identity::SessionProof,
    invitation::{InvitationIssuer, InvitationSnapshot},
    workspace::WorkspaceRole,
};
use sqlx::{Row, postgres::PgRow};
use uuid::Uuid;

/**
 * Decode snapshot persisted bằng projection xác định, không đưa token digest ra transport.
 * Input
 * Param: row — hàng invitation trong workspace đã khóa.
 * Output: snapshot thuần; literal role lạ gây unavailable, không tự nâng quyền.
 */
fn snapshot(row: &PgRow) -> Result<InvitationSnapshot, ApplicationError> {
    let role = match row
        .try_get::<String, _>("role")
        .map_err(storage_error)?
        .as_str()
    {
        "ADMIN" => WorkspaceRole::Admin,
        "USER" => WorkspaceRole::User,
        _ => return Err(ApplicationError::Unavailable),
    };
    Ok(InvitationSnapshot {
        workspace_id: row.try_get("workspace_id").map_err(storage_error)?,
        invitation_id: row.try_get("invitation_id").map_err(storage_error)?,
        email_normalized: row.try_get("email_normalized").map_err(storage_error)?,
        role,
        issuer_user_id: row.try_get("issued_by_user_id").map_err(storage_error)?,
        issuer_grant_generation: row
            .try_get("issuer_grant_generation")
            .map_err(storage_error)?,
        issuer_authorization_version: row
            .try_get("issuer_authorization_version")
            .map_err(storage_error)?,
        admission_generation: row.try_get("admission_generation").map_err(storage_error)?,
        issued_at: row.try_get("issued_at").map_err(storage_error)?,
        expires_at: row.try_get("expires_at").map_err(storage_error)?,
        terminal: row
            .try_get::<Option<DateTime<Utc>>, _>("used_at")
            .map_err(storage_error)?
            .is_some()
            || row
                .try_get::<Option<DateTime<Utc>>, _>("revoked_at")
                .map_err(storage_error)?
                .is_some()
            || row
                .try_get::<Option<DateTime<Utc>>, _>("expired_at")
                .map_err(storage_error)?
                .is_some(),
    })
}

impl InvitationTransaction for PgUnitOfWork {
    /**
     * Tra identity hint bất biến để chọn khóa; kết quả chưa cấp authority.
     * Input
     * Param: digest — SHA-256 capability dùng lookup bằng tham số bind.
     * Output: workspace/issuer hoặc None; caller phải đọc lại sau khóa.
     */
    async fn invitation_hint(
        &mut self,
        digest: [u8; 32],
    ) -> Result<Option<(Uuid, Uuid)>, ApplicationError> {
        sqlx::query_as("SELECT workspace_id,issued_by_user_id FROM workspace_invitations WHERE token_digest=$1")
            .bind(digest.as_slice()).fetch_optional(&mut *self.transaction).await.map_err(storage_error)
    }

    /**
     * Khóa hai User theo UUID tăng dần để accept chéo không đảo thứ tự khóa.
     * Input
     * Param: proof — digest session chỉ dùng resolve account hint, chưa cấp quyền.
     * Param: `issuer_id` — issuer identity bất biến lấy từ invitation hint.
     * Output: hoàn thành hoặc session/storage error; khóa giữ đến cuối transaction.
     */
    async fn lock_invitation_users(
        &mut self,
        proof: &SessionProof,
        issuer_id: Uuid,
    ) -> Result<(), ApplicationError> {
        self.lock_session_subjects(proof, issuer_id).await
    }

    /// Statement riêng sau khóa trả clock admission mới, không dùng snapshot thời điểm BEGIN.
    async fn invitation_now(&mut self) -> Result<DateTime<Utc>, ApplicationError> {
        sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *self.transaction)
            .await
            .map_err(storage_error)
    }

    /**
     * Reserve đúng namespace receipt trong cùng transaction, không lưu capability.
     * Input
     * Param: scope — enum route create scoped hoặc accept global do application chọn.
     * Param: `actor_id` — principal đã xác thực, sở hữu receipt.
     * Param: `key_digest` — fingerprint key, không phải raw key.
     * Param: `request_digest` — fingerprint body để phát hiện khác intent.
     * Param: now — clock admission lấy sau khóa.
     * Output: reserved hoặc receipt hiện hành; lỗi shape/storage fail closed.
     */
    async fn reserve_invitation_receipt(
        &mut self,
        scope: InvitationReceiptScope,
        actor_id: Uuid,
        key_digest: [u8; 32],
        request_digest: [u8; 32],
        now: DateTime<Utc>,
    ) -> Result<InvitationClaim, ApplicationError> {
        self.reserve_invitation(scope, actor_id, key_digest, request_digest, now)
            .await
    }

    /**
     * Chốt receipt allowlist cùng commit với mutation/audit để retry không tạo grant trùng.
     * Input
     * Param: scope — namespace khớp bước reserve.
     * Param: `actor_id` — principal sở hữu receipt.
     * Param: `key_digest` — digest cùng key đã reserve.
     * Param: result — workspace/invitation/generation không chứa token hoặc email.
     * Output: hoàn thành hoặc conflict/storage error; chưa commit riêng.
     */
    async fn complete_invitation_receipt(
        &mut self,
        scope: InvitationReceiptScope,
        actor_id: Uuid,
        key_digest: [u8; 32],
        result: &InvitationReceipt,
    ) -> Result<(), ApplicationError> {
        self.complete_invitation(scope, actor_id, key_digest, result)
            .await
    }

    /**
     * Đọc metadata replay sau current Admin admission bằng composite scope.
     * Input
     * Param: `workspace_id` — tenant đã kiểm quyền trong transaction.
     * Param: `invitation_id` — identity receipt đã hoàn thành, không là quyền truy cập.
     * Output: snapshot không raw token hoặc unavailable/storage error.
     */
    async fn invitation_metadata(
        &mut self,
        workspace_id: Uuid,
        invitation_id: Uuid,
    ) -> Result<InvitationSnapshot, ApplicationError> {
        let row = sqlx::query(
            "SELECT * FROM workspace_invitations WHERE workspace_id=$1 AND invitation_id=$2",
        )
        .bind(workspace_id)
        .bind(invitation_id)
        .fetch_optional(&mut *self.transaction)
        .await
        .map_err(storage_error)?
        .ok_or(ApplicationError::InvitationUnavailable)?;
        snapshot(&row)
    }

    /**
     * Chốt email fence và expire pending cũ để lời mời hết hạn không chiếm unique key mãi.
     * Input
     * Param: `workspace_id` — tenant đang giữ parent fence.
     * Param: email — email chuẩn hóa để kiểm membership chưa REMOVED.
     * Param: `email_digest` — HMAC email dùng identity admission fence.
     * Param: now — clock sau parent lock để quyết định expiry.
     * Output: current admission generation; conflict khi membership còn tồn tại hoặc lỗi storage.
     */
    async fn prepare_invitation(
        &mut self,
        workspace_id: Uuid,
        email: &str,
        email_digest: [u8; 32],
        now: DateTime<Utc>,
    ) -> Result<i64, ApplicationError> {
        // Workspace fence đã giữ nên membership mutation cùng tenant không thể chen vào check/insert.
        let exists:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM memberships membership JOIN users account USING(user_id) WHERE membership.workspace_id=$1 AND account.email_normalized=$2 AND membership.status<>'REMOVED')")
            .bind(workspace_id).bind(email).fetch_one(&mut *self.transaction).await.map_err(storage_error)?;
        if exists {
            return Err(ApplicationError::Conflict);
        }
        sqlx::query("INSERT INTO membership_admission_fences(workspace_id,email_digest,admission_generation) VALUES($1,$2,1) ON CONFLICT DO NOTHING")
            .bind(workspace_id).bind(email_digest.as_slice()).execute(&mut *self.transaction).await.map_err(storage_error)?;
        let generation=sqlx::query_scalar("SELECT admission_generation FROM membership_admission_fences WHERE workspace_id=$1 AND email_digest=$2 FOR UPDATE")
            .bind(workspace_id).bind(email_digest.as_slice()).fetch_one(&mut *self.transaction).await.map_err(storage_error)?;
        // Pending partial unique không có now(); expiry được materialize dưới cùng email fence.
        sqlx::query("UPDATE workspace_invitations SET expired_at=$3 WHERE workspace_id=$1 AND email_digest=$2 AND used_at IS NULL AND revoked_at IS NULL AND expired_at IS NULL AND expires_at<=$3")
            .bind(workspace_id).bind(email_digest.as_slice()).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(generation)
    }

    /**
     * Lưu snapshot đã admit; unique pending và FK kiểm lại invariant tại engine.
     * Input
     * Param: invitation — identity/email/role/issuer/fence/TTL do application tạo.
     * Param: `email_digest` — HMAC khớp fence đã khóa.
     * Param: `token_digest` — SHA-256 capability; raw token không vào storage.
     * Output: hoàn thành trong transaction hoặc conflict/storage error, không tự commit.
     */
    async fn insert_invitation(
        &mut self,
        invitation: &InvitationSnapshot,
        email_digest: [u8; 32],
        token_digest: [u8; 32],
    ) -> Result<(), ApplicationError> {
        // Raw token không vào adapter; mọi giá trị đều bind, role encode từ enum hữu hạn.
        sqlx::query("INSERT INTO workspace_invitations(workspace_id,invitation_id,token_digest,email_normalized,email_digest,role,issued_by_user_id,issuer_grant_generation,issuer_authorization_version,admission_generation,issued_at,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)")
            .bind(invitation.workspace_id).bind(invitation.invitation_id).bind(token_digest.as_slice()).bind(&invitation.email_normalized).bind(email_digest.as_slice()).bind(if invitation.role==WorkspaceRole::Admin {"ADMIN"} else {"USER"}).bind(invitation.issuer_user_id).bind(invitation.issuer_grant_generation).bind(invitation.issuer_authorization_version).bind(invitation.admission_generation).bind(invitation.issued_at).bind(invitation.expires_at).execute(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(())
    }

    /**
     * Khóa context sau User fences và đọc clock cuối để lock wait không kéo dài capability.
     * Input
     * Param: digest — capability fingerprint cần đọc lại trong đúng workspace.
     * Param: `recipient_id` — account đã khóa để lấy email đăng nhập hiện hành.
     * Output: snapshot/fence/issuer/email/clock cho domain; forbidden/unavailable/storage error.
     */
    async fn lock_invitation(
        &mut self,
        digest: [u8; 32],
        recipient_id: Uuid,
    ) -> Result<LockedInvitation, ApplicationError> {
        let hint=sqlx::query("SELECT workspace_id,issued_by_user_id,email_digest FROM workspace_invitations WHERE token_digest=$1")
            .bind(digest.as_slice()).fetch_optional(&mut *self.transaction).await.map_err(storage_error)?.ok_or(ApplicationError::InvitationUnavailable)?;
        let workspace_id: Uuid = hint.try_get("workspace_id").map_err(storage_error)?;
        let issuer_id: Uuid = hint.try_get("issued_by_user_id").map_err(storage_error)?;
        let email_digest: Vec<u8> = hint.try_get("email_digest").map_err(storage_error)?;
        let workspace_status: String =
            sqlx::query_scalar("SELECT status FROM workspaces WHERE workspace_id=$1 FOR UPDATE")
                .bind(workspace_id)
                .fetch_one(&mut *self.transaction)
                .await
                .map_err(storage_error)?;
        if workspace_status != "ACTIVE" {
            return Err(ApplicationError::Forbidden);
        }
        // Composite JOIN chỉ quyền issuer trong đúng tenant/current grant; account đã khóa từ bước participants.
        let issuer=sqlx::query("SELECT membership.current_grant_generation,membership.authorization_version,(account.account_status='ACTIVE' AND NOT account.must_change_password AND membership.status='ACTIVE' AND membership.role='ADMIN' AND grant_row.revoked_at IS NULL) AS capable FROM memberships membership JOIN users account USING(user_id) JOIN membership_grants grant_row ON (grant_row.workspace_id,grant_row.user_id,grant_row.grant_generation)=(membership.workspace_id,membership.user_id,membership.current_grant_generation) WHERE membership.workspace_id=$1 AND membership.user_id=$2 FOR SHARE OF membership,grant_row")
            .bind(workspace_id).bind(issuer_id).fetch_optional(&mut *self.transaction).await.map_err(storage_error)?.ok_or(ApplicationError::InvitationUnavailable)?;
        let generation=sqlx::query_scalar("SELECT admission_generation FROM membership_admission_fences WHERE workspace_id=$1 AND email_digest=$2 FOR UPDATE")
            .bind(workspace_id).bind(email_digest).fetch_one(&mut *self.transaction).await.map_err(storage_error)?;
        let row=sqlx::query("SELECT * FROM workspace_invitations WHERE workspace_id=$1 AND token_digest=$2 FOR UPDATE")
            .bind(workspace_id).bind(digest.as_slice()).fetch_one(&mut *self.transaction).await.map_err(storage_error)?;
        let email = sqlx::query_scalar("SELECT email_normalized FROM users WHERE user_id=$1")
            .bind(recipient_id)
            .fetch_one(&mut *self.transaction)
            .await
            .map_err(storage_error)?;
        let observed_at = self.invitation_now().await?;
        Ok(LockedInvitation {
            snapshot: snapshot(&row)?,
            issuer: InvitationIssuer {
                user_id: issuer_id,
                capable_admin: issuer.try_get("capable").map_err(storage_error)?,
                grant_generation: issuer
                    .try_get("current_grant_generation")
                    .map_err(storage_error)?,
                authorization_version: issuer
                    .try_get("authorization_version")
                    .map_err(storage_error)?,
            },
            admission_generation: generation,
            recipient_email: email,
            observed_at,
        })
    }

    /**
     * CAS consume và tạo grant mới atomically; không dùng invitation để resume SUSPENDED.
     * Input
     * Param: invitation — snapshot đã được domain admit trong cùng transaction.
     * Param: `recipient_id` — principal đúng email, không lấy từ body request.
     * Param: now — clock sau khóa để kiểm hạn và gắn used/grant instant.
     * Output: generation mới hoặc conflict/unavailable/storage error; mọi thay đổi rollback nếu audit fail.
     */
    async fn consume_invitation(
        &mut self,
        invitation: &InvitationSnapshot,
        recipient_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<i64, ApplicationError> {
        let workspace_id = invitation.workspace_id;
        let membership=sqlx::query("SELECT status,current_grant_generation FROM memberships WHERE workspace_id=$1 AND user_id=$2 FOR UPDATE")
            .bind(workspace_id).bind(recipient_id).fetch_optional(&mut *self.transaction).await.map_err(storage_error)?;
        let generation = if let Some(row) = membership {
            if row.try_get::<String, _>("status").map_err(storage_error)? != "REMOVED" {
                return Err(ApplicationError::Conflict);
            }
            row.try_get::<i64, _>("current_grant_generation")
                .map_err(storage_error)?
                .checked_add(1)
                .ok_or(ApplicationError::Unavailable)?
        } else {
            1
        };
        let changed=sqlx::query("UPDATE workspace_invitations SET used_at=$3 WHERE workspace_id=$1 AND invitation_id=$2 AND used_at IS NULL AND revoked_at IS NULL AND expired_at IS NULL AND issued_at<=$3 AND expires_at>$3")
            .bind(workspace_id).bind(invitation.invitation_id).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?.rows_affected();
        if changed != 1 {
            return Err(ApplicationError::InvitationUnavailable);
        }
        // Deferred current-grant FK cho phép pointer và grant mới cùng transaction; grant cũ không bị un-revoke.
        sqlx::query("INSERT INTO memberships(workspace_id,user_id,role,status,current_grant_generation,joined_at) VALUES($1,$2,$3,'ACTIVE',$4,$5) ON CONFLICT(workspace_id,user_id) DO UPDATE SET role=EXCLUDED.role,status='ACTIVE',current_grant_generation=EXCLUDED.current_grant_generation,joined_at=EXCLUDED.joined_at,removed_at=NULL,revision=memberships.revision+1,authorization_version=memberships.authorization_version+1")
            .bind(workspace_id).bind(recipient_id).bind(if invitation.role==WorkspaceRole::Admin {"ADMIN"} else {"USER"}).bind(generation).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        sqlx::query("INSERT INTO membership_grants(workspace_id,user_id,grant_generation,issued_at) VALUES($1,$2,$3,$4)")
            .bind(workspace_id).bind(recipient_id).bind(generation).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(generation)
    }
}
