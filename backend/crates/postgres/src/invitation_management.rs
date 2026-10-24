//! Metadata/read/revoke SQL scoped sau current Admin fence; không select token/email digest vào projection.

use crate::{PgUnitOfWork, storage_error};
use chrono::{DateTime, Utc};
use iot_application::{
    error::ApplicationError, invitation_management::InvitationManagementTransaction,
};
use iot_domain::{
    invitation_management::{InvitationCursor, InvitationMetadata, InvitationStatus},
    workspace::WorkspaceRole,
};
use sqlx::{Row, postgres::PgRow};
use uuid::Uuid;

/**
 * Decode projection metadata hữu hạn, tách khỏi internal issuer/capability snapshot.
 * Input
 * Param: row — các cột allowlist từ tenant đã current-authorize, không raw token/digest.
 * Output: metadata thuần; Errors: storage/unknown role fail closed.
 */
fn metadata(row: &PgRow) -> Result<InvitationMetadata, ApplicationError> {
    let role = match row
        .try_get::<String, _>("role")
        .map_err(storage_error)?
        .as_str()
    {
        "ADMIN" => WorkspaceRole::Admin,
        "USER" => WorkspaceRole::User,
        _ => return Err(ApplicationError::Unavailable),
    };
    Ok(InvitationMetadata {
        workspace_id: row.try_get("workspace_id").map_err(storage_error)?,
        invitation_id: row.try_get("invitation_id").map_err(storage_error)?,
        email_normalized: row.try_get("email_normalized").map_err(storage_error)?,
        role,
        issued_at: row.try_get("issued_at").map_err(storage_error)?,
        expires_at: row.try_get("expires_at").map_err(storage_error)?,
        used_at: row.try_get("used_at").map_err(storage_error)?,
        revoked_at: row.try_get("revoked_at").map_err(storage_error)?,
        expired_at: row.try_get("expired_at").map_err(storage_error)?,
        revision: row.try_get("revision").map_err(storage_error)?,
    })
}

impl InvitationManagementTransaction for PgUnitOfWork {
    /**
     * Đọc bounded page tenant bằng index workspace/issued/id, status tính với cùng clock của request.
     * Input
     * Param: `workspace_id` — current Admin tenant từ application, không scope từ body tùy ý.
     * Param: status — filter enum hữu hạn; deadline expiry không chờ cron UPDATE.
     * Param: cursor — tuple continuation nội bộ, mọi giá trị được bind.
     * Param: limit — application đã bound1…101 gồm overfetch, không SQL interpolation.
     * Param: now — DB clock sau User/Workspace locks để trạng thái nhất quán trong trang.
     * Output: metadata rows không capability hoặc digest; Errors: storage đã lọc.
     */
    async fn list_invitation_metadata(
        &mut self,
        workspace_id: Uuid,
        status: Option<InvitationStatus>,
        cursor: Option<&InvitationCursor>,
        limit: i64,
        now: DateTime<Utc>,
    ) -> Result<Vec<InvitationMetadata>, ApplicationError> {
        let status = status.map(|value| match value {
            InvitationStatus::Pending => "PENDING",
            InvitationStatus::Used => "USED",
            InvitationStatus::Revoked => "REVOKED",
            InvitationStatus::Expired => "EXPIRED",
        });
        // Tenant/filter/keyset/limit/clock đều bind; CASE ưu tiên terminal truth trước expiry theo clock.
        sqlx::query("SELECT workspace_id,invitation_id,email_normalized,role,issued_at,expires_at,used_at,revoked_at,expired_at,revision FROM workspace_invitations WHERE workspace_id=$1 AND ($2::timestamptz IS NULL OR (issued_at,invitation_id)<($2,$3::uuid)) AND ($4::text IS NULL OR CASE WHEN used_at IS NOT NULL THEN 'USED' WHEN revoked_at IS NOT NULL THEN 'REVOKED' WHEN expired_at IS NOT NULL OR expires_at<=$5 THEN 'EXPIRED' ELSE 'PENDING' END=$4) ORDER BY issued_at DESC,invitation_id DESC LIMIT $6")
            .bind(workspace_id).bind(cursor.map(|value|value.issued_at)).bind(cursor.map(|value|value.invitation_id)).bind(status).bind(now).bind(limit).fetch_all(&mut *self.transaction).await.map_err(storage_error)?.iter().map(metadata).collect()
    }

    /**
     * Khóa một invitation trong đúng tenant; foreign ID không được lookup global hay trả token digest.
     * Input
     * Param: `workspace_id` — tenant đã khóa/current Admin authorize.
     * Param: `invitation_id` — identity metadata do caller chọn trong tenant đó.
     * Output: row metadata hoặc unavailable; caller phải lấy clock/authorize expiry sau lock wait.
     */
    async fn lock_invitation_metadata(
        &mut self,
        workspace_id: Uuid,
        invitation_id: Uuid,
    ) -> Result<InvitationMetadata, ApplicationError> {
        // Workspace fence serialize accept/create/member effects; row lock cũng bảo vệ CAS với native writer.
        let row=sqlx::query("SELECT workspace_id,invitation_id,email_normalized,role,issued_at,expires_at,used_at,revoked_at,expired_at,revision FROM workspace_invitations WHERE workspace_id=$1 AND invitation_id=$2 FOR UPDATE").bind(workspace_id).bind(invitation_id).fetch_optional(&mut *self.transaction).await.map_err(storage_error)?.ok_or(ApplicationError::InvitationUnavailable)?;
        metadata(&row)
    }

    /**
     * CAS revoke pending còn hạn; native trigger tự tăng revision, không cho application tự ghi version.
     * Input
     * Param: `workspace_id` — tenant đã khóa và current-authorize.
     * Param: `invitation_id` — row đã đọc dưới lock, không raw capability.
     * Param: `expected_revision` — version snapshot trước mutation.
     * Param: now — DB admission clock sau row lock và session recheck.
     * Output: revision engine xác nhận; Errors: stale/terminal hoặc storage, required audit còn cùng transaction.
     */
    async fn revoke_invitation_row(
        &mut self,
        workspace_id: Uuid,
        invitation_id: Uuid,
        expected_revision: i64,
        now: DateTime<Utc>,
    ) -> Result<i64, ApplicationError> {
        // Predicate bảo vệ lại scope/revision/lifetime ngay tại UPDATE, mọi value đều bind.
        sqlx::query_scalar("UPDATE workspace_invitations SET revoked_at=$4 WHERE workspace_id=$1 AND invitation_id=$2 AND revision=$3 AND used_at IS NULL AND revoked_at IS NULL AND expired_at IS NULL AND issued_at<=$4 AND expires_at>$4 RETURNING revision").bind(workspace_id).bind(invitation_id).bind(expected_revision).bind(now).fetch_optional(&mut *self.transaction).await.map_err(storage_error)?.ok_or(ApplicationError::StaleRevision)
    }
}
