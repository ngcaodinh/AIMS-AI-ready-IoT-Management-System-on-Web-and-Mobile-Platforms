//! Fault reset qua native PHC/revoke trigger và audit denial; chỉ seed legacy capability tổng hợp hợp lệ schema.

use super::{ApplicationError, AuthService, PgPool, ProbeConfig};
use iot_platform_backend::{
    adapters::security::{PasswordService, generate_token},
    domain::{
        identity::{SecretString, SessionProof},
        password_reset::TEMPORARY_ACCOUNT_ORIGIN,
    },
};
use uuid::Uuid;

/// Verifier chỉ giữ trong bộ nhớ để SQL so sánh sau rollback; không Debug hoặc xuất trong lỗi.
struct ResetFixture {
    verifier: SecretString,
    session_id: Uuid,
    ticket_id: Uuid,
    binding_generation: i64,
}

/**
 * Tạo temporary target riêng chỉ có một membership và các capability native-valid để kiểm rollback.
 * Input
 * Param: service — chỉ dùng digest token; không phát credential qua evidence.
 * Param: pool — role probe, không quyền DDL hoặc bỏ constraint.
 * Param: `workspace_id` — tenant fault của current Admin.
 * Param: config — target mới có UUID/email/creation-audit marker do launcher sở hữu.
 * Output: verifier và IDs chỉ trong bộ nhớ; Errors: storage đã lọc.
 */
async fn seed(
    service: &AuthService,
    pool: &PgPool,
    workspace_id: Uuid,
    config: &ProbeConfig,
) -> Result<ResetFixture, ApplicationError> {
    let verifier = SecretString::new(
        PasswordService::default()
            .hash(generate_token().expose().to_owned())
            .await?,
    );
    let target = config.user_ids[4];
    let session_id = Uuid::new_v4();
    let ticket_id = Uuid::new_v4();
    let session = service.session_proof(generate_token().expose(), None);
    let ticket = service.session_proof(generate_token().expose(), None);
    let mut transaction = pool
        .begin()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    // Account có provenance rõ ràng, chưa activated và chỉ một tenant; không gắn lại legacy unknown thành temporary.
    sqlx::query("INSERT INTO users(user_id,email_normalized,password_hash,account_status,must_change_password,activation_provenance) VALUES($1,$2,$3,'ACTIVE',true,$4)")
        .bind(target).bind(&config.emails[5]).bind(verifier.expose()).bind(TEMPORARY_ACCOUNT_ORIGIN).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO memberships(workspace_id,user_id,role,current_grant_generation) VALUES($1,$2,'USER',1)")
        .bind(workspace_id).bind(target).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query(
        "INSERT INTO membership_grants(workspace_id,user_id,grant_generation) VALUES($1,$2,1)",
    )
    .bind(workspace_id)
    .bind(target)
    .execute(&mut *transaction)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO sessions(session_id,user_id,token_digest,auth_context_id,limited,client_type,issued_at,expires_at) VALUES($1,$2,$3,$4,true,'ANDROID',transaction_timestamp(),transaction_timestamp()+interval '24 hours')")
        .bind(session_id).bind(target).bind(session.token_digest.as_slice()).bind(Uuid::new_v4()).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    // Remnant chỉ mô phỏng state storage cần thu hồi; không chứng nhận limited client được issue ticket qua API.
    sqlx::query("INSERT INTO websocket_tickets(ticket_id,ticket_digest,workspace_id,user_id,session_id,grant_generation,workspace_authorization_version,membership_authorization_version,issued_at,expires_at) SELECT $1,$2,$3,$4,$5,1,authorization_version,1,transaction_timestamp(),transaction_timestamp()+interval '30 seconds' FROM workspaces WHERE workspace_id=$3")
        .bind(ticket_id).bind(ticket.token_digest.as_slice()).bind(workspace_id).bind(target).bind(session_id).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    let binding_generation = sqlx::query_scalar("UPDATE push_installations SET active_user_id=$2,active_session_id=$3,binding_generation=binding_generation+1,enabled=false WHERE installation_id=$1 AND app_version=$4 RETURNING binding_generation")
        .bind(config.run_id).bind(target).bind(session_id).bind(format!("REPOSITORY_PROBE:{}",config.run_id)).fetch_one(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    transaction
        .commit()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    Ok(ResetFixture {
        verifier,
        session_id,
        ticket_id,
        binding_generation,
    })
}

/**
 * Buộc reset hợp lệ đi tới audit bị từ chối và kiểm mọi credential/capability/admission rollback.
 * Input
 * Param: service — application/PG/crypto thật; lỗi không được trả password.
 * Param: pool — đọc committed state bằng boolean, không SELECT verifier ra log.
 * Param: proof — current full Admin của tenant fault.
 * Param: `workspace_id` — tenant duy nhất của target temporary mới.
 * Param: config — IDs/marker tổng hợp đã được launcher cấp.
 * Output: thành công khi PHC, revision, ledger, session/ticket/binding/outbox giữ nguyên.
 */
pub(super) async fn verify(
    service: &AuthService,
    pool: &PgPool,
    proof: &SessionProof,
    workspace_id: Uuid,
    config: &ProbeConfig,
) -> Result<(), ApplicationError> {
    let fixture = seed(service, pool, workspace_id, config).await?;
    let target = config.user_ids[4];
    if !matches!(
        service
            .reset_temporary_password(proof, workspace_id, target, 1, config.run_id)
            .await,
        Err(ApplicationError::Unavailable)
    ) {
        return Err(ApplicationError::Conflict);
    }
    // So sánh PHC trong engine bằng tham số; chỉ nhận boolean, không đưa PHC/digest vào evidence.
    let unchanged: bool = sqlx::query_scalar("SELECT account.password_hash=$2 AND account.must_change_password AND account.activated_at IS NULL AND account.activation_provenance=$3 AND member.revision=1 AND NOT EXISTS(SELECT 1 FROM password_reset_admissions WHERE target_user_id=$1) AND EXISTS(SELECT 1 FROM sessions WHERE session_id=$4 AND user_id=$1 AND revoked_at IS NULL) AND EXISTS(SELECT 1 FROM websocket_tickets WHERE ticket_id=$5 AND user_id=$1 AND revoked_at IS NULL) AND EXISTS(SELECT 1 FROM push_installations WHERE installation_id=$6 AND active_user_id=$1 AND active_session_id=$4 AND binding_generation=$7) AND NOT EXISTS(SELECT 1 FROM outbox_events WHERE payload->>'userId'=$1::uuid::text) FROM users account JOIN memberships member USING(user_id) WHERE account.user_id=$1 AND member.workspace_id=$8")
        .bind(target).bind(fixture.verifier.expose()).bind(TEMPORARY_ACCOUNT_ORIGIN).bind(fixture.session_id).bind(fixture.ticket_id).bind(config.run_id).bind(fixture.binding_generation).bind(workspace_id).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !unchanged {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}
