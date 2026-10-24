//! Counter audit degraded có cardinality cố định; không lưu secret/PII hoặc queue event trong RAM.

use iot_domain::audit_write::FailureAuditKind;
use std::sync::atomic::{AtomicU64, Ordering};

/// Snapshot cộng dồn từ khi composition tạo store; exporter vận hành có thể scrape mà không đọc DB secret.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AuditFailureCounts {
    pub login: u64,
    pub password_change: u64,
}

/// Clone store dùng chung counter; mỗi process cần composition/exporter riêng, không suy thành durable audit.
#[derive(Default)]
pub(crate) struct AuditFailureCounters {
    login: AtomicU64,
    password_change: AtomicU64,
}

impl AuditFailureCounters {
    /**
     * Đếm failure sink bằng series hữu hạn mà không block async use case hoặc gọi lại audit.
     * Input
     * Param: kind — chỉ Login/PasswordChange, không nhận label từ request.
     * Side effects: counter bão hòa tại `u64::MAX`; không cấp quyền hoặc sửa transaction.
     */
    pub(crate) fn increment(&self, kind: FailureAuditKind) {
        let counter = match kind {
            FailureAuditKind::Login => &self.login,
            FailureAuditKind::PasswordChange => &self.password_change,
        };
        // Relaxed đủ cho telemetry độc lập; không dùng counter làm fence hoặc truyền authority.
        let mut observed = counter.load(Ordering::Relaxed);
        while observed < u64::MAX {
            match counter.compare_exchange_weak(
                observed,
                observed + 1,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Ok(_) => break,
                Err(current) => observed = current,
            }
        }
    }

    /// Đọc counter hiện hành cho operator/exporter; hai series không hứa là snapshot transaction toàn hệ thống.
    pub(crate) fn snapshot(&self) -> AuditFailureCounts {
        AuditFailureCounts {
            login: self.login.load(Ordering::Relaxed),
            password_change: self.password_change.load(Ordering::Relaxed),
        }
    }
}
