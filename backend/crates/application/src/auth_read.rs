//! Bootstrap chỉ trả projection được phép; discovery là đường đọc riêng, không nới domain guard chung.

use crate::{
    error::ApplicationError,
    identity::IdentityService,
    ports::{IdentitySecurity, IdentityStore, IdentityTransaction, WorkspaceTransaction},
};
use chrono::{DateTime, Utc};
use iot_domain::{
    identity::{ClientType, SessionProof},
    workspace::WorkspaceSummary,
};
use std::future::Future;
use uuid::Uuid;

/// Hồ sơ allowlist; không mang password verifier, role global hoặc dữ liệu workspace.
pub struct Profile {
    pub user_id: Uuid,
    pub email: String,
    pub display_timezone: String,
    pub preferences_revision: i64,
}

/// Metadata phiên sau admission; ID dùng đóng đúng socket phiên và limited không bao giờ có profile.
pub struct SessionInspection {
    pub user_id: Uuid,
    pub session_id: Uuid,
    pub context_id: Uuid,
    pub limited: bool,
    pub profile: Option<Profile>,
    pub expires_at: DateTime<Utc>,
}

/// Chi tiết scope sau membership admission; chỉ projection hợp đồng, không chứa grant capability.
pub struct WorkspaceDetail {
    pub summary: WorkspaceSummary,
    pub description: Option<String>,
    pub default_timezone: String,
    pub creator_id: Uuid,
    pub authorization_version: i64,
    pub membership_revision: i64,
    pub membership_authorization_version: i64,
    pub created_at: DateTime<Utc>,
    pub archived_at: Option<DateTime<Utc>>,
}

/// Snapshot page và epoch cùng một DB statement để quyền đổi không bị ghép từ hai snapshot.
pub struct WorkspacePage {
    pub authority_fingerprint: String,
    pub items: Vec<WorkspaceSummary>,
}

pub trait AuthReadTransaction: WorkspaceTransaction {
    /** Đọc hồ sơ chính chủ sau session admission; Input: `user_id` từ principal, default preference UTC/1. */
    fn read_profile(
        &mut self,
        user_id: Uuid,
    ) -> impl Future<Output = Result<Profile, ApplicationError>> + Send;
    /** Clock mới sau query/lock wait để recheck expiry trước khi phát projection. */
    fn auth_read_now(
        &mut self,
    ) -> impl Future<Output = Result<DateTime<Utc>, ApplicationError>> + Send;
    /** Page và fingerprint cùng snapshot; Input: `user_id` đã admit, after là keyset, limit có cận1–100. */
    fn read_workspace_page(
        &mut self,
        user_id: Uuid,
        after: Option<Uuid>,
        limit: i64,
    ) -> impl Future<Output = Result<WorkspacePage, ApplicationError>> + Send;
    /** Đọc detail sau parent/member lock; Input: `workspace_id` và `user_id` đã admit cùng transaction. */
    fn read_workspace_detail(
        &mut self,
        workspace_id: Uuid,
        user_id: Uuid,
    ) -> impl Future<Output = Result<WorkspaceDetail, ApplicationError>> + Send;
}

impl<S: IdentityStore, C: IdentitySecurity> IdentityService<S, C>
where
    S::Transaction: AuthReadTransaction,
{
    /**
     * Đối soát session hiện hành, chỉ cho /me headerless khám phá context mà không mutation.
     * Input
     * Param: proof — digest/context chưa được tin cậy, không profile do client tự khai.
     * Param: transport — cookie Web hoặc bearer Android/IOS đã tách tại HTTP boundary.
     * Param: discovery — chỉ true cho GET /me khi hoàn toàn không có context header.
     * Output: limited metadata không profile, hoặc hồ sơ full chính chủ.
     * # Errors
     * Credential sai transport, revoked/expired/disabled, context mismatch hoặc storage.
     */
    pub async fn inspect_session(
        &self,
        proof: &SessionProof,
        transport: ClientType,
        discovery: bool,
    ) -> Result<SessionInspection, ApplicationError> {
        let mut transaction = self.store.begin().await?;
        let locked = transaction.lock_session(proof).await?;
        if !locked.session.client_type.matches_transport(transport) {
            return Err(ApplicationError::SessionInvalid);
        }
        // Chỉ read-only discovery được đối soát context cookie hiện tại; mọi use case khác giữ nguyên proof.
        let discovery_proof = SessionProof {
            token_digest: proof.token_digest,
            expected_context: if discovery && proof.expected_context.is_none() {
                Some(locked.session.auth_context_id)
            } else {
                proof.expected_context
            },
        };
        let principal = locked.session.authorize(
            &locked.account,
            &discovery_proof,
            locked.observed_at,
            true,
        )?;
        let limited = locked.session.limited || locked.account.must_change_password;
        let profile = if limited {
            None
        } else {
            Some(transaction.read_profile(principal.user_id()).await?)
        };
        let now = transaction.auth_read_now().await?;
        locked
            .session
            .authorize(&locked.account, &discovery_proof, now, true)?;
        transaction.commit().await?;
        Ok(SessionInspection {
            user_id: principal.user_id(),
            session_id: principal.session_id(),
            context_id: locked.session.auth_context_id,
            limited,
            profile,
            expires_at: locked.session.expires_at,
        })
    }

    /**
     * Đối soát riêng logout idempotent, giữ quyền revoke khi session đã hết hạn/thu hồi.
     * Input: proof chứa context cần khớp; transport phải khớp cookie/bearer, Android/IOS cùng bearer.
     * Output: metadata không profile.
     * # Errors
     * Unknown token, sai transport/context hoặc storage.
     */
    pub async fn inspect_logout(
        &self,
        proof: &SessionProof,
        transport: ClientType,
    ) -> Result<SessionInspection, ApplicationError> {
        let mut transaction = self.store.begin().await?;
        let locked = transaction.lock_session(proof).await?;
        if !locked.session.client_type.matches_transport(transport) {
            return Err(ApplicationError::SessionInvalid);
        }
        let principal = locked
            .session
            .authorize_revocation(&locked.account, proof)?;
        transaction.commit().await?;
        Ok(SessionInspection {
            user_id: principal.user_id(),
            session_id: principal.session_id(),
            context_id: locked.session.auth_context_id,
            limited: true,
            profile: None,
            expires_at: locked.session.expires_at,
        })
    }

    /**
     * Lấy page với current authority trong cùng transaction, không tin cursor như quyền truy cập.
     * Input: proof là credential/context, after là UUID đã verify chữ ký, limit trong1–100.
     * Output: items/fingerprint.
     * # Errors
     * Session/limited/input/storage, không trả dữ liệu ngoài quyền.
     */
    pub async fn workspace_page(
        &self,
        proof: &SessionProof,
        after: Option<Uuid>,
        limit: i64,
    ) -> Result<WorkspacePage, ApplicationError> {
        if !(1..=100).contains(&limit) {
            return Err(ApplicationError::InvalidInput);
        }
        let mut transaction = self.store.begin().await?;
        let locked = transaction.lock_session(proof).await?;
        let principal =
            locked
                .session
                .authorize(&locked.account, proof, locked.observed_at, false)?;
        let page = transaction
            .read_workspace_page(principal.user_id(), after, limit)
            .await?;
        let now = transaction.auth_read_now().await?;
        locked
            .session
            .authorize(&locked.account, proof, now, false)?;
        transaction.commit().await?;
        Ok(page)
    }

    /**
     * Mở detail chỉ sau kiểm membership/grant hiện hành và recheck expiry sau lock wait.
     * Input: proof là phiên hiện tại, `workspace_id` chỉ là selector tenant chưa đáng tin.
     * Output: detail allowlist.
     * # Errors
     * Không còn membership/workspace hoặc session hết quyền.
     */
    pub async fn workspace_detail(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
    ) -> Result<WorkspaceDetail, ApplicationError> {
        let mut transaction = self.store.begin().await?;
        let locked = transaction.lock_session(proof).await?;
        let principal =
            locked
                .session
                .authorize(&locked.account, proof, locked.observed_at, false)?;
        transaction
            .lock_workspace(workspace_id, principal.user_id())
            .await?
            .authorize(&principal, false)?;
        let detail = transaction
            .read_workspace_detail(workspace_id, principal.user_id())
            .await?;
        let now = transaction.auth_read_now().await?;
        locked
            .session
            .authorize(&locked.account, proof, now, false)?;
        transaction.commit().await?;
        Ok(detail)
    }
}
