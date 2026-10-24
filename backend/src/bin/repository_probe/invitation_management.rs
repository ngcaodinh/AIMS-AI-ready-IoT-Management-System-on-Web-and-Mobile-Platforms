//! Metadata/revoke probe hai pool, không cần provider và không in accept capability.

use super::{
    ApplicationError, AuthService, PgIdentityStore, PgPool, ProbeConfig, WorkspaceRole,
    preferences_probe::seed_session, request_key,
};
use iot_platform_backend::{
    adapters::security::{CryptoService, PasswordService},
    application::ports::IdentitySecurity,
    domain::{identity::SessionProof, invitation_management::InvitationStatus},
    postgres::connection::connect_local_probe,
};
use uuid::Uuid;

struct InvitationProbe<'a> {
    first: &'a AuthService,
    second: &'a AuthService,
    pool: &'a PgPool,
    config: &'a ProbeConfig,
    admin: &'a SessionProof,
    recipient: &'a SessionProof,
    workspace_id: Uuid,
    crypto: &'a CryptoService,
}

impl InvitationProbe<'_> {
    /**
     * Phát invitation USER qua use case thật cho nhiều nhánh probe, không lặp hoặc seed capability giả.
     * Input
     * Param: `email_index` — vị trí email synthetic do launcher cấp; chỉ dùng index nội bộ đã biết.
     * Output: invitation mới cùng token một lần trong bộ nhớ; Errors: authority/conflict/storage đã lọc.
     */
    async fn issue(
        &self,
        email_index: usize,
    ) -> Result<iot_platform_backend::domain::invitation::IssuedInvitation, ApplicationError> {
        self.first
            .create_invitation(
                self.admin,
                self.workspace_id,
                &self.config.emails[email_index],
                WorkspaceRole::User,
                &request_key(),
                self.config.run_id,
            )
            .await
    }
}

/**
 * Chạy quản trị invitation với Admin/recipient synthetic từ các phase trước, không đọc credential.
 * Input
 * Param: config — DB transport và identity/correlation thuộc run.
 * Param: checks — tên invariant chỉ thêm sau khi đạt thật.
 * Output: hoàn tất và đóng hai pool; Errors: ownership/invariant/storage đã lọc.
 */
pub(super) async fn verify(
    config: ProbeConfig,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let pool = connect_local_probe(config.port, &config.username, &config.password).await?;
    let second_pool = connect_local_probe(config.port, &config.username, &config.password).await?;
    let crypto = CryptoService::new(PasswordService::default(), config.limiter_key).await?;
    let first = AuthService::new(PgIdentityStore::new(pool.clone()), crypto.clone());
    let second = AuthService::new(PgIdentityStore::new(second_pool.clone()), crypto.clone());
    // Actor5 đã được CRT tạo có marker, current Admin của tenant riêng; không chọn account người dùng.
    let workspace:Uuid=sqlx::query_scalar("SELECT workspace_id FROM workspaces JOIN users account ON account.user_id=created_by_user_id WHERE created_by_user_id=$1 AND account.activation_provenance=$2").bind(config.user_ids[5]).bind(format!("REPOSITORY_PROBE:{}",config.run_id)).fetch_one(&pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let admin = seed_session(&first, &pool, config.user_ids[5], false).await?;
    let recipient = seed_session(&first, &pool, config.user_ids[1], false).await?;
    let context = InvitationProbe {
        first: &first,
        second: &second,
        pool: &pool,
        config: &config,
        admin: &admin,
        recipient: &recipient,
        workspace_id: workspace,
        crypto: &crypto,
    };
    for index in [11, 12, 13] {
        first
            .create_invitation(
                &admin,
                workspace,
                &config.emails[index],
                WorkspaceRole::User,
                &request_key(),
                config.run_id,
            )
            .await?;
    }
    verify_pages(&context).await?;
    checks.push("PASS: current Admin reads metadata-only invitation pages with stable keyset/status and bounded limits");
    verify_revoke(&context).await?;
    checks.push("PASS: two-pool revoke CAS has one winner, native revision2, one audit and current-revision no-op; revoked token cannot join");
    verify_accept_race(&context).await?;
    checks.push("PASS: accept versus revoke has one terminal winner and used invitation remains conflict instead of rewritten truth");
    verify_scope_and_expiry(&context).await?;
    checks.push("PASS: expired invitation metadata needs no cron and revoke denies expired, foreign Admin and full USER without crossing workspace scope");
    pool.close().await;
    second_pool.close().await;
    Ok(())
}

/**
 * Kiểm keyset/status trên metadata projection không chứa raw token/digest.
 * Input
 * Param: context — full Admin/tenant của fixture, hai pool dùng cùng DB.
 * Output: ít nhất hai trang khác nhau và không vượt limit; Errors: Conflict/storage.
 */
async fn verify_pages(context: &InvitationProbe<'_>) -> Result<(), ApplicationError> {
    let page = context
        .first
        .list_invitations(
            context.admin,
            context.workspace_id,
            Some(InvitationStatus::Pending),
            None,
            1,
        )
        .await?;
    if page.entries.len() != 1
        || page.entries[0].status != InvitationStatus::Pending
        || page.next_cursor.is_none()
    {
        return Err(ApplicationError::Conflict);
    }
    let next = context
        .second
        .list_invitations(
            context.admin,
            context.workspace_id,
            Some(InvitationStatus::Pending),
            page.next_cursor.as_ref(),
            1,
        )
        .await?;
    if next.entries.len() != 1
        || page.entries[0].metadata.invitation_id == next.entries[0].metadata.invitation_id
    {
        return Err(ApplicationError::Conflict);
    }
    let read = context
        .first
        .get_invitation(
            context.admin,
            context.workspace_id,
            page.entries[0].metadata.invitation_id,
        )
        .await?;
    if read.metadata.workspace_id != context.workspace_id
        || read.metadata.revision != 1
        || read.status != InvitationStatus::Pending
        || !matches!(
            context
                .first
                .list_invitations(context.admin, context.workspace_id, None, None, 101)
                .await,
            Err(ApplicationError::InvalidInput)
        )
    {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}

/**
 * Tranh cùng revoke revision qua hai pool, rồi kiểm no-op không audit lặp và accept bị vô hiệu.
 * Input
 * Param: context — issuer Admin và recipient đúng email, không cross-account token giả.
 * Output:1 terminal/audit, revision2 và không có membership mới; Errors: Conflict/storage.
 */
async fn verify_revoke(context: &InvitationProbe<'_>) -> Result<(), ApplicationError> {
    let invitation = context.issue(1).await?;
    let (left, right) = tokio::join!(
        context.first.revoke_invitation(
            context.admin,
            context.workspace_id,
            invitation.invitation_id,
            1,
            context.config.run_id
        ),
        context.second.revoke_invitation(
            context.admin,
            context.workspace_id,
            invitation.invitation_id,
            1,
            context.config.run_id
        )
    );
    if !matches!(
        (left, right),
        (Ok(()), Err(ApplicationError::StaleRevision))
            | (Err(ApplicationError::StaleRevision), Ok(()))
    ) {
        return Err(ApplicationError::Conflict);
    }
    let read = context
        .first
        .get_invitation(
            context.admin,
            context.workspace_id,
            invitation.invitation_id,
        )
        .await?;
    if read.status != InvitationStatus::Revoked || read.metadata.revision != 2 {
        return Err(ApplicationError::Conflict);
    }
    context
        .first
        .revoke_invitation(
            context.admin,
            context.workspace_id,
            invitation.invitation_id,
            2,
            context.config.run_id,
        )
        .await?;
    let token = invitation.token.ok_or(ApplicationError::Conflict)?;
    if !matches!(
        context
            .second
            .accept_invitation(
                context.recipient,
                token.expose(),
                &request_key(),
                context.config.run_id
            )
            .await,
        Err(ApplicationError::InvitationUnavailable)
    ) {
        return Err(ApplicationError::Conflict);
    }
    // Resource/correlation chọn đúng mutation; no-op/retry không thêm audit hoặc member ngầm.
    let correct:bool=sqlx::query_scalar("SELECT (SELECT count(*)=1 AND bool_and(redacted_diff->>'revision_before'='1' AND redacted_diff->>'revision_after'='2') FROM audit_events WHERE workspace_id=$1 AND resource_id=$2::uuid::text AND correlation_id=$3 AND event_type='INVITATION_REVOKED') AND NOT EXISTS(SELECT 1 FROM memberships WHERE workspace_id=$1 AND user_id=$4)").bind(context.workspace_id).bind(invitation.invitation_id).bind(context.config.run_id).bind(context.config.user_ids[1]).fetch_one(context.pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !correct {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}

/**
 * Tranh accept/revoke bằng đúng recipient và issuer, giữ một terminal và kiểm used409.
 * Input
 * Param: context — snapshot principal hiện hành cùng namespace fixture.
 * Output: winner duy nhất; nếu revoke thắng tạo invitation mới để kiểm used branch thực tế.
 */
async fn verify_accept_race(context: &InvitationProbe<'_>) -> Result<(), ApplicationError> {
    let issued = context.issue(1).await?;
    let token = issued.token.ok_or(ApplicationError::Conflict)?;
    let accept_key = request_key();
    let (revoked, accepted) = tokio::join!(
        context.first.revoke_invitation(
            context.admin,
            context.workspace_id,
            issued.invitation_id,
            1,
            context.config.run_id
        ),
        context.second.accept_invitation(
            context.recipient,
            token.expose(),
            &accept_key,
            context.config.run_id
        )
    );
    let used_id = match (revoked, accepted) {
        (Err(ApplicationError::Conflict), Ok(workspace)) if workspace == context.workspace_id => {
            issued.invitation_id
        }
        (Ok(()), Err(ApplicationError::InvitationUnavailable)) => {
            let next = context.issue(1).await?;
            let token = next.token.ok_or(ApplicationError::Conflict)?;
            context
                .second
                .accept_invitation(
                    context.recipient,
                    token.expose(),
                    &request_key(),
                    context.config.run_id,
                )
                .await?;
            next.invitation_id
        }
        _ => return Err(ApplicationError::Conflict),
    };
    let used = context
        .first
        .get_invitation(context.admin, context.workspace_id, used_id)
        .await?;
    if used.status != InvitationStatus::Used
        || used.metadata.revision != 2
        || !matches!(
            context
                .first
                .revoke_invitation(
                    context.admin,
                    context.workspace_id,
                    used_id,
                    1,
                    context.config.run_id
                )
                .await,
            Err(ApplicationError::Conflict)
        )
    {
        return Err(ApplicationError::Conflict);
    }
    let page = context
        .first
        .list_invitations(
            context.admin,
            context.workspace_id,
            Some(InvitationStatus::Used),
            None,
            100,
        )
        .await?;
    if page.entries.is_empty()
        || page
            .entries
            .iter()
            .any(|entry| entry.status != InvitationStatus::Used)
    {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}

/**
 * Dựng expired chưa materialize để kiểm deadline/filter, rồi chứng minh foreign/full USER bị deny.
 * Input
 * Param: context — fixture scope/Admin/crypto không lấy secret từ DB.
 * Output: expired native row giữ revision1 và `expired_at` NULL, metadata vẫn Expired và không thể revoke.
 */
async fn verify_scope_and_expiry(context: &InvitationProbe<'_>) -> Result<(), ApplicationError> {
    let digest = context.crypto.bucket_digest(&context.config.emails[10])?;
    let (_, token_digest) = context.crypto.issue_token();
    let id = Uuid::new_v4();
    let admission = context
        .first
        .admit_workspace(context.admin, context.workspace_id, true)
        .await?;
    let mut transaction = context
        .pool
        .begin()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    // Native-valid fixture đã hết hạn, không sửa identity timestamp của invitation đã phát hành.
    sqlx::query("INSERT INTO membership_admission_fences(workspace_id,email_digest,admission_generation) VALUES($1,$2,1) ON CONFLICT DO NOTHING").bind(context.workspace_id).bind(digest.as_slice()).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    sqlx::query("INSERT INTO workspace_invitations(workspace_id,invitation_id,email_normalized,email_digest,token_digest,role,issued_by_user_id,issuer_grant_generation,issuer_authorization_version,admission_generation,issued_at,expires_at) VALUES($1,$2,$3,$4,$5,'USER',$6,$7,$8,1,statement_timestamp()-interval '25 hours',statement_timestamp()-interval '1 hour')").bind(context.workspace_id).bind(id).bind(&context.config.emails[10]).bind(digest.as_slice()).bind(token_digest.as_slice()).bind(context.config.user_ids[5]).bind(admission.grant_generation).bind(admission.membership_authorization_version).execute(&mut *transaction).await.map_err(|_|ApplicationError::Unavailable)?;
    transaction
        .commit()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    let read = context
        .first
        .get_invitation(context.admin, context.workspace_id, id)
        .await?;
    if read.status != InvitationStatus::Expired
        || read.metadata.expired_at.is_some()
        || read.metadata.revision != 1
        || !matches!(
            context
                .first
                .revoke_invitation(
                    context.admin,
                    context.workspace_id,
                    id,
                    1,
                    context.config.run_id
                )
                .await,
            Err(ApplicationError::InvitationUnavailable)
        )
    {
        return Err(ApplicationError::Conflict);
    }
    let page = context
        .first
        .list_invitations(
            context.admin,
            context.workspace_id,
            Some(InvitationStatus::Expired),
            None,
            100,
        )
        .await?;
    if !page
        .entries
        .iter()
        .any(|entry| entry.metadata.invitation_id == id)
        || page
            .entries
            .iter()
            .any(|entry| entry.status != InvitationStatus::Expired)
    {
        return Err(ApplicationError::Conflict);
    }
    let foreign = seed_session(
        context.first,
        context.pool,
        context.config.user_ids[6],
        false,
    )
    .await?;
    if !matches!(
        context
            .first
            .get_invitation(&foreign, context.workspace_id, id)
            .await,
        Err(ApplicationError::Forbidden)
    ) || !matches!(
        context
            .first
            .revoke_invitation(
                context.recipient,
                context.workspace_id,
                id,
                1,
                context.config.run_id
            )
            .await,
        Err(ApplicationError::Forbidden)
    ) || !matches!(
        context
            .first
            .list_invitations(context.recipient, context.workspace_id, None, None, 1)
            .await,
        Err(ApplicationError::Forbidden)
    ) {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}

/**
 * Required audit INSERT denial phải rollback cả `revoked_at` và native revision increment.
 * Input
 * Param: service — use case thật, role probe hiện không được INSERT audit.
 * Param: pool — fixture session seed/reader chỉ trong namespace đã chứng minh sở hữu.
 * Param: config — Admin5/email11 pending đã được normal phase tạo.
 * Output: pending revision1 vẫn giữ sau lỗi, không partial terminal; Errors: Conflict/storage.
 */
pub(super) async fn verify_failure(
    service: &AuthService,
    pool: &PgPool,
    config: &ProbeConfig,
) -> Result<(), ApplicationError> {
    let (workspace,id):(Uuid,Uuid)=sqlx::query_as("SELECT invitation.workspace_id,invitation_id FROM workspace_invitations invitation JOIN workspaces workspace USING(workspace_id) WHERE workspace.created_by_user_id=$1 AND email_normalized=$2 AND used_at IS NULL AND revoked_at IS NULL AND expired_at IS NULL").bind(config.user_ids[5]).bind(&config.emails[11]).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let proof = seed_session(service, pool, config.user_ids[5], false).await?;
    let before = service.get_invitation(&proof, workspace, id).await?;
    if !matches!(
        service
            .revoke_invitation(
                &proof,
                workspace,
                id,
                before.metadata.revision,
                config.run_id
            )
            .await,
        Err(ApplicationError::Unavailable)
    ) {
        return Err(ApplicationError::Conflict);
    }
    let after = service.get_invitation(&proof, workspace, id).await?;
    if before.status != InvitationStatus::Pending
        || after.status != InvitationStatus::Pending
        || after.metadata.revision != before.metadata.revision
        || after.metadata.revoked_at.is_some()
    {
        return Err(ApplicationError::Conflict);
    }
    Ok(())
}
