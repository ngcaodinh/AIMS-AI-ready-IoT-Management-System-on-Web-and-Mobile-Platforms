//! PostgreSQL registry `UoW`; SQL bind scope/key, không network hoặc auto-grant writer.

use crate::{PgIdentityStore, PgUnitOfWork, commit_error, storage_error};
use chrono::{DateTime, Utc};
use iot_application::{
    device_ports::{DeviceStore, DeviceTransaction},
    error::ApplicationError,
    ports::{IdentityTransaction, LockedSession, WorkspaceTransaction},
};
use iot_domain::{
    device::{DeviceDraft, DevicePin, RegisteredDevice},
    identity::{AuditRecord, SessionProof},
    template_snapshot::TemplateVersionSnapshot,
    workspace::WorkspaceSnapshot,
};
use sqlx::Row;
use uuid::Uuid;

impl DeviceStore for PgIdentityStore {
    type Transaction = PgUnitOfWork;
    /**
     * Mở physical transaction từ pool composition, không nâng quyền hoặc trộn diagnostic auth vào thiết bị.
     * Output: unit of work không sink/`FencedWork`, giữ vòng đời transaction hiện có.
     * Errors: storage được lọc như trước; không tự áp migration hoặc đổi timeout.
     */
    async fn begin_device(&self) -> Result<PgUnitOfWork, ApplicationError> {
        Ok(PgUnitOfWork {
            transaction: self.pool.begin().await.map_err(storage_error)?,
            // Transaction thiết bị không phải measurement auth; không gắn sink/window của login.
            diagnostics: None,
            fenced_work: None,
        })
    }
}

impl DeviceTransaction for PgUnitOfWork {
    /**
     * Khóa actor/owner theo protocol IAM, tránh lock owner sau Workspace tạo cycle với member mutation.
     * Input
     * Param: proof — digest/context cần resolver kiểm lại dưới User lock.
     * Param: owner — subject của create; None khi đọc schema chỉ cần actor fence.
     * Output: locked account/session; Errors: session/storage, hint không cấp quyền.
     */
    async fn lock_device_actor(
        &mut self,
        proof: &SessionProof,
        owner: Option<Uuid>,
    ) -> Result<LockedSession, ApplicationError> {
        if let Some(owner_id) = owner {
            self.lock_session_subjects(proof, owner_id).await?;
        }
        IdentityTransaction::lock_session(self, proof).await
    }
    /**
     * Delegate scope/member/grant fence sau User, giữ transaction chung và domain admission policy.
     * Input
     * Param: `workspace_id` — selector tenant cần resolve hiện hành.
     * Param: `user_id` — actor từ session đã khóa, không từ body client.
     * Output: snapshot scope cho application authorize; Errors: quyền/storage.
     */
    async fn lock_device_scope(
        &mut self,
        workspace_id: Uuid,
        user_id: Uuid,
    ) -> Result<WorkspaceSnapshot, ApplicationError> {
        WorkspaceTransaction::lock_workspace(self, workspace_id, user_id).await
    }
    /**
     * Chuẩn hóa NFC bằng PostgreSQL 17 UTF8 để kiểm canonical name mà không thêm crate.
     * Input
     * Param: name — text bind chưa tin cậy, domain trim Unicode sau normalize.
     * Output: tên NFC; Errors: NUL bị từ chối trước SQL, storage khi query lỗi.
     */
    async fn normalize_device_name(&mut self, name: &str) -> Result<String, ApplicationError> {
        if name.contains('\0') {
            return Err(ApplicationError::InvalidInput);
        }
        sqlx::query_scalar("SELECT normalize($1::text,NFC)")
            .bind(name)
            .fetch_one(&mut *self.transaction)
            .await
            .map_err(storage_error)
    }
    /**
     * Kiểm owner hiện hành dưới User/Workspace fence, không coi FK membership tồn tại là quyền ACTIVE.
     * Input
     * Param: `workspace_id` — tenant current Admin đã authorize.
     * Param: `owner_id` — User đã khóa cùng actor trước Workspace.
     * Output: bool eligibility; Errors: storage, không leak hồ sơ owner foreign.
     */
    async fn owner_is_current(
        &mut self,
        workspace_id: Uuid,
        owner_id: Uuid,
    ) -> Result<bool, ApplicationError> {
        // Join current generation chặn grant lịch sử mở quyền sau remove/rejoin; mọi giá trị đều bind.
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM users account JOIN memberships member USING(user_id) JOIN membership_grants grant_row ON (grant_row.workspace_id,grant_row.user_id,grant_row.grant_generation)=(member.workspace_id,member.user_id,member.current_grant_generation) WHERE member.workspace_id=$1 AND member.user_id=$2 AND member.status='ACTIVE' AND account.account_status='ACTIVE' AND grant_row.revoked_at IS NULL)")
            .bind(workspace_id).bind(owner_id).fetch_one(&mut *self.transaction).await.map_err(storage_error)
    }
    /**
     * Giữ parent root stable trước pin mới; content lấy version immutable thay vì draft hiện hành.
     * Input
     * Param: `workspace_id` — scope đã authorize.
     * Param: `version_id` — version published trong tenant, không lookup global.
     * Output: immutable snapshot; Errors: not-found foreign/missing/archive, storage khi content sai.
     */
    async fn registration_schema(
        &mut self,
        workspace_id: Uuid,
        version_id: Uuid,
    ) -> Result<TemplateVersionSnapshot, ApplicationError> {
        // Khóa root trước kiểm lifecycle; root DRAFT mới vẫn cho pin version v1 đã công bố.
        let lifecycle:Option<String>=sqlx::query_scalar("SELECT root.lifecycle_status FROM templates root JOIN template_versions version USING(workspace_id,template_id) WHERE version.workspace_id=$1 AND version.template_version_id=$2 FOR SHARE OF root")
            .bind(workspace_id).bind(version_id).fetch_optional(&mut *self.transaction).await.map_err(storage_error)?;
        match lifecycle.as_deref() {
            Some("DRAFT" | "PUBLISHED") => {
                self.read_template_version(workspace_id, version_id).await
            }
            Some("ARCHIVED") | None => Err(ApplicationError::ResourceNotFound),
            _ => Err(ApplicationError::Unavailable),
        }
    }
    /**
     * Resolve pin với tenant ngay trong WHERE, projection không gồm credential hoặc provisioning escrow.
     * Input
     * Param: `workspace_id` — current scope đã authorize.
     * Param: `device_id` — selector chưa được tin cậy.
     * Output: pin dưới row share lock; Errors: not-found chung cho UUID foreign/missing.
     */
    async fn device_pin(
        &mut self,
        workspace_id: Uuid,
        device_id: Uuid,
    ) -> Result<DevicePin, ApplicationError> {
        let row=sqlx::query("SELECT owner_user_id,template_version_id FROM devices WHERE workspace_id=$1 AND device_id=$2 FOR SHARE")
            .bind(workspace_id).bind(device_id).fetch_optional(&mut *self.transaction).await.map_err(storage_error)?.ok_or(ApplicationError::ResourceNotFound)?;
        Ok(DevicePin {
            workspace_id,
            device_id,
            owner_user_id: row.try_get("owner_user_id").map_err(storage_error)?,
            template_version_id: row.try_get("template_version_id").map_err(storage_error)?,
        })
    }
    /**
     * Đọc immutable content của pin đã kiểm owner, không phụ thuộc draft hoặc root lifecycle hiện hành.
     * Input
     * Param: `workspace_id` — scope current member đã authorize.
     * Param: `version_id` — version từ device pin, không selector client tùy ý.
     * Output: snapshot chuẩn để kiểm digest; Errors: not-found hoặc storage.
     */
    async fn pinned_schema(
        &mut self,
        workspace_id: Uuid,
        version_id: Uuid,
    ) -> Result<TemplateVersionSnapshot, ApplicationError> {
        self.read_template_version(workspace_id, version_id).await
    }
    /// Clock riêng sau mọi lock wait; không dùng transaction timestamp cũ cho session expiry.
    async fn device_now(&mut self) -> Result<DateTime<Utc>, ApplicationError> {
        sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *self.transaction)
            .await
            .map_err(storage_error)
    }
    /**
     * Ghi device/runtime/actuator cùng `UoW`, không dùng `safeValue` làm reported truth hoặc cấp credential.
     * Input
     * Param: `workspace_id` — tenant current Admin đã kiểm.
     * Param: `device_id` — identity server cấp cho registry mới.
     * Param: draft — serial canonical, tên NFC và model/owner/version hợp lệ.
     * Param: now — server admission timestamp cho created/updated.
     * Output: receipt chưa commit và số actuator thực; Errors: `DeviceExists` generic hoặc storage.
     * Side effects: ba relation cùng transaction, sensor-only tạo0 actuator hợp lệ.
     */
    async fn insert_registered_device(
        &mut self,
        workspace_id: Uuid,
        device_id: Uuid,
        draft: &DeviceDraft,
        now: DateTime<Utc>,
    ) -> Result<RegisteredDevice, ApplicationError> {
        // UK global(serial) là arbiter cuối, kể cả hai tenant; không trả workspace/chủ đang sở hữu.
        sqlx::query("INSERT INTO devices(device_id,workspace_id,serial_number,template_version_id,owner_user_id,name,model,lifecycle_status,created_at,updated_at) VALUES($1,$2,$3,$4,$5,$6,$7,'REGISTERED',$8,$8)")
            .bind(device_id).bind(workspace_id).bind(&draft.serial_number).bind(draft.template_version_id).bind(draft.owner_user_id).bind(&draft.name).bind(&draft.model).bind(now)
            .execute(&mut *self.transaction).await.map_err(registration_error)?;
        // Chưa hello nên UNKNOWN và last_seen NULL; không tạo provisioning job hoặc credential ACTIVE giả.
        sqlx::query("INSERT INTO device_runtime(workspace_id,device_id,presence_state,maintenance) VALUES($1,$2,'UNKNOWN','NONE')")
            .bind(workspace_id).bind(device_id).execute(&mut *self.transaction).await.map_err(storage_error)?;
        // Chỉ SET_VALUE của đúng pin; không copy safe_value vì đó là cấu hình, không observation vật lý.
        let actuator_count=sqlx::query("INSERT INTO actuator_states(workspace_id,device_id,stream_key,pinned_template_version_id,manual_epoch,reported_source) SELECT workspace_id,$2,stream_key,template_version_id,0,'NONE' FROM datastream_capabilities WHERE workspace_id=$1 AND template_version_id=$3 AND command_type='SET_VALUE'")
            .bind(workspace_id).bind(device_id).bind(draft.template_version_id).execute(&mut *self.transaction).await.map_err(storage_error)?.rows_affected();
        Ok(RegisteredDevice {
            pin: DevicePin {
                workspace_id,
                device_id,
                owner_user_id: draft.owner_user_id,
                template_version_id: draft.template_version_id,
            },
            serial_number: draft.serial_number.clone(),
            name: draft.name.clone(),
            model: draft.model.clone(),
            created_at: now,
            actuator_count,
        })
    }
    /**
     * Delegate required typed audit cùng physical transaction để sink lỗi làm rollback registry.
     * Input
     * Param: audit — actor/scope đã authorize cùng detail UUID/counter allowlist.
     * Output: append thành công trong transaction; Errors: audit/storage.
     */
    async fn append_device_audit(&mut self, audit: AuditRecord) -> Result<(), ApplicationError> {
        IdentityTransaction::append_audit(self, audit).await
    }
    /// Chỉ phát receipt sau commit; lỗi transport giữ `CommitUnknown` và không tự retry INSERT.
    async fn commit_device(self) -> Result<(), ApplicationError> {
        self.transaction.commit().await.map_err(commit_error)
    }
}

/**
 * Ánh xạ unique serial thành lỗi duplicate generic để không lộ DB hoặc workspace sở hữu.
 * Input
 * Param: error — lỗi driver chỉ kiểm SQLSTATE và constraint cố định.
 * Output: `DeviceExists` cho serial collision, còn lại dùng classifier storage chung.
 */
fn registration_error(error: sqlx::Error) -> ApplicationError {
    if error.as_database_error().is_some_and(|database| {
        database.code().as_deref() == Some("23505")
            && database.constraint() == Some("devices_serial_number_key")
    }) {
        ApplicationError::DeviceExists
    } else {
        storage_error(error)
    }
}
