//! Đọc operation credential bằng current Admin và initiator, không ghi lifecycle hoặc gọi broker.

use crate::{
    device_ports::{DeviceStore, DeviceTransaction},
    error::ApplicationError,
};
use chrono::{DateTime, Utc};
use iot_domain::{identity::SessionProof, provisioning::CredentialOperation};
use std::future::Future;
use uuid::Uuid;

/// Unit of work dùng lại User→Workspace fence của registry và chỉ có projection read.
pub trait ProvisioningPollTransaction: DeviceTransaction {
    /**
     * Đọc các cột metadata tường minh của operation cùng tenant và initiator.
     * Input
     * Param: workspace_id — tenant đã authorize.
     * Param: actor_id — current Admin từ session đã khóa.
     * Param: operation_id — selector không mang authority.
     * Output: metadata hoặc not-found cho selector vắng/khác scope.
     */
    fn credential_operation(
        &mut self,
        workspace_id: Uuid,
        actor_id: Uuid,
        operation_id: Uuid,
    ) -> impl Future<Output = Result<CredentialOperation, ApplicationError>> + Send;
}

/// Service chỉ có read path cho các operation credential đã tồn tại.
#[derive(Clone)]
pub struct ProvisioningPollService<S>(S);

impl<S: DeviceStore> ProvisioningPollService<S>
where
    S::Transaction: ProvisioningPollTransaction,
{
    /**
     * Dựng read-only poll service trên transaction dùng chung với authority registry.
     *
     * # Input
     * Param: store — factory giữ actor/workspace fence và không cung cấp producer/broker operation.
     *
     * # Output
     * Service chỉ truy vấn operation metadata hiện hữu.
     */
    #[must_use]
    pub const fn new(store: S) -> Self {
        Self(store)
    }

    /**
     * Đọc operation đúng initiator sau current Admin admission và kiểm lại session trước commit.
     * Input
     * Param: proof — session hiện tại, gồm Web auth context nếu áp dụng.
     * Param: workspace_id — selector workspace ACTIVE.
     * Param: operation_id — UUID operation.
     * Output: metadata và clock DB để chiếu deadline, hoặc lỗi quyền/not-found/storage.
     */
    pub async fn poll(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        operation_id: Uuid,
    ) -> Result<(CredentialOperation, DateTime<Utc>), ApplicationError> {
        let mut tx = self.0.begin_device().await?;
        let locked = tx.lock_device_actor(proof, None).await?;
        let actor =
            locked
                .session
                .authorize_actor(&locked.account, proof, locked.observed_at, false)?;
        tx.lock_device_scope(workspace_id, actor.user_id())
            .await?
            .authorize(&actor, true)?;
        let operation = tx
            .credential_operation(workspace_id, actor.user_id(), operation_id)
            .await?;
        let now = tx.device_now().await?;
        // Sau database wait, clock hiện tại kiểm expiry của chính session đã lock.
        locked
            .session
            .authorize_actor(&locked.account, proof, now, false)?;
        tx.commit_device().await?;
        Ok((operation, now))
    }
}
