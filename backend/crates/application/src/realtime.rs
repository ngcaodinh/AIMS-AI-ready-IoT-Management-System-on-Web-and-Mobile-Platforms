//! Issue/consume realtime qua port, capability chỉ được phát hoặc chấp nhận sau commit.

use crate::{
    error::ApplicationError,
    identity::IdentityService,
    ports::{
        IdentitySecurity, IdentityStore, IdentityTransaction, RealtimeTransaction,
        WorkspaceTransaction,
    },
};
use chrono::TimeDelta;
use iot_domain::audit_write::AuditDetail;
use iot_domain::{
    identity::{AuditRecord, SessionProof},
    realtime::{IssuedWebSocketTicket, NewWebSocketTicket, RealtimeBinding},
};
use uuid::Uuid;

impl<S: IdentityStore, C: IdentitySecurity> IdentityService<S, C>
where
    S::Transaction: RealtimeTransaction,
{
    /**
     * Cấp ticket30giây gắn current session/grant/auth-version, không dùng picker cache làm authority.
     * Input
     * Param: proof — session/context hiện hành; limited bị chặn trước khi tạo ticket.
     * Param: `workspace_id` — tenant selector cần ACTIVE membership/current grant.
     * Param: `correlation_id` — identity request để required audit cùng commit.
     * Output: ticket raw một lần sau commit, DB chỉ giữ digest.
     * # Errors
     * Session/context/limited, forbidden hoặc audit/storage/commit unknown; không phát ticket khi lỗi.
     */
    pub async fn issue_realtime_ticket(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        correlation_id: Uuid,
    ) -> Result<IssuedWebSocketTicket, ApplicationError> {
        let mut transaction = self.store.begin().await?;
        let locked = transaction.lock_session(proof).await?;
        let principal =
            locked
                .session
                .authorize(&locked.account, proof, locked.observed_at, false)?;
        let admission = transaction
            .lock_workspace(workspace_id, principal.user_id())
            .await?
            .authorize(&principal, false)?;
        let (token, digest) = self.security.issue_token();
        let ticket = NewWebSocketTicket {
            ticket_id: Uuid::new_v4(),
            digest,
            workspace_id,
            user_id: principal.user_id(),
            session_id: principal.session_id(),
            grant_generation: admission.grant_generation,
            workspace_authorization_version: admission.workspace_authorization_version,
            membership_authorization_version: admission.membership_authorization_version,
            issued_at: locked.observed_at,
            expires_at: locked.observed_at + TimeDelta::seconds(30),
        };
        transaction.insert_ticket(&ticket).await?;
        transaction
            .append_audit(AuditRecord {
                workspace_id: Some(workspace_id),
                actor_user_id: Some(principal.user_id()),
                session_id: Some(principal.session_id()),
                detail: AuditDetail::RealtimeTicketIssued {
                    ticket_id: ticket.ticket_id,
                },
                client_type: principal.client_type(),
                correlation_id,
            })
            .await?;
        transaction.commit().await?;
        Ok(IssuedWebSocketTicket {
            token,
            expires_at: ticket.expires_at,
        })
    }

    /**
     * Chấp nhận chỉ một consume winner còn quyền hiện hành; không tự mở socket trước COMMIT ACK.
     * Input
     * Param: token — ticket raw tạm từ client, không được log, đặt trong URL hoặc lưu plaintext.
     * Output: binding sau commit để transport đăng ký socket; không là authority cached cho action tương lai.
     * # Errors
     * Forbidden cho ticket không nhận diện/expired/consumed/revoked/stale auth; commit unknown không giả winner.
     */
    pub async fn consume_realtime_ticket(
        &self,
        token: &str,
    ) -> Result<RealtimeBinding, ApplicationError> {
        // Token hex256bit theo issuer, chặn input quá lớn trước crypto/storage.
        if token.len() != 64 || !token.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(ApplicationError::Forbidden);
        }
        let mut transaction = self.store.begin().await?;
        let binding = transaction
            .consume_ticket(self.security.token_digest(token))
            .await?
            .ok_or(ApplicationError::Forbidden)?;
        transaction.commit().await?;
        Ok(binding)
    }
}
