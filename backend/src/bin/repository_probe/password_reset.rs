//! Integration reset qua use case thật; account tạm là fixture có UUID/email/audit marker riêng.

use super::{AuthService, ProbeConfig};
use iot_platform_backend::{
    adapters::security::{CryptoService, PasswordService, generate_token},
    application::{error::ApplicationError, password_reset::ResetPasswordResult},
    domain::{
        identity::{ClientType, SecretString, SessionProof},
        password_reset::TEMPORARY_ACCOUNT_ORIGIN,
    },
    postgres::{PgIdentityStore, connection::connect_local_probe},
};
use sqlx::PgPool;
use uuid::Uuid;

/// Context chỉ dùng cho probe nội bộ, không Debug/Serialize để giữ proof/credential ngoài evidence.
struct ResetProbe<'a> {
    service: &'a AuthService,
    pool: &'a PgPool,
    config: &'a ProbeConfig,
    proof: SessionProof,
    workspace_id: Uuid,
}

/**
 * Dựng target tạm có origin rõ ràng và membership/grant/audit marker cùng transaction.
 * Input
 * Param: context — pool/identity scoped fixture; không dùng account thực của người dùng.
 * Output: mật khẩu fixture ban đầu chỉ ở bộ nhớ hoặc lỗi seed đã lọc.
 */
async fn seed_target(context: &ResetProbe<'_>) -> Result<SecretString, ApplicationError> {
    let password = generate_token();
    let verifier = PasswordService::default()
        .hash(password.expose().to_owned())
        .await?;
    let mut transaction = context
        .pool
        .begin()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    let target = context.config.user_ids[3];
    // Origin fixture chỉ được cleanup khi email/UUID và resource audit cùng run đều khớp.
    sqlx::query("INSERT INTO users(user_id,email_normalized,password_hash,account_status,must_change_password,activation_provenance) VALUES($1,$2,$3,'ACTIVE',true,$4)")
        .bind(target).bind(&context.config.emails[4]).bind(verifier).bind(TEMPORARY_ACCOUNT_ORIGIN).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO memberships(workspace_id,user_id,role,current_grant_generation) VALUES($1,$2,'USER',1)")
        .bind(context.workspace_id).bind(target).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query(
        "INSERT INTO membership_grants(workspace_id,user_id,grant_generation) VALUES($1,$2,1)",
    )
    .bind(context.workspace_id)
    .bind(target)
    .execute(&mut *transaction)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO audit_events(audit_event_id,workspace_id,actor_user_id,event_type,outcome,resource_type,resource_id,correlation_id,client_type) VALUES($1,$2,$3,'TEMPORARY_ACCOUNT_CREATED','SUCCESS','USER',$4,$5,'UNKNOWN')")
        .bind(Uuid::new_v4()).bind(context.workspace_id).bind(context.config.user_ids[0]).bind(target.to_string()).bind(context.config.run_id).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    transaction
        .commit()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    Ok(password)
}

/**
 * Chạy reset theo current Admin, CAS, quota và protected scopes trước khi test password toàn account khác.
 * Input
 * Param: service — application/PG/crypto composition instance A.
 * Param: pool — probe pool dùng dựng fixture và đọc metadata không secret.
 * Param: config — UUID/email/correlation fixture do launcher sinh.
 * Param: password — mật khẩu issuer tổng hợp hiện hành, không log.
 * Param: checks — danh sách evidence chỉ thêm sau invariant đạt.
 * Output: hoàn tất hoặc lỗi đã lọc; không in mật khẩu tạm của bất kỳ reset nào.
 */
pub(super) async fn verify(
    service: &AuthService,
    pool: &PgPool,
    config: &ProbeConfig,
    password: &SecretString,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let session = service
        .login(
            &config.emails[0],
            password.expose().to_owned(),
            ClientType::Android,
            config.run_id,
        )
        .await?;
    let proof = service.session_proof(session.token.expose(), None);
    let workspace_id = service
        .list_workspaces(&proof, None, 1)
        .await?
        .first()
        .ok_or(ApplicationError::Conflict)?
        .workspace_id;
    let context = ResetProbe {
        service,
        pool,
        config,
        proof,
        workspace_id,
    };
    let old_password = seed_target(&context).await?;
    authority_checks(&context, password, checks).await?;
    let first_reset = concurrent_reset_checks(&context, &old_password, checks).await?;
    quota_checks(&context, first_reset, checks).await?;
    multi_workspace_checks(&context, checks).await
}

/**
 * Kiểm protected account, USER và tenant selector giả không cấp quyền reset toàn cục.
 * Input
 * Param: context — Admin context và target fixture đủ điều kiện dùng làm positive control.
 * Param: password — credential fixture USER đã có, không thuộc target mới.
 * Param: checks — evidence chỉ thêm sau khi tất cả negative đạt.
 * Output: hoàn thành hoặc lỗi nếu boundary cho phép reset không hợp lệ.
 */
async fn authority_checks(
    context: &ResetProbe<'_>,
    password: &SecretString,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let ResetProbe {
        service,
        config,
        proof,
        workspace_id,
        ..
    } = context;
    if !matches!(
        service
            .reset_temporary_password(proof, *workspace_id, config.user_ids[2], 1, config.run_id)
            .await,
        Err(ApplicationError::GlobalAccountProtected)
    ) || !matches!(
        service
            .reset_temporary_password(proof, Uuid::new_v4(), config.user_ids[3], 1, config.run_id)
            .await,
        Err(ApplicationError::Forbidden)
    ) {
        return Err(ApplicationError::Conflict);
    }
    let user = service
        .login(
            &config.emails[1],
            password.expose().to_owned(),
            ClientType::Android,
            config.run_id,
        )
        .await?;
    let user_proof = service.session_proof(user.token.expose(), None);
    if !matches!(
        service
            .reset_temporary_password(
                &user_proof,
                *workspace_id,
                config.user_ids[3],
                1,
                config.run_id
            )
            .await,
        Err(ApplicationError::Forbidden)
    ) {
        return Err(ApplicationError::Conflict);
    }
    checks.push(
        "PASS: temporary reset denies activated account, USER role and forged workspace selector",
    );
    Ok(())
}

/**
 * Cho hai pool tranh reset cùng revision để chỉ một credential/revision/audit được commit.
 * Input
 * Param: context — Admin context và target mới ở revision1.
 * Param: password — password fixture trước reset để kiểm bị thay và revoke cả hai phiên cũ.
 * Param: checks — evidence chỉ thêm sau kiểm CAS/revocation/limited login.
 * Output: reset winner chỉ ở bộ nhớ; lỗi nếu cả hai intent cũ thành công hoặc partial mutation.
 */
async fn concurrent_reset_checks(
    context: &ResetProbe<'_>,
    password: &SecretString,
    checks: &mut Vec<&'static str>,
) -> Result<ResetPasswordResult, ApplicationError> {
    let target = context.config.user_ids[3];
    let mut old_sessions = Vec::new();
    for _ in 0..2 {
        let session = context
            .service
            .login(
                &context.config.emails[4],
                password.expose().to_owned(),
                ClientType::Android,
                context.config.run_id,
            )
            .await?;
        old_sessions.push(session.session_id);
    }
    let other_pool = connect_local_probe(
        context.config.port,
        &context.config.username,
        &context.config.password,
    )
    .await?;
    let other = super::IdentityService::new(
        PgIdentityStore::new(other_pool.clone()),
        CryptoService::new(PasswordService::default(), context.config.limiter_key).await?,
    );
    let (first, second) = tokio::join!(
        context.service.reset_temporary_password(
            &context.proof,
            context.workspace_id,
            target,
            1,
            context.config.run_id
        ),
        other.reset_temporary_password(
            &context.proof,
            context.workspace_id,
            target,
            1,
            context.config.run_id
        )
    );
    let ((Ok(winner), Err(ApplicationError::StaleRevision))
    | (Err(ApplicationError::StaleRevision), Ok(winner))) = (first, second)
    else {
        return Err(ApplicationError::Conflict);
    };
    other_pool.close().await;
    if winner.membership_revision != 2 {
        return Err(ApplicationError::Conflict);
    }
    // Target session IDs là fixture; chỉ lấy trạng thái và số close intent, không đọc token/PHC.
    let revoked:bool=sqlx::query_scalar("SELECT count(*)=2 AND bool_and(revoked_at IS NOT NULL) FROM sessions WHERE session_id=ANY($1)")
        .bind(&old_sessions).fetch_one(context.pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let session_ids: Vec<_> = old_sessions.iter().map(ToString::to_string).collect();
    let intents:i64=sqlx::query_scalar("SELECT count(*) FROM outbox_events WHERE event_type='SESSION_REVOKED' AND payload->>'sessionId'=ANY($1)")
        .bind(session_ids).fetch_one(context.pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !revoked
        || intents != 2
        || !matches!(
            context
                .service
                .login(
                    &context.config.emails[4],
                    password.expose().to_owned(),
                    ClientType::Android,
                    context.config.run_id
                )
                .await,
            Err(ApplicationError::InvalidCredentials)
        )
    {
        return Err(ApplicationError::Conflict);
    }
    let fresh = context
        .service
        .login(
            &context.config.emails[4],
            winner.temporary_password.expose().to_owned(),
            ClientType::Android,
            context.config.run_id,
        )
        .await?;
    if !fresh.limited {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: two-pool temporary reset has one CAS winner; old credential/two sessions die and new login stays limited");
    Ok(winner)
}

/**
 * Đẩy ledger tới quota5 rồi kiểm request6 giữ nguyên password, revision, audit và admission count.
 * Input
 * Param: context — Admin/target cùng workspace và User fences do use case quản lý.
 * Param: last — credential của reset đầu, được thay trong bộ nhớ sau mỗi reset hợp lệ.
 * Param: checks — evidence chỉ thêm khi cả rate denial và ledger count đúng.
 * Output: hoàn thành hoặc lỗi nếu quota khác5 hoặc có half reset.
 */
async fn quota_checks(
    context: &ResetProbe<'_>,
    mut last: ResetPasswordResult,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    for _ in 0..4 {
        last = context
            .service
            .reset_temporary_password(
                &context.proof,
                context.workspace_id,
                context.config.user_ids[3],
                last.membership_revision,
                context.config.run_id,
            )
            .await?;
    }
    if !matches!(context.service.reset_temporary_password(&context.proof,context.workspace_id,context.config.user_ids[3],last.membership_revision,context.config.run_id).await,Err(ApplicationError::RateLimited {retry_after_seconds}) if retry_after_seconds>0 && retry_after_seconds<=900)
    {
        return Err(ApplicationError::Conflict);
    }
    // Ledger và audit cùng scope actor/target; target marker không chứa plaintext password.
    let admissions:i64=sqlx::query_scalar("SELECT count(*) FROM password_reset_admissions WHERE workspace_id=$1 AND actor_user_id=$2 AND target_user_id=$3")
        .bind(context.workspace_id).bind(context.config.user_ids[0]).bind(context.config.user_ids[3]).fetch_one(context.pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let audits:i64=sqlx::query_scalar("SELECT count(*) FROM audit_events WHERE workspace_id=$1 AND actor_user_id=$2 AND correlation_id=$3 AND event_type='MEMBERSHIP_RESET_ADMITTED'")
        .bind(context.workspace_id).bind(context.config.user_ids[0]).bind(context.config.run_id).fetch_one(context.pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let fresh = context
        .service
        .login(
            &context.config.emails[4],
            last.temporary_password.expose().to_owned(),
            ClientType::Android,
            context.config.run_id,
        )
        .await?;
    if admissions != 5 || audits != 5 || last.membership_revision != 6 || !fresh.limited {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: reset five-per-fifteen-minute ledger and required audit commit together; request six preserves last credential");
    Ok(())
}

/**
 * Thêm membership lịch sử tenant khác vào target tạm để kiểm protected trước cả quota.
 * Input
 * Param: context — target vẫn chưa activated và đúng temporary origin sau5 reset.
 * Param: checks — evidence chỉ thêm sau deny và kiểm global session vẫn sống.
 * Output: hoàn thành hoặc lỗi nếu Admin W1 reset được account cũng thuộc W2.
 */
async fn multi_workspace_checks(
    context: &ResetProbe<'_>,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let workspace = context
        .service
        .list_workspaces(&context.proof, None, 2)
        .await?
        .get(1)
        .ok_or(ApplicationError::Conflict)?
        .workspace_id;
    let target = context.config.user_ids[3];
    let mut transaction = context
        .pool
        .begin()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    // Membership SUSPENDED vẫn chứng minh account thuộc tenant khác; không chỉ đếm ACTIVE.
    sqlx::query("INSERT INTO memberships(workspace_id,user_id,role,status,current_grant_generation) VALUES($1,$2,'USER','SUSPENDED',1)")
        .bind(workspace).bind(target).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query(
        "INSERT INTO membership_grants(workspace_id,user_id,grant_generation) VALUES($1,$2,1)",
    )
    .bind(workspace)
    .bind(target)
    .execute(&mut *transaction)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    transaction
        .commit()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    if !matches!(
        context
            .service
            .reset_temporary_password(
                &context.proof,
                context.workspace_id,
                target,
                6,
                context.config.run_id
            )
            .await,
        Err(ApplicationError::GlobalAccountProtected)
    ) {
        return Err(ApplicationError::Conflict);
    }
    let live: i64 =
        sqlx::query_scalar("SELECT count(*) FROM sessions WHERE user_id=$1 AND revoked_at IS NULL")
            .bind(target)
            .fetch_one(context.pool)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
    if live != 1 {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: temporary account with another workspace membership is globally protected and its live session is preserved");
    Ok(())
}
