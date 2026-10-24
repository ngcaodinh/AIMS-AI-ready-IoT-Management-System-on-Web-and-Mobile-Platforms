//! Registry và assignment bằng PostgreSQL thật; không giả board/ACL hoặc DTO HTTP đã nghiệm thu.

use super::{ApplicationError, AuthService, PgPool, ProbeConfig, preferences_probe::seed_session};
use iot_platform_backend::{
    adapters::security::{CryptoService, PasswordService, generate_token},
    application::{device::DeviceService, template::TemplateService},
    domain::{
        device::{ApprovedDeviceModels, DeviceDraft, RegisteredDevice},
        identity::SessionProof,
        membership::{MembershipPatch, MembershipStatus},
        template::{
            ChannelKind, StreamDirection, StreamDraft, StreamType, StreamValue, TemplateDraft,
        },
        template_snapshot::PublishedTemplate,
    },
    postgres::{PgIdentityStore, connection::connect_local_probe},
};
use uuid::Uuid;

type Service = DeviceService<PgIdentityStore, CryptoService>;

/**
 * Dựng allowlist fixture tường minh; không coi model synthetic là production `PoC` đã được duyệt.
 * Input
 * Param: pool — pool probe thuộc run, không runtime writer.
 * Param: crypto — SHA256 adapter đã được composition dựng.
 * Output: service registry chỉ nhận `DEVICE_PROBE`.
 */
fn service(pool: &PgPool, crypto: &CryptoService) -> Result<Service, ApplicationError> {
    Ok(Service::new(
        PgIdentityStore::new(pool.clone()),
        crypto.clone(),
        ApprovedDeviceModels::new(vec!["DEVICE_PROBE".into()])?,
    ))
}

/**
 * Tạo schema synthetic có sensor và tùy chọn actuator; output capability không là reported truth.
 * Input
 * Param: name — marker thuộc run.
 * Param: writable — bật một capability `SET_VALUE` để kiểm actuator initialization.
 * Output: draft valid với model fixture được allowlist.
 */
fn template(name: String, writable: bool) -> TemplateDraft {
    let mut streams = vec![StreamDraft {
        key: "temperature".into(),
        display_name: "Temperature".into(),
        channel_kind: ChannelKind::Telemetry,
        data_type: StreamType::Number,
        direction: StreamDirection::Read,
        unit: None,
        minimum: None,
        maximum: None,
        string_max_length: None,
        enum_values: vec![],
        safe_value: None,
    }];
    if writable {
        streams.push(StreamDraft {
            key: "fan".into(),
            display_name: "Fan".into(),
            channel_kind: ChannelKind::State,
            data_type: StreamType::Boolean,
            direction: StreamDirection::ReadWrite,
            unit: None,
            minimum: None,
            maximum: None,
            string_max_length: None,
            enum_values: vec![],
            safe_value: Some(StreamValue::Boolean(false)),
        });
    }
    TemplateDraft {
        name,
        model: "DEVICE_PROBE".into(),
        description: None,
        streams,
    }
}

/**
 * Dựng intent registry không có trường hardware/firmware/credential để service không thể nhận metadata giả.
 * Input
 * Param: owner — identity fixture trong cùng workspace.
 * Param: version — immutable snapshot fixture.
 * Param: serial — canonical serial cần tranh unique hoặc kiểm rollback.
 * Output: input domain không chứa authority từ role/workspace client tự khai.
 */
fn input(owner: Uuid, version: Uuid, serial: String) -> DeviceDraft {
    DeviceDraft {
        serial_number: serial,
        name: " Device probe ".into(),
        model: "DEVICE_PROBE".into(),
        template_version_id: version,
        owner_user_id: owner,
    }
}

/// Chỉ giữ reference fixture của một run; không có credential trong Debug hoặc evidence.
struct DeviceProbe<'a> {
    first: &'a Service,
    second: &'a Service,
    templates: &'a TemplateService<PgIdentityStore, CryptoService>,
    pool: &'a PgPool,
    identity: &'a AuthService,
    config: &'a ProbeConfig,
    admin: &'a SessionProof,
    member: &'a SessionProof,
    foreign: &'a SessionProof,
    workspace: Uuid,
    foreign_workspace: Uuid,
}

impl DeviceProbe<'_> {
    /**
     * Giữ unique serial bằng transaction B rồi rollback sau khi phiên A hết hạn, quan sát blocked backend thật.
     * Input
     * Param: local — published snapshot tenant A.
     * Param: foreign — published snapshot tenant B cho row đang giữ unique index.
     * Output: A bị `SessionInvalid` sau wait và không registry/runtime/actuator nào commit.
     */
    async fn expiry_during_serial_wait(
        &self,
        local: &PublishedTemplate,
        foreign: &PublishedTemplate,
    ) -> Result<(), ApplicationError> {
        let token = generate_token();
        let proof = self.identity.session_proof(token.expose(), None);
        // Phiên test TTL đúng24h nhưng chỉ còn3 giây; timestamp trong một statement giữ equality constraint.
        let expires:chrono::DateTime<chrono::Utc>=sqlx::query_scalar("INSERT INTO sessions(session_id,user_id,token_digest,auth_context_id,limited,client_type,issued_at,expires_at) VALUES($1,$2,$3,$4,false,'ANDROID',statement_timestamp()-interval '24 hours'+interval '3 seconds',statement_timestamp()+interval '3 seconds') RETURNING expires_at")
            .bind(Uuid::new_v4()).bind(self.config.user_ids[5]).bind(proof.token_digest.as_slice()).bind(Uuid::new_v4()).fetch_one(self.pool).await.map_err(|_|ApplicationError::Unavailable)?;
        let serial = format!("EXPIRY-{}", self.config.run_id);
        let mut blocker = self
            .pool
            .begin()
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let blocker_pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
            .fetch_one(&mut *blocker)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        // Fixture B giữ unique(serial) nhưng không khóa User/Workspace A; rollback sẽ nhường slot cho waiter A.
        sqlx::query("INSERT INTO devices(device_id,workspace_id,serial_number,template_version_id,owner_user_id,name,model) VALUES($1,$2,$3,$4,$5,'Expiry blocker','DEVICE_PROBE')")
            .bind(Uuid::new_v4()).bind(self.foreign_workspace).bind(&serial).bind(foreign.template_version_id).bind(self.config.user_ids[6]).execute(&mut *blocker).await.map_err(|_|ApplicationError::Unavailable)?;
        let release = async {
            let mut observed = false;
            loop {
                // Chỉ metadata session cùng role; không đọc query chứa credential hoặc dữ liệu người dùng.
                let waiting:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE usename=current_user AND $1=ANY(pg_blocking_pids(pid)) AND wait_event_type='Lock')")
                    .bind(blocker_pid).fetch_one(self.pool).await.map_err(|_|ApplicationError::Unavailable)?;
                observed |= waiting;
                let now: chrono::DateTime<chrono::Utc> =
                    sqlx::query_scalar("SELECT clock_timestamp()")
                        .fetch_one(self.pool)
                        .await
                        .map_err(|_| ApplicationError::Unavailable)?;
                if observed && now >= expires {
                    blocker
                        .rollback()
                        .await
                        .map_err(|_| ApplicationError::Unavailable)?;
                    return Ok::<(), ApplicationError>(());
                }
                if now > expires + chrono::Duration::seconds(5) {
                    return Err(ApplicationError::Conflict);
                }
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
        };
        let (attempt, released) = tokio::join!(
            self.first.register(
                &proof,
                self.workspace,
                input(
                    self.config.user_ids[1],
                    local.template_version_id,
                    serial.clone()
                ),
                self.config.run_id
            ),
            release
        );
        released?;
        if !matches!(attempt, Err(ApplicationError::SessionInvalid)) {
            return Err(ApplicationError::Conflict);
        }
        let absent: bool =
            sqlx::query_scalar("SELECT NOT EXISTS(SELECT 1 FROM devices WHERE serial_number=$1)")
                .bind(serial)
                .fetch_one(self.pool)
                .await
                .map_err(|_| ApplicationError::Unavailable)?;
        if !absent {
            return Err(ApplicationError::Conflict);
        }
        Ok(())
    }
    /**
     * Tranh global serial giữa hai workspace qua hai pool, không chỉ dựa Workspace mutex cùng tenant.
     * Input
     * Param: local — version tenant A.
     * Param: foreign — version tenant B, owner/proof B hợp lệ.
     * Output: một winner và một `DeviceExists` không chứa identity tenant khác.
     */
    async fn cross_scope_race(
        &self,
        local: &PublishedTemplate,
        foreign: &PublishedTemplate,
    ) -> Result<(), ApplicationError> {
        let serial = format!("GLOBAL-{}", self.config.run_id);
        let (left, right) = tokio::join!(
            self.first.register(
                self.admin,
                self.workspace,
                input(
                    self.config.user_ids[1],
                    local.template_version_id,
                    serial.clone()
                ),
                self.config.run_id
            ),
            self.second.register(
                self.foreign,
                self.foreign_workspace,
                input(
                    self.config.user_ids[6],
                    foreign.template_version_id,
                    serial.clone()
                ),
                self.config.run_id
            )
        );
        if !matches!(
            (left, right),
            (Ok(_), Err(ApplicationError::DeviceExists))
                | (Err(ApplicationError::DeviceExists), Ok(_))
        ) {
            return Err(ApplicationError::Conflict);
        }
        let count: i64 = sqlx::query_scalar("SELECT count(*) FROM devices WHERE serial_number=$1")
            .bind(serial)
            .fetch_one(self.pool)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        if count != 1 {
            return Err(ApplicationError::Conflict);
        }
        Ok(())
    }

    /**
     * Kiểm deny theo current role/owner/model/template và NFC sau normalize mà không partial registry.
     * Input
     * Param: local — snapshot A có actuator.
     * Param: foreign — snapshot B không được resolve từ A.
     * Output: negative paths đúng lỗi và tên100 ký tự NFC được nhận; Errors: invariant/storage.
     */
    async fn denials_and_names(
        &self,
        local: &PublishedTemplate,
        foreign: &PublishedTemplate,
    ) -> Result<(), ApplicationError> {
        let draft = input(
            self.config.user_ids[1],
            local.template_version_id,
            format!("DENIED-{}", self.config.run_id),
        );
        if !matches!(
            self.first
                .register(
                    self.member,
                    self.workspace,
                    draft.clone(),
                    self.config.run_id
                )
                .await,
            Err(ApplicationError::Forbidden)
        ) || !matches!(
            self.first
                .register(
                    self.foreign,
                    self.workspace,
                    draft.clone(),
                    self.config.run_id
                )
                .await,
            Err(ApplicationError::Forbidden)
        ) {
            return Err(ApplicationError::Conflict);
        }
        let mut invalid = draft.clone();
        invalid.owner_user_id = self.config.user_ids[6];
        if !matches!(
            self.first
                .register(self.admin, self.workspace, invalid, self.config.run_id)
                .await,
            Err(ApplicationError::DeviceOwnerInvalid)
        ) {
            return Err(ApplicationError::Conflict);
        }
        let mut invalid = draft.clone();
        invalid.template_version_id = foreign.template_version_id;
        invalid.model = "Wrong model must not disclose foreign template".into();
        if !matches!(
            self.first
                .register(self.admin, self.workspace, invalid, self.config.run_id)
                .await,
            Err(ApplicationError::ResourceNotFound)
        ) {
            return Err(ApplicationError::Conflict);
        }
        let mut invalid = draft.clone();
        invalid.model = "Wrong model".into();
        if !matches!(
            self.first
                .register(self.admin, self.workspace, invalid, self.config.run_id)
                .await,
            Err(ApplicationError::DeviceModelMismatch)
        ) {
            return Err(ApplicationError::Conflict);
        }
        self.unapproved_model(&draft).await?;
        let exists: bool =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM devices WHERE serial_number=$1)")
                .bind(&draft.serial_number)
                .fetch_one(self.pool)
                .await
                .map_err(|_| ApplicationError::Unavailable)?;
        if exists {
            return Err(ApplicationError::Conflict);
        }
        let mut canonical = draft;
        canonical.name = format!("  {}  ", "e\u{301}".repeat(100));
        let saved = self
            .first
            .register(self.admin, self.workspace, canonical, self.config.run_id)
            .await?;
        if saved.name != "é".repeat(100) {
            return Err(ApplicationError::Conflict);
        }
        Ok(())
    }

    /**
     * Template tự khai model không được mở registry nếu model đó thiếu approved bootstrap allowlist.
     * Input
     * Param: draft — base intent A chưa được tạo, không có secret.
     * Output: đúng lỗi unsupported và không partial registry; Errors: invariant/storage.
     */
    async fn unapproved_model(&self, draft: &DeviceDraft) -> Result<(), ApplicationError> {
        let mut unsupported = template(format!("UNSUPPORTED:{}", self.config.run_id), false);
        unsupported.model = "UNAPPROVED_MODEL".into();
        let unsupported = self
            .templates
            .create(self.admin, self.workspace, unsupported, self.config.run_id)
            .await?;
        let unsupported = self
            .templates
            .publish(
                self.admin,
                self.workspace,
                unsupported.template_id,
                unsupported.revision,
                self.config.run_id,
            )
            .await?;
        let mut invalid = draft.clone();
        invalid.model = "UNAPPROVED_MODEL".into();
        invalid.template_version_id = unsupported.template_version_id;
        if !matches!(
            self.first
                .register(self.admin, self.workspace, invalid, self.config.run_id)
                .await,
            Err(ApplicationError::DeviceModelUnsupported)
        ) {
            return Err(ApplicationError::Conflict);
        }
        Ok(())
    }

    /**
     * Owner mất membership thì đăng ký/schema bị chặn ngay; resume chỉ khôi phục current grant hợp lệ.
     * Input
     * Param: winner — registry đã pin cho owner fixture A.
     * Param: version — schema A dùng intent chưa được ghi.
     * Output: suspend chặn create/read, resume trả schema; Errors: invariant/storage.
     */
    async fn current_authority(
        &self,
        winner: &RegisteredDevice,
        version: &PublishedTemplate,
    ) -> Result<(), ApplicationError> {
        let revision: i64 = sqlx::query_scalar(
            "SELECT revision FROM memberships WHERE workspace_id=$1 AND user_id=$2",
        )
        .bind(self.workspace)
        .bind(self.config.user_ids[1])
        .fetch_one(self.pool)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
        let suspended = self
            .identity
            .update_member(
                self.admin,
                self.workspace,
                self.config.user_ids[1],
                revision,
                &MembershipPatch {
                    status: Some(MembershipStatus::Suspended),
                    ..MembershipPatch::default()
                },
                self.config.run_id,
            )
            .await?;
        let draft = input(
            self.config.user_ids[1],
            version.template_version_id,
            format!("SUSPENDED-{}", self.config.run_id),
        );
        if !matches!(
            self.first
                .register(self.admin, self.workspace, draft, self.config.run_id)
                .await,
            Err(ApplicationError::DeviceOwnerInvalid)
        ) || !matches!(
            self.first
                .schema(self.member, self.workspace, winner.pin.device_id)
                .await,
            Err(ApplicationError::Forbidden)
        ) {
            return Err(ApplicationError::Conflict);
        }
        self.identity
            .update_member(
                self.admin,
                self.workspace,
                self.config.user_ids[1],
                suspended.revision,
                &MembershipPatch {
                    status: Some(MembershipStatus::Active),
                    ..MembershipPatch::default()
                },
                self.config.run_id,
            )
            .await?;
        self.first
            .schema(self.member, self.workspace, winner.pin.device_id)
            .await?;
        // Revoke đúng phiên fixture mới; không đổi account hoặc global session khác.
        let stale = seed_session(self.identity, self.pool, self.config.user_ids[5], false).await?;
        sqlx::query("UPDATE sessions SET revoked_at=clock_timestamp() WHERE token_digest=$1")
            .bind(stale.token_digest.as_slice())
            .execute(self.pool)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let draft = input(
            self.config.user_ids[1],
            version.template_version_id,
            format!("STALE-{}", self.config.run_id),
        );
        if !matches!(
            self.first
                .register(&stale, self.workspace, draft, self.config.run_id)
                .await,
            Err(ApplicationError::SessionInvalid)
        ) {
            return Err(ApplicationError::Conflict);
        }
        Ok(())
    }

    /**
     * Sensor-only không tạo actuator; root đang DRAFT vẫn cho pin v1, root archived chặn pin mới.
     * Input
     * Param: version — snapshot sensor-only đã publish, sau đó root được sửa và archive trong fixture.
     * Output:0 actuator, immutable pin đọc được và registry mới bị chặn sau archive.
     */
    async fn sensor_and_root_lifecycle(
        &self,
        version: &PublishedTemplate,
    ) -> Result<(), ApplicationError> {
        self.templates
            .replace(
                self.admin,
                self.workspace,
                version.template_id,
                version.template_revision,
                template(format!("SENSOR_DRAFT:{}", self.config.run_id), true),
                self.config.run_id,
            )
            .await?;
        let registered = self
            .first
            .register(
                self.admin,
                self.workspace,
                input(
                    self.config.user_ids[1],
                    version.template_version_id,
                    format!("SENSOR-{}", self.config.run_id),
                ),
                self.config.run_id,
            )
            .await?;
        if registered.actuator_count != 0 {
            return Err(ApplicationError::Conflict);
        }
        // Chỉ fixture root thuộc run; không coi câu SQL này là acceptance của template archive service.
        sqlx::query("UPDATE templates SET lifecycle_status='ARCHIVED',revision=revision+1 WHERE workspace_id=$1 AND template_id=$2").bind(self.workspace).bind(version.template_id).execute(self.pool).await.map_err(|_|ApplicationError::Unavailable)?;
        let draft = input(
            self.config.user_ids[1],
            version.template_version_id,
            format!("ARCHIVED-{}", self.config.run_id),
        );
        if !matches!(
            self.first
                .register(self.admin, self.workspace, draft, self.config.run_id)
                .await,
            Err(ApplicationError::ResourceNotFound)
        ) {
            return Err(ApplicationError::Conflict);
        }
        let retained = self
            .first
            .schema(self.member, self.workspace, registered.pin.device_id)
            .await?;
        if retained.template_version_id != version.template_version_id {
            return Err(ApplicationError::Conflict);
        }
        Ok(())
    }
    /**
     * Tạo/publish template qua application thật, không seed digest giả cho đường registry cần kiểm integrity.
     * Input
     * Param: foreign — chọn tenant B/proof B để kiểm isolation và race serial xuyên tenant.
     * Param: writable — schema có actuator hoặc sensor-only.
     * Output: publication committed, không giả HTTP hoặc firmware consumption.
     */
    async fn publish(
        &self,
        foreign: bool,
        writable: bool,
    ) -> Result<PublishedTemplate, ApplicationError> {
        let (proof, workspace) = if foreign {
            (self.foreign, self.foreign_workspace)
        } else {
            (self.admin, self.workspace)
        };
        let draft = self
            .templates
            .create(
                proof,
                workspace,
                template(
                    format!("DEVICE_PROBE:{}:{foreign}:{writable}", self.config.run_id),
                    writable,
                ),
                self.config.run_id,
            )
            .await?;
        self.templates
            .publish(
                proof,
                workspace,
                draft.template_id,
                draft.revision,
                self.config.run_id,
            )
            .await
    }

    /**
     * Tranh serial qua hai pool thật, đối chiếu registry/runtime/actuator/audit không có partial state.
     * Input
     * Param: version — published snapshot fixture A.
     * Output: winner receipt, loser `DeviceExists` generic; Errors: invariant/storage chặn PASS.
     */
    async fn serial_race(
        &self,
        version: &PublishedTemplate,
    ) -> Result<RegisteredDevice, ApplicationError> {
        let draft = input(
            self.config.user_ids[1],
            version.template_version_id,
            format!("REG-{}", self.config.run_id),
        );
        let (left, right) = tokio::join!(
            self.first.register(
                self.admin,
                self.workspace,
                draft.clone(),
                self.config.run_id
            ),
            self.second
                .register(self.admin, self.workspace, draft, self.config.run_id)
        );
        let ((Ok(winner), Err(ApplicationError::DeviceExists))
        | (Err(ApplicationError::DeviceExists), Ok(winner))) = (left, right)
        else {
            return Err(ApplicationError::Conflict);
        };
        // Projection allowlist kiểm state init và atomic audit; không SELECT credential verifier hoặc raw device row.
        let valid:bool=sqlx::query_scalar("SELECT device.lifecycle_status='REGISTERED' AND device.hardware_revision IS NULL AND device.firmware_version IS NULL AND device.firmware_digest IS NULL AND device.revision=1 AND runtime.presence_state='UNKNOWN' AND runtime.last_seen_at IS NULL AND runtime.maintenance='NONE' AND NOT EXISTS(SELECT 1 FROM device_credentials credential WHERE credential.workspace_id=device.workspace_id AND credential.device_id=device.device_id) AND (SELECT count(*)=1 FROM actuator_states actuator WHERE actuator.workspace_id=device.workspace_id AND actuator.device_id=device.device_id AND actuator.manual_epoch=0 AND actuator.last_reported_value IS NULL AND actuator.last_reported_at IS NULL AND actuator.unresolved_command_id IS NULL AND actuator.reported_source='NONE') AND (SELECT count(*)=1 FROM audit_events audit WHERE audit.workspace_id=device.workspace_id AND audit.resource_type='DEVICE' AND audit.resource_id=device.device_id::text AND audit.event_type='DEVICE_REGISTERED' AND audit.redacted_diff->>'template_version_id'=device.template_version_id::text AND audit.redacted_diff->>'actuator_count'='1' AND NOT audit.redacted_diff ?| ARRAY['serial','serial_number','name','hardware_revision']) FROM devices device JOIN device_runtime runtime USING(workspace_id,device_id) WHERE device.workspace_id=$1 AND device.device_id=$2")
            .bind(self.workspace).bind(winner.pin.device_id).fetch_one(self.pool).await.map_err(|_|ApplicationError::Unavailable)?;
        if !valid || winner.actuator_count != 1 || winner.name != "Device probe" {
            return Err(ApplicationError::Conflict);
        }
        Ok(winner)
    }

    /**
     * Admin/owner đọc đúng pin; USER không được đọc device cùng tenant thuộc người khác hoặc UUID tenant B.
     * Input
     * Param: winner — device owner member A vừa register.
     * Param: version — snapshot immutable dùng so digest/identity.
     * Output: thành công khi mọi boundary và history pin được giữ.
     */
    async fn schema_access(
        &self,
        winner: &RegisteredDevice,
        version: &PublishedTemplate,
    ) -> Result<(), ApplicationError> {
        let owner = self
            .first
            .schema(self.member, self.workspace, winner.pin.device_id)
            .await?;
        let admin = self
            .second
            .schema(self.admin, self.workspace, winner.pin.device_id)
            .await?;
        if owner.template_version_id != version.template_version_id
            || owner.content_digest != version.content_digest
            || admin.content_digest != owner.content_digest
        {
            return Err(ApplicationError::Conflict);
        }
        let unassigned = self
            .first
            .register(
                self.admin,
                self.workspace,
                input(
                    self.config.user_ids[5],
                    version.template_version_id,
                    format!("ADMIN-{}", self.config.run_id),
                ),
                self.config.run_id,
            )
            .await?;
        for id in [unassigned.pin.device_id, Uuid::new_v4()] {
            if !matches!(
                self.first.schema(self.member, self.workspace, id).await,
                Err(ApplicationError::ResourceNotFound)
            ) {
                return Err(ApplicationError::Conflict);
            }
        }
        if !matches!(
            self.first
                .schema(self.foreign, self.foreign_workspace, winner.pin.device_id)
                .await,
            Err(ApplicationError::ResourceNotFound)
        ) {
            return Err(ApplicationError::Conflict);
        }
        // Draft mới trên root không được sửa schema cũ của thiết bị đã pin.
        let changed = self
            .templates
            .replace(
                self.admin,
                self.workspace,
                version.template_id,
                version.template_revision,
                template(format!("DEVICE_EDIT:{}", self.config.run_id), false),
                self.config.run_id,
            )
            .await?;
        self.templates
            .publish(
                self.admin,
                self.workspace,
                version.template_id,
                changed.revision,
                self.config.run_id,
            )
            .await?;
        let after = self
            .first
            .schema(self.member, self.workspace, winner.pin.device_id)
            .await?;
        if after.content_digest != owner.content_digest
            || after.template_version_id != owner.template_version_id
        {
            return Err(ApplicationError::Conflict);
        }
        Ok(())
    }
}

/**
 * Điều phối hai pool và proofs đã có provenance, chỉ thêm PASS sau kiểm invariant bằng DB thật.
 * Input
 * Param: config — transport/identity synthetic của launcher qua stdin kín.
 * Param: checks — evidence tên invariant không PII/secret.
 * Output: workflow registry/schema và pool đã đóng; Errors: invariant/storage được lọc.
 */
pub(super) async fn verify(
    config: ProbeConfig,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let pool = connect_local_probe(config.port, &config.username, &config.password).await?;
    let other = connect_local_probe(config.port, &config.username, &config.password).await?;
    let crypto = CryptoService::new(PasswordService::default(), config.limiter_key).await?;
    let identity = AuthService::new(PgIdentityStore::new(pool.clone()), crypto.clone());
    let admin = seed_session(&identity, &pool, config.user_ids[5], false).await?;
    let member = seed_session(&identity, &pool, config.user_ids[1], false).await?;
    let foreign = seed_session(&identity, &pool, config.user_ids[6], false).await?;
    // Creator/provenance chỉ chọn tenant fixture thuộc run, không lookup workspace người dùng.
    let mut scopes = Vec::new();
    for creator in &config.user_ids[5..7] {
        let workspace:Uuid=sqlx::query_scalar("SELECT workspace_id FROM workspaces JOIN users account ON account.user_id=created_by_user_id WHERE created_by_user_id=$1 AND account.activation_provenance=$2")
            .bind(creator).bind(format!("REPOSITORY_PROBE:{}",config.run_id)).fetch_one(&pool).await.map_err(|_|ApplicationError::Unavailable)?;
        scopes.push(workspace);
    }
    let first = service(&pool, &crypto)?;
    let second = service(&other, &crypto)?;
    let templates = TemplateService::new(PgIdentityStore::new(pool.clone()), crypto);
    let context = DeviceProbe {
        first: &first,
        second: &second,
        templates: &templates,
        pool: &pool,
        identity: &identity,
        config: &config,
        admin: &admin,
        member: &member,
        foreign: &foreign,
        workspace: scopes[0],
        foreign_workspace: scopes[1],
    };
    let version = context.publish(false, true).await?;
    let foreign_version = context.publish(true, true).await?;
    let winner = context.serial_race(&version).await?;
    checks.push("PASS: two-pool registry serial race has one device, UNKNOWN runtime, unreported actuator and redacted required audit");
    context.cross_scope_race(&version, &foreign_version).await?;
    checks.push("PASS: two independent workspace and pool registrations arbitrate global serial with one winner and a generic duplicate error");
    context
        .expiry_during_serial_wait(&version, &foreign_version)
        .await?;
    checks.push("PASS: registry rechecks session expiry after an observed cross-workspace unique-serial lock wait and rolls back after blocker rollback");
    context
        .denials_and_names(&version, &foreign_version)
        .await?;
    checks.push("PASS: registry denies USER, foreign owner/version, mismatched and unapproved model; NFC normalization precedes the hundred-scalar name limit");
    context.schema_access(&winner, &version).await?;
    checks.push("PASS: device schema enforces current Admin or assigned owner, hides foreign/unassigned UUIDs and preserves v1 pin after v2");
    context.current_authority(&winner, &version).await?;
    checks.push("PASS: current owner suspension blocks registration and assigned schema reads immediately; revoked Admin session cannot register");
    let sensor = context.publish(false, false).await?;
    context.sensor_and_root_lifecycle(&sensor).await?;
    checks.push("PASS: sensor-only registration creates zero actuators; root draft accepts a published pin and archive prevents new pins while preserving assigned schema");
    pool.close().await;
    other.close().await;
    Ok(())
}

/**
 * Fault audit INSERT bị revoke thật phải rollback cả registry/runtime/actuator, không phát receipt.
 * Input
 * Param: pool — role probe bị launcher revoke audit INSERT, không dùng role owner.
 * Param: identity — service chỉ dựng session synthetic cho Admin fixture.
 * Param: crypto — digest adapter của cùng composition.
 * Param: config — provenance/correlation của run.
 * Param: checks — chỉ tên invariant sau khi fault được quan sát.
 * Output: thành công khi mọi aggregate count giữ nguyên; Errors: invariant/storage.
 */
pub(super) async fn verify_failure(
    pool: &PgPool,
    identity: &AuthService,
    crypto: &CryptoService,
    config: &ProbeConfig,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let admin = seed_session(identity, pool, config.user_ids[5], false).await?;
    // Chỉ chọn template thuộc workspace do fixture run tạo, không lookup version của account người dùng.
    let (workspace,version):(Uuid,Uuid)=sqlx::query_as("SELECT root.workspace_id,version.template_version_id FROM templates root JOIN template_versions version USING(workspace_id,template_id) JOIN workspaces scope USING(workspace_id) WHERE scope.created_by_user_id=$1 AND root.lifecycle_status<>'ARCHIVED' AND version.model='DEVICE_PROBE' ORDER BY version.version_number DESC LIMIT 1")
        .bind(config.user_ids[5]).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let counts = "SELECT (SELECT count(*) FROM devices WHERE workspace_id=$1),(SELECT count(*) FROM device_runtime WHERE workspace_id=$1),(SELECT count(*) FROM actuator_states WHERE workspace_id=$1)";
    let before: (i64, i64, i64) = sqlx::query_as(counts)
        .bind(workspace)
        .fetch_one(pool)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    let registry = service(pool, crypto)?;
    let draft = input(
        config.user_ids[5],
        version,
        format!("AUDIT-FAULT-{}", config.run_id),
    );
    if !matches!(
        registry
            .register(&admin, workspace, draft, config.run_id)
            .await,
        Err(ApplicationError::Unavailable)
    ) {
        return Err(ApplicationError::Conflict);
    }
    let after: (i64, i64, i64) = sqlx::query_as(counts)
        .bind(workspace)
        .fetch_one(pool)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    if before != after {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: audit INSERT denial rolls back device registry, UNKNOWN runtime and actuator initialization without emitting a receipt");
    Ok(())
}
