//! Fault/concurrency probe của lease kernel; không mở socket hoặc tuyên bố external side effect đã hoàn tất.

use super::{ApplicationError, PgPool, ProbeConfig};
use iot_platform_backend::{
    application::outbox::CloseOutboxService,
    domain::outbox::{ClaimOptions, ClaimedCloseIntent, CloseConsumer, CloseIntent, RetryDelay},
    postgres::{PgIdentityStore, connection::connect_local_probe},
};
use sqlx::Row;
use uuid::Uuid;

type OutboxService = CloseOutboxService<PgIdentityStore>;

/**
 * Seed một close envelope synthetic, giữ userId trong namespace cleanup của launcher.
 * Input
 * Param: pool — fixture writer tạm, không runtime production.
 * Param: config — user/correlation thuộc run đã preflight DB trống.
 * Param: schema — version1 hợp lệ hoặc version2 cố ý lỗi để kiểm rollback claim.
 * Output: event ID; Side effects: event/consumption atomic, không session/token mới.
 */
async fn seed(pool: &PgPool, config: &ProbeConfig, schema: i32) -> Result<Uuid, ApplicationError> {
    let event = Uuid::new_v4();
    let mut transaction = pool
        .begin()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    // Event key và UUID tổng hợp được bind, payload chỉ identity vô hại dùng kiểm decoder.
    sqlx::query("INSERT INTO outbox_events(outbox_event_id,event_key,event_type,payload_schema_version,payload) VALUES($1,$2,'SESSION_REVOKED',$3,jsonb_build_object('userId',$4::uuid::text,'sessionId',$5::uuid::text))")
        .bind(event).bind(format!("outbox-probe:{}:{event}",config.run_id)).bind(schema).bind(config.user_ids[0]).bind(Uuid::new_v4())
        .execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO outbox_consumptions(outbox_event_id,consumer_code,available_at) VALUES($1,'REALTIME_SESSION_CLOSE',clock_timestamp()-interval '1 second')")
        .bind(event).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    transaction
        .commit()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    Ok(event)
}

/**
 * Cô lập lịch fixture hiện có, không sửa row không thuộc run hoặc dữ liệu ứng dụng thực.
 * Input
 * Param: pool — fixture pool được launcher grant UPDATE riêng trong phase.
 * Param: config — tất cả identity marker của run.
 * Output: thành công nếu toàn bộ event thuộc run; Errors: Conflict khi thấy scope ngoài ownership.
 */
async fn isolate(pool: &PgPool, config: &ProbeConfig) -> Result<(), ApplicationError> {
    // Scoped event thuộc workspace có creator synthetic; global event phải là session revoke của user synthetic.
    let foreign: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM outbox_events event WHERE NOT (EXISTS(SELECT 1 FROM workspaces workspace WHERE workspace.workspace_id=event.workspace_id AND workspace.created_by_user_id=ANY($1)) OR (event.workspace_id IS NULL AND event.event_type='SESSION_REVOKED' AND EXISTS(SELECT 1 FROM users account WHERE account.user_id::text=event.payload->>'userId' AND (account.user_id=ANY($1) OR EXISTS(SELECT 1 FROM audit_events audit WHERE audit.resource_type='USER' AND audit.resource_id=account.user_id::text AND audit.correlation_id=$2 AND audit.event_type='TEMPORARY_ACCOUNT_CREATED'))))))")
        .bind(config.user_ids.as_slice()).bind(config.run_id)
        .fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if foreign {
        return Err(ApplicationError::Conflict);
    }
    // Chỉ lịch fixture của phase bị dời, toàn bộ graph được cleanup ở finally launcher.
    sqlx::query("UPDATE outbox_consumptions SET available_at=clock_timestamp()+interval '1 hour' WHERE state='PENDING'")
        .execute(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    Ok(())
}

/**
 * Đọc state/epoch/attempt để chứng minh không có phantom success khi claim bị rollback.
 * Input
 * Param: pool — fixture reader có quyền outbox.
 * Param: event — event synthetic cụ thể, không selector tùy ý của user.
 * Output: tuple trạng thái riêng session consumer; Errors: Unavailable nếu thiếu row/storage.
 */
async fn state(pool: &PgPool, event: Uuid) -> Result<(String, i64, i32), ApplicationError> {
    let row=sqlx::query("SELECT state,lease_generation,attempt_count FROM outbox_consumptions WHERE outbox_event_id=$1 AND consumer_code='REALTIME_SESSION_CLOSE'")
        .bind(event).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    Ok((
        row.try_get("state")
            .map_err(|_| ApplicationError::Unavailable)?,
        row.try_get("lease_generation")
            .map_err(|_| ApplicationError::Unavailable)?,
        row.try_get("attempt_count")
            .map_err(|_| ApplicationError::Unavailable)?,
    ))
}

/**
 * Lấy đúng một claim cho ca test đã cô lập, không dùng sleep để tạo interleaving giả.
 * Input
 * Param: service — adapter instance được kiểm.
 * Output: một session close claim; Errors: Conflict nếu count không đúng.
 */
async fn claim_one(service: &OutboxService) -> Result<ClaimedCloseIntent, ApplicationError> {
    let mut claims = service
        .claim(
            CloseConsumer::Session,
            ClaimOptions::new(300, 1).ok_or(ApplicationError::Conflict)?,
        )
        .await?;
    if claims.len() != 1 {
        return Err(ApplicationError::Conflict);
    }
    claims.pop().ok_or(ApplicationError::Conflict)
}

/**
 * Hai pool tranh một event; retry/expiry/takeover giữ epoch và không cho worker cũ settle.
 * Input
 * Param: first — service poolA.
 * Param: second — service poolB độc lập.
 * Param: pool — fixture pool chỉ sửa lịch/lease của event test.
 * Param: config — marker sở hữu seed.
 * Output: kiểm thành công hoặc lỗi chặn evidence PASS.
 */
async fn lease_races(
    first: &OutboxService,
    second: &OutboxService,
    pool: &PgPool,
    config: &ProbeConfig,
) -> Result<(), ApplicationError> {
    let event = seed(pool, config, 1).await?;
    let options = ClaimOptions::new(300, 1).ok_or(ApplicationError::Conflict)?;
    let (left, right) = tokio::join!(
        first.claim(CloseConsumer::Session, options),
        second.claim(CloseConsumer::Session, options)
    );
    let mut claims = left?;
    claims.extend(right?);
    if claims.len() != 1 || claims[0].receipt.event_id() != event || claims[0].attempt_count != 1 {
        return Err(ApplicationError::Conflict);
    }
    let original = claims[0].receipt;
    if !first
        .retry(
            original,
            RetryDelay::new(300).ok_or(ApplicationError::Conflict)?,
        )
        .await?
        || second.complete(original).await?
        || second
            .retry(
                original,
                RetryDelay::new(1).ok_or(ApplicationError::Conflict)?,
            )
            .await?
        || !second
            .claim(CloseConsumer::Session, options)
            .await?
            .is_empty()
    {
        return Err(ApplicationError::Conflict);
    }
    // Rút ngắn clock fixture có chủ đích, không đổi generation/attempt; không cần chờ300 giây.
    sqlx::query("UPDATE outbox_consumptions SET available_at=clock_timestamp()-interval '1 second' WHERE outbox_event_id=$1 AND consumer_code='REALTIME_SESSION_CLOSE'")
        .bind(event).execute(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let renewed = claim_one(second).await?;
    if renewed.receipt.generation() != 2 || renewed.attempt_count != 2 {
        return Err(ApplicationError::Conflict);
    }
    sqlx::query("UPDATE outbox_consumptions SET lease_until=clock_timestamp()-interval '1 second' WHERE outbox_event_id=$1 AND consumer_code='REALTIME_SESSION_CLOSE'")
        .bind(event).execute(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if first.complete(renewed.receipt).await?
        || first
            .retry(
                renewed.receipt,
                RetryDelay::new(1).ok_or(ApplicationError::Conflict)?,
            )
            .await?
    {
        return Err(ApplicationError::Conflict);
    }
    let takeover = claim_one(first).await?;
    if takeover.receipt.generation() != 3
        || takeover.attempt_count != 3
        || second.complete(renewed.receipt).await?
    {
        return Err(ApplicationError::Conflict);
    }
    let (left, right) = tokio::join!(
        first.complete(takeover.receipt),
        second.complete(takeover.receipt)
    );
    if u8::from(left?) + u8::from(right?) != 1
        || state(pool, event).await? != ("COMPLETED".into(), 3, 3)
        || !first
            .claim(CloseConsumer::Session, options)
            .await?
            .is_empty()
    {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}

/**
 * Giữ row lock để chứng minh `SKIP LOCKED` tiến triển; rollback native claim không tiêu hao epoch.
 * Input
 * Param: service — service đã nối pool riêng với fixture lock.
 * Param: pool — fixture pool giữ transaction/row lock.
 * Param: config — seed marker.
 * Output: thành công khi event khóa được giữ và event khác xử lý độc lập.
 */
async fn locks_and_rollback(
    service: &OutboxService,
    pool: &PgPool,
    config: &ProbeConfig,
) -> Result<(), ApplicationError> {
    let locked = seed(pool, config, 1).await?;
    let mut held = pool
        .begin()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    sqlx::query("SELECT 1 FROM outbox_consumptions WHERE outbox_event_id=$1 FOR UPDATE")
        .bind(locked)
        .execute(&mut *held)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    let free = seed(pool, config, 1).await?;
    let claim = claim_one(service).await?;
    if claim.receipt.event_id() != free || !service.complete(claim.receipt).await? {
        return Err(ApplicationError::Conflict);
    }
    held.rollback()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    let mut abandoned = pool
        .begin()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    // Mô phỏng crash trước COMMIT của native operation; không mất nghĩa vụ hoặc tăng attempt durable.
    sqlx::query("SELECT * FROM public.claim_outbox('REALTIME_SESSION_CLOSE',300,1)")
        .fetch_all(&mut *abandoned)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    abandoned
        .rollback()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    if state(pool, locked).await? != ("PENDING".into(), 0, 0) {
        return Err(ApplicationError::Conflict);
    }
    let claim = claim_one(service).await?;
    if claim.receipt.event_id() != locked || !service.complete(claim.receipt).await? {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}

/**
 * Kiểm strict decoder rollback và scoped consumer không chạm pipeline reconcile cùng event.
 * Input
 * Param: service — worker kernel đã nối store thật.
 * Param: pool — fixture pool.
 * Param: config — ownership marker.
 * Output: thành công hoặc lỗi nếu claim sai scope/version/consumer.
 */
async fn payload_and_scope(
    service: &OutboxService,
    pool: &PgPool,
    config: &ProbeConfig,
) -> Result<(), ApplicationError> {
    let malformed = seed(pool, config, 2).await?;
    if !matches!(
        service
            .claim(
                CloseConsumer::Session,
                ClaimOptions::new(300, 1).ok_or(ApplicationError::Conflict)?
            )
            .await,
        Err(ApplicationError::Unavailable)
    ) || state(pool, malformed).await? != ("PENDING".into(), 0, 0)
    {
        return Err(ApplicationError::Conflict);
    }
    // Một scoped event producer thật có hai consumer độc lập; chỉ mở lịch close, giữ reconcile không đổi.
    let row=sqlx::query("SELECT event.outbox_event_id,event.workspace_id FROM outbox_events event JOIN outbox_consumptions consumption USING(outbox_event_id) WHERE event.event_type='MEMBERSHIP_AUTHORITY_CHANGED' AND consumption.consumer_code='REALTIME_WORKSPACE_CLOSE' ORDER BY event.created_at DESC LIMIT 1")
        .fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let event: Uuid = row
        .try_get("outbox_event_id")
        .map_err(|_| ApplicationError::Unavailable)?;
    let workspace: Uuid = row
        .try_get("workspace_id")
        .map_err(|_| ApplicationError::Unavailable)?;
    sqlx::query("UPDATE outbox_consumptions SET available_at=clock_timestamp()-interval '1 second' WHERE outbox_event_id=$1 AND consumer_code='REALTIME_WORKSPACE_CLOSE'")
        .bind(event).execute(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let claims = service
        .claim(
            CloseConsumer::Workspace,
            ClaimOptions::new(300, 1).ok_or(ApplicationError::Conflict)?,
        )
        .await?;
    if claims.len() != 1
        || !matches!(claims[0].intent,CloseIntent::Workspace{workspace_id,..} if workspace_id==workspace)
        || !service.complete(claims[0].receipt).await?
    {
        return Err(ApplicationError::Conflict);
    }
    let untouched:bool=sqlx::query_scalar("SELECT state='PENDING' AND lease_generation=0 AND attempt_count=0 FROM outbox_consumptions WHERE outbox_event_id=$1 AND consumer_code='WORKSPACE_PRINCIPAL_RECONCILE'")
        .bind(event).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !untouched {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}

/**
 * Chờ worker thực sự bị khóa chặn rồi giữ row qua deadline để bắt clock-before-lock race.
 * Input
 * Param: pool — observer cùng login, chỉ xem backend của chính login probe.
 * Param: held — transaction fixture giữ consumption lock, rollback sau deadline.
 * Output: thành công sau release; Errors: Conflict nếu không thấy contention thật trong2 giây.
 */
async fn release_after_expiry(
    pool: &PgPool,
    mut held: sqlx::Transaction<'_, sqlx::Postgres>,
) -> Result<(), ApplicationError> {
    tokio::time::timeout(std::time::Duration::from_secs(2),async {
        loop {
            // pg_blocking_pids chứng minh wait thật; không đoán rằng task đã bắt đầu UPDATE.
            let blocked:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE usename=current_user AND cardinality(pg_blocking_pids(pid))>0)")
                .fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
            if blocked { break Ok::<(),ApplicationError>(()); }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    }).await.map_err(|_|ApplicationError::Conflict)??;
    // Lease fixture2s bắt đầu trước khóa; giữ thêm2.1s bảo đảm expiry trước rollback locker.
    sqlx::query("SELECT pg_sleep(2.1)")
        .execute(&mut *held)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    held.rollback()
        .await
        .map_err(|_| ApplicationError::Unavailable)
}

/**
 * Complete/retry phải kiểm clock sau lock, kể cả locker rollback không thay tuple.
 * Input
 * Param: service — worker pool riêng với transaction giữ lock.
 * Param: pool — fixture writer/observer.
 * Param: config — seed marker thuộc run.
 * Output: cả hai settle false sau chờ qua deadline, nghĩa vụ còn để takeover.
 */
async fn expiry_during_lock(
    service: &OutboxService,
    pool: &PgPool,
    config: &ProbeConfig,
) -> Result<(), ApplicationError> {
    for retry in [false, true] {
        let event = seed(pool, config, 1).await?;
        let claim = claim_one(service).await?;
        sqlx::query("UPDATE outbox_consumptions SET lease_until=clock_timestamp()+interval '2 seconds' WHERE outbox_event_id=$1")
            .bind(event).execute(pool).await.map_err(|_|ApplicationError::Unavailable)?;
        let mut held = pool
            .begin()
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        sqlx::query("SELECT 1 FROM outbox_consumptions WHERE outbox_event_id=$1 FOR UPDATE")
            .bind(event)
            .execute(&mut *held)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let settle = async {
            if retry {
                service
                    .retry(
                        claim.receipt,
                        RetryDelay::new(1).ok_or(ApplicationError::Conflict)?,
                    )
                    .await
            } else {
                service.complete(claim.receipt).await
            }
        };
        let (settled, released) = tokio::join!(settle, release_after_expiry(pool, held));
        released?;
        if settled? {
            return Err(ApplicationError::Conflict);
        }
        // Nghĩa vụ expired vẫn có thể takeover; giữ cùng identity và dọn trước ca tiếp theo.
        let takeover = claim_one(service).await?;
        if takeover.receipt.event_id() != event || !service.complete(takeover.receipt).await? {
            return Err(ApplicationError::Conflict);
        }
    }
    Ok(())
}

/**
 * Chạy repository kernel qua hai pool; không đồng nhất success của ledger với socket đóng thật.
 * Input
 * Param: config — gateway/credential tạm qua stdin và fixture namespace.
 * Param: checks — chỉ tên invariant, không raw payload/credential.
 * Output: sáu check kernel hoặc lỗi chặn PASS; launcher luôn cleanup graph/grants ở finally.
 */
pub(super) async fn verify(
    config: ProbeConfig,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let pool = connect_local_probe(config.port, &config.username, &config.password).await?;
    let other = connect_local_probe(config.port, &config.username, &config.password).await?;
    isolate(&pool, &config).await?;
    let first = OutboxService::new(PgIdentityStore::new(pool.clone()));
    let second = OutboxService::new(PgIdentityStore::new(other.clone()));
    lease_races(&first, &second, &pool, &config).await?;
    checks.push("PASS: two pools produce one outbox lease winner and one completion winner");
    checks.push(
        "PASS: retry delay, expiry, takeover and stale lease fencing preserve attempts and epoch",
    );
    expiry_during_lock(&second, &pool, &config).await?;
    checks.push(
        "PASS: complete and retry recheck lease clock after waiting for a rolled-back row lock",
    );
    locks_and_rollback(&first, &pool, &config).await?;
    checks.push("PASS: outbox SKIP LOCKED progresses and uncommitted claim rolls back generation and attempt");
    payload_and_scope(&first, &pool, &config).await?;
    checks.push("PASS: unsupported payload version rolls back outbox claim before dispatch");
    checks
        .push("PASS: workspace close preserves scope and leaves reconciliation consumer untouched");
    pool.close().await;
    other.close().await;
    Ok(())
}
