//! Scoped revocation là durable DB intent; không khẳng định socket/provider hoặc thiết bị đã thu hồi vật lý.

use crate::{PgUnitOfWork, storage_error};
use chrono::{DateTime, Utc};
use iot_application::error::ApplicationError;
use iot_domain::membership::{MembershipSnapshot, MembershipStatus};
use uuid::Uuid;

impl PgUnitOfWork {
    /**
     * Persist invalidation theo workspace/user/version, giữ session và tenant khác nguyên quyền.
     * Input
     * Param: before — identity/grant đang được parent/User fences bảo vệ.
     * Param: after — trạng thái/version mới đã persist cùng transaction.
     * Param: `email_digest` — HMAC target email dùng admission fence, không raw email trong outbox.
     * Param: now — instant revocation/intent dùng chung cho mutation.
     * Output: hoàn thành hoặc lỗi storage; caller chưa được commit nếu bất kỳ bước nào thất bại.
     */
    pub(crate) async fn invalidate_workspace_member(
        &mut self,
        before: &MembershipSnapshot,
        after: &MembershipSnapshot,
        email_digest: [u8; 32],
        now: DateTime<Utc>,
    ) -> Result<(), ApplicationError> {
        let workspace_id = before.workspace_id;
        let user_id = before.user_id;
        // Ticket scope cũ không còn quyền; không revoke session global hoặc binding installation toàn account.
        sqlx::query("UPDATE websocket_tickets SET revoked_at=$3 WHERE workspace_id=$1 AND user_id=$2 AND revoked_at IS NULL")
            .bind(workspace_id).bind(user_id).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        sqlx::query("UPDATE workspace_invitations SET revoked_at=$3 WHERE workspace_id=$1 AND issued_by_user_id=$2 AND used_at IS NULL AND revoked_at IS NULL AND expired_at IS NULL")
            .bind(workspace_id).bind(user_id).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        if after.status != MembershipStatus::Active {
            // Fence chống token đã phát trước suspend/remove; pending issuer/recipient phải terminal để không chiếm unique key mãi.
            sqlx::query("INSERT INTO membership_admission_fences(workspace_id,email_digest,admission_generation,updated_at) VALUES($1,$2,1,$3) ON CONFLICT(workspace_id,email_digest) DO UPDATE SET admission_generation=membership_admission_fences.admission_generation+1,updated_at=EXCLUDED.updated_at")
                .bind(workspace_id).bind(email_digest.as_slice()).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
            sqlx::query("UPDATE workspace_invitations SET revoked_at=$3 WHERE workspace_id=$1 AND email_digest=$2 AND used_at IS NULL AND revoked_at IS NULL AND expired_at IS NULL")
                .bind(workspace_id).bind(email_digest.as_slice()).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
            self.stop_workspace_member_work(workspace_id, user_id, now)
                .await?;
            self.stop_workspace_member_deliveries(workspace_id, user_id, after.status, now)
                .await?;
        }
        if after.status == MembershipStatus::Removed {
            // Suspend giữ grant để resume; remove revoke vĩnh viễn, invitation rejoin phải cấp generation mới.
            sqlx::query("UPDATE membership_grants SET revoked_at=$4 WHERE workspace_id=$1 AND user_id=$2 AND grant_generation=$3 AND revoked_at IS NULL")
                .bind(workspace_id).bind(user_id).bind(before.grant_generation).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        }
        let event_id = Uuid::new_v4();
        sqlx::query("INSERT INTO outbox_events(outbox_event_id,workspace_id,event_key,event_type,payload_schema_version,payload,created_at) VALUES($1,$2,$3,'MEMBERSHIP_AUTHORITY_CHANGED',1,jsonb_build_object('workspaceId',$2::uuid::text,'userId',$4::uuid::text,'membershipAuthorizationVersion',$5::bigint),$6)")
            .bind(event_id).bind(workspace_id).bind(format!("membership-authority:{workspace_id}:{user_id}:{}",after.authorization_version)).bind(user_id).bind(after.authorization_version).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        sqlx::query("INSERT INTO outbox_consumptions(outbox_event_id,consumer_code,available_at) VALUES($1,'REALTIME_WORKSPACE_CLOSE',$2),($1,'WORKSPACE_PRINCIPAL_RECONCILE',$2)")
            .bind(event_id).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(())
    }

    /**
     * Dừng công việc chưa dispatch của owner trong tenant; giữ trạng thái đã có khả năng tác động ngoài DB.
     * Input
     * Param: `workspace_id` — tenant duy nhất bị mất membership.
     * Param: `user_id` — owner snapshot hoặc actor/key-owner cần suppress.
     * Param: now — instant terminal của công việc chưa gửi.
     * Output: hoàn thành hoặc storage error; `DISPATCHING/AWAITING_RESULT/UNKNOWN` không bị xóa hoặc giả CANCELLED.
     */
    async fn stop_workspace_member_work(
        &mut self,
        workspace_id: Uuid,
        user_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<(), ApplicationError> {
        // Chỉ cancel chắc chắn khi command chưa có intent và cả action lẫn job chưa báo đã dispatch; kiểm hai ledger độc lập.
        sqlx::query("UPDATE commands command SET state='CANCELLED',outcome='FAILED',terminal_at=$3,revision=revision+1 WHERE command.workspace_id=$1 AND command.state='ADMITTED' AND command.dispatch_intent_at IS NULL AND (command.actor_user_id=$2 OR command.api_key_id IN(SELECT api_key_id FROM api_keys WHERE workspace_id=$1 AND owner_user_id=$2) OR command.action_execution_id IN(SELECT action.action_execution_id FROM action_executions action JOIN rule_executions execution ON (execution.workspace_id,execution.rule_execution_id)=(action.workspace_id,action.rule_execution_id) WHERE action.workspace_id=$1 AND execution.owner_user_id_snapshot=$2)) AND NOT EXISTS(SELECT 1 FROM action_executions action WHERE action.workspace_id=command.workspace_id AND (action.action_execution_id=command.action_execution_id OR action.command_id=command.command_id) AND action.state NOT IN ('BLOCKED','READY','WAITING','CANCELLED')) AND NOT EXISTS(SELECT 1 FROM action_executions action JOIN action_jobs job USING(workspace_id,rule_execution_id,action_position) WHERE action.workspace_id=command.workspace_id AND (action.action_execution_id=command.action_execution_id OR action.command_id=command.command_id) AND job.state NOT IN ('BLOCKED','READY','WAITING','CANCELLED'))")
            .bind(workspace_id).bind(user_id).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        // Snapshot action có thể chậm hơn job/command: bằng chứng dispatch/UNKNOWN ở bất kỳ ledger nào đều cần đối soát.
        sqlx::query("UPDATE action_executions action SET state='NEEDS_ATTENTION',ended_at=$3,reason_code='CANCELLED_PERMISSION_CHANGED' FROM rule_executions execution WHERE action.workspace_id=$1 AND (execution.workspace_id,execution.rule_execution_id)=(action.workspace_id,action.rule_execution_id) AND execution.owner_user_id_snapshot=$2 AND action.state IN ('BLOCKED','READY','WAITING') AND (EXISTS(SELECT 1 FROM action_jobs job WHERE (job.workspace_id,job.rule_execution_id,job.action_position)=(action.workspace_id,action.rule_execution_id,action.action_position) AND job.state NOT IN ('BLOCKED','READY','WAITING','CANCELLED')) OR EXISTS(SELECT 1 FROM commands command WHERE command.workspace_id=action.workspace_id AND (command.action_execution_id=action.action_execution_id OR command.command_id=action.command_id) AND (command.dispatch_intent_at IS NOT NULL OR command.outcome='UNKNOWN' OR command.state IN ('DISPATCHING','DISPATCHED','ACCEPTED','SUCCEEDED','FAILED','TIMED_OUT'))))")
            .bind(workspace_id).bind(user_id).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        sqlx::query("UPDATE action_jobs job SET state='NEEDS_ATTENTION',lease_until=NULL,lease_generation=lease_generation+1 FROM action_executions action JOIN rule_executions execution USING(workspace_id,rule_execution_id) WHERE job.workspace_id=$1 AND (action.workspace_id,action.rule_execution_id,action.action_position)=(job.workspace_id,job.rule_execution_id,job.action_position) AND execution.owner_user_id_snapshot=$2 AND action.state IN ('DISPATCHING','AWAITING_RESULT','NEEDS_ATTENTION') AND job.state IN ('BLOCKED','READY','WAITING')")
            .bind(workspace_id).bind(user_id).execute(&mut *self.transaction).await.map_err(storage_error)?;
        // Lease generation tiến để stale worker không settle job sau khi mất authority; WAIT due_at không bị reset.
        sqlx::query("UPDATE action_jobs job SET state='CANCELLED',lease_until=NULL,lease_generation=lease_generation+1 FROM rule_executions execution WHERE job.workspace_id=$1 AND (execution.workspace_id,execution.rule_execution_id)=(job.workspace_id,job.rule_execution_id) AND execution.owner_user_id_snapshot=$2 AND job.state IN ('BLOCKED','READY','WAITING')")
            .bind(workspace_id).bind(user_id).execute(&mut *self.transaction).await.map_err(storage_error)?;
        sqlx::query("UPDATE action_executions action SET state='CANCELLED',ended_at=$3,reason_code='CANCELLED_PERMISSION_CHANGED' FROM rule_executions execution WHERE action.workspace_id=$1 AND (execution.workspace_id,execution.rule_execution_id)=(action.workspace_id,action.rule_execution_id) AND execution.owner_user_id_snapshot=$2 AND action.state IN ('BLOCKED','READY','WAITING')")
            .bind(workspace_id).bind(user_id).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        // Có action đã dispatch hoặc UNKNOWN thì execution cần đối soát; không khẳng định tác động đã được thu hồi.
        sqlx::query("UPDATE rule_executions execution SET state=CASE WHEN EXISTS(SELECT 1 FROM action_executions action WHERE (action.workspace_id,action.rule_execution_id)=(execution.workspace_id,execution.rule_execution_id) AND action.state IN ('DISPATCHING','AWAITING_RESULT','NEEDS_ATTENTION')) OR EXISTS(SELECT 1 FROM action_jobs job WHERE (job.workspace_id,job.rule_execution_id)=(execution.workspace_id,execution.rule_execution_id) AND job.state IN ('DISPATCHING','AWAITING_RESULT','NEEDS_ATTENTION')) THEN 'NEEDS_ATTENTION' ELSE 'CANCELLED' END,ended_at=$3,failure_reason='CANCELLED_PERMISSION_CHANGED' WHERE execution.workspace_id=$1 AND execution.owner_user_id_snapshot=$2 AND execution.state IN ('RUNNING','WAITING')")
            .bind(workspace_id).bind(user_id).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(())
    }

    /**
     * Suppress pending delivery/key đúng tenant khi membership không còn ACTIVE, giữ send intent đã phát.
     * Input
     * Param: `workspace_id` — tenant cần chặn các delivery mới.
     * Param: `user_id` — recipient/owner mất quyền trong tenant đó.
     * Param: status — REMOVED revoke subscription vĩnh viễn, SUSPENDED pause để Admin đối soát.
     * Param: now — instant terminal/revoke, không gọi provider hoặc socket.
     * Output: hoàn thành trong transaction hoặc lỗi storage; SENDING được giữ để reconciliation.
     */
    async fn stop_workspace_member_deliveries(
        &mut self,
        workspace_id: Uuid,
        user_id: Uuid,
        status: MembershipStatus,
        now: DateTime<Utc>,
    ) -> Result<(), ApplicationError> {
        if status == MembershipStatus::Removed {
            // FEAT057 §8.5: suspend chỉ chặn current-rights intersection; remove mới kết thúc key/grant vĩnh viễn.
            sqlx::query("UPDATE api_keys SET revoked_at=$3,revision=revision+1 WHERE workspace_id=$1 AND owner_user_id=$2 AND revoked_at IS NULL")
                .bind(workspace_id).bind(user_id).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        }
        sqlx::query("UPDATE push_deliveries SET state='SUPPRESSED',terminal_at=$3,next_attempt_at=NULL,lease_until=NULL,lease_generation=lease_generation+1 WHERE workspace_id=$1 AND recipient_user_id=$2 AND state IN ('PENDING','RETRY_WAIT')")
            .bind(workspace_id).bind(user_id).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        sqlx::query("UPDATE webhook_subscriptions SET lifecycle_status=$3,revision=revision+1,updated_at=$4 WHERE workspace_id=$1 AND owner_user_id=$2 AND lifecycle_status IN ('ACTIVE','PAUSED')")
            .bind(workspace_id).bind(user_id).bind(if status==MembershipStatus::Removed {"REVOKED"} else {"PAUSED"}).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        sqlx::query("UPDATE webhook_deliveries delivery SET state='CANCELLED',terminal_at=$3,next_attempt_at=NULL,lease_until=NULL,lease_generation=lease_generation+1 FROM webhook_subscriptions subscription WHERE delivery.workspace_id=$1 AND (subscription.workspace_id,subscription.webhook_subscription_id)=(delivery.workspace_id,delivery.webhook_subscription_id) AND subscription.owner_user_id=$2 AND delivery.state IN ('PENDING','RETRY_WAIT')")
            .bind(workspace_id).bind(user_id).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(())
    }
}
