//! Tạo member bằng use case thật; fixtures riêng tránh làm lệch quota/manifest của các slice trước.

use super::{
    ApplicationError, AuthService, ClientType, PgIdentityStore, PgPool, ProbeConfig, WorkspaceRole,
    request_key,
};
use iot_platform_backend::{
    adapters::security::{CryptoService, PasswordService, generate_token},
    domain::{
        identity::SessionProof,
        member_creation::{MemberCreationOutcome, MemberCreationRequest},
    },
    postgres::connection::connect_local_probe,
};
use uuid::Uuid;
#[path = "member_creation_security.rs"]
mod security_probe;
use security_probe::HashProbeSecurity;
use std::sync::atomic::{AtomicU64, Ordering};
type CreationService = iot_platform_backend::application::identity::IdentityService<
    PgIdentityStore,
    HashProbeSecurity,
>;

/**
 * Đo hash counter trước request không có quyền để bắt thứ tự hash-before-authorization.
 * Input
 * Param: first — service có crypto decorator nhưng mọi policy/SQL giữ nguyên.
 * Param: pool — đọc current member, không có credential input từ DB.
 * Param: config — email/correlation synthetic của test.
 * Param: proof — Admin full session dùng tạo proof sai context và selector sai.
 * Param: `workspace_id` — tenant hợp lệ để body không gây lỗi trước authorization.
 * Param: calls — counter hash chia sẻ giữa hai instance test.
 * Output: denied request phải gọi0 hash; Errors: Conflict nếu chiếm hasher trước deny.
 */
async fn verify_denied_cost(
    first: &CreationService,
    pool: &PgPool,
    config: &ProbeConfig,
    proof: &SessionProof,
    workspace_id: Uuid,
    calls: &AtomicU64,
) -> Result<(), ApplicationError> {
    let request = MemberCreationRequest::new(&config.emails[10], "Denied", WorkspaceRole::User)
        .ok_or(ApplicationError::InvalidInput)?;
    let before = calls.load(Ordering::SeqCst);
    let invalid = SessionProof {
        token_digest: [0; 32],
        expected_context: None,
    };
    if !matches!(
        first
            .create_member(
                &invalid,
                workspace_id,
                &request,
                &request_key(),
                config.run_id
            )
            .await,
        Err(ApplicationError::SessionInvalid)
    ) {
        return Err(ApplicationError::Conflict);
    }
    if !matches!(
        first
            .create_member(
                proof,
                Uuid::new_v4(),
                &request,
                &request_key(),
                config.run_id
            )
            .await,
        Err(ApplicationError::Forbidden)
    ) {
        return Err(ApplicationError::Conflict);
    }
    // Giữ tham số pool cho assertion native không có side effect ở email bị deny.
    let absent: bool =
        sqlx::query_scalar("SELECT NOT EXISTS(SELECT 1 FROM users WHERE email_normalized=$1)")
            .bind(&config.emails[10])
            .fetch_one(pool)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
    if calls.load(Ordering::SeqCst) != before || !absent {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}

/**
 * Đối chiếu audit credential global/admission tenant và allowlist receipt không secret.
 * Input
 * Param: pool — đọc metadata synthetic bằng parameter binding, không đọc PHC/token.
 * Param: config — email/correlation run để chỉ chọn account vừa tạo qua use case.
 * Output: hai audit đúng scope/resource và receipt chỉ có projection; Errors: Conflict nếu lệch mapping.
 */
async fn verify_creation_metadata(
    pool: &PgPool,
    config: &ProbeConfig,
) -> Result<(), ApplicationError> {
    // Actor/session đã được writer authorize; ở đây kiểm riêng resource/scope và không có hồ sơ trong metadata.
    let correct:bool=sqlx::query_scalar("SELECT count(*) FILTER(WHERE audit.event_type='TEMPORARY_ACCOUNT_CREATED' AND audit.workspace_id IS NULL AND audit.resource_type='USER' AND audit.redacted_diff->>'secret_changed'='true')=1 AND count(*) FILTER(WHERE audit.event_type='MEMBERSHIP_CREATED' AND audit.workspace_id IS NOT NULL AND audit.resource_type='MEMBERSHIP' AND audit.redacted_diff->>'role'='USER')=1 AND bool_and(NOT EXISTS(SELECT 1 FROM jsonb_object_keys(audit.redacted_diff) key WHERE key NOT IN('schema_version','phase','result','actor_type','secret_changed','role'))) FROM audit_events audit JOIN users account ON audit.resource_id=account.user_id::text WHERE account.email_normalized=$1 AND audit.correlation_id=$2 AND audit.event_type IN('TEMPORARY_ACCOUNT_CREATED','MEMBERSHIP_CREATED')")
        .bind(&config.emails[8]).bind(config.run_id).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    // Receipt chỉ giữ enum/UUID/expiry, tuyệt đối không serialize IssuedMemberCreation.secret.
    let safe:bool=sqlx::query_scalar("SELECT count(*)>=3 AND bool_and(state='COMPLETED' AND NOT EXISTS(SELECT 1 FROM jsonb_object_keys(sanitized_result) key WHERE key NOT IN('kind','resourceId','expiresAt'))) FROM workspace_idempotency_records WHERE route_key='MEMBER_CREATE_V1' AND user_id=ANY($1)")
        .bind(&config.user_ids[5..7]).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !correct || !safe {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}

/**
 * Dựng hai Admin độc lập để race email không bị serialize sẵn bởi cùng actor/tenant.
 * Input
 * Param: service — application thật để login/create workspace.
 * Param: pool — fixture writer cấp riêng, chỉ seed identity có marker run.
 * Param: config — namespace và IDs do launcher sinh trước khi test.
 * Param: index — chỉ5/6 là principal dành riêng cho create-member probe.
 * Output: full App proof và tenant của Admin; Errors: lỗi đã lọc, không in credential.
 */
async fn admin(
    service: &CreationService,
    pool: &PgPool,
    config: &ProbeConfig,
    index: usize,
) -> Result<(SessionProof, Uuid), ApplicationError> {
    let password = generate_token();
    let verifier = PasswordService::default()
        .hash(password.expose().to_owned())
        .await?;
    // Identity fixture chỉ thuộc run, không dùng quyền owner để gọi business mutation.
    sqlx::query("INSERT INTO users(user_id,email_normalized,password_hash,account_status,must_change_password,activated_at,activation_provenance) VALUES($1,$2,$3,'ACTIVE',false,clock_timestamp(),$4)")
        .bind(config.user_ids[index]).bind(&config.emails[index+1]).bind(verifier).bind(format!("REPOSITORY_PROBE:{}",config.run_id)).execute(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let issued = service
        .login(
            &config.emails[index + 1],
            password.expose().to_owned(),
            ClientType::Android,
            config.run_id,
        )
        .await?;
    let proof = service.session_proof(issued.token.expose(), None);
    let workspace = service
        .create_workspace(
            &proof,
            "Create member fixture",
            None,
            "UTC",
            &request_key(),
            config.run_id,
        )
        .await?;
    Ok((proof, workspace))
}

/**
 * Kiểm create/replay, account toàn cục và branch invitation bằng hai pool PostgreSQL độc lập.
 * Input
 * Param: config — transport SCRAM tạm nhận qua stdin, không đọc env.
 * Param: checks — tên invariant chỉ thêm sau assertion thật.
 * Output: hoàn tất và đóng pool; Errors: conflict khi invariant không khớp.
 */
pub(super) async fn verify(
    config: ProbeConfig,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let pool = connect_local_probe(config.port, &config.username, &config.password).await?;
    let other_pool = connect_local_probe(config.port, &config.username, &config.password).await?;
    let inner = CryptoService::new(PasswordService::default(), config.limiter_key).await?;
    let crypto = HashProbeSecurity::new(inner.clone());
    let calls = crypto.calls.clone();
    let first = CreationService::new(PgIdentityStore::new(pool.clone()), crypto.clone());
    let second = CreationService::new(PgIdentityStore::new(other_pool.clone()), crypto);
    let (first_proof, first_workspace) = admin(&first, &pool, &config, 5).await?;
    let (second_proof, second_workspace) = admin(&second, &pool, &config, 6).await?;
    verify_replay(
        &first,
        &second,
        &pool,
        &config,
        [
            (&first_proof, first_workspace),
            (&second_proof, second_workspace),
        ],
        checks,
        &calls,
    )
    .await?;
    verify_email_race(
        &first,
        &second,
        &pool,
        &config,
        [
            (&first_proof, first_workspace),
            (&second_proof, second_workspace),
        ],
        checks,
    )
    .await?;
    verify_denied_cost(
        &first,
        &pool,
        &config,
        &first_proof,
        first_workspace,
        &calls,
    )
    .await?;
    checks.push(
        "PASS: invalid/limited/USER/foreign member-create requests consume zero password hashes",
    );
    verify_reauthorization(&pool, &config, &first_proof, first_workspace, inner).await?;
    checks.push("PASS: workspace suspension after preflight is rechecked at final member-create fence and issues no credential");
    verify_creation_metadata(&pool, &config).await?;
    checks.push("PASS: member creation separates global credential audit from tenant admission and stores only redacted receipt projection");
    pool.close().await;
    other_pool.close().await;
    Ok(())
}

/**
 * Kiểm required audit bị từ chối thật rollback cả account mới lẫn invitation cho account cũ.
 * Input
 * Param: service — use case thật, audit INSERT đã bị launcher REVOKE trên role probe.
 * Param: pool — chỉ đọc state committed để phát hiện partial mutation/receipt.
 * Param: proof — full Admin của tenant fault đã seed có marker.
 * Param: `workspace_id` — tenant fault hợp lệ, không giả cross-workspace authority.
 * Param: config — email mới/cũ synthetic thuộc cùng run.
 * Output: không account/member/grant/invitation/receipt rò commit; Errors: Conflict nếu mutation lọt.
 */
pub(super) async fn verify_failure(
    service: &AuthService,
    pool: &PgPool,
    proof: &SessionProof,
    workspace_id: Uuid,
    config: &ProbeConfig,
) -> Result<(), ApplicationError> {
    for index in [10, 8] {
        let request =
            MemberCreationRequest::new(&config.emails[index], "Fault alias", WorkspaceRole::User)
                .ok_or(ApplicationError::InvalidInput)?;
        if !matches!(
            service
                .create_member(proof, workspace_id, &request, &request_key(), config.run_id)
                .await,
            Err(ApplicationError::Unavailable)
        ) {
            return Err(ApplicationError::Conflict);
        }
    }
    // FK không cho member/grant orphan; account mới, invitation và receipt cùng tenant phải đều vắng.
    let clean:bool=sqlx::query_scalar("SELECT NOT EXISTS(SELECT 1 FROM users WHERE email_normalized=$1) AND NOT EXISTS(SELECT 1 FROM workspace_invitations WHERE workspace_id=$2 AND email_normalized=ANY($3)) AND NOT EXISTS(SELECT 1 FROM workspace_idempotency_records WHERE workspace_id=$2 AND route_key='MEMBER_CREATE_V1')").bind(&config.emails[10]).bind(workspace_id).bind(vec![config.emails[8].clone(),config.emails[10].clone()]).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !clean {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}

/**
 * Kiểm one-time password/replay và negative current authority của workflow tạo member.
 * Input
 * Param: first — instance A gọi mutation/login/password change thật.
 * Param: second — instance B dùng pool độc lập để tranh cùng receipt.
 * Param: pool — fixture reader đọc state/digest shape, không log secret.
 * Param: config — email/correlation synthetic do launcher cấp.
 * Param: admins — hai current Admin và tenant riêng để kiểm foreign selector.
 * Param: checks — evidence chỉ ghi sau invariant đạt.
 * Param: calls — counter để limited/foreign bị chặn trước chi phí hash.
 * Output: hoàn tất hoặc lỗi invariant/storage đã lọc.
 */
async fn verify_replay(
    first: &CreationService,
    second: &CreationService,
    pool: &PgPool,
    config: &ProbeConfig,
    admins: [(&SessionProof, Uuid); 2],
    checks: &mut Vec<&'static str>,
    calls: &AtomicU64,
) -> Result<(), ApplicationError> {
    let [(first_proof, first_workspace), (second_proof, _)] = admins;
    let request =
        MemberCreationRequest::new(&config.emails[8], "  Tên riêng  ", WorkspaceRole::User)
            .ok_or(ApplicationError::InvalidInput)?;
    let key = request_key();
    let (left, right) = tokio::join!(
        first.create_member(first_proof, first_workspace, &request, &key, config.run_id),
        second.create_member(first_proof, first_workspace, &request, &key, config.run_id)
    );
    let left = left?;
    let right = right?;
    if left.outcome != right.outcome
        || usize::from(left.secret.is_some()) + usize::from(right.secret.is_some()) != 1
    {
        return Err(ApplicationError::Conflict);
    }
    let MemberCreationOutcome::Created { user_id } = left.outcome else {
        return Err(ApplicationError::Conflict);
    };
    let secret = left
        .secret
        .or(right.secret)
        .ok_or(ApplicationError::Conflict)?;
    let state: bool = sqlx::query_scalar("SELECT account.must_change_password AND account.activated_at IS NULL AND account.activation_provenance='ADMIN_TEMPORARY_V1' AND member.alias=$3 AND member.current_grant_generation=1 AND EXISTS(SELECT 1 FROM membership_grants WHERE workspace_id=$1 AND user_id=$2 AND grant_generation=1 AND revoked_at IS NULL) FROM users account JOIN memberships member USING(user_id) WHERE member.workspace_id=$1 AND account.user_id=$2")
        .bind(first_workspace).bind(user_id).bind(request.display_name()).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let login = first
        .login(
            &config.emails[8],
            secret.expose().to_owned(),
            ClientType::Android,
            config.run_id,
        )
        .await?;
    if !state || !login.limited {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: two-pool member create replays one account/grant, preserves alias and releases one password for limited login");
    let changed = MemberCreationRequest::new(&config.emails[8], "Changed", WorkspaceRole::Admin)
        .ok_or(ApplicationError::InvalidInput)?;
    if !matches!(
        first
            .create_member(first_proof, first_workspace, &changed, &key, config.run_id)
            .await,
        Err(ApplicationError::Conflict)
    ) {
        return Err(ApplicationError::Conflict);
    }
    let denied_before = calls.load(Ordering::SeqCst);
    let limited_proof = first.session_proof(login.token.expose(), None);
    if !matches!(
        first
            .create_member(
                &limited_proof,
                first_workspace,
                &request,
                &request_key(),
                config.run_id
            )
            .await,
        Err(ApplicationError::PasswordChangeRequired)
    ) || !matches!(
        first
            .create_member(
                second_proof,
                first_workspace,
                &request,
                &request_key(),
                config.run_id
            )
            .await,
        Err(ApplicationError::Forbidden)
    ) {
        return Err(ApplicationError::Conflict);
    }
    if calls.load(Ordering::SeqCst) != denied_before {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: member create rejects changed body, limited account and foreign Admin selectors before mutation");
    verify_full_user(
        first,
        config,
        first_workspace,
        &request,
        &limited_proof,
        secret.expose(),
        calls,
    )
    .await?;
    checks.push("PASS: activated full USER membership cannot use member-create administration");
    Ok(())
}

/**
 * Kiểm global email fence bằng hai actor/tenant khác nhau, tránh serialize sẵn qua receipt hoặc User.
 * Input
 * Param: first — instance A phát intent cho email canonical.
 * Param: second — instance B phát intent khác key với email hoa/whitespace cùng canonical.
 * Param: pool — đọc count account/member và shape invitation bằng SQL bind.
 * Param: config — namespace email/correlation synthetic của run.
 * Param: admins — hai current Admin độc lập cùng tenant mỗi người.
 * Param: checks — evidence chỉ thêm khi1 account/1 member/1 invitation đã xác nhận.
 * Output: hoàn tất hoặc Conflict/storage lỗi, không in response secret.
 */
async fn verify_email_race(
    first: &CreationService,
    second: &CreationService,
    pool: &PgPool,
    config: &ProbeConfig,
    admins: [(&SessionProof, Uuid); 2],
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let [
        (first_proof, first_workspace),
        (second_proof, second_workspace),
    ] = admins;
    let raw_upper = format!(" {} ", config.emails[9].to_ascii_uppercase());
    let a = MemberCreationRequest::new(&config.emails[9], "A", WorkspaceRole::User)
        .ok_or(ApplicationError::InvalidInput)?;
    let b = MemberCreationRequest::new(&raw_upper, "B", WorkspaceRole::Admin)
        .ok_or(ApplicationError::InvalidInput)?;
    let a_key = request_key();
    let b_key = request_key();
    let (left, right) = tokio::join!(
        first.create_member(first_proof, first_workspace, &a, &a_key, config.run_id),
        second.create_member(second_proof, second_workspace, &b, &b_key, config.run_id)
    );
    let left = left?;
    let right = right?;
    let (created, invited) = match (&left.outcome, &right.outcome) {
        (MemberCreationOutcome::Created { .. }, MemberCreationOutcome::Invitation { .. }) => {
            (&left, &right)
        }
        (MemberCreationOutcome::Invitation { .. }, MemberCreationOutcome::Created { .. }) => {
            (&right, &left)
        }
        _ => return Err(ApplicationError::Conflict),
    };
    let MemberCreationOutcome::Created { user_id } = created.outcome else {
        return Err(ApplicationError::Conflict);
    };
    let account_count: i64 =
        sqlx::query_scalar("SELECT count(*) FROM users WHERE email_normalized=$1")
            .bind(&config.emails[9])
            .fetch_one(pool)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
    let membership_count: i64 =
        sqlx::query_scalar("SELECT count(*) FROM memberships WHERE user_id=$1")
            .bind(user_id)
            .fetch_one(pool)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
    let MemberCreationOutcome::Invitation { invitation_id, .. } = invited.outcome else {
        return Err(ApplicationError::Conflict);
    };
    let digest_only:bool=sqlx::query_scalar("SELECT octet_length(token_digest)=32 AND expires_at-issued_at=interval '24 hours' AND used_at IS NULL FROM workspace_invitations WHERE workspace_id=$1 AND invitation_id=$2").bind(invited.workspace_id).bind(invitation_id).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if account_count != 1
        || membership_count != 1
        || !digest_only
        || created.secret.is_none()
        || invited.secret.is_none()
    {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: distinct Admins/workspaces race normalized email into one global account and one invitation without autojoin");
    Ok(())
}

/**
 * Loại trừ khả năng chỉ limited-session guard che lỗi thiếu Admin authorization.
 * Input
 * Param: first — application thật để đổi password/login rồi gọi mutation bị cấm.
 * Param: config — email/correlation synthetic của member mới.
 * Param: `workspace_id` — tenant member chỉ có role USER.
 * Param: request — body create hợp lệ để lỗi phải đến từ authority.
 * Param: `limited_proof` — phiên account tạm vừa phát, được phép đổi password.
 * Param: `temporary_password` — secret chỉ trong bộ nhớ, không log hoặc lưu receipt.
 * Param: calls — counter để full USER vẫn bị chặn trước hash.
 * Output: full USER vẫn Forbidden; Errors: Conflict nếu mutation được admit.
 */
async fn verify_full_user(
    first: &CreationService,
    config: &ProbeConfig,
    workspace_id: Uuid,
    request: &MemberCreationRequest,
    limited_proof: &SessionProof,
    temporary_password: &str,
    calls: &AtomicU64,
) -> Result<(), ApplicationError> {
    let permanent_password = generate_token();
    first
        .change_password(
            limited_proof,
            temporary_password.to_owned(),
            permanent_password.expose().to_owned(),
            config.run_id,
        )
        .await?;
    let full_user = first
        .login(
            &config.emails[8],
            permanent_password.expose().to_owned(),
            ClientType::Android,
            config.run_id,
        )
        .await?;
    let user_proof = first.session_proof(full_user.token.expose(), None);
    let before = calls.load(Ordering::SeqCst);
    if !matches!(
        first
            .create_member(
                &user_proof,
                workspace_id,
                request,
                &request_key(),
                config.run_id
            )
            .await,
        Err(ApplicationError::Forbidden)
    ) {
        return Err(ApplicationError::Conflict);
    }
    if calls.load(Ordering::SeqCst) != before {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}

/**
 * Dừng hash bằng barrier để workspace suspension chắc chắn xảy ra sau preflight và trước mutation.
 * Input
 * Param: pool — fixture writer chỉ đổi tenant đã có marker, rồi khôi phục ACTIVE.
 * Param: config — email mới/correlation synthetic, không phải account người dùng.
 * Param: proof — current Admin full session tại lúc preflight.
 * Param: `workspace_id` — tenant fixture cần suspend giữa hai lần authorize.
 * Param: crypto — crypto thật bọc barrier; không thay SQL/authorization policy.
 * Output: final fence Forbidden và không tạo account; Errors: timeout/invariant/storage đã lọc.
 */
async fn verify_reauthorization(
    pool: &PgPool,
    config: &ProbeConfig,
    proof: &SessionProof,
    workspace_id: Uuid,
    crypto: CryptoService,
) -> Result<(), ApplicationError> {
    let (security, entered, release) = HashProbeSecurity::paused(crypto);
    let service = CreationService::new(PgIdentityStore::new(pool.clone()), security);
    let request =
        MemberCreationRequest::new(&config.emails[10], "Reauthorization", WorkspaceRole::User)
            .ok_or(ApplicationError::InvalidInput)?;
    let key = request_key();
    let mutate = async {
        entered.wait().await;
        // Fixture status change có owner predicate; không dùng đường này thay lifecycle service production.
        let changed=sqlx::query("UPDATE workspaces SET status='SUSPENDED' WHERE workspace_id=$1 AND created_by_user_id=$2").bind(workspace_id).bind(config.user_ids[5]).execute(pool).await;
        release.wait().await;
        changed.map_err(|_| ApplicationError::Unavailable)
    };
    let outcome = tokio::time::timeout(std::time::Duration::from_secs(20), async {
        tokio::join!(
            service.create_member(proof, workspace_id, &request, &key, config.run_id),
            mutate
        )
    })
    .await;
    // Khôi phục fixture kể cả khi assertion fail; launcher vẫn cleanup toàn graph theo ownership guard.
    sqlx::query(
        "UPDATE workspaces SET status='ACTIVE' WHERE workspace_id=$1 AND created_by_user_id=$2",
    )
    .bind(workspace_id)
    .bind(config.user_ids[5])
    .execute(pool)
    .await
    .map_err(|_| ApplicationError::Unavailable)?;
    let (result, changed) = outcome.map_err(|_| ApplicationError::Unavailable)?;
    if changed?.rows_affected() != 1 || !matches!(result, Err(ApplicationError::Forbidden)) {
        return Err(ApplicationError::Conflict);
    }
    let absent: bool =
        sqlx::query_scalar("SELECT NOT EXISTS(SELECT 1 FROM users WHERE email_normalized=$1)")
            .bind(&config.emails[10])
            .fetch_one(pool)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
    if !absent {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}
