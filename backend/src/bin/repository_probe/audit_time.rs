//! Regression thời gian audit và quyền đọc tenant inactive; không thay lifecycle production.

use super::{ApplicationError, AuthService, PgPool, ProbeConfig};
use iot_platform_backend::domain::{audit::AuditCursor, identity::SessionProof};
use uuid::Uuid;

/**
 * Kiểm late/future event và stable keyset chỉ dựa ingestion time thay vì event-time không đáng tin.
 * Input
 * Param: service — application/PG adapter thật.
 * Param: proof — current Admin của workspace fixture.
 * Param: pool — role probe được backdate created-at chỉ để tạo history synthetic.
 * Param: config — correlation của lượt chạy để cleanup giữ đúng ownership.
 * Param: workspace — tenant đã current-authorize, không tạo tenant vượt quota.
 * Param: checks — chỉ lưu tên invariant, không audit row hoặc payload.
 * Output: thành công hoặc lỗi đã lọc nếu temporal order/scope sai.
 */
pub(super) async fn verify(
    service: &AuthService,
    proof: &SessionProof,
    pool: &PgPool,
    config: &ProbeConfig,
    workspace: Uuid,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let late = Uuid::new_v4();
    let expired = Uuid::new_v4();
    // Late event mới nhận vẫn thấy; future event có ingestion quá hạn không vượt cutoff.
    for (id, event_days, ingestion_days) in [(late, -90, 0), (expired, 90, -31)] {
        sqlx::query("INSERT INTO audit_events(audit_event_id,workspace_id,event_type,outcome,correlation_id,client_type,occurred_at,created_at) VALUES($1,$2,'AUDIT_TIME_PROBE','SUCCESS',$3,'UNKNOWN',clock_timestamp()+make_interval(days=>$4),clock_timestamp()+make_interval(days=>$5))")
            .bind(id).bind(workspace).bind(config.run_id).bind(event_days).bind(ingestion_days).execute(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    }
    let entries = service.list_audit(proof, workspace, None, 100).await?;
    if !entries.iter().any(|row| {
        row.audit_event_id == late && row.occurred_at < row.created_at - chrono::TimeDelta::days(30)
    }) || entries.iter().any(|row| row.audit_event_id == expired)
    {
        return Err(ApplicationError::Conflict);
    }
    let first = service.list_audit(proof, workspace, None, 1).await?;
    let cursor = AuditCursor {
        created_at: first[0].created_at,
        audit_event_id: first[0].audit_event_id,
    };
    let next = service
        .list_audit(proof, workspace, Some(&cursor), 100)
        .await?;
    if next.iter().any(|row| {
        row.audit_event_id == first[0].audit_event_id
            || (row.created_at, row.audit_event_id) >= (cursor.created_at, cursor.audit_event_id)
    }) {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: audit late/future event-time cannot bypass ingestion retention or created-time keyset");
    inactive_read(service, proof, pool, config, workspace).await?;
    checks.push("PASS: current Admin reads audit in SUSPENDED/ARCHIVED workspace while live workspace admission stays denied");
    Ok(())
}

/**
 * Kiểm route audit allowlisted trên tenant inactive và khôi phục trạng thái fixture sau mỗi phép kiểm.
 * Input
 * Param: service — use case audit/current scope thật trên pool khác với transaction giữ fixture.
 * Param: proof — current Admin cần giữ membership/grant, không cached picker authority.
 * Param: pool — pool fixture, không schema owner.
 * Param: config — provenance tenant do run tạo để không sửa workspace ngoài fixture.
 * Param: workspace — tenant cần test trạng thái và restore ACTIVE sau từng phép kiểm.
 * Output: audit được đọc, live admission bị từ chối; Errors: storage/guard sai.
 */
async fn inactive_read(
    service: &AuthService,
    proof: &SessionProof,
    pool: &PgPool,
    config: &ProbeConfig,
    workspace: Uuid,
) -> Result<(), ApplicationError> {
    for status in ["SUSPENDED", "ARCHIVED"] {
        // Mutation fixture có owner marker và restore ngay; không đại diện workflow archive/physical cleanup đã chạy.
        let changed=sqlx::query("UPDATE workspaces SET status=$2,archived_at=CASE WHEN $2='ARCHIVED' THEN clock_timestamp() ELSE NULL END WHERE workspace_id=$1 AND created_by_user_id=$3")
            .bind(workspace).bind(status).bind(config.user_ids[0]).execute(pool).await.map_err(|_|ApplicationError::Unavailable)?.rows_affected();
        if changed != 1 {
            return Err(ApplicationError::Conflict);
        }
        let audit = service.list_audit(proof, workspace, None, 100).await;
        let live = service.admit_workspace(proof, workspace, true).await;
        sqlx::query("UPDATE workspaces SET status='ACTIVE',archived_at=NULL WHERE workspace_id=$1 AND created_by_user_id=$2")
            .bind(workspace).bind(config.user_ids[0]).execute(pool).await.map_err(|_|ApplicationError::Unavailable)?;
        if audit?.is_empty() || !matches!(live, Err(ApplicationError::Forbidden)) {
            return Err(ApplicationError::Conflict);
        }
    }
    Ok(())
}
