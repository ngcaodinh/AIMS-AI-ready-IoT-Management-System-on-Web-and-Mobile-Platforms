//! Lời mời là capability email-bound; quyền hiện hành phải được cung cấp lại tại mỗi lần consume.

use crate::{identity::SecretString, workspace::WorkspaceRole};
use chrono::{DateTime, Utc};
use uuid::Uuid;

/// Snapshot bất biến của lời mời; các mốc terminal chỉ tiến một chiều trong DB.
pub struct InvitationSnapshot {
    pub workspace_id: Uuid,
    pub invitation_id: Uuid,
    pub email_normalized: String,
    pub role: WorkspaceRole,
    pub issuer_user_id: Uuid,
    pub issuer_grant_generation: i64,
    pub issuer_authorization_version: i64,
    pub admission_generation: i64,
    pub issued_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub terminal: bool,
}

/// Quyền người mời được adapter đọc dưới khóa, không suy từ snapshot lúc issue.
pub struct InvitationIssuer {
    pub user_id: Uuid,
    pub capable_admin: bool,
    pub grant_generation: i64,
    pub authorization_version: i64,
}

/// Lý do từ chối được transport ánh xạ sang lỗi recipient mismatch hoặc unavailable.
#[derive(Debug, PartialEq, Eq)]
pub enum InvitationFailure {
    RecipientMismatch,
    Unavailable,
}

/// Kết quả issue; replay chỉ trả metadata và không có raw capability.
pub struct IssuedInvitation {
    pub invitation_id: Uuid,
    pub workspace_id: Uuid,
    pub expires_at: DateTime<Utc>,
    pub token: Option<SecretString>,
}

/**
 * Đóng gói role hữu hạn và raw email thành body fingerprint không nhập nhằng.
 * Input
 * Param: email — input nguyên bản trước normalize để retry khác body bị conflict.
 * Param: role — vai trò workspace được encode bằng byte cố định.
 * Output: bytes canonical cho crypto port băm, không tự lưu email vào receipt.
 */
#[must_use]
pub fn invitation_request_bytes(email: &str, role: WorkspaceRole) -> Vec<u8> {
    let mut body = vec![if role == WorkspaceRole::Admin { 1 } else { 2 }];
    body.extend_from_slice(email.as_bytes());
    body
}

impl InvitationSnapshot {
    /**
     * Tạo projection issue tối thiểu, không mang email hoặc issuer snapshot ra response.
     * Input
     * Param: token — capability một lần sau commit; None khi replay chỉ metadata.
     * Output: identity/expiry và token theo quyền tiết lộ của application.
     */
    #[must_use]
    pub fn issued(&self, token: Option<SecretString>) -> IssuedInvitation {
        IssuedInvitation {
            invitation_id: self.invitation_id,
            workspace_id: self.workspace_id,
            expires_at: self.expires_at,
            token,
        }
    }

    /**
     * Chấp nhận capability chỉ khi đúng email, còn hạn và mọi fence người mời còn khớp.
     * Input
     * Param: email — email chuẩn hóa của account đã khóa và xác thực.
     * Param: now — clock DB lấy sau toàn bộ khóa để không gia hạn token do chờ lock.
     * Param: `admission_generation` — fence hiện hành của workspace/email.
     * Param: issuer — authority hiện hành của người mời trong đúng workspace.
     * Output: cho phép consume hoặc lý do từ chối; không tự tạo membership.
     * # Errors
     * `RecipientMismatch` khi sai email; Unavailable khi token/fence/issuer không còn hợp lệ.
     */
    pub fn authorize_recipient(
        &self,
        email: &str,
        now: DateTime<Utc>,
        admission_generation: i64,
        issuer: &InvitationIssuer,
    ) -> Result<(), InvitationFailure> {
        if self.email_normalized != email {
            return Err(InvitationFailure::RecipientMismatch);
        }
        if self.terminal
            || now < self.issued_at
            || now >= self.expires_at
            || self.admission_generation != admission_generation
            || issuer.user_id != self.issuer_user_id
            || !issuer.capable_admin
            || issuer.grant_generation != self.issuer_grant_generation
            || issuer.authorization_version != self.issuer_authorization_version
        {
            return Err(InvitationFailure::Unavailable);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    /// Dựng snapshot tổng hợp để kiểm policy mà không cần DB hoặc credential thật.
    fn fixture() -> (InvitationSnapshot, InvitationIssuer) {
        let issuer_id = Uuid::new_v4();
        let now = DateTime::from_timestamp(1_700_000_000, 0).unwrap();
        (
            InvitationSnapshot {
                workspace_id: Uuid::new_v4(),
                invitation_id: Uuid::new_v4(),
                email_normalized: "recipient@example.invalid".to_owned(),
                role: WorkspaceRole::User,
                issuer_user_id: issuer_id,
                issuer_grant_generation: 2,
                issuer_authorization_version: 4,
                admission_generation: 3,
                issued_at: now,
                expires_at: now + Duration::hours(24),
                terminal: false,
            },
            InvitationIssuer {
                user_id: issuer_id,
                capable_admin: true,
                grant_generation: 2,
                authorization_version: 4,
            },
        )
    }

    /// Email khác không được consume kể cả người nhận có full session hợp lệ.
    #[test]
    fn rejects_wrong_recipient() {
        let (invitation, issuer) = fixture();
        assert_eq!(
            invitation.authorize_recipient(
                "other@example.invalid",
                invitation.issued_at,
                3,
                &issuer
            ),
            Err(InvitationFailure::RecipientMismatch)
        );
    }

    /// Biên hết hạn là exclusive; mọi terminal hoặc stale admission đều mất capability.
    #[test]
    fn rejects_expiry_terminal_and_old_admission() {
        let (mut invitation, issuer) = fixture();
        let email = invitation.email_normalized.clone();
        assert!(
            invitation
                .authorize_recipient(&email, invitation.expires_at, 3, &issuer)
                .is_err()
        );
        assert!(
            invitation
                .authorize_recipient(&email, invitation.issued_at, 4, &issuer)
                .is_err()
        );
        invitation.terminal = true;
        assert!(
            invitation
                .authorize_recipient(&email, invitation.issued_at, 3, &issuer)
                .is_err()
        );
    }

    /// Rejoin của issuer hoặc thay role/version không hồi sinh lời mời cũ.
    #[test]
    fn requires_current_capable_issuer_with_same_grant_and_version() {
        let (invitation, mut issuer) = fixture();
        assert!(
            invitation
                .authorize_recipient(
                    &invitation.email_normalized,
                    invitation.issued_at,
                    3,
                    &issuer
                )
                .is_ok()
        );
        issuer.authorization_version += 1;
        assert!(
            invitation
                .authorize_recipient(
                    &invitation.email_normalized,
                    invitation.issued_at,
                    3,
                    &issuer
                )
                .is_err()
        );
        issuer.authorization_version -= 1;
        issuer.grant_generation += 1;
        assert!(
            invitation
                .authorize_recipient(
                    &invitation.email_normalized,
                    invitation.issued_at,
                    3,
                    &issuer
                )
                .is_err()
        );
        issuer.grant_generation -= 1;
        issuer.capable_admin = false;
        assert!(
            invitation
                .authorize_recipient(
                    &invitation.email_normalized,
                    invitation.issued_at,
                    3,
                    &issuer
                )
                .is_err()
        );
    }
}
