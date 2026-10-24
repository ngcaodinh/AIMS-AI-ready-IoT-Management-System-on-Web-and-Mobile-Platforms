//! Purge probe chỉ chạy sau preflight DB trống; worker role riêng không inherit quyền fixture/app.

use super::{ApplicationError, PgPool, ProbeConfig};
use chrono::{DateTime, TimeDelta, Utc};
use iot_platform_backend::{
    application::audit_retention::AuditRetentionService,
    postgres::{
        PgIdentityStore,
        connection::{connect_local_probe, connect_local_retention_probe},
    },
};
use uuid::Uuid;

type RetentionService = AuditRetentionService<PgIdentityStore>;

/// Metadata fixture không chứa token/verifier; session/ticket chỉ dùng kiểm FK và không được consume.
struct References {
    session_id: Uuid,
    ticket_id: Uuid,
    binding_generation: i64,
    boundary_id: Uuid,
}

/**
 * Chặn purge test nếu có row ngoài correlation synthetic dù launcher đã preflight trống.
 * Input
 * Param: pool — pool fixture đọc count, không in audit row.
 * Param: config — correlation sở hữu của lượt chạy.
 * Output: thành công khi toàn bộ audit thuộc fixture; Errors: Conflict bảo toàn dữ liệu lạ.
 */
async fn assert_owned(pool: &PgPool, config: &ProbeConfig) -> Result<(), ApplicationError> {
    let foreign: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM audit_events WHERE correlation_id<>$1)")
            .bind(config.run_id)
            .fetch_one(pool)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
    if foreign {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}

/**
 * Seed audit quá hạn cùng expired session, ticket/binding và row đúng cutoff để kiểm dependency graph.
 * Input
 * Param: pool — role fixture, không là pool worker.
 * Param: config — User/workspace/installation synthetic đã thuộc run hiện hành.
 * Param: cutoff — cutoff durable của run cần kiểm.
 * Output: IDs/binding generation, không chứa credential hoặc audit payload.
 */
async fn seed(
    pool: &PgPool,
    config: &ProbeConfig,
    cutoff: DateTime<Utc>,
) -> Result<References, ApplicationError> {
    let session_id = Uuid::new_v4();
    let ticket_id = Uuid::new_v4();
    let boundary_id = Uuid::new_v4();
    let mut transaction = pool
        .begin()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    // Remnant storage hợp lệ schema, không giả rằng API cho bind/issue bằng session đã expired.
    sqlx::query("INSERT INTO sessions(session_id,user_id,token_digest,auth_context_id,limited,client_type,issued_at,expires_at) VALUES($1,$2,$3,$4,false,'ANDROID',transaction_timestamp()-interval '25 hours',transaction_timestamp()-interval '1 hour')")
        .bind(session_id).bind(config.user_ids[0]).bind(rand::random::<[u8;32]>().as_slice()).bind(Uuid::new_v4()).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO websocket_tickets(ticket_id,ticket_digest,workspace_id,user_id,session_id,grant_generation,workspace_authorization_version,membership_authorization_version,issued_at,expires_at) SELECT $1,$2,workspace.workspace_id,$3,$4,member.current_grant_generation,workspace.authorization_version,member.authorization_version,transaction_timestamp()-interval '1 minute',transaction_timestamp()-interval '30 seconds' FROM workspaces workspace JOIN memberships member USING(workspace_id) WHERE member.user_id=$3 AND member.status='ACTIVE' ORDER BY workspace.workspace_id LIMIT 1")
        .bind(ticket_id).bind(rand::random::<[u8;32]>().as_slice()).bind(config.user_ids[0]).bind(session_id).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    let binding_generation=sqlx::query_scalar("UPDATE push_installations SET active_user_id=$2,active_session_id=$3,binding_generation=binding_generation+1,enabled=false WHERE installation_id=$1 AND app_version=$4 RETURNING binding_generation")
        .bind(config.run_id).bind(config.user_ids[0]).bind(session_id).bind(format!("REPOSITORY_PROBE:{}",config.run_id)).fetch_one(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    // Ba row expired chung session lớn hơn batch2; đúng cutoff và sau cutoff phải được giữ qua purge.
    for offset in [-3, -2, -1, 0, 1] {
        let id = if offset == 0 {
            boundary_id
        } else {
            Uuid::new_v4()
        };
        sqlx::query("INSERT INTO audit_events(audit_event_id,actor_user_id,session_id,event_type,outcome,correlation_id,client_type,created_at) VALUES($1,$2,$3,'RETENTION_PROBE','SUCCESS',$4,'UNKNOWN',$5)")
            .bind(id).bind(config.user_ids[0]).bind(session_id).bind(config.run_id).bind(cutoff+TimeDelta::microseconds(offset)).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    }
    transaction
        .commit()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    Ok(References {
        session_id,
        ticket_id,
        binding_generation,
        boundary_id,
    })
}

/**
 * Đếm audit expired để đối chiếu DELETE thực; không đọc body hoặc subject của row.
 * Input
 * Param: pool — pool fixture hoặc worker có SELECT audit.
 * Param: cutoff — cutoff cố định, không tính lại now qua các batch.
 * Output: số row trước cutoff.
 */
async fn expired_count(pool: &PgPool, cutoff: DateTime<Utc>) -> Result<i64, ApplicationError> {
    sqlx::query_scalar("SELECT count(*) FROM audit_events WHERE created_at<$1")
        .bind(cutoff)
        .fetch_one(pool)
        .await
        .map_err(|_| ApplicationError::Unavailable)
}

/**
 * Kiểm worker có quyền row lock cần thiết nhưng không được rewrite payload hoặc đọc IAM.
 * Input
 * Param: worker — connection đã SET ROLE NOLOGIN cố định, không owner/broad app grants.
 * Param: correlation — chỉ chọn audit synthetic của run hiện hành để thử immutable guard.
 * Output: thành công nếu đúng privilege set; Errors: Conflict khi quyền quá rộng hoặc thiếu.
 */
async fn worker_acl(worker: &PgPool, correlation: Uuid) -> Result<(), ApplicationError> {
    let valid:bool=sqlx::query_scalar("SELECT current_user='iot_audit_retention_probe' AND has_table_privilege(current_user,'audit_events','DELETE') AND has_column_privilege(current_user,'audit_events','audit_event_id','UPDATE') AND NOT has_column_privilege(current_user,'audit_events','outcome','UPDATE') AND NOT has_column_privilege(current_user,'audit_events','created_at','UPDATE') AND NOT has_table_privilege(current_user,'users','SELECT') AND NOT has_table_privilege(current_user,'sessions','DELETE') AND NOT has_table_privilege(current_user,'audit_retention_runs','UPDATE')")
        .fetch_one(worker).await.map_err(|_|ApplicationError::Unavailable)?;
    if !valid {
        return Err(ApplicationError::Conflict);
    }
    // Quyền UPDATE ID dùng cho row lock không được cho sửa identity thực; kiểm trigger dưới chính worker role.
    let audit_id: Uuid = sqlx::query_scalar(
        "SELECT audit_event_id FROM audit_events WHERE correlation_id=$1 LIMIT 1",
    )
    .bind(correlation)
    .fetch_one(worker)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    let rewrite = sqlx::query("UPDATE audit_events SET audit_event_id=$2 WHERE audit_event_id=$1")
        .bind(audit_id)
        .bind(Uuid::new_v4())
        .execute(worker)
        .await;
    if !rewrite.err().is_some_and(|error| {
        error
            .as_database_error()
            .and_then(sqlx::error::DatabaseError::code)
            .as_deref()
            == Some("23514")
    }) {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}

/**
 * Chứng minh hai worker retry cùng batch chỉ DELETE một lần và skip audit đang bị khóa thật.
 * Input
 * Param: first — worker service/pool A.
 * Param: second — worker service/pool B độc lập.
 * Param: worker — pool A giữ một row lock riêng để tạo contention xác định.
 * Param: fixture — pool đọc committed count.
 * Param: `run_id` — cùng run durable.
 * Param: cutoff — cutoff snapshot chung.
 * Output: batch ID đã commit; Errors: Conflict nếu mất count/duplicate hoặc không SKIP LOCKED.
 */
async fn concurrent_batch(
    first: &RetentionService,
    second: &RetentionService,
    worker: &PgPool,
    fixture: &PgPool,
    run_id: Uuid,
    cutoff: DateTime<Utc>,
) -> Result<Uuid, ApplicationError> {
    let before = expired_count(fixture, cutoff).await?;
    if before <= 2 {
        return Err(ApplicationError::Conflict);
    }
    let mut holder = worker
        .begin()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    let held:Uuid=sqlx::query_scalar("SELECT audit_event_id FROM audit_events WHERE created_at<$1 ORDER BY created_at,audit_event_id LIMIT 1 FOR UPDATE")
        .bind(cutoff).fetch_one(&mut *holder).await.map_err(|_|ApplicationError::Unavailable)?;
    let batch_id = Uuid::new_v4();
    let (left, right) = tokio::join!(
        first.purge_batch(run_id, batch_id, 2),
        second.purge_batch(run_id, batch_id, 2)
    );
    let left = left?;
    let right = right?;
    let kept: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM audit_events WHERE audit_event_id=$1)")
            .bind(held)
            .fetch_one(fixture)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
    if left.removed_count != 2
        || right.removed_count != 2
        || left.completed_at != right.completed_at
        || !kept
        || expired_count(fixture, cutoff).await? != before - 2
    {
        return Err(ApplicationError::Conflict);
    }
    holder
        .rollback()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    Ok(batch_id)
}

/**
 * Kiểm purge vẫn tiến triển trong khi session/ticket/binding và exact-cutoff audit cần được giữ.
 * Input
 * Param: pool — fixture pool đọc boolean không PII.
 * Param: config — User/installation marker của run.
 * Param: references — IDs/binding generation phải giữ sau audit purge.
 * Output: thành công nếu FK graph không bị cascade hoặc xóa theo session expiry.
 */
async fn assert_references(
    pool: &PgPool,
    config: &ProbeConfig,
    references: &References,
) -> Result<(), ApplicationError> {
    let kept:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sessions WHERE session_id=$1 AND expires_at<=clock_timestamp()) AND EXISTS(SELECT 1 FROM websocket_tickets WHERE ticket_id=$2 AND session_id=$1) AND EXISTS(SELECT 1 FROM push_installations WHERE installation_id=$3 AND active_session_id=$1 AND binding_generation=$4) AND EXISTS(SELECT 1 FROM audit_events WHERE audit_event_id=$5 AND session_id=$1)")
        .bind(references.session_id).bind(references.ticket_id).bind(config.run_id).bind(references.binding_generation).bind(references.boundary_id).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !kept {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}

/**
 * Chạy positive/race/replay/cutoff probe bằng worker role riêng và dữ liệu đã chứng minh sở hữu.
 * Input
 * Param: config — gateway/role credential qua stdin và marker không secret.
 * Param: checks — chỉ tên invariant sau khi đạt, không dump audit rows.
 * Output: checks retention đã commit; Errors: lỗi đã lọc, launcher cleanup graph sau mọi failure.
 */
pub(super) async fn verify(
    config: ProbeConfig,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let fixture = connect_local_probe(config.port, &config.username, &config.password).await?;
    assert_owned(&fixture, &config).await?;
    let worker =
        connect_local_retention_probe(config.port, &config.username, &config.password).await?;
    let other =
        connect_local_retention_probe(config.port, &config.username, &config.password).await?;
    worker_acl(&worker, config.run_id).await?;
    checks.push("PASS: retention uses separate NOLOGIN worker role with only ID row-lock privilege and no IAM/payload UPDATE");
    let first = AuditRetentionService::new(PgIdentityStore::new(worker.clone()));
    let second = AuditRetentionService::new(PgIdentityStore::new(other.clone()));
    let run = first.start_run(config.run_id).await?;
    let resumed = second.start_run(config.run_id).await?;
    if resumed.cutoff() != run.cutoff() {
        return Err(ApplicationError::Conflict);
    }
    let references = seed(&fixture, &config, run.cutoff()).await?;
    let before = expired_count(&fixture, run.cutoff()).await?;
    let batch = concurrent_batch(
        &first,
        &second,
        &worker,
        &fixture,
        config.run_id,
        run.cutoff(),
    )
    .await?;
    assert_references(&fixture, &config, &references).await?;
    checks.push("PASS: two retention pools process one batch once, skip a held row and preserve session/ticket/binding references");
    if !matches!(
        first.purge_batch(config.run_id, batch, 3).await,
        Err(ApplicationError::Conflict)
    ) || !matches!(
        first.purge_batch(config.run_id, Uuid::new_v4(), 0).await,
        Err(ApplicationError::InvalidInput)
    ) {
        return Err(ApplicationError::Conflict);
    }
    let other_run = second.start_run(config.user_ids[4]).await?;
    if !matches!(
        second.purge_batch(other_run.run_id(), batch, 2).await,
        Err(ApplicationError::Conflict)
    ) {
        return Err(ApplicationError::Conflict);
    }
    let replay = second.purge_batch(config.run_id, batch, 2).await?;
    let next = second
        .purge_batch(config.run_id, Uuid::new_v4(), 1000)
        .await?;
    if replay.removed_count != 2
        || i64::from(next.removed_count) + 2 != before
        || expired_count(&fixture, run.cutoff()).await? != 0
    {
        return Err(ApplicationError::Conflict);
    }
    assert_references(&fixture, &config, &references).await?;
    checks.push("PASS: retention restart preserves cutoff, replay rejects changed run/limit and next batch keeps exact-cutoff rows");
    let zero = first.purge_batch(config.run_id, Uuid::new_v4(), 1).await?;
    let total: i64 = sqlx::query_scalar(
        "SELECT sum(removed_count)::bigint FROM audit_retention_batches WHERE run_id=$1",
    )
    .bind(config.run_id)
    .fetch_one(&worker)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    if zero.removed_count != 0 || total != before {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: retention batch metadata reports only committed DELETE counts including zero-work batch");
    fixture.close().await;
    worker.close().await;
    other.close().await;
    Ok(())
}

/**
 * Fault metadata INSERT thật phải rollback audit DELETE, giữ batch intent chưa có result để retry cùng ID.
 * Input
 * Param: config — launcher đã REVOKE INSERT batch ledger chỉ trên worker role sở hữu.
 * Param: checks — tên check không chứa row/credential.
 * Output: thành công khi audit/count/result không partial; Errors: lỗi đã lọc.
 */
pub(super) async fn verify_failure(
    config: ProbeConfig,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let fixture = connect_local_probe(config.port, &config.username, &config.password).await?;
    assert_owned(&fixture, &config).await?;
    let worker =
        connect_local_retention_probe(config.port, &config.username, &config.password).await?;
    let service = AuditRetentionService::new(PgIdentityStore::new(worker.clone()));
    let run = service.start_run(config.run_id).await?;
    // Chỉ thêm audit tổng hợp vào trước cutoff; không chạm row ngoài correlation đã preflight.
    for _ in 0..2 {
        sqlx::query("INSERT INTO audit_events(audit_event_id,event_type,outcome,correlation_id,client_type,created_at) VALUES($1,'RETENTION_FAULT_PROBE','SUCCESS',$2,'UNKNOWN',$3)")
            .bind(Uuid::new_v4()).bind(config.run_id).bind(run.cutoff()-TimeDelta::seconds(1)).execute(&fixture).await.map_err(|_|ApplicationError::Unavailable)?;
    }
    let before = expired_count(&fixture, run.cutoff()).await?;
    let batch = Uuid::new_v4();
    if !matches!(
        service.purge_batch(config.run_id, batch, 2).await,
        Err(ApplicationError::Unavailable)
    ) || expired_count(&fixture, run.cutoff()).await? != before
    {
        return Err(ApplicationError::Conflict);
    }
    let absent: bool = sqlx::query_scalar(
        "SELECT NOT EXISTS(SELECT 1 FROM audit_retention_batches WHERE batch_id=$1)",
    )
    .bind(batch)
    .fetch_one(&worker)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    if !absent {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: PostgreSQL batch-result INSERT denial rolls back audit DELETE and leaves no partial retention receipt");
    fixture.close().await;
    worker.close().await;
    Ok(())
}
