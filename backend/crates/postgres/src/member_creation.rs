//! Account-create serialization theo email toàn cục; không thay account đã tồn tại.

use crate::{PgUnitOfWork, storage_error};
use chrono::{DateTime, Utc};
use iot_application::{
    error::ApplicationError,
    member_creation_ports::{
        MemberCreationClaim, MemberCreationReceiptKey, MemberCreationTransaction,
    },
};
use iot_domain::{
    identity::SecretString,
    member_creation::{MemberCreationOutcome, MemberCreationRequest},
    password_reset::TEMPORARY_ACCOUNT_ORIGIN,
    workspace::WorkspaceRole,
};
use uuid::Uuid;

impl MemberCreationTransaction for PgUnitOfWork {
    /**
     * Serialize account-create theo email trước mọi User lock để hai tenant không tạo hai account.
     * Input
     * Param: `email_digest` — HMAC email canonical bằng key ổn định giữa các instance.
     * Output: giữ advisory transaction lock đến commit/rollback; không lưu PII hoặc đổi account.
     */
    async fn lock_creation_email(
        &mut self,
        email_digest: [u8; 32],
    ) -> Result<(), ApplicationError> {
        // Namespace tách các worker khác; hash collision chỉ serialize thêm, không cấp authority.
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended('member-create-email:'||encode($1::bytea,'hex'),0))").bind(email_digest.as_slice()).execute(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(())
    }

    /**
     * Chọn branch dưới creation fence, chỉ đọc existence để không lộ verifier của account cũ.
     * Input
     * Param: email — canonical đã validate, bind vào unique index lookup.
     * Output: true nếu account đã có; account status không cấp quyền autojoin.
     */
    async fn creation_account_exists(&mut self, email: &str) -> Result<bool, ApplicationError> {
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM users WHERE email_normalized=$1)")
            .bind(email)
            .fetch_one(&mut *self.transaction)
            .await
            .map_err(storage_error)
    }

    /**
     * Reserve receipt scoped đúng actor sau current Admin admission, không tự commit.
     * Input
     * Param: key — namespace tenant/actor/key digest đã authorize.
     * Param: `request_digest` — fingerprint raw body để retry không đổi intent.
     * Param: now — DB clock sau locks, làm mốc hạn24 giờ.
     * Output: Reserved hoặc result không secret đã decode allowlist.
     */
    async fn reserve_member_creation(
        &mut self,
        key: MemberCreationReceiptKey,
        request_digest: [u8; 32],
        now: DateTime<Utc>,
    ) -> Result<MemberCreationClaim, ApplicationError> {
        self.reserve_member_creation_receipt(key, request_digest, now)
            .await
    }

    /**
     * Ghi account tạm cùng Membership/grant1; không có nhánh UPDATE account theo email.
     * Input
     * Param: `workspace_id` — tenant dưới current Admin fence.
     * Param: `user_id` — UUID mới do application sinh, không nhận từ client.
     * Param: request — email canonical/alias/role đã validate.
     * Param: verifier — PHC thật từ bounded hasher, không raw password.
     * Param: now — admission clock; account chưa activated và buộc đổi password.
     * Output: graph mới cùng transaction; uniqueness/FK/audit lỗi làm rollback cả graph.
     */
    async fn insert_temporary_member(
        &mut self,
        workspace_id: Uuid,
        user_id: Uuid,
        request: &MemberCreationRequest,
        verifier: &SecretString,
        now: DateTime<Utc>,
    ) -> Result<(), ApplicationError> {
        // Unique email giữ global identity nếu writer ngoài workflow chen vào; không merge/update credential.
        sqlx::query("INSERT INTO users(user_id,email_normalized,password_hash,account_status,must_change_password,activation_provenance) VALUES($1,$2,$3,'ACTIVE',true,$4)").bind(user_id).bind(request.email_normalized()).bind(verifier.expose()).bind(TEMPORARY_ACCOUNT_ORIGIN).execute(&mut *self.transaction).await.map_err(storage_error)?;
        // Deferred current-grant FK cho phép chốt member/grant cùng commit, alias chỉ nằm trong tenant.
        sqlx::query("INSERT INTO memberships(workspace_id,user_id,role,status,alias,current_grant_generation,joined_at) VALUES($1,$2,$3,'ACTIVE',$4,1,$5)").bind(workspace_id).bind(user_id).bind(if request.role()==WorkspaceRole::Admin {"ADMIN"}else{"USER"}).bind(request.display_name()).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        sqlx::query("INSERT INTO membership_grants(workspace_id,user_id,grant_generation,issued_at) VALUES($1,$2,1,$3)").bind(workspace_id).bind(user_id).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(())
    }

    /**
     * Chốt receipt projection, chỉ status/outcome/UUID/expiry, không serialize response chứa secret.
     * Input
     * Param: key — đúng namespace/actor/key đã reserve.
     * Param: outcome — Created hoặc Invitation đã ghi thành công cùng audit.
     * Output: hoàn thành hoặc Conflict khi receipt không còn pending; chưa commit riêng.
     */
    async fn complete_member_creation(
        &mut self,
        key: MemberCreationReceiptKey,
        outcome: &MemberCreationOutcome,
    ) -> Result<(), ApplicationError> {
        self.complete_member_creation_receipt(key, outcome).await
    }
}
