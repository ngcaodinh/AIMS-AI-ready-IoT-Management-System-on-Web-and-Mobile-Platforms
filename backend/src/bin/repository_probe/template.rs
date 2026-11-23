//! Template workflow qua port/PG thật; fixture metadata không chứa credential và không là HTTP acceptance.

use super::{ApplicationError, AuthService, PgPool, ProbeConfig, preferences_probe::seed_session};
use iot_platform_backend::{
    adapters::security::{CryptoService, PasswordService},
    application::template::TemplateService,
    domain::{
        identity::SessionProof,
        template::{
            ChannelKind, StreamDirection, StreamDraft, StreamType, StreamValue, TemplateDraft,
        },
        template_snapshot::{PublishedTemplate, TemplateStatus},
        template_value::DecimalLiteral,
    },
    postgres::{PgIdentityStore, connection::connect_local_probe},
};
use uuid::Uuid;

type Service = TemplateService<PgIdentityStore, CryptoService>;

/**
 * Tạo schema fixture đủ bốn kiểu/hai loại kênh, ENUM chuỗi và NUMBER exact vượt2^53.
 * Input
 * Param: name — marker synthetic thuộc run, không tên template người dùng.
 * Output: input domain hợp lệ có safe values typed và enum exact.
 */
fn schema(name: String) -> TemplateDraft {
    let number =
        |text: &str| StreamValue::Number(DecimalLiteral::new(text).expect("literal fixture valid"));
    let temperature = StreamDraft {
        key: "temperature".into(),
        display_name: "Temperature".into(),
        channel_kind: ChannelKind::Telemetry,
        data_type: StreamType::Number,
        direction: StreamDirection::Read,
        unit: Some("C".into()),
        minimum: Some(-20.0),
        maximum: Some(100.0),
        string_max_length: None,
        enum_values: vec![],
        safe_value: None,
    };
    let mut fan = temperature.clone();
    fan.key = "fan".into();
    fan.display_name = "Fan".into();
    fan.channel_kind = ChannelKind::State;
    fan.data_type = StreamType::Boolean;
    fan.direction = StreamDirection::ReadWrite;
    fan.unit = None;
    fan.minimum = None;
    fan.maximum = None;
    fan.safe_value = Some(StreamValue::Boolean(false));
    let mut state = fan.clone();
    state.key = "operating_state".into();
    state.data_type = StreamType::Enum;
    state.enum_values = vec![
        StreamValue::Text("off".into()),
        StreamValue::Text("on".into()),
    ];
    state.safe_value = Some(StreamValue::Text("off".into()));
    let mut label = temperature.clone();
    label.key = "label".into();
    label.data_type = StreamType::String;
    label.unit = None;
    label.minimum = None;
    label.maximum = None;
    label.string_max_length = Some(40);
    let mut precision = fan.clone();
    precision.key = "precision".into();
    precision.display_name = "Exact numeric value".into();
    precision.data_type = StreamType::Number;
    precision.unit = None;
    precision.minimum = Some(0.0);
    precision.maximum = Some(10_000_000_000_000_000.0);
    precision.safe_value = Some(number("9007199254740993"));
    TemplateDraft {
        name,
        model: "ESP32_PROBE".into(),
        description: Some("Private root metadata".into()),
        streams: vec![temperature, fan, state, label, precision],
    }
}

/// Context chỉ giữ reference tới fixtures đã được launcher preflight, không secret trong Debug/evidence.
struct TemplateProbe<'a> {
    first: &'a Service,
    second: &'a Service,
    pool: &'a PgPool,
    config: &'a ProbeConfig,
    admin: &'a SessionProof,
    member: &'a SessionProof,
    foreign: &'a SessionProof,
    workspace: Uuid,
    foreign_workspace: Uuid,
}

impl TemplateProbe<'_> {
    /**
     * Tạo draft và publish cạnh tranh, kiểm count snapshot đầy đủ cùng scoped audit sau winner commit.
     * Output: một publication để test pin/history; Errors: storage/invariant chặn evidence PASS.
     */
    async fn publish_race(&self) -> Result<PublishedTemplate, ApplicationError> {
        let input = schema(format!("TEMPLATE_PROBE:{}", self.config.run_id));
        let created = self
            .first
            .create(
                self.admin,
                self.workspace,
                input.clone(),
                self.config.run_id,
            )
            .await?;
        let read = self
            .first
            .get(self.admin, self.workspace, created.template_id)
            .await?;
        if read.revision != 1
            || read.status != TemplateStatus::Draft
            || read.draft.canonical_bytes()
                != input
                    .validate()
                    .map_err(ApplicationError::TemplateInvalid)?
                    .canonical_bytes()
        {
            return Err(ApplicationError::Conflict);
        }
        let (left, right) = tokio::join!(
            self.first.publish(
                self.admin,
                self.workspace,
                created.template_id,
                1,
                self.config.run_id
            ),
            self.second.publish(
                self.admin,
                self.workspace,
                created.template_id,
                1,
                self.config.run_id
            )
        );
        let ((Ok(version), Err(ApplicationError::StaleRevision))
        | (Err(ApplicationError::StaleRevision), Ok(version))) = (left, right)
        else {
            return Err(ApplicationError::Conflict);
        };
        let complete:bool=sqlx::query_scalar("SELECT (SELECT count(*)=1 FROM template_versions WHERE workspace_id=$1 AND template_id=$2) AND (SELECT count(*)=5 FROM datastream_definitions WHERE workspace_id=$1 AND template_version_id=$3) AND (SELECT count(*)=2 FROM datastream_enum_values WHERE workspace_id=$1 AND template_version_id=$3) AND (SELECT count(*)=3 FROM datastream_capabilities WHERE workspace_id=$1 AND template_version_id=$3) AND (SELECT count(*)=1 FROM audit_events WHERE workspace_id=$1 AND resource_id=$3::text AND event_type='TEMPLATE_PUBLISHED')")
            .bind(self.workspace).bind(created.template_id).bind(version.template_version_id).fetch_one(self.pool).await.map_err(|_|ApplicationError::Unavailable)?;
        if !complete
            || version.version_number != 1
            || version.source_revision != 1
            || version.published_root_revision != 2
        {
            return Err(ApplicationError::Conflict);
        }
        Ok(version)
    }

    /**
     * Pin device thật trong DB vào v1 rồi sửa root/draft/publish v2, kiểm digest v1 tái dựng không cần root metadata.
     * Input
     * Param: original — winner publication v1 của fixture này.
     * Output: thành công khi pin/digest/typed enum v1 không đổi và v2 tách version identity.
     */
    async fn immutable_history(
        &self,
        original: &PublishedTemplate,
    ) -> Result<(), ApplicationError> {
        let device = Uuid::new_v4();
        // Chỉ tạo registry fixture, không cấp credential hoặc giả rằng board vật lý đã được provision.
        sqlx::query("INSERT INTO devices(device_id,workspace_id,serial_number,template_version_id,owner_user_id,name,model,hardware_revision) VALUES($1,$2,$3,$4,$5,'D1 template pin probe','ESP32_PROBE','1')")
            .bind(device).bind(self.workspace).bind(format!("TPL-{device}")).bind(original.template_version_id).bind(self.config.user_ids[1]).execute(self.pool).await.map_err(|_|ApplicationError::Unavailable)?;
        let initial_pin: Uuid = sqlx::query_scalar(
            "SELECT template_version_id FROM devices WHERE workspace_id=$1 AND device_id=$2",
        )
        .bind(self.workspace)
        .bind(device)
        .fetch_one(self.pool)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
        if initial_pin != original.template_version_id {
            return Err(ApplicationError::Conflict);
        }
        let before = self
            .first
            .get_version(self.admin, self.workspace, original.template_version_id)
            .await?;
        let mut changed = schema(format!("TEMPLATE_PROBE_CHANGED:{}", self.config.run_id));
        changed.model = "ESP32_PROBE_2".into();
        changed.description = Some("Root changed after immutable v1".into());
        changed.streams[0].maximum = Some(150.0);
        let updated = self
            .first
            .replace(
                self.admin,
                self.workspace,
                original.template_id,
                2,
                changed,
                self.config.run_id,
            )
            .await?;
        let second = self
            .first
            .publish(
                self.admin,
                self.workspace,
                original.template_id,
                updated.revision,
                self.config.run_id,
            )
            .await?;
        let pin: Uuid = sqlx::query_scalar(
            "SELECT template_version_id FROM devices WHERE workspace_id=$1 AND device_id=$2",
        )
        .bind(self.workspace)
        .bind(device)
        .fetch_one(self.pool)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
        let after = self
            .second
            .get_version(self.admin, self.workspace, pin)
            .await?;
        if before.content.canonical_bytes() != after.content.canonical_bytes()
            || before.content_digest != original.content_digest
            || after.content_digest != original.content_digest
            || pin != original.template_version_id
            || after.template_version_id != pin
            || before.source_revision != Some(1)
            || before.published_root_revision != Some(2)
            || second.source_revision != 3
            || second.published_root_revision != 4
            || second.version_number != 2
            || second.content_digest == original.content_digest
        {
            return Err(ApplicationError::Conflict);
        }
        let precision = after
            .content
            .draft()
            .streams
            .iter()
            .find(|stream| stream.key == "precision")
            .ok_or(ApplicationError::Conflict)?;
        let operating_state = after
            .content
            .draft()
            .streams
            .iter()
            .find(|stream| stream.key == "operating_state")
            .ok_or(ApplicationError::Conflict)?;
        if operating_state.enum_values.len() != 2
            || operating_state.safe_value != Some(StreamValue::Text("off".into()))
            || precision.safe_value
                != Some(StreamValue::Number(
                    DecimalLiteral::new("9007199254740993").ok_or(ApplicationError::Conflict)?,
                ))
        {
            return Err(ApplicationError::Conflict);
        }
        Ok(())
    }

    /**
     * Kiểm tra các nhánh từ chối validation, quyền, phạm vi workspace và CAS không tạo root/version một phần.
     *
     * # Input
     * Param: original — template root của workspace hiện hành dùng làm đối tượng kiểm tra âm tính.
     *
     * # Output
     * Trả về `Ok(())` khi mọi nhánh âm tính trả đúng lỗi theo hợp đồng và root revision giữ nguyên là 4;
     * trả về `Err(ApplicationError::Conflict)` nếu bất kỳ nhánh nào sai mã lỗi hoặc làm thay đổi revision.
     */
    async fn negatives(&self, original: &PublishedTemplate) -> Result<(), ApplicationError> {
        let mut duplicate = schema("Duplicate".into());
        duplicate.streams.push(duplicate.streams[0].clone());
        if !matches!(
            self.first
                .create(self.admin, self.workspace, duplicate, self.config.run_id)
                .await,
            Err(ApplicationError::TemplateInvalid(_))
        ) || !matches!(
            self.first
                .create(
                    self.member,
                    self.workspace,
                    schema("Denied".into()),
                    self.config.run_id
                )
                .await,
            Err(ApplicationError::Forbidden)
        ) || !matches!(
            self.first
                .get(self.member, self.workspace, original.template_id)
                .await,
            Err(ApplicationError::Forbidden)
        ) || !matches!(
            self.first
                .get_version(
                    self.foreign,
                    self.foreign_workspace,
                    original.template_version_id
                )
                .await,
            Err(ApplicationError::ResourceNotFound)
        ) || !matches!(
            // Admin không có membership tại `foreign_workspace` nên `TemplateService::open`
            // che sự tồn tại của workspace khác bằng `ResourceNotFound` thay vì `Forbidden`.
            self.first
                .get_version(
                    self.admin,
                    self.foreign_workspace,
                    original.template_version_id
                )
                .await,
            Err(ApplicationError::ResourceNotFound)
        ) || !matches!(
            self.first
                .replace(
                    self.admin,
                    self.workspace,
                    original.template_id,
                    1,
                    schema("Stale".into()),
                    self.config.run_id
                )
                .await,
            Err(ApplicationError::StaleRevision)
        ) || !matches!(
            self.first
                .publish(
                    self.admin,
                    self.workspace,
                    original.template_id,
                    4,
                    self.config.run_id
                )
                .await,
            Err(ApplicationError::ImmutableSchema)
        ) {
            return Err(ApplicationError::Conflict);
        }
        if self
            .first
            .get(self.admin, self.workspace, original.template_id)
            .await?
            .revision
            != 4
        {
            return Err(ApplicationError::Conflict);
        }
        Ok(())
    }
}

/**
 * Tạo current proof từ fixtures đã thuộc run, rồi chạy workflow qua hai pool độc lập.
 * Input
 * Param: config — transport/identity synthetic qua stdin launcher.
 * Param: checks — chỉ invariant names, không schema text hay credential.
 * Output: các check đạt và đóng pool; Errors: bất kỳ invariant/storage sai chặn PASS.
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
    // Creator/provenance là fixture CRT, không chọn workspace của account ngoài run.
    let workspaces:Vec<Uuid>=sqlx::query_scalar("SELECT workspace_id FROM workspaces JOIN users account ON account.user_id=created_by_user_id WHERE created_by_user_id=ANY($1) AND account.activation_provenance=$2 ORDER BY created_by_user_id")
        .bind(&config.user_ids[5..7]).bind(format!("REPOSITORY_PROBE:{}",config.run_id)).fetch_all(&pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let workspace: Uuid =
        sqlx::query_scalar("SELECT workspace_id FROM workspaces WHERE created_by_user_id=$1")
            .bind(config.user_ids[5])
            .fetch_one(&pool)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
    let foreign_workspace = *workspaces
        .iter()
        .find(|id| **id != workspace)
        .ok_or(ApplicationError::Conflict)?;
    let first = Service::new(PgIdentityStore::new(pool.clone()), crypto.clone());
    let second = Service::new(PgIdentityStore::new(other.clone()), crypto);
    let context = TemplateProbe {
        first: &first,
        second: &second,
        pool: &pool,
        config: &config,
        admin: &admin,
        member: &member,
        foreign: &foreign,
        workspace,
        foreign_workspace,
    };
    let version = context.publish_race().await?;
    checks.push("PASS: normalized template create/read and two-pool publish CAS commit one complete version and audit");
    if !matches!(
        context
            .first
            .get_version(
                context.member,
                context.workspace,
                version.template_version_id
            )
            .await,
        Err(ApplicationError::Forbidden)
    ) {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: direct template-version reads deny USER without an assigned device instead of granting tenant-wide schema access");
    context.immutable_history(&version).await?;
    checks.push("PASS: published template digest reconstructs from immutable version rows after root edits and v2 leaves device pin on v1");
    checks.push("PASS: template channel kind and direction persist independently and ENUM values above two-to-the-fifty-third remain exact");
    context.negatives(&version).await?;
    checks.push("PASS: invalid template, stale revision, USER draft administration and foreign-version selectors are denied without partial mutation");
    first
        .create(
            &admin,
            workspace,
            schema(format!("TEMPLATE_PUBLISH_FAULT:{}", config.run_id)),
            config.run_id,
        )
        .await?;
    pool.close().await;
    other.close().await;
    Ok(())
}

/**
 * Audit INSERT bị launcher từ chối thật phải rollback create, draft replace và publication cùng mọi child.
 * Input
 * Param: pool — fixture role đang bị revoke INSERT audit, không owner hoặc runtime production.
 * Param: identity — IAM composition chỉ dùng tạo proof synthetic.
 * Param: crypto — digest adapter SHA256 của template.
 * Param: config — marker fixture của normal template phase.
 * Param: checks — invariant names sau fault đã được chứng minh.
 * Output: thành công hoặc lỗi nếu một mutation/version lọt commit khi audit thất bại.
 */
pub(super) async fn verify_failure(
    pool: &PgPool,
    identity: &AuthService,
    crypto: &CryptoService,
    config: &ProbeConfig,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    let proof = seed_session(identity, pool, config.user_ids[5], false).await?;
    let workspace: Uuid =
        sqlx::query_scalar("SELECT workspace_id FROM workspaces WHERE created_by_user_id=$1")
            .bind(config.user_ids[5])
            .fetch_one(pool)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
    let service = Service::new(PgIdentityStore::new(pool.clone()), crypto.clone());
    let fault:Uuid=sqlx::query_scalar("SELECT template_id FROM templates WHERE workspace_id=$1 AND created_by_user_id=$2 AND name=$3").bind(workspace).bind(config.user_ids[5]).bind(format!("TEMPLATE_PUBLISH_FAULT:{}",config.run_id)).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let before = service.get(&proof, workspace, fault).await?;
    let count_before: i64 =
        sqlx::query_scalar("SELECT count(*) FROM templates WHERE workspace_id=$1")
            .bind(workspace)
            .fetch_one(pool)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
    if !matches!(
        service
            .create(
                &proof,
                workspace,
                schema("Audit denied create".into()),
                config.run_id
            )
            .await,
        Err(ApplicationError::Unavailable)
    ) || !matches!(
        service
            .replace(
                &proof,
                workspace,
                fault,
                before.revision,
                schema("Audit denied replace".into()),
                config.run_id
            )
            .await,
        Err(ApplicationError::Unavailable)
    ) || !matches!(
        service
            .publish(&proof, workspace, fault, before.revision, config.run_id)
            .await,
        Err(ApplicationError::Unavailable)
    ) {
        return Err(ApplicationError::Conflict);
    }
    let after = service.get(&proof, workspace, fault).await?;
    let clean:bool=sqlx::query_scalar("SELECT (SELECT count(*) FROM templates WHERE workspace_id=$1)=$3 AND NOT EXISTS(SELECT 1 FROM template_versions WHERE workspace_id=$1 AND template_id=$2)")
        .bind(workspace).bind(fault).bind(count_before).fetch_one(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    if !clean
        || after.revision != before.revision
        || after.status != before.status
        || after.draft.canonical_bytes() != before.draft.canonical_bytes()
    {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: audit INSERT denial rolls back template create, normalized draft replacement and immutable publication with no partial version");
    Ok(())
}
