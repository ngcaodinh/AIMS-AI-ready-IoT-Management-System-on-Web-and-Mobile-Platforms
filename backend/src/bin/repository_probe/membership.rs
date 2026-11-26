//! Integration member dùng hai tenant và pending/dispatch fixtures; không giả bằng chứng physical worker.

#[path = "membership_command.rs"]
mod command_probe;

use super::{AuthService, ProbeConfig, request_key};
use iot_platform_backend::{
    adapters::security::{CryptoService, PasswordService},
    application::{error::ApplicationError, identity::IdentityService},
    domain::{
        identity::{ClientType, SecretString, SessionProof},
        membership::{AliasChange, MembershipPatch, MembershipSnapshot, MembershipStatus},
        workspace::WorkspaceRole,
    },
    postgres::{PgIdentityStore, connection::connect_local_probe},
};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use uuid::Uuid;

/// Authority/fixture context riêng cho member probes, không Debug hoặc serialize proof.
struct MemberProbe<'a> {
    service: &'a AuthService,
    pool: &'a PgPool,
    config: &'a ProbeConfig,
    admin: SessionProof,
    member: SessionProof,
    workspace_a: Uuid,
    workspace_b: Uuid,
}

/**
 * Chạy member CAS/last Admin và scope isolation bằng application thật trên DB canonical.
 * Input
 * Param: service — composition application/PG/crypto instance A.
 * Param: pool — pool tạm để dựng state fixture và đọc kết quả không secret.
 * Param: config — UUID/email marker riêng của lượt chạy.
 * Param: password — credential fixture Admin/member hiện hành, không log.
 * Param: checks — danh sách tên kiểm chỉ thêm sau invariant đạt.
 * Output: hoàn thành hoặc lỗi đã lọc; không mutate account global.
 */
pub(super) async fn verify(
    service: &AuthService,
    pool: &PgPool,
    config: &ProbeConfig,
    password: &SecretString,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let admin = service
        .login(
            &config.emails[0],
            password.expose().to_owned(),
            ClientType::Android,
            config.run_id,
        )
        .await?;
    let member = service
        .login(
            &config.emails[1],
            password.expose().to_owned(),
            ClientType::Android,
            config.run_id,
        )
        .await?;
    let admin = service.session_proof(admin.token.expose(), None);
    let member = service.session_proof(member.token.expose(), None);
    // Chọn tenant thật của fixture USER đã có; không giả role bằng một workspace mà actor không thuộc.
    let workspace_a: Uuid = sqlx::query_scalar(
        "SELECT workspace_id FROM memberships WHERE user_id=$1 ORDER BY workspace_id LIMIT 1",
    )
    .bind(config.user_ids[1])
    .fetch_one(pool)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    let workspace_b = service
        .list_workspaces(&admin, None, 5)
        .await?
        .into_iter()
        .find(|item| item.workspace_id != workspace_a)
        .ok_or(ApplicationError::Conflict)?
        .workspace_id;
    let context = MemberProbe {
        service,
        pool,
        config,
        admin,
        member,
        workspace_a,
        workspace_b,
    };
    seed_second_membership(&context).await?;
    seed_keys(&context).await?;
    let member = alias_and_authority_checks(&context, checks).await?;
    let member = suspension_checks(&context, &member, checks).await?;
    let member = remove_reinvite_checks(&context, &member, checks).await?;
    last_admin_checks(&context, &member, checks).await
}

/**
 * Dựng membership USER thứ hai để mọi scope-negative có positive control cùng global session.
 * Input
 * Param: context — hai tenant thuộc fixture và User đã tồn tại.
 * Output: hoàn thành hoặc storage error; không nâng global role hoặc tạo session khác.
 */
async fn seed_second_membership(context: &MemberProbe<'_>) -> Result<(), ApplicationError> {
    let mut transaction = context
        .pool
        .begin()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO memberships(workspace_id,user_id,role,current_grant_generation) VALUES($1,$2,'USER',1)")
        .bind(context.workspace_b).bind(context.config.user_ids[1]).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query(
        "INSERT INTO membership_grants(workspace_id,user_id,grant_generation) VALUES($1,$2,1)",
    )
    .bind(context.workspace_b)
    .bind(context.config.user_ids[1])
    .execute(&mut *transaction)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    transaction
        .commit()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    Ok(())
}

/**
 * Dựng hai key metadata cùng owner/grant ở A/B để phân biệt suspension với permanent revoke.
 * Input
 * Param: context — fixture scope và owner; không là key sử dụng thật ở integration API.
 * Output: hoàn thành hoặc lỗi seed; không tạo hoặc phát raw API key.
 */
async fn seed_keys(context: &MemberProbe<'_>) -> Result<(), ApplicationError> {
    for workspace in [context.workspace_a, context.workspace_b] {
        let verifier = Sha256::digest(Uuid::new_v4().as_bytes());
        let mut transaction = context
            .pool
            .begin()
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let device = seed_key_device(context, workspace, &mut transaction).await?;
        let key = Uuid::new_v4();
        // Key+device allowlist+scope cùng commit để native cardinality không phải bị tắt khi dựng fixture.
        sqlx::query("INSERT INTO api_keys(api_key_id,workspace_id,owner_user_id,owner_grant_generation,verifier_digest,name,prefix,issued_at,expires_at) VALUES($1,$2,$3,1,$4,$5,'probe',transaction_timestamp(),transaction_timestamp()+interval '24 hours')")
            .bind(key).bind(workspace).bind(context.config.user_ids[1]).bind(verifier.as_slice()).bind(format!("REPOSITORY_PROBE:{}",context.config.run_id)).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
        sqlx::query(
            "INSERT INTO api_key_devices(workspace_id,api_key_id,device_id) VALUES($1,$2,$3)",
        )
        .bind(workspace)
        .bind(key)
        .bind(device)
        .execute(&mut *transaction)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
        sqlx::query("INSERT INTO api_key_scopes(workspace_id,api_key_id,scope_code) VALUES($1,$2,'telemetry:read')")
            .bind(workspace).bind(key).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
        transaction
            .commit()
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
    }
    Ok(())
}

/**
 * Dựng device đã pin một read stream để key allowlist đáp ứng native FK/cardinality thực.
 * Input
 * Param: context — issuer/owner và marker fixture, không liên quan board thật.
 * Param: workspace — tenant của device/key đang tạo.
 * Param: transaction — cùng unit seed version/stream/key; không extend published content sau commit.
 * Output: device ID tổng hợp hoặc lỗi storage đã lọc.
 */
async fn seed_key_device(
    context: &MemberProbe<'_>,
    workspace: Uuid,
    transaction: &mut sqlx::Transaction<'_, sqlx::Postgres>,
) -> Result<Uuid, ApplicationError> {
    let template = Uuid::new_v4();
    let version = Uuid::new_v4();
    let device = Uuid::new_v4();
    // Metadata fixture tối thiểu, mọi UUID/marker đều bind; đây không là template publish/device provisioning acceptance.
    sqlx::query("INSERT INTO templates(workspace_id,template_id,name,model,created_by_user_id) VALUES($1,$2,'Probe','PROBE',$3)")
        .bind(workspace).bind(template).bind(context.config.user_ids[0]).execute(&mut **transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO template_versions(workspace_id,template_version_id,template_id,version_number,name,model,published_by_user_id,content_digest,source_revision,published_root_revision) VALUES($1,$2,$3,1,'Probe','PROBE',$4,$5,$6,$7)")
        .bind(workspace).bind(version).bind(template).bind(context.config.user_ids[0]).bind([53_u8;32].as_slice()).bind(1_i64).bind(2_i64).execute(&mut **transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO datastream_definitions(workspace_id,template_version_id,stream_key,display_name,data_type,direction,channel_kind) VALUES($1,$2,'temperature','Temperature','NUMBER','READ','TELEMETRY')")
        .bind(workspace).bind(version).execute(&mut **transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    for stream in ["fan", "fan_secondary"] {
        // Hai actuator độc lập cho hai regression lag/UNKNOWN, không nới single-flight guard của command.
        sqlx::query("INSERT INTO datastream_definitions(workspace_id,template_version_id,stream_key,display_name,data_type,direction,channel_kind) VALUES($1,$2,$3,'Fan','BOOLEAN','READ_WRITE','STATE')")
            .bind(workspace).bind(version).bind(stream).execute(&mut **transaction).await.map_err(|_|ApplicationError::Unavailable)?;
        sqlx::query("INSERT INTO datastream_capabilities(workspace_id,template_version_id,stream_key,command_type,safe_value) VALUES($1,$2,$3,'SET_VALUE','false')")
            .bind(workspace).bind(version).bind(stream).execute(&mut **transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    }
    sqlx::query("INSERT INTO devices(device_id,workspace_id,serial_number,template_version_id,owner_user_id,name,model,hardware_revision) VALUES($1,$2,$3,$4,$5,'Probe','PROBE','1')")
        .bind(device).bind(workspace).bind(format!("PROBE-{device}")).bind(version).bind(context.config.user_ids[1]).execute(&mut **transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    for stream in ["fan", "fan_secondary"] {
        sqlx::query("INSERT INTO actuator_states(workspace_id,device_id,stream_key,pinned_template_version_id) VALUES($1,$2,$3,$4)")
            .bind(workspace).bind(device).bind(stream).bind(version).execute(&mut **transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    }
    Ok(device)
}

/**
 * Kiểm revoke key chỉ khi remove; key B và key A qua suspend/resume giữ metadata chưa revoke.
 * Input
 * Param: context — hai tenant và owner fixture có đúng một key metadata mỗi tenant.
 * Param: removed — true sau remove, false sau suspend/resume.
 * Output: hoàn thành hoặc conflict nếu permanent revoke lan sai thời điểm/scope.
 */
async fn key_state_checks(
    context: &MemberProbe<'_>,
    removed: bool,
) -> Result<(), ApplicationError> {
    let states:Vec<(Uuid,bool)>=sqlx::query_as("SELECT workspace_id,revoked_at IS NOT NULL FROM api_keys WHERE owner_user_id=$1 AND workspace_id=ANY($2)")
        .bind(context.config.user_ids[1]).bind(vec![context.workspace_a,context.workspace_b]).fetch_all(context.pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if states.len() != 2
        || states
            .iter()
            .any(|(workspace, revoked)| *revoked != (*workspace == context.workspace_a && removed))
    {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}

/**
 * Kiểm nullable alias, empty patch, stale revision và USER không tự nâng role.
 * Input
 * Param: context — Admin và USER hiện hành cùng tenant A/B.
 * Param: checks — tên evidence sau khi positive/negative đạt.
 * Output: snapshot revision mới, giữ auth version/grant nguyên khi alias-only.
 */
async fn alias_and_authority_checks(
    context: &MemberProbe<'_>,
    checks: &mut Vec<&'static str>,
) -> Result<MembershipSnapshot, ApplicationError> {
    let target = context.config.user_ids[1];
    let patch = MembershipPatch {
        alias: AliasChange::Set(Some("alias ' quoted".to_owned())),
        ..MembershipPatch::default()
    };
    let saved = context
        .service
        .update_member(
            &context.admin,
            context.workspace_a,
            target,
            1,
            &patch,
            context.config.run_id,
        )
        .await?;
    let clear = MembershipPatch {
        alias: AliasChange::Set(None),
        ..MembershipPatch::default()
    };
    let cleared = context
        .service
        .update_member(
            &context.admin,
            context.workspace_a,
            target,
            saved.revision,
            &clear,
            context.config.run_id,
        )
        .await?;
    if saved.alias.as_deref() != Some("alias ' quoted")
        || cleared.alias.is_some()
        || cleared.authorization_version != 1
        || cleared.grant_generation != 1
    {
        return Err(ApplicationError::Conflict);
    }
    let events:i64=sqlx::query_scalar("SELECT count(*) FROM outbox_events WHERE workspace_id=$1 AND event_type='MEMBERSHIP_AUTHORITY_CHANGED'")
        .bind(context.workspace_a).fetch_one(context.pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if events != 0
        || !matches!(
            context
                .service
                .update_member(
                    &context.admin,
                    context.workspace_a,
                    target,
                    1,
                    &clear,
                    context.config.run_id
                )
                .await,
            Err(ApplicationError::StaleRevision)
        )
        || !matches!(
            context
                .service
                .update_member(
                    &context.admin,
                    context.workspace_a,
                    target,
                    cleared.revision,
                    &MembershipPatch::default(),
                    context.config.run_id
                )
                .await,
            Err(ApplicationError::InvalidInput)
        )
    {
        return Err(ApplicationError::Conflict);
    }
    let promote = MembershipPatch {
        role: Some(WorkspaceRole::Admin),
        ..MembershipPatch::default()
    };
    if !matches!(
        context
            .service
            .update_member(
                &context.member,
                context.workspace_a,
                target,
                cleared.revision,
                &promote,
                context.config.run_id
            )
            .await,
        Err(ApplicationError::Forbidden)
    ) {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: member alias CAS preserves authority; explicit null clears and stale/empty/USER elevation are denied");
    Ok(cleared)
}

/**
 * Dựng một execution WAIT hoặc dispatch intent bằng version immutable cùng transaction.
 * Input
 * Param: context — marker và owner fixture cần kiểm scoped cancellation.
 * Param: workspace — tenant A hoặc B; cùng owner để so khác biệt quyền.
 * Param: dispatching — true dựng NOTIFY dispatch intent, false dựng WAIT chưa dispatch.
 * Output: execution ID để kiểm truth sau mutation; không gửi event/provider/device thật.
 */
async fn seed_execution(
    context: &MemberProbe<'_>,
    workspace: Uuid,
    dispatching: bool,
) -> Result<Uuid, ApplicationError> {
    let rule = Uuid::new_v4();
    let version = Uuid::new_v4();
    let execution = Uuid::new_v4();
    let mut transaction = context
        .pool
        .begin()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    // Nội dung fixture hợp lệ được publish cùng version/action; không sửa child sau commit hoặc gọi evaluator.
    sqlx::query("INSERT INTO rules(workspace_id,rule_id,owner_user_id,name) VALUES($1,$2,$3,$4)")
        .bind(workspace)
        .bind(rule)
        .bind(context.config.user_ids[1])
        .bind(format!("REPOSITORY_PROBE:{}", context.config.run_id))
        .execute(&mut *transaction)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO rule_versions(workspace_id,rule_version_id,rule_id,version_number,trigger_type,trigger_config,condition_ast,cooldown_seconds,priority,on_failure,content_digest) VALUES($1,$2,$3,1,'MANUAL','{}','{\"type\":\"AND\",\"children\":[]}',10,'NORMAL','STOP',$4)")
        .bind(workspace).bind(version).bind(rule).bind([49_u8;32].as_slice()).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    if dispatching {
        sqlx::query("INSERT INTO rule_version_actions(workspace_id,rule_version_id,action_position,action_type,notification_config) VALUES($1,$2,0,'NOTIFY','{\"recipient\":\"OWNER\"}')")
            .bind(workspace).bind(version).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    } else {
        sqlx::query("INSERT INTO rule_version_actions(workspace_id,rule_version_id,action_position,action_type,wait_seconds) VALUES($1,$2,0,'WAIT',30)")
            .bind(workspace).bind(version).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    }
    sqlx::query("INSERT INTO rule_executions(workspace_id,rule_execution_id,rule_id,rule_version_id,trigger_key,state,admitted_at,deadline_at,owner_user_id_snapshot) VALUES($1,$2,$3,$4,$5,$6,transaction_timestamp(),transaction_timestamp()+interval '15 minutes',$7)")
        .bind(workspace).bind(execution).bind(rule).bind(version).bind(context.config.run_id.to_string()).bind(if dispatching {"RUNNING"} else {"WAITING"}).bind(context.config.user_ids[1]).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    let state = if dispatching {
        "DISPATCHING"
    } else {
        "WAITING"
    };
    sqlx::query("INSERT INTO action_executions(workspace_id,rule_execution_id,action_position,action_execution_id,rule_version_id,state,started_at) VALUES($1,$2,0,$3,$4,$5,transaction_timestamp())")
        .bind(workspace).bind(execution).bind(Uuid::new_v4()).bind(version).bind(if dispatching {"READY"} else {"WAITING"}).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO action_jobs(workspace_id,rule_execution_id,action_position,state,due_at) VALUES($1,$2,0,$3,transaction_timestamp()+interval '30 seconds')")
        .bind(workspace).bind(execution).bind(state).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    transaction
        .commit()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    Ok(execution)
}

/**
 * Suspend A phải cancel WAIT A, giữ WAIT B/global session và dispatch intent A để reconcile.
 * Input
 * Param: context — cùng USER sở hữu work ở cả A/B.
 * Param: before — target revision hiện hành sau alias checks.
 * Param: checks — evidence chỉ thêm khi state/current authority/ticket isolation đúng.
 * Output: snapshot sau resume, giữ grant cũ; lỗi nếu scope lan sang B hoặc giả thu hồi dispatch.
 */
async fn suspension_checks(
    context: &MemberProbe<'_>,
    before: &MembershipSnapshot,
    checks: &mut Vec<&'static str>,
) -> Result<MembershipSnapshot, ApplicationError> {
    let waiting_a = seed_execution(context, context.workspace_a, false).await?;
    let waiting_b = seed_execution(context, context.workspace_b, false).await?;
    let dispatch_a = seed_execution(context, context.workspace_a, true).await?;
    let reverse_lag = command_probe::seed(context, true).await?;
    let unknown_command = command_probe::seed(context, false).await?;
    let ticket_a = context
        .service
        .issue_realtime_ticket(&context.member, context.workspace_a, context.config.run_id)
        .await?;
    let ticket_b = context
        .service
        .issue_realtime_ticket(&context.member, context.workspace_b, context.config.run_id)
        .await?;
    let patch = MembershipPatch {
        status: Some(MembershipStatus::Suspended),
        ..MembershipPatch::default()
    };
    let suspended = context
        .service
        .update_member(
            &context.admin,
            context.workspace_a,
            before.user_id,
            before.revision,
            &patch,
            context.config.run_id,
        )
        .await?;
    if key_state_checks(context, false).await.is_err() {
        checks.push("FAIL: membership suspension permanently revoked a still-valid API key");
        return Err(ApplicationError::Conflict);
    }
    if let Err(failure) = command_probe::assert_preserved(context, reverse_lag, true).await {
        if failure == ApplicationError::Conflict {
            checks.push("FAIL: action dispatch intent was overwritten by cancellation of its lagging command");
        }
        return Err(failure);
    }
    command_probe::assert_preserved(context, unknown_command, false).await?;
    // Đọc state theo cả tenant/execution; A/B dùng cùng owner nhưng quyền được resolve độc lập.
    let state_a: String = sqlx::query_scalar(
        "SELECT state FROM action_jobs WHERE workspace_id=$1 AND rule_execution_id=$2",
    )
    .bind(context.workspace_a)
    .bind(waiting_a)
    .fetch_one(context.pool)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    let state_b: String = sqlx::query_scalar(
        "SELECT state FROM action_jobs WHERE workspace_id=$1 AND rule_execution_id=$2",
    )
    .bind(context.workspace_b)
    .bind(waiting_b)
    .fetch_one(context.pool)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    let inflight:(String,String,String)=sqlx::query_as("SELECT execution.state,job.state,action.state FROM rule_executions execution JOIN action_jobs job USING(workspace_id,rule_execution_id) JOIN action_executions action USING(workspace_id,rule_execution_id,action_position) WHERE execution.workspace_id=$1 AND execution.rule_execution_id=$2")
        .bind(context.workspace_a).bind(dispatch_a).fetch_one(context.pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if state_a != "CANCELLED"
        || state_b != "WAITING"
        || inflight
            != (
                "NEEDS_ATTENTION".to_owned(),
                "DISPATCHING".to_owned(),
                "NEEDS_ATTENTION".to_owned(),
            )
        || !matches!(
            context
                .service
                .admit_workspace(&context.member, context.workspace_a, false)
                .await,
            Err(ApplicationError::Forbidden)
        )
    {
        checks.push("FAIL: lagging action/job state lost the unresolved dispatch obligation");
        return Err(ApplicationError::Conflict);
    }
    context
        .service
        .admit_workspace(&context.member, context.workspace_b, false)
        .await?;
    if !matches!(
        context
            .service
            .consume_realtime_ticket(ticket_a.token.expose())
            .await,
        Err(ApplicationError::Forbidden)
    ) || context
        .service
        .consume_realtime_ticket(ticket_b.token.expose())
        .await?
        .workspace_id
        != context.workspace_b
    {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: membership suspension cancels WAIT/ticket only in A; B/global session remain valid and dispatch intent needs reconciliation");
    resume_checks(context, before, &suspended, checks).await
}

/**
 * Resume kiểm admission hiện hành và giữ grant generation thay vì cấp quyền từ cache trước suspend.
 * Input
 * Param: context — Admin/member/tenant fixture.
 * Param: before — snapshot trước suspend để so generation/auth version.
 * Param: suspended — revision sau suspend để CAS resume.
 * Param: checks — evidence chỉ thêm khi current admission và counter đúng.
 * Output: snapshot resumed hoặc lỗi nếu authority/grant không đúng policy.
 */
async fn resume_checks(
    context: &MemberProbe<'_>,
    before: &MembershipSnapshot,
    suspended: &MembershipSnapshot,
    checks: &mut Vec<&'static str>,
) -> Result<MembershipSnapshot, ApplicationError> {
    key_state_checks(context, false).await?;
    let resume = MembershipPatch {
        status: Some(MembershipStatus::Active),
        ..MembershipPatch::default()
    };
    let resumed = context
        .service
        .update_member(
            &context.admin,
            context.workspace_a,
            before.user_id,
            suspended.revision,
            &resume,
            context.config.run_id,
        )
        .await?;
    context
        .service
        .admit_workspace(&context.member, context.workspace_a, false)
        .await?;
    if resumed.grant_generation != before.grant_generation
        || resumed.authorization_version != before.authorization_version + 2
    {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: resume restores current workspace admission with advanced auth version and unchanged grant");
    Ok(resumed)
}

/**
 * Remove qua use case phải revoke grant, advance email fence và chỉ cho rejoin bằng token mới.
 * Input
 * Param: context — Admin và member cùng global session vẫn sống.
 * Param: before — current member revision/grant sau resume.
 * Param: checks — evidence chỉ thêm sau remove/PATCH denial/new grant đạt.
 * Output: snapshot sau rejoin để tiếp tục kiểm last Admin.
 */
async fn remove_reinvite_checks(
    context: &MemberProbe<'_>,
    before: &MembershipSnapshot,
    checks: &mut Vec<&'static str>,
) -> Result<MembershipSnapshot, ApplicationError> {
    let remove = MembershipPatch {
        status: Some(MembershipStatus::Removed),
        ..MembershipPatch::default()
    };
    let removed = context
        .service
        .update_member(
            &context.admin,
            context.workspace_a,
            before.user_id,
            before.revision,
            &remove,
            context.config.run_id,
        )
        .await?;
    key_state_checks(context, true).await?;
    let resume = MembershipPatch {
        status: Some(MembershipStatus::Active),
        ..MembershipPatch::default()
    };
    if !matches!(
        context
            .service
            .update_member(
                &context.admin,
                context.workspace_a,
                before.user_id,
                removed.revision,
                &resume,
                context.config.run_id
            )
            .await,
        Err(ApplicationError::Conflict)
    ) {
        return Err(ApplicationError::Conflict);
    }
    let invitation = context
        .service
        .create_invitation(
            &context.admin,
            context.workspace_a,
            &context.config.emails[1],
            WorkspaceRole::User,
            &request_key(),
            context.config.run_id,
        )
        .await?;
    context
        .service
        .accept_invitation(
            &context.member,
            invitation.token.ok_or(ApplicationError::Conflict)?.expose(),
            &request_key(),
            context.config.run_id,
        )
        .await?;
    let admission = context
        .service
        .admit_workspace(&context.member, context.workspace_a, false)
        .await?;
    if admission.grant_generation != before.grant_generation + 1 {
        return Err(ApplicationError::Conflict);
    }
    let patch = MembershipPatch {
        alias: AliasChange::Set(None),
        ..MembershipPatch::default()
    };
    let snapshot = context
        .service
        .update_member(
            &context.admin,
            context.workspace_a,
            before.user_id,
            removed.revision + 1,
            &patch,
            context.config.run_id,
        )
        .await?;
    checks.push("PASS: member remove revokes historical grant; PATCH cannot rejoin and new invitation creates the next grant");
    Ok(snapshot)
}

/**
 * Hai Admin đồng thời demote chính mình phải giữ đúng một capable Admin và deny actor vừa mất quyền.
 * Input
 * Param: context — Admin A và member sẽ được promote bằng current Admin.
 * Param: before — revision member sau rejoin.
 * Param: checks — evidence chỉ thêm khi hai-pool race/current authority đều đúng.
 * Output: hoàn thành hoặc lỗi nếu có zero Admin, cả hai thắng hoặc session stale vẫn có quyền Admin.
 */
async fn last_admin_checks(
    context: &MemberProbe<'_>,
    before: &MembershipSnapshot,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let promote = MembershipPatch {
        role: Some(WorkspaceRole::Admin),
        ..MembershipPatch::default()
    };
    let promoted = context
        .service
        .update_member(
            &context.admin,
            context.workspace_a,
            before.user_id,
            before.revision,
            &promote,
            context.config.run_id,
        )
        .await?;
    let other_pool = connect_local_probe(
        context.config.port,
        &context.config.username,
        &context.config.password,
    )
    .await?;
    let other = IdentityService::new(
        PgIdentityStore::new(other_pool.clone()),
        CryptoService::new(PasswordService::default(), context.config.limiter_key).await?,
    );
    let demote = MembershipPatch {
        role: Some(WorkspaceRole::User),
        ..MembershipPatch::default()
    };
    // Fixture invitation trước đó có thể tăng revision của issuer trong tenant được chọn theo UUID.
    // Hai contender phải dùng revision hiện hành; vẫn yêu cầu loser là LastAdminRequired, không chấp nhận stale CAS.
    let admin_revision: i64 = sqlx::query_scalar("SELECT revision FROM memberships WHERE workspace_id=$1 AND user_id=$2 AND role='ADMIN' AND status='ACTIVE'")
        .bind(context.workspace_a).bind(context.config.user_ids[0]).fetch_one(context.pool).await.map_err(|_|ApplicationError::Unavailable)?;
    // Mỗi contender có session/Admin riêng, không thể coi lock actor duy nhất là bằng chứng bảo vệ last Admin.
    let (first, second) = tokio::join!(
        context.service.update_member(
            &context.admin,
            context.workspace_a,
            context.config.user_ids[0],
            admin_revision,
            &demote,
            context.config.run_id
        ),
        other.update_member(
            &context.member,
            context.workspace_a,
            before.user_id,
            promoted.revision,
            &demote,
            context.config.run_id
        )
    );
    let loser_proof = match (&first, &second) {
        (Ok(_), Err(ApplicationError::LastAdminRequired)) => &context.admin,
        (Err(ApplicationError::LastAdminRequired), Ok(_)) => &context.member,
        _ => {
            // Chỉ in loại lỗi application đã lọc để chẩn đoán race; không in snapshot hoặc SQL/credential.
            println!(
                "FAIL:last-admin outcomes={:?}/{:?}",
                first.as_ref().map(|_| ()).map_err(ToString::to_string),
                second.as_ref().map(|_| ()).map_err(ToString::to_string)
            );
            return Err(ApplicationError::Conflict);
        }
    };
    if !matches!(
        context
            .service
            .admit_workspace(loser_proof, context.workspace_a, true)
            .await,
        Err(ApplicationError::Forbidden)
    ) {
        return Err(ApplicationError::Conflict);
    }
    let count:i64=sqlx::query_scalar("SELECT count(*) FROM memberships membership JOIN users account USING(user_id) WHERE membership.workspace_id=$1 AND membership.role='ADMIN' AND membership.status='ACTIVE' AND account.account_status='ACTIVE' AND NOT account.must_change_password")
        .bind(context.workspace_a).fetch_one(context.pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if count != 1 {
        return Err(ApplicationError::Conflict);
    }
    other_pool.close().await;
    checks.push("PASS: two-pool simultaneous Admin demotion keeps one capable Admin and rejects stale actor authority");
    Ok(())
}
