//! Regression uncertainty ba ledger: action/job có thể chậm nhau, command UNKNOWN luôn giữ truth.

use super::MemberProbe;
use iot_platform_backend::application::error::ApplicationError;
use uuid::Uuid;

/**
 * Dựng command bằng các native transition thật, cùng pinned `SET_VALUE` action và parent execution.
 * Input
 * Param: context — fixture device/owner/tenant A, không gửi lệnh ra broker.
 * Param: `reverse_lag` — true tạo action DISPATCHING/job READY/command ADMITTED; false tạo action/job READY/command UNKNOWN.
 * Output: command ID để kiểm truth sau suspend; lỗi fixture đã lọc, không tắt guard hoặc sửa terminal truth.
 */
pub(super) async fn seed(
    context: &MemberProbe<'_>,
    reverse_lag: bool,
) -> Result<Uuid, ApplicationError> {
    let workspace = context.workspace_a;
    let mut transaction = context
        .pool
        .begin()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    let (device,pin):(Uuid,Uuid)=sqlx::query_as("SELECT device_id,template_version_id FROM devices WHERE workspace_id=$1 AND owner_user_id=$2 ORDER BY device_id LIMIT 1")
        .bind(workspace).bind(context.config.user_ids[1]).fetch_one(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    let stream = if reverse_lag { "fan" } else { "fan_secondary" };
    let rule = Uuid::new_v4();
    let version = Uuid::new_v4();
    let execution = Uuid::new_v4();
    let action = Uuid::new_v4();
    let command = Uuid::new_v4();
    // Version/action cùng transaction INSERT; không thay bất kỳ published snapshot sau commit.
    sqlx::query("INSERT INTO rules(workspace_id,rule_id,owner_user_id,name) VALUES($1,$2,$3,'Probe uncertainty')")
        .bind(workspace).bind(rule).bind(context.config.user_ids[1]).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO rule_versions(workspace_id,rule_version_id,rule_id,version_number,trigger_type,trigger_config,condition_ast,cooldown_seconds,priority,on_failure,content_digest) VALUES($1,$2,$3,1,'MANUAL','{}','{\"op\":\"AND\",\"children\":[]}',10,'NORMAL','STOP',$4)")
        .bind(workspace).bind(version).bind(rule).bind([59_u8;32].as_slice()).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO rule_version_actions(workspace_id,rule_version_id,action_position,action_type,target_device_id,target_template_version_id,target_stream_key,target_value) VALUES($1,$2,0,'SET_VALUE',$3,$4,$5,'false')")
        .bind(workspace).bind(version).bind(device).bind(pin).bind(stream).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO rule_executions(workspace_id,rule_execution_id,rule_id,rule_version_id,trigger_key,state,admitted_at,deadline_at,owner_user_id_snapshot) VALUES($1,$2,$3,$4,$5,'RUNNING',transaction_timestamp(),transaction_timestamp()+interval '15 minutes',$6)")
        .bind(workspace).bind(execution).bind(rule).bind(version).bind(context.config.run_id.to_string()).bind(context.config.user_ids[1]).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO action_executions(workspace_id,rule_execution_id,action_position,action_execution_id,rule_version_id,state,started_at,command_id) VALUES($1,$2,0,$3,$4,$5,transaction_timestamp(),$6)")
        .bind(workspace).bind(execution).bind(action).bind(version).bind(if reverse_lag {"DISPATCHING"} else {"READY"}).bind(command).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO action_jobs(workspace_id,rule_execution_id,action_position,state,due_at) VALUES($1,$2,0,'READY',transaction_timestamp())")
        .bind(workspace).bind(execution).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO commands(workspace_id,command_id,device_id,stream_key,origin_type,action_execution_id,value_type,boolean_value,admitted_at,deadline_at,manual_epoch_snapshot) VALUES($1,$2,$3,$4,'AUTOMATION',$5,'BOOLEAN',false,transaction_timestamp()-interval '20 seconds',transaction_timestamp()-interval '10 seconds',0)")
        .bind(workspace).bind(command).bind(device).bind(stream).bind(action).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    if !reverse_lag {
        // Đi đúng ADMITTED→DISPATCHING→TIMED_OUT/UNKNOWN; unresolved actuator giữ nghĩa vụ sau timeout.
        sqlx::query("UPDATE commands SET state='DISPATCHING',dispatch_intent_at=transaction_timestamp()-interval '19 seconds' WHERE workspace_id=$1 AND command_id=$2")
            .bind(workspace).bind(command).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
        sqlx::query("UPDATE commands SET state='TIMED_OUT',outcome='UNKNOWN',terminal_at=transaction_timestamp() WHERE workspace_id=$1 AND command_id=$2")
            .bind(workspace).bind(command).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
        sqlx::query("UPDATE actuator_states SET unresolved_command_id=$3 WHERE workspace_id=$1 AND device_id=$2 AND stream_key='fan_secondary'")
            .bind(workspace).bind(device).bind(command).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    }
    transaction
        .commit()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    Ok(command)
}

/**
 * Kiểm suspend giữ command truth và chuyển lagging action/job/root sang cần đối soát.
 * Input
 * Param: context — tenant/owner fixture vừa suspend.
 * Param: command — identity do seed cấp, không là UUID từ client.
 * Param: `reverse_lag` — chọn expected case action đi trước hoặc command UNKNOWN đi trước.
 * Output: hoàn thành hoặc conflict nếu command bị giả CANCELLED/FAILED hoặc mất unresolved actuator.
 */
pub(super) async fn assert_preserved(
    context: &MemberProbe<'_>,
    command: Uuid,
    reverse_lag: bool,
) -> Result<(), ApplicationError> {
    let state:(String,String,String,String,String,bool)=sqlx::query_as("SELECT command.state,command.outcome,action.state,job.state,execution.state,actuator.unresolved_command_id IS NOT DISTINCT FROM command.command_id FROM commands command JOIN action_executions action ON action.workspace_id=command.workspace_id AND action.action_execution_id=command.action_execution_id JOIN action_jobs job ON (job.workspace_id,job.rule_execution_id,job.action_position)=(action.workspace_id,action.rule_execution_id,action.action_position) JOIN rule_executions execution ON (execution.workspace_id,execution.rule_execution_id)=(action.workspace_id,action.rule_execution_id) JOIN actuator_states actuator ON (actuator.workspace_id,actuator.device_id,actuator.stream_key)=(command.workspace_id,command.device_id,command.stream_key) WHERE command.workspace_id=$1 AND command.command_id=$2")
        .bind(context.workspace_a).bind(command).fetch_one(context.pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let expected = if reverse_lag {
        (
            "ADMITTED",
            "PENDING",
            "DISPATCHING",
            "NEEDS_ATTENTION",
            "NEEDS_ATTENTION",
            false,
        )
    } else {
        (
            "TIMED_OUT",
            "UNKNOWN",
            "NEEDS_ATTENTION",
            "NEEDS_ATTENTION",
            "NEEDS_ATTENTION",
            true,
        )
    };
    if (
        state.0.as_str(),
        state.1.as_str(),
        state.2.as_str(),
        state.3.as_str(),
        state.4.as_str(),
        state.5,
    ) != expected
    {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}
