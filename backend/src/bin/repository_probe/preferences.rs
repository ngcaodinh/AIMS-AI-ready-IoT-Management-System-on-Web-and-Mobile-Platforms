//! Preference probe dùng session synthetic có marker và application/SQLx thật, không dùng env hoặc owner.

use super::{ApplicationError, AuthService, PgIdentityStore, PgPool, ProbeConfig};
use iot_platform_backend::{
    adapters::security::{CryptoService, PasswordService, generate_token},
    domain::{identity::SessionProof, preferences::DisplayTimezone},
    postgres::connection::connect_local_probe,
};
use uuid::Uuid;

/**
 * Dựng proof fixture cho account thuộc đúng marker, không giả làm login acceptance.
 * Input
 * Param: service — crypto port thật để digest token sinh ngẫu nhiên trong bộ nhớ.
 * Param: pool — writer fixture hẹp, không role owner/runtime production.
 * Param: `user_id` — chỉ account synthetic đã được caller kiểm marker.
 * Param: limited — snapshot giới hạn tương ứng account tạm của fixture.
 * Output: Web proof/context mới; Errors: storage đã lọc, không in raw token.
 */
pub(super) async fn seed_session(
    service: &AuthService,
    pool: &PgPool,
    user_id: Uuid,
    limited: bool,
) -> Result<SessionProof, ApplicationError> {
    let token = generate_token();
    let context = Uuid::new_v4();
    let proof = service.session_proof(token.expose(), Some(context));
    // UUID/token đều thuộc fixture, mọi value bind; context Web chỉ được dùng với proof đúng.
    sqlx::query("INSERT INTO sessions(session_id,user_id,token_digest,auth_context_id,limited,client_type,issued_at,expires_at) VALUES($1,$2,$3,$4,$5,'WEB',statement_timestamp(),statement_timestamp()+interval '24 hours')").bind(Uuid::new_v4()).bind(user_id).bind(proof.token_digest.as_slice()).bind(context).bind(limited).execute(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    Ok(proof)
}

/**
 * Kiểm legacy default, CAS hai pool, self scope và negative session/timezone bằng DB thật.
 * Input
 * Param: config — transport tạm và identity/correlation của run.
 * Param: checks — evidence chỉ thêm sau invariant đã đạt.
 * Output: đóng pool sau kiểm; Errors: invariant/storage đã lọc.
 */
pub(super) async fn verify(
    config: ProbeConfig,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let pool = connect_local_probe(config.port, &config.username, &config.password).await?;
    let second_pool = connect_local_probe(config.port, &config.username, &config.password).await?;
    let crypto = CryptoService::new(PasswordService::default(), config.limiter_key).await?;
    let first = AuthService::new(PgIdentityStore::new(pool.clone()), crypto.clone());
    let second = AuthService::new(PgIdentityStore::new(second_pool.clone()), crypto);
    // Không mint session cho identity lạ, kể cả test role có INSERT.
    let owned:bool=sqlx::query_scalar("SELECT count(*)=2 FROM users WHERE user_id=ANY($1) AND activation_provenance=$2 AND account_status='ACTIVE' AND NOT must_change_password").bind(&config.user_ids[..2]).bind(format!("REPOSITORY_PROBE:{}",config.run_id)).fetch_one(&pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !owned {
        return Err(ApplicationError::Conflict);
    }
    let proof = seed_session(&first, &pool, config.user_ids[0], false).await?;
    let other = seed_session(&first, &pool, config.user_ids[1], false).await?;
    let default = first.get_preferences(&proof).await?;
    let untouched = first.get_preferences(&other).await?;
    // GET default phải không tạo row hoặc làm tăng revision ngầm.
    let rows: i64 =
        sqlx::query_scalar("SELECT count(*) FROM user_preferences WHERE user_id=ANY($1)")
            .bind(&config.user_ids[..2])
            .fetch_one(&pool)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
    if default.revision != 1
        || default.display_timezone != "UTC"
        || untouched.revision != 1
        || untouched.display_timezone != "UTC"
        || rows != 0
    {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: legacy own-account preferences read UTC/revision1 without creating rows or altering another account");
    verify_cas(&first, &second, &pool, &config, &proof, &other).await?;
    checks.push("PASS: two-pool preference CAS has one winner, one stale revision and one redacted global audit");
    verify_denials(&first, &pool, &config, &proof, &other).await?;
    checks.push("PASS: invalid IANA/context and limited preference requests are denied; stale legacy update creates no row and other account stays unchanged");
    pool.close().await;
    second_pool.close().await;
    Ok(())
}

/**
 * Tranh cùng preference revision qua hai pool và đối chiếu audit cũng như WAIT instant bất biến.
 * Input
 * Param: first — instance A cập nhật timezone cá nhân.
 * Param: second — instance B cạnh tranh cùng expected revision.
 * Param: pool — đọc metadata fixture độc lập transaction mutation.
 * Param: config — owner/correlation của namespace synthetic.
 * Param: proof — current full principal account0.
 * Param: other — full principal account1 cần giữ default riêng.
 * Output: một revision2, một stale, audit1 và dueAt không đổi; Errors: Conflict/storage.
 */
async fn verify_cas(
    first: &AuthService,
    second: &AuthService,
    pool: &PgPool,
    config: &ProbeConfig,
    proof: &SessionProof,
    other: &SessionProof,
) -> Result<(), ApplicationError> {
    // WAIT fixture đã có từ membership suite; chụp ID/instant để preference không sửa thời gian nghiệp vụ.
    let before:String=sqlx::query_scalar("SELECT coalesce(jsonb_agg(jsonb_build_array(workspace_id,rule_execution_id,action_position,due_at) ORDER BY workspace_id,rule_execution_id,action_position),'[]'::jsonb)::text FROM action_jobs WHERE due_at IS NOT NULL AND workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id=ANY($1))").bind(&config.user_ids[..]).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if before == "[]" {
        return Err(ApplicationError::Conflict);
    }
    let local = DisplayTimezone::new("Asia/Ho_Chi_Minh").ok_or(ApplicationError::InvalidInput)?;
    let utc = DisplayTimezone::new("UTC").ok_or(ApplicationError::InvalidInput)?;
    let (left, right) = tokio::join!(
        first.update_preferences(proof, &local, 1, config.run_id),
        second.update_preferences(proof, &utc, 1, config.run_id)
    );
    let ((Ok(winner), Err(ApplicationError::StaleRevision))
    | (Err(ApplicationError::StaleRevision), Ok(winner))) = (left, right)
    else {
        return Err(ApplicationError::Conflict);
    };
    let current = first.get_preferences(proof).await?;
    let untouched = first.get_preferences(other).await?;
    // Scope theo principal trong port, không nhận userId đích từ HTTP body hoặc Admin.
    let audit:bool=sqlx::query_scalar("SELECT count(*)=1 AND bool_and(workspace_id IS NULL AND resource_type='USER' AND resource_id=$1::uuid::text AND redacted_diff->>'revision_before'='1' AND redacted_diff->>'revision_after'='2' AND NOT EXISTS(SELECT 1 FROM jsonb_object_keys(redacted_diff) key WHERE key NOT IN('schema_version','phase','result','actor_type','revision_before','revision_after','timezone_changed'))) FROM audit_events WHERE actor_user_id=$1 AND correlation_id=$2 AND event_type='PREFERENCES_CHANGED'").bind(config.user_ids[0]).bind(config.run_id).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    // So lại full composite key/instant của đúng workspace fixture, không dùng surrogate ID không có trong schema.
    let after:String=sqlx::query_scalar("SELECT coalesce(jsonb_agg(jsonb_build_array(workspace_id,rule_execution_id,action_position,due_at) ORDER BY workspace_id,rule_execution_id,action_position),'[]'::jsonb)::text FROM action_jobs WHERE due_at IS NOT NULL AND workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id=ANY($1))").bind(&config.user_ids[..]).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if winner.revision != 2
        || current != winner
        || untouched.user_id != config.user_ids[1]
        || untouched.revision != 1
        || untouched.display_timezone != "UTC"
        || !audit
        || before != after
    {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}

/**
 * Kiểm sai timezone/context/limited và stale legacy không materialize preference ngoài ý muốn.
 * Input
 * Param: service — application và PG adapter thật.
 * Param: pool — fixture reader/session seed có marker.
 * Param: config — account/email/correlation synthetic đã thuộc run.
 * Param: proof — full account0 hiện có preference revision2.
 * Param: other — full account1 chưa có row preference.
 * Output: denied paths không ghi row/revision mới; Errors: Conflict/storage.
 */
async fn verify_denials(
    service: &AuthService,
    pool: &PgPool,
    config: &ProbeConfig,
    proof: &SessionProof,
    other: &SessionProof,
) -> Result<(), ApplicationError> {
    let invalid = DisplayTimezone::new("Not/A_Timezone").ok_or(ApplicationError::InvalidInput)?;
    let utc = DisplayTimezone::new("UTC").ok_or(ApplicationError::InvalidInput)?;
    let context = SessionProof {
        token_digest: proof.token_digest,
        expected_context: Some(Uuid::new_v4()),
    };
    if !matches!(
        service
            .update_preferences(proof, &invalid, 2, config.run_id)
            .await,
        Err(ApplicationError::TimezoneInvalid)
    ) || !matches!(
        service.get_preferences(&context).await,
        Err(ApplicationError::Conflict)
    ) || !matches!(
        service
            .update_preferences(other, &utc, 2, config.run_id)
            .await,
        Err(ApplicationError::StaleRevision)
    ) {
        return Err(ApplicationError::Conflict);
    }
    // Account race-email do CRT tạo vẫn limited, origin/audit provenance đã có; không đọc password.
    let limited_id:Uuid=sqlx::query_scalar("SELECT user_id FROM users WHERE email_normalized=$1 AND activation_provenance='ADMIN_TEMPORARY_V1' AND must_change_password AND activated_at IS NULL").bind(&config.emails[9]).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let limited = seed_session(service, pool, limited_id, true).await?;
    if !matches!(
        service.get_preferences(&limited).await,
        Err(ApplicationError::PasswordChangeRequired)
    ) || !matches!(
        service
            .update_preferences(&limited, &utc, 1, config.run_id)
            .await,
        Err(ApplicationError::PasswordChangeRequired)
    ) {
        return Err(ApplicationError::Conflict);
    }
    let absent: bool = sqlx::query_scalar(
        "SELECT NOT EXISTS(SELECT 1 FROM user_preferences WHERE user_id=ANY($1))",
    )
    .bind(vec![config.user_ids[1], limited_id])
    .fetch_one(pool)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    if !absent {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}

/**
 * Gây required audit failure với preference có/không có row, kiểm rollback CAS và materialization.
 * Input
 * Param: service — audit INSERT đã bị REVOKE thật trên role probe.
 * Param: pool — đọc committed state và seed session marker, không thay quyền production.
 * Param: proof — full account1 của audit fault fixture, chưa có preference row.
 * Param: config — identity/correlation synthetic cùng run.
 * Output: snapshot giữ nguyên cả hai account, account1 vẫn không có row; Errors: Conflict/storage.
 */
pub(super) async fn verify_failure(
    service: &AuthService,
    pool: &PgPool,
    proof: &SessionProof,
    config: &ProbeConfig,
) -> Result<(), ApplicationError> {
    let owned = seed_session(service, pool, config.user_ids[0], false).await?;
    let timezone =
        DisplayTimezone::new("Asia/Ho_Chi_Minh").ok_or(ApplicationError::InvalidInput)?;
    for current in [proof, &owned] {
        let before = service.get_preferences(current).await?;
        if !matches!(
            service
                .update_preferences(current, &timezone, before.revision, config.run_id)
                .await,
            Err(ApplicationError::Unavailable)
        ) || service.get_preferences(current).await? != before
        {
            return Err(ApplicationError::Conflict);
        }
    }
    // Account1 materialize UTC/1 trước UPDATE nhưng audit lỗi phải rollback cả INSERT, không chỉ revision.
    let absent: bool =
        sqlx::query_scalar("SELECT NOT EXISTS(SELECT 1 FROM user_preferences WHERE user_id=$1)")
            .bind(config.user_ids[1])
            .fetch_one(pool)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
    if !absent {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}
