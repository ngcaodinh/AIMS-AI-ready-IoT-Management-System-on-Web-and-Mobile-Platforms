//! Lỗi audit thật do launcher REVOKE INSERT chỉ trên role probe; không DDL hoặc tắt constraint.

#[path = "audit_reset.rs"]
mod reset_fault;

use super::{ApplicationError, AuthService, PgPool, ProbeConfig, request_key};
use iot_platform_backend::{
    adapters::security::{CryptoService, PasswordService, generate_token},
    application::{identity::IdentityService, ports::IdentitySecurity},
    domain::{
        identity::SessionProof,
        membership::{MembershipPatch, MembershipStatus},
    },
    postgres::{PgIdentityStore, connection::connect_local_probe},
};
use sqlx::Row;
use uuid::Uuid;

/**
 * Tạo aggregate/session synthetic trực tiếp để test required audit hỏng vẫn đi qua đúng use case.
 * Input
 * Param: pool — role probe đã bị thu hồi INSERT audit, vẫn chỉ có quyền fixture cần thiết.
 * Param: service — composition thật để hash token, không dùng token hardcode.
 * Param: config — UUID/email marker phải thuộc lượt normal probe vừa chạy.
 * Output: workspace fixture và full Admin proof; Errors: storage hoặc ownership không hợp lệ.
 */
async fn seed_fault_fixture(
    pool: &PgPool,
    service: &AuthService,
    config: &ProbeConfig,
) -> Result<(Uuid, SessionProof), ApplicationError> {
    let owned: bool = sqlx::query_scalar("SELECT count(*)=2 FROM users WHERE user_id=ANY($1) AND activation_provenance=$2 AND account_status='ACTIVE' AND NOT must_change_password")
        .bind(&config.user_ids[..2]).bind(format!("REPOSITORY_PROBE:{}",config.run_id))
        .fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !owned {
        return Err(ApplicationError::Conflict);
    }
    let workspace_id = Uuid::new_v4();
    let token = generate_token();
    let proof = service.session_proof(token.expose(), None);
    let mut transaction = pool
        .begin()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    // Seed chỉ liên kết IDs synthetic đã chứng minh sở hữu; không dùng writer để sửa audit/role/constraint.
    sqlx::query("INSERT INTO sessions(session_id,user_id,token_digest,auth_context_id,limited,client_type,issued_at,expires_at) VALUES($1,$2,$3,$4,false,'ANDROID',transaction_timestamp(),transaction_timestamp()+interval '24 hours')")
        .bind(Uuid::new_v4()).bind(config.user_ids[1]).bind(proof.token_digest.as_slice()).bind(Uuid::new_v4())
        .execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO workspaces(workspace_id,name,default_timezone,created_by_user_id) VALUES($1,'Audit fault fixture','UTC',$2)")
        .bind(workspace_id).bind(config.user_ids[1]).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    for (index, role) in [(1, "ADMIN"), (0, "USER")] {
        sqlx::query("INSERT INTO memberships(workspace_id,user_id,role,current_grant_generation) VALUES($1,$2,$3,1)")
            .bind(workspace_id).bind(config.user_ids[index]).bind(role).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
        sqlx::query(
            "INSERT INTO membership_grants(workspace_id,user_id,grant_generation) VALUES($1,$2,1)",
        )
        .bind(workspace_id)
        .bind(config.user_ids[index])
        .execute(&mut *transaction)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    }
    transaction
        .commit()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    Ok((workspace_id, proof))
}

/**
 * Chứng minh member state/outbox rollback khi audit INSERT bị PostgreSQL từ chối thật.
 * Input
 * Param: service — application/PG adapter thật, không mock writer.
 * Param: pool — đọc lại committed state sau unit of work bị abort.
 * Param: proof — current Admin session của aggregate fault synthetic.
 * Param: `workspace_id` — tenant fault đã tạo; không đụng tenant của người dùng.
 * Param: config — target UUID/correlation của cùng lượt probe.
 * Output: hoàn thành khi không có state/outbox partial; Errors: Conflict nếu mutation lọt commit.
 */
async fn member_rollback(
    service: &AuthService,
    pool: &PgPool,
    proof: &SessionProof,
    workspace_id: Uuid,
    config: &ProbeConfig,
) -> Result<(), ApplicationError> {
    let result = service
        .update_member(
            proof,
            workspace_id,
            config.user_ids[0],
            1,
            &MembershipPatch {
                status: Some(MembershipStatus::Suspended),
                ..MembershipPatch::default()
            },
            config.run_id,
        )
        .await;
    if !matches!(result, Err(ApplicationError::Unavailable)) {
        return Err(ApplicationError::Conflict);
    }
    // Đọc từ pool sau Drop rollback; kiểm cả CAS/auth version và durable close intent.
    let unchanged: bool = sqlx::query_scalar("SELECT status='ACTIVE' AND revision=1 AND authorization_version=1 AND NOT EXISTS(SELECT 1 FROM outbox_events WHERE workspace_id=$1) FROM memberships WHERE workspace_id=$1 AND user_id=$2")
        .bind(workspace_id).bind(config.user_ids[0]).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !unchanged {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}

/**
 * Chạy fault phase sau normal probe để PostgreSQL permission denial kiểm atomicity và failed-auth exception.
 * Input
 * Param: config — launcher vừa REVOKE INSERT audit; không có secret được in hoặc ghi file.
 * Param: checks — chỉ nhận tên invariant đã đạt, không chứa data/SQL error.
 * Output: checks audit thật; Errors: lỗi storage hoặc invariant đã lọc.
 */
pub(super) async fn verify(
    config: ProbeConfig,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let pool = connect_local_probe(config.port, &config.username, &config.password).await?;
    let denied: bool = sqlx::query_scalar(
        "SELECT NOT has_table_privilege(current_user,'public.audit_events','INSERT')",
    )
    .fetch_one(&pool)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    if !denied {
        return Err(ApplicationError::Conflict);
    }
    let security = CryptoService::new(PasswordService::default(), config.limiter_key).await?;
    let digest = security.bucket_digest(&config.emails[1])?;
    let store = PgIdentityStore::new(pool.clone());
    let service = IdentityService::new(store.clone(), security.clone());
    let (workspace, proof) = seed_fault_fixture(&pool, &service, &config).await?;
    member_rollback(&service, &pool, &proof, workspace, &config).await?;
    checks.push("PASS: PostgreSQL audit INSERT denial rolls back member revision/authority and scoped outbox together");
    let before: i64 =
        sqlx::query_scalar("SELECT count(*) FROM global_idempotency_records WHERE user_id=$1")
            .bind(config.user_ids[1])
            .fetch_one(&pool)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
    if !matches!(
        service
            .create_workspace(
                &proof,
                "Audit rollback",
                None,
                "UTC",
                &request_key(),
                config.run_id
            )
            .await,
        Err(ApplicationError::Unavailable)
    ) {
        return Err(ApplicationError::Conflict);
    }
    let after=sqlx::query("SELECT (SELECT count(*) FROM global_idempotency_records WHERE user_id=$1) AS receipts,(SELECT count(*) FROM workspaces WHERE created_by_user_id=$1) AS workspaces")
        .bind(config.user_ids[1]).fetch_one(&pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if after.get::<i64, _>("receipts") != before || after.get::<i64, _>("workspaces") != 1 {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: PostgreSQL audit INSERT denial rolls back workspace aggregate and idempotency receipt");
    failed_auth(&service, &store, &pool, &proof, &config, digest).await?;
    checks.push("PASS: failed-login audit INSERT denial preserves committed limiter admission and grants no session");
    checks.push("PASS: login/password failure-audit degradation increments fixed counters shared by cloned stores");
    reset_fault::verify(&service, &pool, &proof, workspace, &config).await?;
    checks.push("PASS: audit INSERT denial rolls back reset PHC/revision/admission/session/ticket/binding/outbox and returns no password");
    super::member_creation_probe::verify_failure(&service, &pool, &proof, workspace, &config)
        .await?;
    checks.push("PASS: audit INSERT denial rolls back temporary account/member/grant and existing-account invitation with both receipts");
    super::preferences_probe::verify_failure(&service, &pool, &proof, &config).await?;
    checks.push("PASS: audit INSERT denial rolls back preference CAS and missing-row materialization for both accounts");
    super::invitation_management_probe::verify_failure(&service, &pool, &config).await?;
    checks.push("PASS: audit INSERT denial rolls back invitation revoked_at and engine revision with no partial terminal");
    super::template_probe::verify_failure(&pool, &service, &security, &config, checks).await?;
    super::device_probe::verify_failure(&pool, &service, &security, &config, checks).await?;
    assert_append_only(&pool, config.run_id).await?;
    checks.push("PASS: repository role cannot UPDATE or DELETE audit rows");
    pool.close().await;
    Ok(())
}

/**
 * Kiểm quyền append-only bằng SQLSTATE, không xuất SQL/detail nhạy cảm.
 * Input
 * Param: pool — role probe không có UPDATE/DELETE audit.
 * Param: correlation — chỉ chọn rows synthetic của cùng lượt chạy.
 * Output: thành công khi cả hai lệnh bị từ chối; Errors: Conflict nếu quyền bị mở.
 */
async fn assert_append_only(pool: &PgPool, correlation: Uuid) -> Result<(), ApplicationError> {
    // App role không có UPDATE/DELETE audit; kiểm lỗi permission code thay vì in SQL/detail nhạy cảm.
    for statement in [
        "UPDATE audit_events SET reason_code='FORBIDDEN_PROBE' WHERE correlation_id=$1",
        "DELETE FROM audit_events WHERE correlation_id=$1",
    ] {
        let result = sqlx::query(statement).bind(correlation).execute(pool).await;
        if !result.err().is_some_and(|error| {
            error
                .as_database_error()
                .and_then(sqlx::error::DatabaseError::code)
                .as_deref()
                == Some("42501")
        }) {
            return Err(ApplicationError::Conflict);
        }
    }
    Ok(())
}

/**
 * Kiểm audit sink hỏng vẫn deny, giữ limiter và có metric hữu hạn cho cả login lẫn đổi password sai.
 * Input
 * Param: service — application thật dùng clone của store đang quan sát.
 * Param: store — nguồn hai counter, không chứa label identity/secret.
 * Param: pool — chỉ đọc counter/session fixture sau commit.
 * Param: proof — full session chính chủ cho nhánh đổi password.
 * Param: config — email/UUID fixture nội bộ, không ghi vào metric.
 * Param: digest — HMAC bucket tổng hợp chỉ bind, không in.
 * Output: thành công khi login và password change giữ counter riêng, cả hai vẫn tăng sau audit failure.
 */
async fn failed_auth(
    service: &AuthService,
    store: &PgIdentityStore,
    pool: &PgPool,
    proof: &SessionProof,
    config: &ProbeConfig,
    digest: [u8; 32],
) -> Result<(), ApplicationError> {
    // Đọc hai limiter độc lập trước thao tác để chứng minh login không tiêu hao ngân sách đổi mật khẩu.
    // Chỉ đọc count login theo digest fixture đã bind; không hiển thị digest hoặc email.
    let failures:i32=sqlx::query_scalar("SELECT coalesce((SELECT failure_count FROM login_attempt_buckets WHERE email_digest=$1),0)")
        .bind(digest.as_slice()).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    // Bucket password change dùng User ID tổng hợp, không chia sẻ khóa với login.
    let password_failures: i32 = sqlx::query_scalar(
        "SELECT coalesce((SELECT failure_count FROM password_change_attempt_buckets WHERE user_id=$1),0)",
    )
    .bind(config.user_ids[1])
    .fetch_one(pool)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    // Snapshot số session để xác nhận failed credential không thu hồi session đang hợp lệ.
    let sessions: i64 = sqlx::query_scalar("SELECT count(*) FROM sessions WHERE user_id=$1")
        .bind(config.user_ids[1])
        .fetch_one(pool)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    if failures >= 5
        || password_failures >= 5
        || !matches!(
            service
                .login(
                    &config.emails[1],
                    generate_token().expose().to_owned(),
                    iot_platform_backend::domain::identity::ClientType::Android,
                    config.run_id
                )
                .await,
            Err(ApplicationError::InvalidCredentials)
        )
    {
        return Err(ApplicationError::Conflict);
    }
    // Xác nhận login chỉ cập nhật login limiter trước khi thử đổi password sai.
    let stored: i32 =
        sqlx::query_scalar("SELECT failure_count FROM login_attempt_buckets WHERE email_digest=$1")
            .bind(digest.as_slice())
            .fetch_one(pool)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
    // Đọc lại password limiter để bắt việc vô tình dùng chung bucket với failed login.
    let password_after_login: i32 = sqlx::query_scalar(
        "SELECT coalesce((SELECT failure_count FROM password_change_attempt_buckets WHERE user_id=$1),0)",
    )
    .bind(config.user_ids[1])
    .fetch_one(pool)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    // Đối chiếu số session sau login sai; failed login không được chạm session đã cấp.
    let after_sessions: i64 = sqlx::query_scalar("SELECT count(*) FROM sessions WHERE user_id=$1")
        .bind(config.user_ids[1])
        .fetch_one(pool)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    if stored != failures + 1
        || password_after_login != password_failures
        || sessions != after_sessions
    {
        return Err(ApplicationError::Conflict);
    }
    let observed = store.failed_audit_counts();
    if observed.login != 1 || observed.password_change != 0 {
        return Err(ApplicationError::Conflict);
    }
    // Tạo newPassword tổng hợp đủ composition để phép thử chạm nhánh currentPassword sai thay vì dừng ở validation.
    let invalid_current_password = generate_token();
    let policy_valid_new_password = format!("Aa1{}", generate_token().expose());
    if !matches!(
        service
            .change_password(
                proof,
                invalid_current_password.expose().to_owned(),
                policy_valid_new_password,
                config.run_id
            )
            .await,
        Err(ApplicationError::InvalidCredentials)
    ) {
        return Err(ApplicationError::Conflict);
    }
    let observed = store.failed_audit_counts();
    // Đọc riêng từng row sau password failure để chứng minh không tăng login counter.
    let login_admitted: i32 =
        sqlx::query_scalar("SELECT failure_count FROM login_attempt_buckets WHERE email_digest=$1")
            .bind(digest.as_slice())
            .fetch_one(pool)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
    // User ID bind vào dedicated bucket để xác nhận chỉ limiter đổi mật khẩu tăng.
    let password_admitted: i32 = sqlx::query_scalar(
        "SELECT failure_count FROM password_change_attempt_buckets WHERE user_id=$1",
    )
    .bind(config.user_ids[1])
    .fetch_one(pool)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    if observed.login != 1
        || observed.password_change != 1
        || login_admitted != failures + 1
        || password_admitted != password_failures + 1
    {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}
