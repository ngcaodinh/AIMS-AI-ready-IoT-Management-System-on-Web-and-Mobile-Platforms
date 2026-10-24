//! Retention audit30 ngày theo ingestion UTC; giữ cutoff cố định qua mọi batch/restart.

use chrono::{DateTime, TimeDelta, Utc};
use uuid::Uuid;

/// Batch có cận1…1000 theo quyết định vận hành của slice; không mang query/SQL vào domain.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BatchLimit(i32);

impl BatchLimit {
    /**
     * Giới hạn mỗi transaction purge để tránh giữ khóa vô hạn.
     * Input
     * Param: limit — số row tối đa cần xét, không nhận zero hoặc số vượt1000.
     * Output: giá trị đã kiểm hoặc None khi ngoài cận.
     */
    #[must_use]
    pub fn new(limit: i32) -> Option<Self> {
        (1..=1000).contains(&limit).then_some(Self(limit))
    }

    /// Lấy số row tối đa đã kiểm để bind query purge, không cần validate lại ở transport.
    #[must_use]
    pub const fn get(self) -> i32 {
        self.0
    }
}

/// Identity run và cutoff snapshot; không chứa tenant selector hoặc quyền của user request.
#[derive(Clone, Copy, Debug)]
pub struct AuditRetentionRun {
    run_id: Uuid,
    cutoff: DateTime<Utc>,
}

impl AuditRetentionRun {
    /**
     * Đóng cutoff UTC từ thời điểm bắt đầu run; DST không làm thay đổi duration720 giờ.
     * Input
     * Param: `run_id` — identity ổn định để restart cùng intent, không dùng UUID nil.
     * Param: `started_at` — clock server đã quan sát khi bắt đầu run.
     * Output: run hoặc None nếu identity/range timestamp không hợp lệ.
     */
    #[must_use]
    pub fn new(run_id: Uuid, started_at: DateTime<Utc>) -> Option<Self> {
        Self::restore(
            run_id,
            started_at.checked_sub_signed(TimeDelta::hours(720))?,
        )
    }

    /**
     * Khôi phục cutoff đã lưu thay vì tính lại sau restart khiến run trôi cửa sổ.
     * Input
     * Param: `run_id` — identity durable của run.
     * Param: cutoff — snapshot đã được adapter kiểm schema/clock, không input HTTP.
     * Output: run hoặc None khi UUID nil; không tự xác thực quyền retention.
     */
    #[must_use]
    pub fn restore(run_id: Uuid, cutoff: DateTime<Utc>) -> Option<Self> {
        (!run_id.is_nil()).then_some(Self { run_id, cutoff })
    }

    /// Trả identity durable để batch tham chiếu đúng run, không cấp quyền purge.
    #[must_use]
    pub const fn run_id(self) -> Uuid {
        self.run_id
    }

    /// Trả cutoff đã đóng cho mọi query/retry của run.
    #[must_use]
    pub const fn cutoff(self) -> DateTime<Utc> {
        self.cutoff
    }

    /**
     * Chọn row hết hạn theo ingestion time; timestamp đúng cutoff vẫn được giữ.
     * Input
     * Param: `created_at` — timestamp server của audit row, độc lập event-time.
     * Output: true chỉ khi row nằm trước cutoff cố định.
     */
    #[must_use]
    pub fn is_expired(self, created_at: DateTime<Utc>) -> bool {
        created_at < self.cutoff
    }
}

/// Kết quả purge đã commit; count0 không chứng nhận run drain vì row khác có thể còn đang bị khóa.
#[derive(Clone, Copy, Debug)]
pub struct AuditRetentionBatch {
    pub batch_id: Uuid,
    pub run_id: Uuid,
    pub limit: BatchLimit,
    pub removed_count: i32,
    pub completed_at: DateTime<Utc>,
}
