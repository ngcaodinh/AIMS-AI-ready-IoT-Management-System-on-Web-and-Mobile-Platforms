//! Issue/consume realtime qua port, capability chỉ được phát hoặc chấp nhận sau commit.

use crate::{
    error::ApplicationError,
    identity::IdentityService,
    ports::{
        IdentitySecurity, IdentityStore, IdentityTransaction, RealtimeSessionStore,
        RealtimeTransaction, WorkspaceTransaction,
    },
};
use chrono::TimeDelta;
use iot_domain::audit_write::AuditDetail;
use iot_domain::{
    identity::{AuditRecord, SessionProof},
    realtime::{IssuedWebSocketTicket, NewWebSocketTicket, RealtimeBinding},
};
use std::collections::HashSet;
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
}

impl<S: IdentityStore + RealtimeSessionStore, C: IdentitySecurity> IdentityService<S, C> {
    /**
     * Chấp nhận một consume winner còn quyền hiện hành mà không ACK trước khi storage chốt kết quả.
     * Input
     * Param: token — ticket raw tạm từ frame đầu, không được log, đặt trong URL hoặc lưu plaintext.
     * Output: binding đã commit để transport đăng ký socket; không là authority cached cho action sau.
     * Errors: Forbidden cho ticket invalid/expired/consumed/revoked; lỗi storage/commit giữ nguyên UNKNOWN.
     */
    pub async fn consume_realtime_ticket(
        &self,
        token: &str,
    ) -> Result<RealtimeBinding, ApplicationError> {
        // Token hex256bit theo issuer, chặn input quá lớn trước crypto/storage.
        if token.len() != 64 || !token.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(ApplicationError::Forbidden);
        }
        self.store
            .consume_realtime_ticket(self.security.token_digest(token))
            .await?
            .ok_or(ApplicationError::Forbidden)
    }
}

impl<S: IdentityStore + RealtimeSessionStore, C: IdentitySecurity> IdentityService<S, C> {
    /**
     * Đối soát subset session socket của instance với trạng thái DB hiện hành để worker đóng phiên cũ.
     * Input
     * Param: session_ids — danh sách ID đã lấy từ socket registry local, không phải authority client.
     * Output: ID còn active; session vắng khỏi tập kết quả phải bị đóng.
     * Errors: storage unavailable; transport caller phải fail-closed thay vì giữ socket sống.
     */
    pub async fn active_realtime_sessions(
        &self,
        session_ids: &[Uuid],
    ) -> Result<HashSet<Uuid>, ApplicationError> {
        self.store
            .active_realtime_sessions(session_ids.to_vec())
            .await
    }

    /**
     * Đối soát session vừa consume trước ACK để thu hồi ngay nếu logout chen giữa hai bước.
     * Input
     * Param: session_id — ID lấy từ binding ticket đã commit và registry local.
     * Output: true khi session còn active; false khi revoke/hết hạn/account không hoạt động.
     * Errors: lỗi storage đã chuẩn hóa; caller đóng socket và giữ quota tới khi adapter hoàn tất checkout.
     */
    pub async fn active_realtime_session_for_handshake(
        &self,
        session_id: Uuid,
    ) -> Result<bool, ApplicationError> {
        self.store
            .active_realtime_session_for_handshake(session_id)
            .await
    }
}
