//! Lease kernel nội bộ, tách scheduler/socket registry khỏi transaction PostgreSQL.

use crate::error::ApplicationError;
use iot_domain::outbox::{
    ClaimOptions, ClaimedCloseIntent, CloseConsumer, LeaseReceipt, RetryDelay,
};
use std::future::Future;

/// Port nguyên tử: implementation phải commit trước trả claim hoặc kết quả CAS; không callback network trong transaction.
pub trait CloseOutboxStore: Clone + Send + Sync {
    /// Claim một pipeline và đọc typed intent cùng transaction; metadata sai rollback cả batch, lỗi commit không phát claim.
    fn claim_close_intents(
        &self,
        consumer: CloseConsumer,
        options: ClaimOptions,
    ) -> impl Future<Output = Result<Vec<ClaimedCloseIntent>, ApplicationError>> + Send;
    /// Hoàn tất chỉ khi epoch còn sống; false gồm stale/expired/already complete, không cho phép gửi lại side effect.
    fn complete_close_intent(
        &self,
        receipt: LeaseReceipt,
    ) -> impl Future<Output = Result<bool, ApplicationError>> + Send;
    /// Trả lease sống về `RETRY_WAIT`; không reset attempt hoặc đổi event identity khi external outcome còn chưa rõ.
    fn retry_close_intent(
        &self,
        receipt: LeaseReceipt,
        delay: RetryDelay,
    ) -> impl Future<Output = Result<bool, ApplicationError>> + Send;
}

/// Service chỉ được composition nội bộ cấp store; không gắn vào `IdentityService` hay user route.
pub struct CloseOutboxService<S> {
    store: S,
}

impl<S: CloseOutboxStore> CloseOutboxService<S> {
    /**
     * Nhận store worker đã cấp quyền, không tìm credential hoặc tự tạo loop chạy nền.
     * Input
     * Param: store — adapter giữ claim/settle transaction và clock DB.
     * Output: lease service cho coordinator; không khẳng định socket đã đóng.
     */
    #[must_use]
    pub const fn new(store: S) -> Self {
        Self { store }
    }

    /**
     * Claim bounded batch của consumer đã cấu hình; caller chỉ xử lý intent sau kết quả thành công.
     * Input
     * Param: consumer — một trong hai close pipelines hiện có, không chuỗi client tự nhập.
     * Param: options — lease1…300 giây và batch1…1000 đã kiểm.
     * Output: typed claims sau commit; batch rỗng không chứng nhận đã drain vì `SKIP LOCKED`.
     * # Errors
     * Unavailable với storage/payload sai hoặc `CommitUnknown`; không tự dispatch khi chưa biết commit.
     */
    pub async fn claim(
        &self,
        consumer: CloseConsumer,
        options: ClaimOptions,
    ) -> Result<Vec<ClaimedCloseIntent>, ApplicationError> {
        self.store.claim_close_intents(consumer, options).await
    }

    /**
     * Ghi nhận close intent đã được consumer xử lý; caller cần phối hợp registry trước khi gọi.
     * Input
     * Param: receipt — event/consumer/epoch từ claim, giữ nguyên qua network và retry.
     * Output: true sau commit nếu CAS thắng; false không cho phép worker cũ ghi tiếp.
     * # Errors
     * Storage hoặc `CommitUnknown`; COMPLETED chỉ nói consumer đã xử lý intent, không là transport ACK từ client.
     */
    pub async fn complete(&self, receipt: LeaseReceipt) -> Result<bool, ApplicationError> {
        self.store.complete_close_intent(receipt).await
    }

    /**
     * Nhả claim sống để retry close idempotent sau delay; không dùng cho physical command/provider tùy ý.
     * Input
     * Param: receipt — epoch hiện hành cần nhả, không cấp epoch mới.
     * Param: delay — thời gian chờ vận hành đã kiểm, DB tự lấy clock.
     * Output: true nếu retry được commit, false khi lease hết/stale/terminal.
     * # Errors
     * Storage hoặc `CommitUnknown`; không tự gửi lại side effect trong phương thức này.
     */
    pub async fn retry(
        &self,
        receipt: LeaseReceipt,
        delay: RetryDelay,
    ) -> Result<bool, ApplicationError> {
        self.store.retry_close_intent(receipt, delay).await
    }
}
