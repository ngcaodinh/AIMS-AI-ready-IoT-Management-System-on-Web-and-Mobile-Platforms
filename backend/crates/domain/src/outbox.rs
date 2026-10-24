//! Receipt và close intent nội bộ; metadata này chỉ yêu cầu thu hẹp kết nối, không cấp authority.

use chrono::{DateTime, Utc};
use uuid::Uuid;

/// Chỉ kích hoạt hai consumer close đã có producer; reconciliation/provider là pipeline khác.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CloseConsumer {
    Session,
    Workspace,
}

impl CloseConsumer {
    /// Trả tên pipeline cố định để adapter bind, không ghép identifier từ request.
    #[must_use]
    pub const fn code(self) -> &'static str {
        match self {
            Self::Session => "REALTIME_SESSION_CLOSE",
            Self::Workspace => "REALTIME_WORKSPACE_CLOSE",
        }
    }
}

/// Cận vận hành native claim: lease1…300 giây và tối đa1000 row mỗi transaction.
#[derive(Clone, Copy, Debug)]
pub struct ClaimOptions {
    lease_seconds: i32,
    batch_limit: i32,
}

impl ClaimOptions {
    /**
     * Kiểm giới hạn trước khi mở transaction để tránh lease vô hạn hoặc batch quá lớn.
     * Input
     * Param: `lease_seconds` — thời gian thuê xử lý, đơn vị giây.
     * Param: `batch_limit` — số event tối đa mỗi lượt của một consumer.
     * Output: options hợp lệ hoặc None khi ngoài cận native.
     */
    #[must_use]
    pub fn new(lease_seconds: i32, batch_limit: i32) -> Option<Self> {
        ((1..=300).contains(&lease_seconds) && (1..=1000).contains(&batch_limit)).then_some(Self {
            lease_seconds,
            batch_limit,
        })
    }

    /// Trả duration đã kiểm để SQL bind, không là deadline nghiệp vụ của event.
    #[must_use]
    pub const fn lease_seconds(self) -> i32 {
        self.lease_seconds
    }

    /// Trả cận row đã kiểm; batch rỗng không chứng nhận pipeline đã drain.
    #[must_use]
    pub const fn batch_limit(self) -> i32 {
        self.batch_limit
    }
}

/// Delay retry vận hành1…300 giây; không đặt lại identity, generation hoặc attempt budget.
#[derive(Clone, Copy, Debug)]
pub struct RetryDelay(i32);

impl RetryDelay {
    /**
     * Giới hạn thời gian chờ retry để caller không tạo lịch vô hạn hoặc busy loop tức thì.
     * Input
     * Param: seconds — delay từ clock DB, không timestamp tùy ý của client.
     * Output: delay hợp lệ hoặc None ngoài1…300.
     */
    #[must_use]
    pub fn new(seconds: i32) -> Option<Self> {
        (1..=300).contains(&seconds).then_some(Self(seconds))
    }

    /// Trả delay giây đã kiểm cho conditional retry update.
    #[must_use]
    pub const fn seconds(self) -> i32 {
        self.0
    }
}

/// Receipt epoch riêng từng consumer; không dùng như session token hoặc quyền user.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LeaseReceipt {
    event_id: Uuid,
    consumer: CloseConsumer,
    generation: i64,
}

impl LeaseReceipt {
    /**
     * Nhận identity/epoch đã claim để ngăn nil hoặc generation chưa được cấp đi vào settle.
     * Input
     * Param: `event_id` — UUID event bền vững.
     * Param: consumer — pipeline nội bộ đã chọn.
     * Param: generation — epoch dương do DB tăng khi claim/takeover.
     * Output: receipt hợp lệ hoặc None; quyền DB vẫn do composition cấp riêng.
     */
    #[must_use]
    pub fn new(event_id: Uuid, consumer: CloseConsumer, generation: i64) -> Option<Self> {
        (!event_id.is_nil() && generation > 0).then_some(Self {
            event_id,
            consumer,
            generation,
        })
    }

    /// Trả event identity để CAS đúng nghĩa vụ, không tạo event mới khi retry.
    #[must_use]
    pub const fn event_id(self) -> Uuid {
        self.event_id
    }

    /// Trả pipeline của receipt; không settle consumer khác cùng event.
    #[must_use]
    pub const fn consumer(self) -> CloseConsumer {
        self.consumer
    }

    /// Trả epoch đã claim; worker cũ phải giữ nguyên và nhận false sau takeover.
    #[must_use]
    pub const fn generation(self) -> i64 {
        self.generation
    }
}

/// Payload allowlist không chứa JSON/raw secret; workspace close luôn giữ scope và version nguồn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CloseIntent {
    Session {
        user_id: Uuid,
        session_id: Uuid,
    },
    Workspace {
        workspace_id: Uuid,
        user_id: Uuid,
        membership_authorization_version: i64,
    },
}

/// Claim chỉ được trả sau commit; `lease_until` là gợi ý vận hành, CAS DB mới quyết định còn quyền settle.
#[derive(Clone, Copy, Debug)]
pub struct ClaimedCloseIntent {
    pub receipt: LeaseReceipt,
    pub intent: CloseIntent,
    pub lease_until: DateTime<Utc>,
    pub attempt_count: i32,
}
