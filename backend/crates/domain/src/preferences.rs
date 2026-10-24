//! Preference hiển thị thuộc chính chủ account, độc lập timestamp/schedule hoặc quyền workspace.

use uuid::Uuid;

/// Shape timezone exact name; catalog IANA phải được application xác minh qua port trước ghi.
pub struct DisplayTimezone(String);

impl DisplayTimezone {
    /**
     * Loại bỏ input rỗng/NUL trước I/O, không trim hoặc tự chấp nhận timezone bằng parser lỏng.
     * Input
     * Param: value — tên timezone từ request, cần tra catalog chính xác tại adapter.
     * Output: shape hợp lệ hoặc None; không tự đặt maxLength chưa có contract.
     */
    #[must_use]
    pub fn new(value: &str) -> Option<Self> {
        (!value.trim().is_empty() && !value.contains('\0')).then(|| Self(value.to_owned()))
    }

    /// Trả exact timezone name để bind lookup catalog, không phải SQL expression.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Snapshot không chứa credential; adapter trả default khi legacy chưa có preference row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PreferenceSnapshot {
    pub user_id: Uuid,
    pub display_timezone: String,
    pub revision: i64,
}

#[derive(Debug, PartialEq, Eq)]
pub enum PreferenceFailure {
    StaleRevision,
    RevisionExhausted,
}

impl PreferenceSnapshot {
    /**
     * Dựng default nguồn UTC/revision1 cho account chưa có row mà không cần ghi khi GET.
     * Input
     * Param: `user_id` — account đã xác thực, không target selector từ client.
     * Output: default hiển thị thuần; không thay schedule hoặc timestamps.
     */
    #[must_use]
    pub fn legacy(user_id: Uuid) -> Self {
        Self {
            user_id,
            display_timezone: "UTC".to_owned(),
            revision: 1,
        }
    }

    /**
     * Tính preference tiếp theo bằng CAS, giữ identity và từ chối counter overflow.
     * Input
     * Param: timezone — shape hợp lệ, application phải xác minh catalog trước persist.
     * Param: `expected_revision` — If-Match hiện hành dương của preference chính chủ.
     * Output: snapshot mới tăng revision kể cả cùng giá trị; không tự persist hoặc đổi timestamp nghiệp vụ.
     * # Errors
     * Stale revision hoặc hết miền bigint; không wrap về revision cũ.
     */
    pub fn change(
        &self,
        timezone: &DisplayTimezone,
        expected_revision: i64,
    ) -> Result<Self, PreferenceFailure> {
        if expected_revision <= 0 || expected_revision != self.revision {
            return Err(PreferenceFailure::StaleRevision);
        }
        Ok(Self {
            user_id: self.user_id,
            display_timezone: timezone.as_str().to_owned(),
            revision: self
                .revision
                .checked_add(1)
                .ok_or(PreferenceFailure::RevisionExhausted)?,
        })
    }
}
