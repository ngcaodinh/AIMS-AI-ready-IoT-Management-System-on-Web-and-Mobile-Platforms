//! Đối chiếu commit của registry và producer IAM thật trên cùng PostgreSQL fixture.

use super::{
    ApplicationError, DeviceProbe, MembershipPatch, MembershipStatus, input, seed_session, template,
};
use iot_platform_backend::domain::{
    device::DeviceDraft, identity::SessionProof, template_snapshot::PublishedTemplate,
    workspace::WorkspaceRole,
};
use sqlx::{Postgres, Transaction};
use std::{future::Future, time::Duration};
use uuid::Uuid;

impl DeviceProbe<'_> {
    /// Đọc revision CAS của member fixture trong workspace đang được kiểm.
    async fn member_revision(&self, user_id: Uuid) -> Result<i64, ApplicationError> {
        sqlx::query_scalar("SELECT revision FROM memberships WHERE workspace_id=$1 AND user_id=$2")
            .bind(self.workspace)
            .bind(user_id)
            .fetch_one(self.pool)
            .await
            .map_err(|_| ApplicationError::Unavailable)
    }

    /// Giữ row member bằng transaction chỉ đọc để dừng producer thật sau khi đã lấy User fence.
    async fn hold_member(
        &self,
        user_id: Uuid,
    ) -> Result<Transaction<'static, Postgres>, ApplicationError> {
        let mut gate = self
            .pool
            .begin()
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        // Dùng cùng composite key như repository; fixture không đổi role hoặc trạng thái.
        sqlx::query(
            "SELECT 1 FROM memberships WHERE workspace_id=$1 AND user_id=$2 FOR NO KEY UPDATE",
        )
        .bind(self.workspace)
        .bind(user_id)
        .fetch_one(&mut *gate)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
        Ok(gate)
    }

    /// Chờ độ sâu chuỗi chặn của phiên probe; caller giới hạn thời gian và không đọc SQL text.
    async fn wait_for_lock_chain(&self, gate_pid: i32, depth: i32) -> Result<(), ApplicationError> {
        loop {
            // Chỉ theo PID đang chờ trong DB và role fixture, với hai giá trị bind.
            let observed: bool = sqlx::query_scalar(
                "WITH RECURSIVE blocked(pid,depth) AS (
                    SELECT $1::integer,0
                    UNION ALL
                    SELECT waiter.pid,blocked.depth+1
                    FROM blocked JOIN pg_stat_activity waiter
                        ON blocked.pid=ANY(pg_blocking_pids(waiter.pid))
                    WHERE blocked.depth<$2 AND waiter.datname=current_database()
                      AND waiter.usename=current_user AND waiter.wait_event_type='Lock'
                ) SELECT EXISTS(SELECT 1 FROM blocked WHERE depth=$2)",
            )
            .bind(gate_pid)
            .bind(depth)
            .fetch_one(self.pool)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
            if observed {
                return Ok(());
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    /// Chạy hai service và chỉ nhả gate sau khi PostgreSQL quan sát hai tầng lock wait.
    async fn commit_in_order<First: Future, Second: Future>(
        &self,
        mut gate: Transaction<'static, Postgres>,
        first: First,
        second: Second,
    ) -> Result<(First::Output, Second::Output), ApplicationError> {
        let gate_pid = sqlx::query_scalar("SELECT pg_backend_pid()")
            .fetch_one(&mut *gate)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let after_first_wait = async {
            self.wait_for_lock_chain(gate_pid, 1).await?;
            let release = async {
                self.wait_for_lock_chain(gate_pid, 2).await?;
                gate.rollback()
                    .await
                    .map_err(|_| ApplicationError::Unavailable)
            };
            let (result, released) = tokio::join!(second, release);
            released?;
            Ok::<_, ApplicationError>(result)
        };
        // Giới hạn toàn ca để lỗi khóa không giữ pool hoặc fixture sống vô hạn.
        let (first, second) = tokio::time::timeout(Duration::from_secs(10), async {
            tokio::join!(first, after_first_wait)
        })
        .await
        .map_err(|_| ApplicationError::Conflict)?;
        Ok((first, second?))
    }

    /// Producer thắng phải commit thật, còn attempt register phải trả lỗi hiện hành và không ghi audit thành công.
    async fn denial_after<Output>(
        &self,
        gate: Transaction<'static, Postgres>,
        producer: impl Future<Output = Result<Output, ApplicationError>>,
        proof: &SessionProof,
        draft: DeviceDraft,
        expected: ApplicationError,
    ) -> Result<Output, ApplicationError> {
        let serial = draft.serial_number.clone();
        let correlation_id = Uuid::new_v4();
        let register = self
            .second
            .register(proof, self.workspace, draft, correlation_id);
        let (committed, denied) = self.commit_in_order(gate, producer, register).await?;
        let result = committed?;
        if !matches!(denied, Err(ref failure) if *failure == expected) {
            return Err(ApplicationError::Conflict);
        }
        // Tra scope/serial và correlation đã bind; FK của child ngăn runtime/actuator mồ côi.
        let unchanged: bool = sqlx::query_scalar(
            "SELECT NOT EXISTS(SELECT 1 FROM devices WHERE workspace_id=$1 AND serial_number=$2)
             AND NOT EXISTS(SELECT 1 FROM audit_events WHERE workspace_id=$1
                 AND correlation_id=$3 AND event_type='DEVICE_REGISTERED')",
        )
        .bind(self.workspace)
        .bind(serial)
        .bind(correlation_id)
        .fetch_one(self.pool)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
        if !unchanged {
            return Err(ApplicationError::Conflict);
        }
        Ok(result)
    }

    /// Mất role Admin phải chặn register đang đợi, kể cả khi phiên actor còn hiệu lực.
    async fn demote_registering_admin(
        &self,
        admin: Uuid,
        owner: Uuid,
        version: Uuid,
    ) -> Result<(), ApplicationError> {
        let demote = MembershipPatch {
            role: Some(WorkspaceRole::User),
            ..MembershipPatch::default()
        };
        let revision = self.member_revision(admin).await?;
        let producer = self.identity.update_member(
            self.member,
            self.workspace,
            admin,
            revision,
            &demote,
            Uuid::new_v4(),
        );
        let changed = self
            .denial_after(
                self.hold_member(admin).await?,
                producer,
                self.admin,
                input(owner, version, format!("D2-DEMOTE-{}", self.config.run_id)),
                ApplicationError::Forbidden,
            )
            .await?;
        if changed.role != WorkspaceRole::User || changed.revision != revision + 1 {
            return Err(ApplicationError::Conflict);
        }
        let restore = MembershipPatch {
            role: Some(WorkspaceRole::Admin),
            ..MembershipPatch::default()
        };
        self.identity
            .update_member(
                self.member,
                self.workspace,
                admin,
                changed.revision,
                &restore,
                Uuid::new_v4(),
            )
            .await?;
        Ok(())
    }

    /// Owner tự suspend qua producer membership với một Admin khác còn hoạt động.
    async fn suspend_owner(
        &self,
        owner: Uuid,
        version: Uuid,
        revision: i64,
    ) -> Result<i64, ApplicationError> {
        let suspend = MembershipPatch {
            status: Some(MembershipStatus::Suspended),
            ..MembershipPatch::default()
        };
        let producer = self.identity.update_member(
            self.member,
            self.workspace,
            owner,
            revision,
            &suspend,
            Uuid::new_v4(),
        );
        let changed = self
            .denial_after(
                self.hold_member(owner).await?,
                producer,
                self.admin,
                input(owner, version, format!("D2-SUSPEND-{}", self.config.run_id)),
                ApplicationError::DeviceOwnerInvalid,
            )
            .await?;
        if changed.status != MembershipStatus::Suspended || changed.revision != revision + 1 {
            return Err(ApplicationError::Conflict);
        }
        let resume = MembershipPatch {
            status: Some(MembershipStatus::Active),
            ..MembershipPatch::default()
        };
        Ok(self
            .identity
            .update_member(
                self.admin,
                self.workspace,
                owner,
                changed.revision,
                &resume,
                Uuid::new_v4(),
            )
            .await?
            .revision)
    }

    /// Register giữ fence trước phải commit đúng pin; remove sau đó giữ nguyên registry đã có.
    async fn register_before_remove(
        &self,
        owner: Uuid,
        version: &PublishedTemplate,
        revision: i64,
    ) -> Result<(), ApplicationError> {
        let mut gate = self
            .pool
            .begin()
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        // Row root giữ register ở cuối admission, sau User/Workspace, với UUID fixture bind.
        sqlx::query(
            "SELECT 1 FROM templates WHERE workspace_id=$1 AND template_id=$2 FOR NO KEY UPDATE",
        )
        .bind(self.workspace)
        .bind(version.template_id)
        .fetch_one(&mut *gate)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
        let draft = input(
            owner,
            version.template_version_id,
            format!("D2-REMOVE-{}", self.config.run_id),
        );
        let register = self
            .second
            .register(self.admin, self.workspace, draft, Uuid::new_v4());
        let remove = MembershipPatch {
            status: Some(MembershipStatus::Removed),
            ..MembershipPatch::default()
        };
        let producer = self.identity.update_member(
            self.member,
            self.workspace,
            owner,
            revision,
            &remove,
            Uuid::new_v4(),
        );
        let (registered, removed) = self.commit_in_order(gate, register, producer).await?;
        let registered = registered?;
        let removed = removed?;
        // Đọc lại identity đã commit sau cả hai transaction bằng khóa composite.
        let preserved: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM devices JOIN device_runtime USING(workspace_id,device_id)
            WHERE workspace_id=$1 AND device_id=$2 AND owner_user_id=$3 AND template_version_id=$4
              AND lifecycle_status='REGISTERED' AND presence_state='UNKNOWN')",
        )
        .bind(self.workspace)
        .bind(registered.pin.device_id)
        .bind(owner)
        .bind(version.template_version_id)
        .fetch_one(self.pool)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
        if !preserved
            || removed.status != MembershipStatus::Removed
            || removed.revision != revision + 1
        {
            return Err(ApplicationError::Conflict);
        }
        Ok(())
    }

    /// Logout của Admin dùng cùng User/Session fence và phải thắng attempt register đang đợi.
    async fn logout_before_register(
        &self,
        admin: Uuid,
        version: Uuid,
    ) -> Result<(), ApplicationError> {
        let proof = seed_session(self.identity, self.pool, admin, false).await?;
        let mut gate = self
            .pool
            .begin()
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        // Giữ phiên fixture qua digest bind; không ghi revoked_at bằng SQL test.
        sqlx::query("SELECT 1 FROM sessions WHERE token_digest=$1 FOR NO KEY UPDATE")
            .bind(proof.token_digest.as_slice())
            .fetch_one(&mut *gate)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        self.denial_after(
            gate,
            self.identity.logout(&proof, Uuid::new_v4()),
            &proof,
            input(admin, version, format!("D2-LOGOUT-{}", self.config.run_id)),
            ApplicationError::SessionRevoked,
        )
        .await
    }

    /**
     * Kiểm phân loại draft theo workspace và thứ tự commit giữa registry với producer IAM.
     *
     * # Input
     * Param: version — snapshot đã publish để kiểm pin và các ca tranh khóa.
     * Param: checks — danh sách tên ca đã đạt, không chứa serial hay dữ liệu người dùng.
     *
     * # Output
     * Trả thành công sau các ca kiểm hoặc lỗi khi kết quả sai scope, sai trạng thái hay có lỗi lưu trữ.
     */
    pub(super) async fn authority_checks(
        &self,
        version: &PublishedTemplate,
        checks: &mut Vec<&'static str>,
    ) -> Result<(), ApplicationError> {
        let owner = self.config.user_ids[1];
        let admin = self.config.user_ids[5];
        let draft = self
            .templates
            .create(
                self.admin,
                self.workspace,
                template(format!("D2-DRAFT-{}", self.config.run_id), true),
                Uuid::new_v4(),
            )
            .await?;
        let rejected = self
            .first
            .register(
                self.admin,
                self.workspace,
                input(
                    owner,
                    draft.template_id,
                    format!("D2-DRAFT-{}", self.config.run_id),
                ),
                Uuid::new_v4(),
            )
            .await;
        if !matches!(rejected, Err(ApplicationError::DeviceTemplateNotPublished)) {
            return Err(ApplicationError::Conflict);
        }
        let foreign_draft = self
            .templates
            .create(
                self.foreign,
                self.foreign_workspace,
                template(format!("D2-FOREIGN-ROOT-{}", self.config.run_id), true),
                Uuid::new_v4(),
            )
            .await?;
        let serial = format!("D2-FOREIGN-DRAFT-{}", self.config.run_id);
        let correlation_id = Uuid::new_v4();
        let rejected = self
            .first
            .register(
                self.admin,
                self.workspace,
                input(owner, foreign_draft.template_id, serial.clone()),
                correlation_id,
            )
            .await;
        if !matches!(rejected, Err(ApplicationError::ResourceNotFound)) {
            return Err(ApplicationError::Conflict);
        }
        // Kiểm đúng draft đã commit ở workspace B; serial và mã truy vết đã bind chỉ dùng để kiểm không có bản ghi từ yêu cầu thử.
        let foreign_draft_hidden: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM templates
                 WHERE workspace_id=$1 AND template_id=$2 AND lifecycle_status='DRAFT')
             AND NOT EXISTS(SELECT 1 FROM devices WHERE serial_number=$3)
             AND NOT EXISTS(SELECT 1 FROM audit_events WHERE correlation_id=$4)",
        )
        .bind(self.foreign_workspace)
        .bind(foreign_draft.template_id)
        .bind(serial)
        .bind(correlation_id)
        .fetch_one(self.pool)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
        if !foreign_draft_hidden {
            return Err(ApplicationError::Conflict);
        }
        checks.push("PASS CT-DEVICE-004 / SEC-DEVICE-002: local draft is not published and persisted foreign draft returns not found with no device or audit");

        // Hai Admin fixture cho phép demote/remove qua policy last Admin thật của application.
        let promote = MembershipPatch {
            role: Some(WorkspaceRole::Admin),
            ..MembershipPatch::default()
        };
        let promoted = self
            .identity
            .update_member(
                self.admin,
                self.workspace,
                owner,
                self.member_revision(owner).await?,
                &promote,
                Uuid::new_v4(),
            )
            .await?;
        self.demote_registering_admin(admin, owner, version.template_version_id)
            .await?;
        checks.push("PASS IT-DEVICE-005: real membership producer demotes the registering Admin under observed row-lock contention");
        let resumed = self
            .suspend_owner(owner, version.template_version_id, promoted.revision)
            .await?;
        checks.push("PASS IT-DEVICE-005: real owner suspension commits before the waiting registration and no device is created");
        self.register_before_remove(owner, version, resumed).await?;
        checks.push("PASS IT-DEVICE-005: registration commits before real member removal and preserves the existing pin and owner");
        self.logout_before_register(admin, version.template_version_id)
            .await?;
        checks.push("PASS IT-DEVICE-005: real current-session logout commits before the waiting registration and no device is created");
        Ok(())
    }
}
