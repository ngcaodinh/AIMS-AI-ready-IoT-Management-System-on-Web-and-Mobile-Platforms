//! SQL projection bootstrap; bind identity từ principal và không SELECT credential vào DTO.

use crate::{PgUnitOfWork, storage_error};
use iot_application::{
    auth_read::{AuthReadTransaction, Profile, WorkspaceDetail, WorkspacePage},
    error::ApplicationError,
};
use iot_domain::workspace::{WorkspaceRole, WorkspaceSummary};
use sqlx::Row;
use uuid::Uuid;

/** Decode role hữu hạn từ membership hiện hành; Input: value từ DB. Errors: dữ liệu enum không hợp lệ. */
fn role(value: &str) -> Result<WorkspaceRole, ApplicationError> {
    match value {
        "ADMIN" => Ok(WorkspaceRole::Admin),
        "USER" => Ok(WorkspaceRole::User),
        _ => Err(ApplicationError::Unavailable),
    }
}

impl AuthReadTransaction for PgUnitOfWork {
    /** Query chính chủ bound UUID; LEFT JOIN giữ UTC/1 cho account legacy thiếu preference. */
    async fn read_profile(&mut self, user_id: Uuid) -> Result<Profile, ApplicationError> {
        let row = sqlx::query("SELECT u.user_id,u.email_normalized,coalesce(p.display_timezone,'UTC') AS timezone,coalesce(p.revision,1) AS revision FROM users u LEFT JOIN user_preferences p USING(user_id) WHERE u.user_id=$1")
            .bind(user_id).fetch_one(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(Profile {
            user_id,
            email: row.try_get("email_normalized").map_err(storage_error)?,
            display_timezone: row.try_get("timezone").map_err(storage_error)?,
            preferences_revision: row.try_get("revision").map_err(storage_error)?,
        })
    }

    /** Clock engine sau mọi query để expiry không dựa timestamp đầu transaction. */
    async fn auth_read_now(&mut self) -> Result<chrono::DateTime<chrono::Utc>, ApplicationError> {
        sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *self.transaction)
            .await
            .map_err(storage_error)
    }

    /** Page/fingerprint từ cùng statement snapshot; UUID/limit bind, không nối SQL từ cursor. */
    async fn read_workspace_page(
        &mut self,
        user_id: Uuid,
        after: Option<Uuid>,
        limit: i64,
    ) -> Result<WorkspacePage, ApplicationError> {
        /* Fingerprint phát hiện thay đổi authority/revision kể cả row nằm ngoài page; MD5 ở đây chỉ là
         * checksum snapshot các counter/UUID do server quản lý, không phải chữ ký/capability.
         * HTTP phải HMAC cursor và recheck current fingerprint; LEFT JOIN còn một sentinel cho empty page. */
        let rows = sqlx::query("WITH scoped AS MATERIALIZED (SELECT w.workspace_id,w.name,w.revision,w.status AS workspace_status,w.authorization_version AS workspace_authz,m.role,m.status AS membership_status,m.authorization_version AS membership_authz,m.current_grant_generation,g.revoked_at FROM memberships m JOIN workspaces w USING(workspace_id) JOIN membership_grants g ON (g.workspace_id,g.user_id,g.grant_generation)=(m.workspace_id,m.user_id,m.current_grant_generation) WHERE m.user_id=$1), fingerprint AS (SELECT md5(coalesce(string_agg(concat_ws(':',workspace_id::text,revision::text,workspace_status,workspace_authz::text,role,membership_status,membership_authz::text,current_grant_generation::text,(revoked_at IS NULL)::text),',' ORDER BY workspace_id),'')) AS authority_fingerprint FROM scoped), page AS (SELECT workspace_id,name,revision,role FROM scoped WHERE workspace_status='ACTIVE' AND membership_status='ACTIVE' AND revoked_at IS NULL AND ($2::uuid IS NULL OR workspace_id>$2) ORDER BY workspace_id LIMIT $3) SELECT f.authority_fingerprint,p.workspace_id,p.name,p.revision,p.role FROM fingerprint f LEFT JOIN page p ON true ORDER BY p.workspace_id")
            .bind(user_id).bind(after).bind(limit).fetch_all(&mut *self.transaction).await.map_err(storage_error)?;
        let first = rows.first().ok_or(ApplicationError::Unavailable)?;
        let mut page = WorkspacePage {
            authority_fingerprint: first
                .try_get("authority_fingerprint")
                .map_err(storage_error)?,
            items: Vec::new(),
        };
        for row in rows {
            if let Some(workspace_id) = row
                .try_get::<Option<Uuid>, _>("workspace_id")
                .map_err(storage_error)?
            {
                page.items.push(WorkspaceSummary {
                    workspace_id,
                    name: row.try_get("name").map_err(storage_error)?,
                    revision: row.try_get("revision").map_err(storage_error)?,
                    role: role(&row.try_get::<String, _>("role").map_err(storage_error)?)?,
                });
            }
        }
        Ok(page)
    }

    /** Projection detail sau parent/member locks; cả workspace/user đều bind để không đọc tenant khác. */
    async fn read_workspace_detail(
        &mut self,
        workspace_id: Uuid,
        user_id: Uuid,
    ) -> Result<WorkspaceDetail, ApplicationError> {
        let row = sqlx::query("SELECT w.name,w.description,w.default_timezone,w.revision,w.created_by_user_id,w.authorization_version,w.created_at,w.archived_at,m.role,m.revision AS membership_revision,m.authorization_version AS membership_authz FROM workspaces w JOIN memberships m USING(workspace_id) WHERE w.workspace_id=$1 AND m.user_id=$2")
            .bind(workspace_id).bind(user_id).fetch_one(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(WorkspaceDetail {
            summary: WorkspaceSummary {
                workspace_id,
                name: row.try_get("name").map_err(storage_error)?,
                revision: row.try_get("revision").map_err(storage_error)?,
                role: role(&row.try_get::<String, _>("role").map_err(storage_error)?)?,
            },
            description: row.try_get("description").map_err(storage_error)?,
            default_timezone: row.try_get("default_timezone").map_err(storage_error)?,
            creator_id: row.try_get("created_by_user_id").map_err(storage_error)?,
            authorization_version: row
                .try_get("authorization_version")
                .map_err(storage_error)?,
            membership_revision: row.try_get("membership_revision").map_err(storage_error)?,
            membership_authorization_version: row
                .try_get("membership_authz")
                .map_err(storage_error)?,
            created_at: row.try_get("created_at").map_err(storage_error)?,
            archived_at: row.try_get("archived_at").map_err(storage_error)?,
        })
    }
}
