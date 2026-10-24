//! Preference SQL sau current User fence: default read không ghi và mutation CAS cùng required audit.

use crate::{PgUnitOfWork, storage_error};
use chrono::{DateTime, Utc};
use iot_application::{error::ApplicationError, preferences::PreferenceTransaction};
use iot_domain::preferences::PreferenceSnapshot;
use sqlx::Row;
use uuid::Uuid;

impl PreferenceTransaction for PgUnitOfWork {
    /**
     * Khóa preference của chính chủ sau User fence; missing row là default UTC/1 chứ không INSERT ở GET.
     * Input
     * Param: `user_id` — principal đã xác thực, không target selector từ client.
     * Output: snapshot persisted hoặc default; Errors: storage đã lọc, không đọc verifier/profile.
     */
    async fn lock_preferences(
        &mut self,
        user_id: Uuid,
    ) -> Result<PreferenceSnapshot, ApplicationError> {
        // User fence serialize cả trường hợp chưa có row; bound key không cho đọc account khác từ body.
        let row = sqlx::query(
            "SELECT display_timezone,revision FROM user_preferences WHERE user_id=$1 FOR UPDATE",
        )
        .bind(user_id)
        .fetch_optional(&mut *self.transaction)
        .await
        .map_err(storage_error)?;
        row.map_or_else(
            || Ok(PreferenceSnapshot::legacy(user_id)),
            |row| {
                Ok(PreferenceSnapshot {
                    user_id,
                    display_timezone: row.try_get("display_timezone").map_err(storage_error)?,
                    revision: row.try_get("revision").map_err(storage_error)?,
                })
            },
        )
    }

    /// Đọc clock thật sau lock wait để session expired trong lúc chờ không cập nhật preference.
    async fn preferences_now(&mut self) -> Result<DateTime<Utc>, ApplicationError> {
        sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *self.transaction)
            .await
            .map_err(storage_error)
    }

    /**
     * Xác minh exact name qua catalog timezone cùng engine, không ghép request thành SET/SQL fragment.
     * Input
     * Param: timezone — shape đã validate, vẫn là input không tin cậy được bind.
     * Output: tên có trong catalog hoặc false; Errors: storage không bị biến thành timezone hợp lệ.
     */
    async fn preference_timezone_exists(
        &mut self,
        timezone: &str,
    ) -> Result<bool, ApplicationError> {
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_timezone_names WHERE name=$1)")
            .bind(timezone)
            .fetch_one(&mut *self.transaction)
            .await
            .map_err(storage_error)
    }

    /**
     * Materialize legacy default rồi CAS timezone/revision trong cùng physical transaction.
     * Input
     * Param: before — snapshot dưới User/preference fences, cần khớp expected revision.
     * Param: after — domain transition cùng account, không cho thay identity.
     * Param: now — admission clock sau locks, dùng `updated_at`; không đổi timestamp ngoài bảng này.
     * Output: hoàn tất hoặc StaleRevision/storage; audit lỗi phía caller rollback INSERT và UPDATE.
     */
    async fn save_preferences(
        &mut self,
        before: &PreferenceSnapshot,
        after: &PreferenceSnapshot,
        now: DateTime<Utc>,
    ) -> Result<(), ApplicationError> {
        if before.user_id != after.user_id {
            return Err(ApplicationError::Unavailable);
        }
        // INSERT chỉ trong mutation; row defaults trùng model legacy và rollback nếu CAS/audit không đạt.
        sqlx::query("INSERT INTO user_preferences(user_id) VALUES($1) ON CONFLICT DO NOTHING")
            .bind(before.user_id)
            .execute(&mut *self.transaction)
            .await
            .map_err(storage_error)?;
        let changed=sqlx::query("UPDATE user_preferences SET display_timezone=$3,revision=$4,updated_at=$5 WHERE user_id=$1 AND revision=$2").bind(before.user_id).bind(before.revision).bind(&after.display_timezone).bind(after.revision).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?.rows_affected();
        if changed != 1 {
            return Err(ApplicationError::StaleRevision);
        }
        Ok(())
    }
}
