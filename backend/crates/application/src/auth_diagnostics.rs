//! Port diagnostic thuần; không SQLx/Tokio/HTTP, không nhận credential hoặc identity làm nhãn đo.

use std::{
    sync::Arc,
    time::{Duration, Instant},
};

/// Stage hữu hạn tại adapter; tên mô tả ranh giới đo, không khẳng định server đã nhả khóa.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AuthTimingStage {
    HashQueue,
    BlockingQueue,
    HashWork,
    PoolAcquire,
    TransactionBegin,
    BucketAcquire,
    AccountAcquire,
    FencedWork,
    CommitAck,
}

impl AuthTimingStage {
    /// Trả nhãn literal để exporter không sinh series từ input hoặc identifier của request.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::HashQueue => "hash_queue",
            Self::BlockingQueue => "blocking_queue",
            Self::HashWork => "hash_work",
            Self::PoolAcquire => "pool_acquire",
            Self::TransactionBegin => "transaction_begin",
            Self::BucketAcquire => "bucket_acquire",
            Self::AccountAcquire => "account_acquire",
            Self::FencedWork => "fenced_work",
            Self::CommitAck => "commit_ack",
        }
    }
}

/// Outcome chỉ nói stage kỹ thuật, không suy credential đúng/sai hoặc transaction đã rollback.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AuthTimingOutcome {
    Completed,
    Error,
    Abandoned,
}

impl AuthTimingOutcome {
    /// Trả nhãn stage outcome cố định, tách cancellation khỏi hoàn tất thành công.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Completed => "completed",
            Self::Error => "error",
            Self::Abandoned => "abandoned",
        }
    }
}

/// Sink do composition cấp; callback phải ngắn, không I/O/panic hoặc làm đổi outcome auth.
pub trait AuthDiagnostics: Send + Sync {
    /**
     * Giữ chỗ span trong window hiện hành để exporter phát hiện work còn chạy.
     * Input
     * Param: `stage` — stage literal của adapter, không metadata người dùng.
     * Output: generation được giữ tới finish; None khi instrumentation inactive.
     */
    fn start_span(&self, stage: AuthTimingStage) -> Option<u64>;

    /**
     * Kết thúc đúng span và giữ dữ liệu thời lượng không chứa request input.
     * Input
     * Param: `window_id` — generation đã lấy khi span bắt đầu, chặn callback thuộc window cũ.
     * Param: `stage` — cùng stage lúc giữ chỗ, dùng cho series hữu hạn.
     * Param: `outcome` — completed/error/abandoned của stage, không authority nghiệp vụ.
     * Param: `elapsed` — thời gian monotonic của stage, không timestamp định danh.
     */
    fn finish_span(
        &self,
        window_id: u64,
        stage: AuthTimingStage,
        outcome: AuthTimingOutcome,
        elapsed: Duration,
    );
}

/// Dữ liệu span đang chạy chỉ giữ clock/enum/sink; không capture closure chứa credential.
struct ActiveSpan {
    sink: Arc<dyn AuthDiagnostics>,
    window_id: u64,
    stage: AuthTimingStage,
    started: Instant,
}

/// Guard theo vòng đời future/worker; drop không được báo Completed hoặc giả đã nhả DB lock.
#[must_use]
pub struct AuthTimingSpan {
    active: Option<ActiveSpan>,
}

impl AuthTimingSpan {
    /**
     * Mở span nếu composition và window cho phép; mặc định không đọc clock khi disabled.
     * Input
     * Param: `sink` — observer tùy chọn, không phải dependency bắt buộc để auth hoạt động.
     * Param: `stage` — ranh giới kỹ thuật do adapter chọn từ enum hữu hạn.
     * Output: guard phải finish hoặc drop; generation không được lấy lại ở cuối work.
     */
    pub fn start(sink: Option<&Arc<dyn AuthDiagnostics>>, stage: AuthTimingStage) -> Self {
        let Some(sink) = sink else {
            return Self { active: None };
        };
        let Some(window_id) = sink.start_span(stage) else {
            return Self { active: None };
        };
        // Chỉ span được giữ chỗ mới đọc clock, generation không lấy lại khi work kết thúc.
        Self {
            active: Some(ActiveSpan {
                sink: sink.clone(),
                window_id,
                stage,
                started: Instant::now(),
            }),
        }
    }

    /**
     * Kết thúc stage đúng một lần với outcome do adapter đã quan sát.
     * Input
     * Param: `outcome` — Completed chỉ khi stage đã kết thúc, Error khi có lỗi kỹ thuật.
     * Side effects: gửi elapsed vào sink rồi vô hiệu guard để Drop không ghi lần hai.
     */
    pub fn finish(mut self, outcome: AuthTimingOutcome) {
        if let Some(active) = self.active.take() {
            active.sink.finish_span(
                active.window_id,
                active.stage,
                outcome,
                active.started.elapsed(),
            );
        }
    }
}

impl Drop for AuthTimingSpan {
    /// Ghi Abandoned khi future bị drop; không hứa công việc server/blocking task đã dừng.
    fn drop(&mut self) {
        if let Some(active) = self.active.take() {
            active.sink.finish_span(
                active.window_id,
                active.stage,
                AuthTimingOutcome::Abandoned,
                active.started.elapsed(),
            );
        }
    }
}
