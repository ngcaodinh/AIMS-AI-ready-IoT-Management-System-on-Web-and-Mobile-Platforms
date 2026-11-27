//! Integration probe opt-in; chỉ nhận cấu hình tạm qua stdin, không dùng `.env`.

#[path = "repository_probe/audit_fault.rs"]
mod audit_fault_probe;
#[path = "repository_probe/audit.rs"]
mod audit_probe;
#[path = "repository_probe/audit_retention.rs"]
mod audit_retention_probe;
#[path = "repository_probe/audit_time.rs"]
mod audit_time_probe;
#[path = "repository_probe/device.rs"]
mod device_probe;
#[path = "repository_probe/invitation_management.rs"]
mod invitation_management_probe;
#[path = "repository_probe/member_creation.rs"]
mod member_creation_probe;
#[path = "repository_probe/membership.rs"]
mod membership_probe;
#[path = "repository_probe/outbox.rs"]
mod outbox_probe;
#[path = "repository_probe/password_reset.rs"]
mod password_reset_probe;
#[path = "repository_probe/preferences.rs"]
mod preferences_probe;
#[path = "repository_probe/template.rs"]
mod template_probe;

use iot_platform_backend::{
    adapters::security::{CryptoService, PasswordService, generate_token},
    application::{error::ApplicationError, identity::IdentityService},
    domain::{
        identity::{ClientType, SecretString},
        workspace::WorkspaceRole,
    },
    postgres::{PgIdentityStore, connection::connect_local_probe},
};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Row};
use std::io::{self, Read};
use uuid::Uuid;
type AuthService = IdentityService<PgIdentityStore, CryptoService>;

/// Mỗi process chỉ chạy một phase; enum không cho tổ hợp fault/retention/seed mâu thuẫn nhau.
#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
enum ProbePhase {
    #[default]
    Normal,
    MemberCreation,
    Preferences,
    InvitationManagement,
    Outbox,
    Template,
    Device,
    DeviceAuthority,
    AuditFailure,
    Retention,
    RetentionFailure,
}

/// Payload do launcher nội bộ tạo; không Debug/Serialize để tránh credential xuất hiện trong evidence.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ProbeConfig {
    #[serde(default)]
    phase: ProbePhase,
    port: u16,
    username: String,
    password: String,
    limiter_key: [u8; 32],
    run_id: Uuid,
    user_ids: [Uuid; 7],
    emails: [String; 14],
}

/// Sinh key cho intent test mới; test replay phải giữ nguyên key thay vì gọi lại helper.
fn request_key() -> iot_platform_backend::domain::idempotency::IdempotencyKey {
    iot_platform_backend::domain::idempotency::IdempotencyKey::new(&Uuid::new_v4().to_string())
        .expect("generated UUID is 36 ASCII bytes")
}

/**
 * Tạo ba principal tổng hợp để chạy workflow thật; role probe mới có INSERT này, runtime vẫn đóng.
 * Input
 * Param: pool — pool SCRAM tạm đã giới hạn schema và table.
 * Param: config — identity/marker của lượt chạy, không phải account người dùng.
 * Param: passwords — hasher thật để kiểm Argon2 qua đường login.
 * Output: mật khẩu tổng hợp chỉ trong bộ nhớ; Errors: lỗi được lọc trước khi in.
 */
async fn seed(
    pool: &PgPool,
    config: &ProbeConfig,
    passwords: &PasswordService,
) -> Result<SecretString, ApplicationError> {
    let password = generate_token();
    let verifier = passwords.hash(password.expose().to_owned()).await?;
    for index in 0..3 {
        // Chỉ identity do launcher sinh được bind; marker bảo vệ cleanup sau failure hoặc timeout.
        sqlx::query("INSERT INTO users(user_id,email_normalized,password_hash,account_status,must_change_password,activation_provenance) VALUES($1,$2,$3,$4,$5,$6)")
            .bind(config.user_ids[index]).bind(&config.emails[index]).bind(&verifier)
            .bind(if index==1 { "DISABLED" } else { "ACTIVE" }).bind(index==2)
            .bind(format!("REPOSITORY_PROBE:{}",config.run_id)).execute(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    }
    Ok(password)
}

/**
 * Chạy sáu request qua hai pool độc lập để counter không thể chỉ đúng trong một process mutex.
 * Input
 * Param: first — repository instance A dùng pool riêng.
 * Param: second — repository instance B cùng HMAC key nhưng pool khác.
 * Param: config — email tổng hợp và correlation của lượt kiểm.
 * Output: 5 invalid credential và 1 rate limit, hoặc lỗi chặn evidence PASS.
 */
async fn concurrent_failures(
    first: &AuthService,
    second: &AuthService,
    config: &ProbeConfig,
) -> Result<(), ApplicationError> {
    let start = std::sync::Arc::new(tokio::sync::Barrier::new(6));
    let mut tasks = tokio::task::JoinSet::new();
    for index in 0..6 {
        let repository = if index % 2 == 0 {
            first.clone()
        } else {
            second.clone()
        };
        let start = start.clone();
        let email = config.emails[3].clone();
        let correlation = config.run_id;
        // Barrier tạo contention thật, không dùng sleep để giả lập interleaving.
        tasks.spawn(async move {
            start.wait().await;
            repository
                .login(
                    &email,
                    generate_token().expose().to_owned(),
                    ClientType::Android,
                    correlation,
                )
                .await
        });
    }
    let mut invalid = 0;
    let mut limited = 0;
    while let Some(result) = tasks.join_next().await {
        match result.map_err(|_| ApplicationError::Unavailable)? {
            Err(ApplicationError::InvalidCredentials) => invalid += 1,
            Err(ApplicationError::RateLimited { .. }) => limited += 1,
            _ => return Err(ApplicationError::Conflict),
        }
    }
    if (invalid, limited) != (5, 1) {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}

/**
 * Kiểm các invariant repository bằng dữ liệu thật, không thay HTTP status/provider acceptance.
 * Input
 * Param: config — cổng/role tạm và identity do launcher cấp qua stdin kín.
 * Output: tên các check đã đạt; Errors: dừng ngay tại invariant sai.
 */
async fn verify(
    config: ProbeConfig,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let pool = connect_local_probe(config.port, &config.username, &config.password).await?;
    let second_pool = connect_local_probe(config.port, &config.username, &config.password).await?;
    let passwords = PasswordService::default();
    let password = seed(&pool, &config, &passwords).await?;
    let first = IdentityService::new(
        PgIdentityStore::new(pool.clone()),
        CryptoService::new(passwords.clone(), config.limiter_key).await?,
    );
    let second = IdentityService::new(
        PgIdentityStore::new(second_pool.clone()),
        CryptoService::new(passwords, config.limiter_key).await?,
    );
    concurrent_failures(&first, &second, &config).await?;
    checks.push(
        "PASS: six simultaneous failures across two pools yield five invalid and one limited",
    );
    let issued = first
        .login(
            &config.emails[0],
            password.expose().to_owned(),
            ClientType::Web,
            config.run_id,
        )
        .await?;
    if issued.limited || issued.user_id != config.user_ids[0] {
        return Err(ApplicationError::Conflict);
    }
    // Chỉ kiểm độ dài và digest, không lấy hoặc in raw capability từ storage.
    let stored=sqlx::query("SELECT octet_length(token_digest) AS size,expires_at-issued_at=interval '24 hours' AS ttl FROM sessions WHERE session_id=$1")
        .bind(issued.session_id).fetch_one(&pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if stored.get::<i32, _>("size") != 32 || !stored.get::<bool, _>("ttl") {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: Argon2 login commits digest-only 24-hour session and required audit");
    if !matches!(
        first
            .login(
                &config.emails[1],
                password.expose().to_owned(),
                ClientType::Android,
                config.run_id
            )
            .await,
        Err(ApplicationError::InvalidCredentials)
    ) {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: disabled account returns same invalid-credential outcome");
    let limited = first
        .login(
            &config.emails[2],
            password.expose().to_owned(),
            ClientType::Android,
            config.run_id,
        )
        .await?;
    if !limited.limited {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: temporary account receives limited session");
    let proof = first.session_proof(issued.token.expose(), Some(issued.auth_context_id));
    let limited_proof = first.session_proof(limited.token.expose(), None);
    let wrong_context = first.session_proof(issued.token.expose(), Some(Uuid::new_v4()));
    if !matches!(
        first.list_workspaces(&wrong_context, None, 20).await,
        Err(ApplicationError::Conflict)
    ) || !matches!(
        first.list_workspaces(&limited_proof, None, 20).await,
        Err(ApplicationError::PasswordChangeRequired)
    ) {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: stale Web context and limited session cannot read workspace picker");
    workspace_checks(&first, &second, &proof, &pool, &config, &password, checks).await?;
    realtime_checks(&first, &second, &proof, &config, checks).await?;
    session_checks(&first, &pool, &config, &password, &issued, checks).await?;
    audit_probe::verify(&pool, &config, checks).await?;
    pool.close().await;
    second_pool.close().await;
    Ok(())
}

/**
 * Kiểm logout đúng phiên, binding CAS và đổi mật khẩu account tạm qua use case thật.
 * Input
 * Param: service — composition application + PostgreSQL + crypto thật.
 * Param: pool — chỉ dùng seed/probe metadata dưới role tạm, không bypass use case mutation.
 * Param: config — marker fixture và correlation không secret.
 * Param: password — credential tổng hợp chỉ trong bộ nhớ.
 * Param: web — phiên Web cần kiểm stale-context/logout idempotency.
 * Param: checks — evidence chỉ thêm sau invariant đạt.
 * Output: known revoked session trả SessionRevoked; token unknown vẫn là SessionInvalid, không log credential/verifier.
 */
async fn session_checks(
    service: &AuthService,
    pool: &PgPool,
    config: &ProbeConfig,
    password: &SecretString,
    web: &iot_platform_backend::domain::identity::IssuedSession,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let app = service
        .login(
            &config.emails[0],
            password.expose().to_owned(),
            ClientType::Android,
            config.run_id,
        )
        .await?;
    // Installation đã rebind sang S2: logout S1 không được xóa S2, token/proof ở fixture không dùng thật.
    sqlx::query("INSERT INTO push_installations(installation_id,installation_proof_digest,platform,permission_state,binding_generation,active_user_id,active_session_id,app_version) VALUES($1,$2,'ANDROID','UNKNOWN',1,$3,$4,$5)")
        .bind(config.run_id).bind([19_u8;32].as_slice()).bind(app.user_id).bind(app.session_id).bind(format!("REPOSITORY_PROBE:{}",config.run_id))
        .execute(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let wrong = service.session_proof(web.token.expose(), Some(Uuid::new_v4()));
    if !matches!(
        service.logout(&wrong, config.run_id).await,
        Err(ApplicationError::Conflict)
    ) {
        return Err(ApplicationError::Conflict);
    }
    let proof = service.session_proof(web.token.expose(), Some(web.auth_context_id));
    let workspace = service
        .list_workspaces(&proof, None, 1)
        .await?
        .first()
        .ok_or(ApplicationError::Conflict)?
        .workspace_id;
    let web_ticket = service
        .issue_realtime_ticket(&proof, workspace, config.run_id)
        .await?;
    let app_proof = service.session_proof(app.token.expose(), None);
    let app_ticket = service
        .issue_realtime_ticket(&app_proof, workspace, config.run_id)
        .await?;
    service.logout(&proof, config.run_id).await?;
    service.logout(&proof, config.run_id).await?;
    // Digest đã biết và có revoked_at phải giữ mã riêng để caller phân biệt revoke với token chưa tồn tại.
    if !matches!(
        service.list_workspaces(&proof, None, 20).await,
        Err(ApplicationError::SessionRevoked)
    ) {
        return Err(ApplicationError::Conflict);
    }
    let audits: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM audit_events WHERE session_id=$1 AND event_type='LOGOUT'",
    )
    .bind(web.session_id)
    .fetch_one(pool)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    if audits != 1 {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: stale context cannot logout; recognized revoked session is idempotent with one audit");
    let app_proof = service.session_proof(app.token.expose(), None);
    if service.list_workspaces(&app_proof, None, 20).await?.len() != 5 {
        return Err(ApplicationError::Conflict);
    }
    let still_bound: bool = sqlx::query_scalar(
        "SELECT active_session_id=$2 FROM push_installations WHERE installation_id=$1",
    )
    .bind(config.run_id)
    .bind(app.session_id)
    .fetch_one(pool)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    if !still_bound {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: logout S1 preserves S2 session and installation rebound to S2");
    if !matches!(
        service
            .consume_realtime_ticket(web_ticket.token.expose())
            .await,
        Err(ApplicationError::Forbidden)
    ) || service
        .consume_realtime_ticket(app_ticket.token.expose())
        .await?
        .session_id
        != app.session_id
    {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: logout S1 invalidates its realtime ticket and preserves S2 ticket");
    service.logout(&app_proof, config.run_id).await?;
    let cleared:bool=sqlx::query_scalar("SELECT active_session_id IS NULL AND active_user_id IS NULL AND binding_generation=2 FROM push_installations WHERE installation_id=$1")
        .bind(config.run_id).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let intents:i64=sqlx::query_scalar("SELECT count(*) FROM outbox_events WHERE event_type='SESSION_REVOKED' AND payload->>'userId'=$1")
        .bind(app.user_id.to_string()).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !cleared || intents != 2 {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: revocation atomically clears matching binding and commits one durable close intent per session");
    password_checks(service, pool, config, password, checks).await
}

/**
 * Kiểm ticket issue/current binding và hai consume qua pool độc lập chỉ có một winner.
 * Input
 * Param: first — service instance A dùng pool riêng.
 * Param: second — service instance B cùng key cấu hình, không chia mutex ứng dụng.
 * Param: proof — full session đã xác thực của tenant fixture.
 * Param: config — correlation/identity không secret để cleanup.
 * Param: checks — tên kiểm chỉ thêm sau invariant đạt.
 * Output: hoàn thành hoặc lỗi; raw ticket không đi vào output/evidence.
 */
async fn realtime_checks(
    first: &AuthService,
    second: &AuthService,
    proof: &iot_platform_backend::domain::identity::SessionProof,
    config: &ProbeConfig,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let workspace = first
        .list_workspaces(proof, None, 1)
        .await?
        .first()
        .ok_or(ApplicationError::Conflict)?
        .workspace_id;
    let ticket = first
        .issue_realtime_ticket(proof, workspace, config.run_id)
        .await?;
    // Hai future cùng dùng ticket trên pool độc lập; CAS database quyết định winner, không dùng khóa RAM.
    let (left, right) = tokio::join!(
        first.consume_realtime_ticket(ticket.token.expose()),
        second.consume_realtime_ticket(ticket.token.expose())
    );
    let ((Ok(binding), Err(ApplicationError::Forbidden))
    | (Err(ApplicationError::Forbidden), Ok(binding))) = (left, right)
    else {
        return Err(ApplicationError::Conflict);
    };
    if binding.workspace_id != workspace || binding.user_id != config.user_ids[0] {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: realtime ticket across two pools has one consume winner with bound workspace and principal");
    Ok(())
}

/**
 * Kiểm sai password không logout, limited recovery và credential cũ bị revoke sau commit.
 * Input
 * Param: service — use case dùng ports thật, không sửa trực tiếp bảng User/Session.
 * Param: config — email account tạm và marker/correlation của fixture.
 * Param: password — mật khẩu hiện hành tổng hợp, không trả vào evidence.
 * Param: checks — danh sách kiểm đã đạt, không chứa dữ liệu credential.
 * Output: hoàn thành sau workflow thật hoặc lỗi đã lọc.
 */
async fn password_checks(
    service: &AuthService,
    pool: &PgPool,
    config: &ProbeConfig,
    password: &SecretString,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let temporary = service
        .login(
            &config.emails[2],
            password.expose().to_owned(),
            ClientType::Android,
            config.run_id,
        )
        .await?;
    let proof = service.session_proof(temporary.token.expose(), None);
    let next = generate_token();
    if !matches!(
        service
            .change_password(
                &proof,
                generate_token().expose().to_owned(),
                next.expose().to_owned(),
                config.run_id
            )
            .await,
        Err(ApplicationError::InvalidCredentials)
    ) || !matches!(
        service.list_workspaces(&proof, None, 20).await,
        Err(ApplicationError::PasswordChangeRequired)
    ) {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: incorrect current password preserves the existing limited session");
    service
        .change_password(
            &proof,
            password.expose().to_owned(),
            next.expose().to_owned(),
            config.run_id,
        )
        .await?;
    // Password change đặt revoked_at cho session cũ; giữ distinct error như logout chủ động.
    if !matches!(
        service.list_workspaces(&proof, None, 20).await,
        Err(ApplicationError::SessionRevoked)
    ) || !matches!(
        service
            .login(
                &config.emails[2],
                password.expose().to_owned(),
                ClientType::Android,
                config.run_id
            )
            .await,
        Err(ApplicationError::InvalidCredentials)
    ) {
        return Err(ApplicationError::Conflict);
    }
    let fresh = service
        .login(
            &config.emails[2],
            next.expose().to_owned(),
            ClientType::Android,
            config.run_id,
        )
        .await?;
    if fresh.limited {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: password change revokes old sessions and old credential; new login is full");
    let recipient_proof = service.session_proof(fresh.token.expose(), None);
    invitation_checks(service, pool, config, password, &recipient_proof, checks).await?;
    password_reset_probe::verify(service, pool, config, password, checks).await?;
    membership_probe::verify(service, pool, config, password, checks).await?;
    password_revocation_checks(service, pool, config, password, checks).await
}

/// Context kiểm lời mời chỉ giữ tham chiếu fixture; không Debug để tránh lộ proof.
#[derive(Clone, Copy)]
struct InvitationProbe<'a> {
    service: &'a AuthService,
    pool: &'a PgPool,
    config: &'a ProbeConfig,
    proof: &'a iot_platform_backend::domain::identity::SessionProof,
    recipient: &'a iot_platform_backend::domain::identity::SessionProof,
    workspace: Uuid,
}

/**
 * Kiểm lời mời qua application thật và hai pool, dùng raw SQL chỉ dựng các trạng thái biên fixture.
 * Input
 * Param: service — instance A với crypto/adapter thật.
 * Param: pool — pool probe để đọc kết quả và dựng expiry/revocation tổng hợp.
 * Param: config — UUID/email tổng hợp có marker ownership.
 * Param: password — credential fixture issuer chỉ giữ trong bộ nhớ.
 * Param: recipient — full session sau khi account tạm đã tự đổi password.
 * Param: checks — evidence được thêm sau khi từng invariant đạt.
 * Output: hoàn thành hoặc lỗi đã lọc; không log raw invitation token.
 */
async fn invitation_checks(
    service: &AuthService,
    pool: &PgPool,
    config: &ProbeConfig,
    password: &SecretString,
    recipient: &iot_platform_backend::domain::identity::SessionProof,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let issuer = service
        .login(
            &config.emails[0],
            password.expose().to_owned(),
            ClientType::Android,
            config.run_id,
        )
        .await?;
    let proof = service.session_proof(issuer.token.expose(), None);
    let workspace = service
        .list_workspaces(&proof, None, 1)
        .await?
        .first()
        .ok_or(ApplicationError::Conflict)?
        .workspace_id;
    let key = request_key();
    let created = service
        .create_invitation(
            &proof,
            workspace,
            &config.emails[2],
            WorkspaceRole::User,
            &key,
            config.run_id,
        )
        .await?;
    let token = created.token.ok_or(ApplicationError::Conflict)?;
    let replay = service
        .create_invitation(
            &proof,
            workspace,
            &config.emails[2],
            WorkspaceRole::User,
            &key,
            config.run_id,
        )
        .await?;
    if replay.invitation_id != created.invitation_id
        || replay.token.is_some()
        || !matches!(
            service
                .create_invitation(
                    &proof,
                    workspace,
                    &config.emails[2],
                    WorkspaceRole::Admin,
                    &key,
                    config.run_id
                )
                .await,
            Err(ApplicationError::Conflict)
        )
    {
        return Err(ApplicationError::Conflict);
    }
    let stored:bool=sqlx::query_scalar("SELECT octet_length(token_digest)=32 AND expires_at=issued_at+interval '24 hours' FROM workspace_invitations WHERE workspace_id=$1 AND invitation_id=$2")
        .bind(workspace).bind(created.invitation_id).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !stored {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: Admin invitation is digest-only 24h; create replay hides token and different body conflicts");
    if !matches!(
        service
            .accept_invitation(&proof, token.expose(), &request_key(), config.run_id)
            .await,
        Err(ApplicationError::InvitationRecipientMismatch)
    ) {
        return Err(ApplicationError::Conflict);
    }
    checks.push(
        "PASS: invitation recipient email mismatch cannot consume token or create membership",
    );
    let context = InvitationProbe {
        service,
        pool,
        config,
        proof: &proof,
        recipient,
        workspace,
    };
    let winner = invitation_consume_checks(&context, &token, checks).await?;
    invitation_rejoin_checks(&context, &token, created.invitation_id, &winner, checks).await?;
    invitation_stale_issuer_checks(&context, checks).await?;
    invitation_admission_fence_checks(&context, checks).await
}

/**
 * Kiểm hai pool cạnh tranh để chứng minh consume không dựa mutex trong process.
 * Input
 * Param: context — service/pool/proof và identity fixture đã chuẩn bị.
 * Param: token — capability tổng hợp chỉ giữ trong bộ nhớ.
 * Param: checks — danh sách evidence chỉ thêm sau invariant đạt.
 * Output: key của winner để kiểm replay; lỗi nếu số winner/audit/grant không đúng.
 */
async fn invitation_consume_checks(
    context: &InvitationProbe<'_>,
    token: &SecretString,
    checks: &mut Vec<&'static str>,
) -> Result<iot_platform_backend::domain::idempotency::IdempotencyKey, ApplicationError> {
    let service = context.service;
    let pool = context.pool;
    let config = context.config;
    let recipient = context.recipient;
    let workspace = context.workspace;
    let other_pool = connect_local_probe(config.port, &config.username, &config.password).await?;
    let other = IdentityService::new(
        PgIdentityStore::new(other_pool.clone()),
        CryptoService::new(PasswordService::default(), config.limiter_key).await?,
    );
    let first_key = request_key();
    let second_key = request_key();
    let (first_result, second_result) = tokio::join!(
        service.accept_invitation(recipient, token.expose(), &first_key, config.run_id),
        other.accept_invitation(recipient, token.expose(), &second_key, config.run_id)
    );
    let winner = match (first_result, second_result) {
        (Ok(id), Err(ApplicationError::InvitationUnavailable)) if id == workspace => first_key,
        (Err(ApplicationError::InvitationUnavailable), Ok(id)) if id == workspace => second_key,
        _ => return Err(ApplicationError::Conflict),
    };
    if service
        .accept_invitation(recipient, token.expose(), &winner, config.run_id)
        .await?
        != workspace
    {
        return Err(ApplicationError::Conflict);
    }
    let audits:i64=sqlx::query_scalar("SELECT count(*) FROM audit_events WHERE workspace_id=$1 AND actor_user_id=$2 AND event_type='INVITATION_ACCEPTED'")
        .bind(workspace).bind(config.user_ids[2]).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if audits != 1 {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: two pools consume one invitation once; same-key retry replays one grant and one audit");
    other_pool.close().await;
    Ok(winner)
}

/**
 * Kiểm suspend/remove/rejoin và expiry để grant cũ không được hồi sinh qua lời mời.
 * Input
 * Param: context — scoped fixture và authority tổng hợp của issuer/recipient.
 * Param: token — capability cũ dùng kiểm replay không vượt current authority.
 * Param: `original_id` — invitation đã consume để seed một expired pending độc lập.
 * Param: winner — intent key đã thành công, không tạo key mới khi retry.
 * Param: checks — danh sách evidence chỉ thêm sau invariant đạt.
 * Output: hoàn thành hoặc lỗi nếu generation, pending expiry hay replay sai policy.
 */
async fn invitation_rejoin_checks(
    context: &InvitationProbe<'_>,
    token: &SecretString,
    original_id: Uuid,
    winner: &iot_platform_backend::domain::idempotency::IdempotencyKey,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let InvitationProbe {
        service,
        pool,
        config,
        proof,
        recipient,
        workspace,
    } = *context;
    // Trạng thái SUSPENDED tổng hợp kiểm receipt không vượt current authority; chưa là member API acceptance.
    sqlx::query("UPDATE memberships SET status='SUSPENDED',authorization_version=authorization_version+1,revision=revision+1 WHERE workspace_id=$1 AND user_id=$2")
        .bind(workspace).bind(config.user_ids[2]).execute(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !matches!(
        service
            .accept_invitation(recipient, token.expose(), winner, config.run_id)
            .await,
        Err(ApplicationError::Forbidden)
    ) || !matches!(
        service
            .create_invitation(
                proof,
                workspace,
                &config.emails[2],
                WorkspaceRole::User,
                &request_key(),
                config.run_id
            )
            .await,
        Err(ApplicationError::Conflict)
    ) {
        return Err(ApplicationError::Conflict);
    }
    checks.push(
        "PASS: suspended membership blocks accept replay and cannot be resumed by a new invitation",
    );
    // Dựng remove bằng cùng transaction để current grant không bao giờ commit trái trạng thái.
    let mut removal = pool
        .begin()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    sqlx::query("UPDATE memberships SET status='REMOVED',removed_at=clock_timestamp(),authorization_version=authorization_version+1,revision=revision+1 WHERE workspace_id=$1 AND user_id=$2")
        .bind(workspace).bind(config.user_ids[2]).execute(&mut *removal).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query("UPDATE membership_grants SET revoked_at=clock_timestamp() WHERE workspace_id=$1 AND user_id=$2 AND revoked_at IS NULL")
        .bind(workspace).bind(config.user_ids[2]).execute(&mut *removal).await.map_err(|_|ApplicationError::Unavailable)?;
    removal
        .commit()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    // Seed expired pending từ snapshot đã used; identity mới, không sửa bất kỳ immutable timestamp nào.
    let fresh_token = invitation_expiry_checks(context, original_id, checks).await?;
    service
        .accept_invitation(
            recipient,
            fresh_token.expose(),
            &request_key(),
            config.run_id,
        )
        .await?;
    let generations:bool=sqlx::query_scalar("SELECT membership.current_grant_generation=2 AND old_grant.revoked_at IS NOT NULL AND new_grant.revoked_at IS NULL FROM memberships membership JOIN membership_grants old_grant ON old_grant.workspace_id=membership.workspace_id AND old_grant.user_id=membership.user_id AND old_grant.grant_generation=1 JOIN membership_grants new_grant ON new_grant.workspace_id=membership.workspace_id AND new_grant.user_id=membership.user_id AND new_grant.grant_generation=2 WHERE membership.workspace_id=$1 AND membership.user_id=$2")
        .bind(workspace).bind(config.user_ids[2]).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !generations
        || !matches!(
            service
                .accept_invitation(recipient, token.expose(), winner, config.run_id)
                .await,
            Err(ApplicationError::Forbidden)
        )
    {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: remove/reinvite creates grant two and old receipt cannot cross the new grant generation");
    Ok(())
}

/**
 * Kiểm token hết hạn và pending expiry không chặn lời mời mới lâu dài.
 * Input
 * Param: context — scoped fixture và authority hiện hành cho issue/accept.
 * Param: `original_id` — invitation đã used để dựng expired pending với identity mới.
 * Param: checks — danh sách evidence chỉ thêm sau expiry/reinvite đạt.
 * Output: token lời mời mới chỉ trong bộ nhớ; lỗi nếu token hết hạn còn được consume.
 */
async fn invitation_expiry_checks(
    context: &InvitationProbe<'_>,
    original_id: Uuid,
    checks: &mut Vec<&'static str>,
) -> Result<SecretString, ApplicationError> {
    let InvitationProbe {
        service,
        pool,
        config,
        proof,
        recipient,
        workspace,
    } = *context;
    let expired_id = Uuid::new_v4();
    let expired_token = generate_token();
    let expired_digest = Sha256::digest(expired_token.expose().as_bytes());
    sqlx::query("INSERT INTO workspace_invitations(workspace_id,invitation_id,token_digest,email_normalized,email_digest,role,issued_by_user_id,issuer_grant_generation,issuer_authorization_version,admission_generation,issued_at,expires_at) SELECT workspace_id,$3,$4,email_normalized,email_digest,role,issued_by_user_id,issuer_grant_generation,issuer_authorization_version,admission_generation,transaction_timestamp()-interval '25 hours',transaction_timestamp()-interval '25 hours'+interval '24 hours' FROM workspace_invitations WHERE workspace_id=$1 AND invitation_id=$2")
        .bind(workspace).bind(original_id).bind(expired_id).bind(expired_digest.as_slice()).execute(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !matches!(
        service
            .accept_invitation(
                recipient,
                expired_token.expose(),
                &request_key(),
                config.run_id
            )
            .await,
        Err(ApplicationError::InvitationUnavailable)
    ) {
        return Err(ApplicationError::Conflict);
    }
    checks.push(
        "PASS: expired invitation cannot consume or rejoin even before expiry is materialized",
    );
    let fresh = service
        .create_invitation(
            proof,
            workspace,
            &config.emails[2],
            WorkspaceRole::User,
            &request_key(),
            config.run_id,
        )
        .await?;
    let expired:bool=sqlx::query_scalar("SELECT expired_at IS NOT NULL FROM workspace_invitations WHERE workspace_id=$1 AND invitation_id=$2")
        .bind(workspace).bind(expired_id).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !expired {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: expired pending invitation is materialized under email fence and does not block reinvite");
    let fresh_token = fresh.token.ok_or(ApplicationError::Conflict)?;
    Ok(fresh_token)
}

/**
 * Kiểm token chưa consume bị từ chối khi auth version issuer thay đổi.
 * Input
 * Param: context — fixture có hai workspace để tránh suy quyền giữa các tenant.
 * Param: checks — danh sách evidence chỉ thêm sau khi kiểm deny đạt.
 * Output: hoàn thành hoặc lỗi nếu lời mời vẫn dùng được với authority cũ.
 */
async fn invitation_stale_issuer_checks(
    context: &InvitationProbe<'_>,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let InvitationProbe {
        service,
        pool,
        config,
        proof,
        recipient,
        workspace: _,
    } = *context;
    // Account đã có membership ở W1 vẫn có thể nhận lời mời W2; version issuer khác làm token W2 stale.
    let workspace_two = service
        .list_workspaces(proof, None, 2)
        .await?
        .get(1)
        .ok_or(ApplicationError::Conflict)?
        .workspace_id;
    let stale = service
        .create_invitation(
            proof,
            workspace_two,
            &config.emails[2],
            WorkspaceRole::User,
            &request_key(),
            config.run_id,
        )
        .await?;
    sqlx::query("UPDATE memberships SET authorization_version=authorization_version+1,revision=revision+1 WHERE workspace_id=$1 AND user_id=$2")
        .bind(workspace_two).bind(config.user_ids[0]).execute(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !matches!(
        service
            .accept_invitation(
                recipient,
                stale.token.ok_or(ApplicationError::Conflict)?.expose(),
                &request_key(),
                config.run_id
            )
            .await,
        Err(ApplicationError::InvitationUnavailable)
    ) {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: issuer authorization-version change invalidates an unconsumed invitation in its own workspace");
    Ok(())
}

/**
 * Kiểm admission generation riêng biệt với issuer version để remove/reinvite không mở lại token cũ.
 * Input
 * Param: context — actor/recipient đã xác thực và workspace fixture chưa có membership người nhận.
 * Param: checks — danh sách evidence chỉ thêm sau khi lời mời cũ bị chặn.
 * Output: hoàn thành hoặc lỗi nếu generation cũ vẫn cấp membership; không log token.
 */
async fn invitation_admission_fence_checks(
    context: &InvitationProbe<'_>,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let workspace = context
        .service
        .list_workspaces(context.proof, None, 3)
        .await?
        .get(2)
        .ok_or(ApplicationError::Conflict)?
        .workspace_id;
    let invitation = context
        .service
        .create_invitation(
            context.proof,
            workspace,
            &context.config.emails[2],
            WorkspaceRole::User,
            &request_key(),
            context.config.run_id,
        )
        .await?;
    // Chỉ tiến fence tổng hợp; token snapshot giữ nguyên như khi một membership workflow vô hiệu admission trước đó.
    sqlx::query("UPDATE membership_admission_fences fence SET admission_generation=fence.admission_generation+1,updated_at=clock_timestamp() FROM workspace_invitations invitation WHERE fence.workspace_id=$1 AND invitation.workspace_id=fence.workspace_id AND invitation.email_digest=fence.email_digest AND invitation.invitation_id=$2")
        .bind(workspace).bind(invitation.invitation_id).execute(context.pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !matches!(
        context
            .service
            .accept_invitation(
                context.recipient,
                invitation.token.ok_or(ApplicationError::Conflict)?.expose(),
                &request_key(),
                context.config.run_id
            )
            .await,
        Err(ApplicationError::InvitationUnavailable)
    ) {
        return Err(ApplicationError::Conflict);
    }
    checks.push(
        "PASS: current admission generation rejects a token with an older email fence snapshot",
    );
    Ok(())
}

/**
 * Regression trigger/repository: đổi password phải revoke cả session, ticket, binding và close intent.
 * Input
 * Param: service — application use case thật, không gọi UPDATE credential trực tiếp.
 * Param: pool — chỉ tạo capability fixture và đọc kết quả không secret.
 * Param: config — marker sở hữu fixture/correlation của lượt chạy.
 * Param: password — credential tổng hợp hiện hành chỉ trong bộ nhớ.
 * Param: checks — tên kiểm sau khi invariant đủ thành phần đã đạt.
 * Output: hoàn thành hoặc conflict nếu trigger và adapter làm rơi side-effect obligation.
 */
async fn password_revocation_checks(
    service: &AuthService,
    pool: &PgPool,
    config: &ProbeConfig,
    password: &SecretString,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let app = service
        .login(
            &config.emails[0],
            password.expose().to_owned(),
            ClientType::Android,
            config.run_id,
        )
        .await?;
    let web = service
        .login(
            &config.emails[0],
            password.expose().to_owned(),
            ClientType::Web,
            config.run_id,
        )
        .await?;
    let proof = service.session_proof(app.token.expose(), None);
    let web_proof = service.session_proof(web.token.expose(), Some(web.auth_context_id));
    // Member race có thể demote actor ở A; chọn tenant còn current Admin thay vì giả định trang đầu luôn là Admin.
    let workspace = service
        .list_workspaces(&proof, None, 5)
        .await?
        .into_iter()
        .find(|workspace| workspace.role == WorkspaceRole::Admin)
        .ok_or(ApplicationError::Conflict)?
        .workspace_id;
    let admission = service.admit_workspace(&proof, workspace, true).await?;
    // Binding mới dùng S3, generation3; password change phải clear đúng S3 và tăng generation thêm một lần.
    sqlx::query("UPDATE push_installations SET active_user_id=$2,active_session_id=$3,binding_generation=3 WHERE installation_id=$1")
        .bind(config.run_id).bind(app.user_id).bind(app.session_id).execute(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let ticket = Uuid::new_v4();
    // Instant CTE volatile được materialize một lần để TTL30giây không lệch do hai lần đọc clock.
    sqlx::query("WITH instant AS(SELECT clock_timestamp() AS issued) INSERT INTO websocket_tickets(ticket_id,ticket_digest,workspace_id,user_id,session_id,grant_generation,workspace_authorization_version,membership_authorization_version,issued_at,expires_at) SELECT $1,$2,$3,$4,$5,$6,$7,$8,issued,issued+interval '30 seconds' FROM instant")
        .bind(ticket).bind([23_u8;32].as_slice()).bind(workspace).bind(app.user_id).bind(app.session_id).bind(admission.grant_generation)
        .bind(admission.workspace_authorization_version).bind(admission.membership_authorization_version).execute(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    service
        .change_password(
            &proof,
            password.expose().to_owned(),
            generate_token().expose().to_owned(),
            config.run_id,
        )
        .await?;
    // Cả session Web cũ đều có revoked_at sau commit; probe khóa semantics chính xác của known revoked token.
    if !matches!(
        service.list_workspaces(&web_proof, None, 20).await,
        Err(ApplicationError::SessionRevoked)
    ) {
        return Err(ApplicationError::Conflict);
    }
    let cleared:bool=sqlx::query_scalar("SELECT active_session_id IS NULL AND active_user_id IS NULL AND binding_generation=4 FROM push_installations WHERE installation_id=$1")
        .bind(config.run_id).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let revoked: bool = sqlx::query_scalar(
        "SELECT revoked_at IS NOT NULL FROM websocket_tickets WHERE ticket_id=$1",
    )
    .bind(ticket)
    .fetch_one(pool)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    let intents:i64=sqlx::query_scalar("SELECT count(*) FROM outbox_events WHERE event_type='SESSION_REVOKED' AND payload->>'sessionId'=ANY($1)")
        .bind(vec![app.session_id.to_string(),web.session_id.to_string()]).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !cleared || !revoked || intents != 2 {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: password change atomically revokes two sessions, WebSocket ticket, matching push binding and both close intents");
    Ok(())
}

/**
 * Kiểm workspace aggregate/quota/scope qua application use case và adapter thật.
 * Input
 * Param: first — service đã nối adapter PostgreSQL, không gọi repository SQL trực tiếp.
 * Param: proof — session Web đã đăng nhập của fixture.
 * Param: config — correlation/identity của lượt kiểm.
 * Param: checks — danh sách evidence, chỉ thêm sau khi invariant đạt.
 * Output: hoàn thành hoặc lỗi đã lọc, không secret trong chẩn đoán.
 */
async fn workspace_checks(
    first: &AuthService,
    second: &AuthService,
    proof: &iot_platform_backend::domain::identity::SessionProof,
    pool: &PgPool,
    config: &ProbeConfig,
    password: &SecretString,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let key = request_key();
    let workspace = first
        .create_workspace(proof, "Repository probe", None, "UTC", &key, config.run_id)
        .await?;
    let admission = first.admit_workspace(proof, workspace, true).await?;
    if admission.role != WorkspaceRole::Admin
        || admission.grant_generation != 1
        || first.list_workspaces(proof, None, 20).await?.len() != 1
    {
        return Err(ApplicationError::Conflict);
    }
    if !matches!(
        first.admit_workspace(proof, Uuid::new_v4(), false).await,
        Err(ApplicationError::Forbidden)
    ) {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: workspace plus capable Admin and current grant commit atomically");
    checks.push("PASS: arbitrary cross-workspace selector grants no authority");
    idempotency_checks(first, proof, pool, config, &key, workspace, checks).await?;
    for _ in 0..3 {
        first
            .create_workspace(
                proof,
                "Repository quota probe",
                None,
                "UTC",
                &request_key(),
                config.run_id,
            )
            .await?;
    }
    let left_key = request_key();
    let right_key = request_key();
    // Hai instance cùng admission khi đã có4 tenant; User fence và quota phải cho đúng một winner.
    let (left, right) = tokio::join!(
        first.create_workspace(proof, "Quota A", None, "UTC", &left_key, config.run_id),
        second.create_workspace(proof, "Quota B", None, "UTC", &right_key, config.run_id)
    );
    if !matches!(
        (left, right),
        (Ok(_), Err(ApplicationError::Conflict)) | (Err(ApplicationError::Conflict), Ok(_))
    ) || first.list_workspaces(proof, None, 100).await?.len() != 5
    {
        return Err(ApplicationError::Conflict);
    }
    checks.push(
        "PASS: concurrent workspace create across two pools respects quota five with one winner",
    );
    audit_checks(first, proof, pool, config, password, workspace, checks).await
}

/**
 * Kiểm cùng intent không nhân đôi resource/audit, body guard và cached replay vẫn kiểm current authority.
 * Input
 * Param: service — application use case có idempotency port thật.
 * Param: proof — session đã chọn context; không dùng cached result làm quyền.
 * Param: pool — chỉ thay trạng thái fixture có marker để inject suspension.
 * Param: config — correlation của fixture, không secret.
 * Param: key — key của create intent gốc; mọi retry phải giữ nguyên.
 * Param: workspace — UUID đã trả từ create gốc.
 * Param: checks — evidence chỉ thêm sau khi từng invariant đạt.
 * Output: hoàn thành hoặc conflict nếu duplicate/mismatch/authorization guard sai.
 */
async fn idempotency_checks(
    service: &AuthService,
    proof: &iot_platform_backend::domain::identity::SessionProof,
    pool: &PgPool,
    config: &ProbeConfig,
    key: &iot_platform_backend::domain::idempotency::IdempotencyKey,
    workspace: Uuid,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let (left, right) = tokio::join!(
        service.create_workspace(proof, "Repository probe", None, "UTC", key, config.run_id),
        service.create_workspace(proof, "Repository probe", None, "UTC", key, config.run_id)
    );
    if left? != workspace
        || right? != workspace
        || service.list_workspaces(proof, None, 20).await?.len() != 1
    {
        return Err(ApplicationError::Conflict);
    }
    if !matches!(
        service
            .create_workspace(proof, "Different body", None, "UTC", key, config.run_id)
            .await,
        Err(ApplicationError::Conflict)
    ) {
        return Err(ApplicationError::Conflict);
    }
    let audits:i64=sqlx::query_scalar("SELECT count(*) FROM audit_events WHERE workspace_id=$1 AND event_type='WORKSPACE_CREATED'")
        .bind(workspace).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if audits != 1 {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: duplicate workspace-create intent replays one resource/audit and rejects different body");
    // Không đổi provenance/resource identity; replay khi suspended phải bị từ chối dù receipt đã completed.
    sqlx::query("UPDATE workspaces SET status='SUSPENDED' WHERE workspace_id=$1")
        .bind(workspace)
        .execute(pool)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    let blocked = service
        .create_workspace(proof, "Repository probe", None, "UTC", key, config.run_id)
        .await;
    sqlx::query("UPDATE workspaces SET status='ACTIVE' WHERE workspace_id=$1")
        .bind(workspace)
        .execute(pool)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    if !matches!(blocked, Err(ApplicationError::Forbidden)) {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: completed idempotency receipt cannot bypass current workspace suspension");
    Ok(())
}

/**
 * Kiểm Admin-only audit, logical retention/keyset và negative global/foreign workspace.
 * Input
 * Param: service — use case thông qua transaction port thật.
 * Param: proof — principal Admin của fixture workspace.
 * Param: pool — chỉ seed membership/audit fixture; không dùng để authorize request.
 * Param: config — correlation và identity tổng hợp để cleanup có marker.
 * Param: password — credential tổng hợp của member test, không log.
 * Param: workspace — tenant fixture cần cô lập read audit.
 * Param: checks — tên kiểm sau khi invariant đạt.
 * Output: hoàn thành hoặc lỗi đã lọc, không SELECT diff/credential.
 */
async fn audit_checks(
    service: &AuthService,
    proof: &iot_platform_backend::domain::identity::SessionProof,
    pool: &PgPool,
    config: &ProbeConfig,
    password: &SecretString,
    workspace: Uuid,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let mut transaction = pool
        .begin()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    // Fixture member USER độc lập, không thay role Admin của actor để tránh làm yếu kiểm current authority.
    sqlx::query("UPDATE users SET account_status='ACTIVE' WHERE user_id=$1")
        .bind(config.user_ids[1])
        .execute(&mut *transaction)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO memberships(workspace_id,user_id,role,current_grant_generation) VALUES($1,$2,'USER',1)")
        .bind(workspace).bind(config.user_ids[1]).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query(
        "INSERT INTO membership_grants(workspace_id,user_id,grant_generation) VALUES($1,$2,1)",
    )
    .bind(workspace)
    .bind(config.user_ids[1])
    .execute(&mut *transaction)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    // Hai audit projection tổng hợp: một current, một31 ngày để kiểm cutoff mà không chờ purge.
    for age in [0_i32, 31] {
        sqlx::query("INSERT INTO audit_events(audit_event_id,workspace_id,actor_user_id,event_type,outcome,correlation_id,occurred_at,created_at,client_type) VALUES($1,$2,$3,'AUDIT_SCOPE_PROBE','SUCCESS',$4,clock_timestamp()-make_interval(days=>$5),clock_timestamp()-make_interval(days=>$5),'UNKNOWN')")
            .bind(Uuid::new_v4()).bind(workspace).bind(config.user_ids[0]).bind(config.run_id).bind(age).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    }
    transaction
        .commit()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    let entries = service.list_audit(proof, workspace, None, 100).await?;
    if entries.len() != 2
        || entries
            .iter()
            .any(|entry| entry.workspace_id != workspace || entry.event_type.starts_with("LOGIN"))
    {
        return Err(ApplicationError::Conflict);
    }
    let first = service.list_audit(proof, workspace, None, 1).await?;
    let cursor = iot_platform_backend::domain::audit::AuditCursor {
        created_at: first[0].created_at,
        audit_event_id: first[0].audit_event_id,
    };
    let second = service
        .list_audit(proof, workspace, Some(&cursor), 100)
        .await?;
    if second.len() != 1 || second[0].audit_event_id == first[0].audit_event_id {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: Admin audit read excludes global/other workspace and expired rows; keyset has no duplicate");
    let member = service
        .login(
            &config.emails[1],
            password.expose().to_owned(),
            ClientType::Android,
            config.run_id,
        )
        .await?;
    let member_proof = service.session_proof(member.token.expose(), None);
    if !matches!(
        service.list_audit(&member_proof, workspace, None, 20).await,
        Err(ApplicationError::Forbidden)
    ) || !matches!(
        service
            .list_audit(&member_proof, Uuid::new_v4(), None, 20)
            .await,
        Err(ApplicationError::Forbidden)
    ) {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: USER membership and foreign workspace selectors cannot read audit");
    audit_time_probe::verify(service, proof, pool, config, workspace, checks).await
}

/// Nhận secret qua stdin trước mọi I/O DB; chỉ in tên check hoặc lỗi đã lọc, không panic với `SQLx` error.
#[tokio::main]
async fn main() {
    let mut input = String::new();
    if io::stdin().take(8192).read_to_string(&mut input).is_err() {
        std::process::exit(2);
    }
    let Ok(config) = serde_json::from_str::<ProbeConfig>(&input) else {
        std::process::exit(2);
    };
    let mut checks = Vec::new();
    let result = match config.phase {
        ProbePhase::MemberCreation => member_creation_probe::verify(config, &mut checks).await,
        ProbePhase::Preferences => preferences_probe::verify(config, &mut checks).await,
        ProbePhase::InvitationManagement => {
            invitation_management_probe::verify(config, &mut checks).await
        }
        ProbePhase::Outbox => outbox_probe::verify(config, &mut checks).await,
        ProbePhase::Template => template_probe::verify(config, &mut checks).await,
        ProbePhase::Device => device_probe::verify(config, &mut checks, false).await,
        ProbePhase::DeviceAuthority => device_probe::verify(config, &mut checks, true).await,
        ProbePhase::Retention => audit_retention_probe::verify(config, &mut checks).await,
        ProbePhase::RetentionFailure => {
            audit_retention_probe::verify_failure(config, &mut checks).await
        }
        ProbePhase::AuditFailure => audit_fault_probe::verify(config, &mut checks).await,
        ProbePhase::Normal => verify(config, &mut checks).await,
    };
    match result {
        Ok(()) => println!(
            "{}",
            serde_json::to_string(&checks).unwrap_or_else(|_| "[]".into())
        ),
        Err(error) => {
            println!("FAIL:{error}; completed={checks:?}");
            std::process::exit(1);
        }
    }
}
