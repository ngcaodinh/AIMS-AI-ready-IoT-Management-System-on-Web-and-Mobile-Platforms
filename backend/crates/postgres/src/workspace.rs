//! SQL tenant: scoped keys, lock order và atomic persistence; policy nằm ở domain/application.

use crate::{PgUnitOfWork, storage_error};
use iot_application::{error::ApplicationError, ports::WorkspaceTransaction};
use iot_domain::workspace::{WorkspaceDraft, WorkspaceRole, WorkspaceSnapshot, WorkspaceSummary};
use sqlx::Row;
use uuid::Uuid;

/**
 * Decode role hữu hạn, không tự suy ADMIN khi gặp dữ liệu storage không nhận diện.
 * Input
 * Param: value — literal role lấy từ membership đã scope.
 * Output: enum domain hoặc unavailable nếu schema/data không khớp.
 */
fn parse_role(value: &str) -> Result<WorkspaceRole, ApplicationError> {
    match value {
        "ADMIN" => Ok(WorkspaceRole::Admin),
        "USER" => Ok(WorkspaceRole::User),
        _ => Err(ApplicationError::Unavailable),
    }
}

impl WorkspaceTransaction for PgUnitOfWork {
    /// Bind timezone để kiểm catalog engine, không ghép input thành SET hoặc SQL fragment.
    async fn timezone_exists(&mut self, timezone: &str) -> Result<bool, ApplicationError> {
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_timezone_names WHERE name=$1)")
            .bind(timezone)
            .fetch_one(&mut *self.transaction)
            .await
            .map_err(storage_error)
    }

    /// Persist aggregate và grant1 trong cùng transaction; deferred FK/admin check chạy trước commit.
    async fn insert_workspace(
        &mut self,
        workspace_id: Uuid,
        creator_id: Uuid,
        draft: &WorkspaceDraft,
    ) -> Result<(), ApplicationError> {
        // User đã khóa tại session admission; trigger serialize creator quota5 và chặn direct SQL sai.
        sqlx::query("INSERT INTO workspaces(workspace_id,name,description,default_timezone,created_by_user_id) VALUES($1,$2,$3,$4,$5)")
            .bind(workspace_id).bind(&draft.name).bind(&draft.description).bind(&draft.timezone).bind(creator_id)
            .execute(&mut *self.transaction).await.map_err(storage_error)?;
        sqlx::query("INSERT INTO memberships(workspace_id,user_id,role,current_grant_generation) VALUES($1,$2,'ADMIN',1)")
            .bind(workspace_id).bind(creator_id).execute(&mut *self.transaction).await.map_err(storage_error)?;
        sqlx::query(
            "INSERT INTO membership_grants(workspace_id,user_id,grant_generation) VALUES($1,$2,1)",
        )
        .bind(workspace_id)
        .bind(creator_id)
        .execute(&mut *self.transaction)
        .await
        .map_err(storage_error)?;
        Ok(())
    }

    /// Query keyset bind đủ user/current generation; chỉ trả membership và workspace đang ACTIVE.
    async fn list_workspaces(
        &mut self,
        user_id: Uuid,
        after: Option<Uuid>,
        limit: i64,
    ) -> Result<Vec<WorkspaceSummary>, ApplicationError> {
        // Composite JOIN giữ đúng tenant và grant hiện hành, không cho grant cũ mở quyền sau rejoin.
        let rows=sqlx::query("SELECT workspace.workspace_id,workspace.name,workspace.revision,membership.role FROM workspaces workspace JOIN memberships membership USING(workspace_id) JOIN membership_grants grant_row ON (grant_row.workspace_id,grant_row.user_id,grant_row.grant_generation)=(membership.workspace_id,membership.user_id,membership.current_grant_generation) WHERE membership.user_id=$1 AND membership.status='ACTIVE' AND workspace.status='ACTIVE' AND grant_row.revoked_at IS NULL AND ($2::uuid IS NULL OR workspace.workspace_id>$2) ORDER BY workspace.workspace_id LIMIT $3")
            .bind(user_id).bind(after).bind(limit).fetch_all(&mut *self.transaction).await.map_err(storage_error)?;
        let mut summaries = Vec::with_capacity(rows.len());
        for row in rows {
            summaries.push(WorkspaceSummary {
                workspace_id: row.try_get("workspace_id").map_err(storage_error)?,
                name: row.try_get("name").map_err(storage_error)?,
                revision: row.try_get("revision").map_err(storage_error)?,
                role: parse_role(&row.try_get::<String, _>("role").map_err(storage_error)?)?,
            });
        }
        Ok(summaries)
    }

    /// Khóa Workspace trước membership/grant theo protocol; domain quyết định ACTIVE/role sau decode.
    async fn lock_workspace(
        &mut self,
        workspace_id: Uuid,
        user_id: Uuid,
    ) -> Result<WorkspaceSnapshot, ApplicationError> {
        let workspace = sqlx::query(
            "SELECT status,authorization_version FROM workspaces WHERE workspace_id=$1 FOR UPDATE",
        )
        .bind(workspace_id)
        .fetch_optional(&mut *self.transaction)
        .await
        .map_err(storage_error)?
        .ok_or(ApplicationError::Forbidden)?;
        // Không lọc ACTIVE tại đây để policy domain là nơi quyết định; thiếu hàng vẫn trả forbidden chung.
        let membership=sqlx::query("SELECT membership.user_id,membership.status,membership.role,membership.authorization_version,membership.current_grant_generation,grant_row.revoked_at FROM memberships membership JOIN membership_grants grant_row ON (grant_row.workspace_id,grant_row.user_id,grant_row.grant_generation)=(membership.workspace_id,membership.user_id,membership.current_grant_generation) WHERE membership.workspace_id=$1 AND membership.user_id=$2 FOR SHARE OF membership,grant_row")
            .bind(workspace_id).bind(user_id).fetch_optional(&mut *self.transaction).await.map_err(storage_error)?.ok_or(ApplicationError::Forbidden)?;
        let revoked: Option<chrono::DateTime<chrono::Utc>> =
            membership.try_get("revoked_at").map_err(storage_error)?;
        Ok(WorkspaceSnapshot {
            workspace_id,
            user_id: membership.try_get("user_id").map_err(storage_error)?,
            workspace_active: workspace
                .try_get::<String, _>("status")
                .map_err(storage_error)?
                == "ACTIVE",
            membership_active: membership
                .try_get::<String, _>("status")
                .map_err(storage_error)?
                == "ACTIVE",
            grant_active: revoked.is_none(),
            role: parse_role(
                &membership
                    .try_get::<String, _>("role")
                    .map_err(storage_error)?,
            )?,
            grant_generation: membership
                .try_get("current_grant_generation")
                .map_err(storage_error)?,
            workspace_authorization_version: workspace
                .try_get("authorization_version")
                .map_err(storage_error)?,
            membership_authorization_version: membership
                .try_get("authorization_version")
                .map_err(storage_error)?,
        })
    }
}
