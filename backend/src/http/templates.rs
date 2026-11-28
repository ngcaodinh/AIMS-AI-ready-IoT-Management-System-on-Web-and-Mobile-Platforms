//! Routes template cho current Admin. Workspace và CAS kiểm lại trong cùng unit of work.

use super::{
    HttpError, HttpState,
    members::member_if_match,
    no_store, security, sessions,
    template_wire::{self, Configuration, field_error},
};
use axum::{
    Json, Router,
    extract::{Path, Query, Request, State, rejection::QueryRejection},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Utc};
use iot_application::error::ApplicationError;
use iot_domain::{
    identity::SessionProof,
    template::{TemplateField, TemplateIssueReason, TemplateValidation},
    template_snapshot::{TemplateSnapshot, TemplateStatus, TemplateVersionSnapshot},
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/**
 * Đăng ký root draft, PATCH CAS, clone draft và các endpoint snapshot immutable.
 *
 * # Output
 * Router chỉ dùng trong integrated lab; handler tự enforce session/current workspace/Admin.
 */
pub(super) fn routes() -> Router<HttpState> {
    Router::new()
        .route("/api/v1/templates", get(list).post(create))
        .route("/api/v1/templates/{id}", get(read).patch(patch))
        .route("/api/v1/templates/{id}/draft", post(clone_draft))
        .route("/api/v1/templates/{id}/versions", get(versions))
        .route("/api/v1/templates/{id}/versions/{versionId}", get(version))
}

pub(super) struct Scope {
    pub(super) proof: SessionProof,
    pub(super) workspace_id: Uuid,
    actor_id: Uuid,
}

/**
 * Kiểm session transport hiện hành, yêu cầu CSRF cho mutation và parse workspace selector.
 *
 * # Input
 * Param: state — auth service dùng để resolve lại session hiện hành.
 * Param: headers — credential, workspace và CSRF từ request chưa được tin cậy.
 * Param: mutation — bật kiểm Origin/CSRF khi request có side effect.
 *
 * # Output
 * Proof session và workspace UUID cho application recheck dưới lock.
 *
 * # Errors
 * Session, context, CSRF, workspace thiếu/sai dạng hoặc dependency đã lọc.
 */
pub(super) async fn scope(
    state: &HttpState,
    headers: &HeaderMap,
    mutation: bool,
) -> Result<Scope, HttpError> {
    let (proof, transport, session) = sessions::inspect(state, headers, false, false).await?;
    if session.limited {
        return Err(HttpError::code(403, "PASSWORD_CHANGE_REQUIRED"));
    }
    if mutation {
        sessions::check_mutation(state, headers, transport, &session)?;
    }
    let workspace = security::single_header(headers, "x-workspace-id")?
        .ok_or_else(|| HttpError::code(400, "WORKSPACE_REQUIRED"))?;
    Ok(Scope {
        proof,
        workspace_id: exact_uuid(workspace, "/headers/X-Workspace-Id", 400)?,
        actor_id: session.user_id,
    })
}

/**
 * Parse selector UUID canonical để không nhận các dạng ngắn hoặc nhập nhằng.
 *
 * # Input
 * Param: value — chuỗi từ path/header chưa được tin cậy.
 * Param: path — JSON Pointer cố định do route cung cấp.
 * Param: status — HTTP status cố định cho lỗi format tại boundary đó.
 *
 * # Output
 * UUID canonical.
 *
 * # Errors
 * Validation error không phản chiếu giá trị input.
 */
pub(super) fn exact_uuid(value: &str, path: &str, status: u16) -> Result<Uuid, HttpError> {
    if value.len() == 36 {
        if let Ok(uuid) = Uuid::try_parse(value) {
            return Ok(uuid);
        }
    }
    Err(field_error(status, "VALIDATION_ERROR", path, "FORMAT"))
}

/**
 * Ánh xạ lỗi application thành contract HTTP, giữ khác biệt giữa quyền và resource scope.
 *
 * # Input
 * Param: error — lỗi use case đã được lọc, không chứa câu SQL hoặc request raw.
 *
 * # Output
 * HTTP error với mã và status ổn định cho handler.
 */
pub(super) fn api_error(error: ApplicationError) -> HttpError {
    match error {
        ApplicationError::Forbidden => HttpError::code(403, "FORBIDDEN"),
        ApplicationError::TemplateInvalid(issue) => template_wire::template_error(issue, None),
        ApplicationError::TemplateDraftExists => HttpError::code(409, "DRAFT_EXISTS"),
        ApplicationError::ImmutableSchema => HttpError::code(409, "IMMUTABLE_SCHEMA"),
        ApplicationError::StaleRevision => HttpError::code(412, "VERSION_CONFLICT"),
        other => other.into(),
    }
}

/**
 * Serialize payload workspace không cache và giữ số JSON exact qua serializer.
 *
 * # Input
 * Param: status — HTTP status của kết quả đã xác định.
 * Param: payload — DTO allowlist do handler dựng.
 *
 * # Output
 * Response JSON có `Cache-Control: no-store`.
 *
 * # Errors
 * Serialization/header sai được ánh xạ thành lỗi dependency đã lọc.
 */
pub(super) fn json_response<T: Serialize>(status: StatusCode, payload: T) -> Response {
    let mut response = (status, Json(payload)).into_response();
    no_store(&mut response);
    response
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RootDto<'a> {
    id: Uuid,
    workspace_id: Uuid,
    status: &'static str,
    schema_version: u8,
    revision: i64,
    latest_published_version_id: Option<Uuid>,
    #[serde(flatten)]
    configuration: Configuration<'a>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl<'a> RootDto<'a> {
    /**
     * Dựng root DTO, giữ revision/CAS và latest published ID là metadata riêng.
     *
     * # Input
     * Param: snapshot — root đã được application scope-check.
     *
     * # Output
     * DTO không nhập nhằng draft revision với version number.
     *
     * # Errors
     * Lỗi cấu hình scalar persisted không serialize được.
     */
    fn from_snapshot(snapshot: &'a TemplateSnapshot) -> Result<Self, HttpError> {
        Ok(Self {
            id: snapshot.template_id,
            workspace_id: snapshot.workspace_id,
            status: snapshot.status.code(),
            schema_version: 1,
            revision: snapshot.revision,
            latest_published_version_id: snapshot.latest_published_version_id,
            configuration: template_wire::configuration(snapshot.draft.draft())?,
            created_at: snapshot.created_at,
            updated_at: snapshot.updated_at,
        })
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct VersionDto<'a> {
    id: Uuid,
    workspace_id: Uuid,
    template_id: Uuid,
    version: i32,
    schema_version: u8,
    status: &'static str,
    #[serde(flatten)]
    configuration: Configuration<'a>,
    source_revision: Option<i64>,
    published_at: DateTime<Utc>,
}

impl<'a> VersionDto<'a> {
    /**
     * Dựng DTO cho exact version UUID mà không bịa source revision lịch sử.
     *
     * # Input
     * Param: snapshot — version immutable đã được family/scope kiểm.
     *
     * # Output
     * DTO có `sourceRevision: null` khi legacy row không có provenance.
     *
     * # Errors
     * Lỗi scalar persisted không serialize được.
     */
    fn from_snapshot(snapshot: &'a TemplateVersionSnapshot) -> Result<Self, HttpError> {
        Ok(Self {
            id: snapshot.template_version_id,
            workspace_id: snapshot.workspace_id,
            template_id: snapshot.template_id,
            version: snapshot.version_number,
            schema_version: 1,
            status: "PUBLISHED",
            configuration: template_wire::configuration(snapshot.content.draft())?,
            // Không suy revision lịch sử từ version sequence hoặc root có thể đã đổi.
            source_revision: None,
            published_at: snapshot.published_at,
        })
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Page<T> {
    items: Vec<T>,
    next_cursor: Option<String>,
}

struct PatchError(HttpError);

impl From<ApplicationError> for PatchError {
    /**
     * Giữ error route cho lỗi authority/CAS trước hoặc trong khi dựng candidate PATCH.
     *
     * # Input
     * Param: error — lỗi application từ admission, root revision hoặc mutation.
     *
     * # Output
     * Lỗi HTTP scoped tương ứng, không làm mất mã stale/immutable riêng.
     */
    fn from(error: ApplicationError) -> Self {
        Self(api_error(error))
    }
}

/**
 * Kiểm model exact với allowlist do composition cấp, fail-closed khi chưa có nguồn phê duyệt.
 *
 * # Input
 * Param: state — composition giữ policy model hiện hành.
 * Param: model — model ID đã parse từ draft, không tự chứng minh approval.
 *
 * # Output
 * Thành công khi model nằm trong allowlist.
 *
 * # Errors
 * `Unavailable` khi thiếu policy hoặc lỗi domain khi model không được duyệt.
 */
fn approved_model(state: &HttpState, model: &str) -> Result<(), ApplicationError> {
    let models = state
        .device_models
        .as_ref()
        .ok_or(ApplicationError::Unavailable)?;
    models.validate(model, model).map_err(|_| {
        ApplicationError::TemplateInvalid(TemplateValidation {
            stream_index: None,
            field: TemplateField::Model,
            reason: TemplateIssueReason::Incompatible,
        })
    })
}

/**
 * Tạo draft sau kiểm session/Admin/CSRF, strict JSON và policy model của composition.
 *
 * # Input
 * Param: state — application service và allowlist model được composition cấp.
 * Param: headers — session/workspace/CSRF selectors chưa được tin cậy.
 * Param: request — JSON draft strict, không nhận authority hoặc server ID.
 *
 * # Output
 * HTTP 201 root DTO sau commit và audit.
 *
 * # Errors
 * Validation, model, CAS/authority hoặc storage được ánh xạ sang envelope API.
 */
async fn create(
    State(state): State<HttpState>,
    headers: HeaderMap,
    request: Request,
) -> Result<Response, HttpError> {
    let scope = scope(&state, &headers, true).await?;
    let fields = template_wire::read_fields(request).await?;
    let draft = template_wire::candidate(&fields, None)?;
    let correlation = Uuid::new_v4();
    let result = state
        .templates
        .create_checked(
            &scope.proof,
            scope.workspace_id,
            draft,
            correlation,
            |draft| approved_model(&state, &draft.draft().model),
        )
        .await
        .map_err(|error| api_error(error).correlated(correlation))?;
    Ok(json_response(
        StatusCode::CREATED,
        RootDto::from_snapshot(&result)?,
    ))
}

/**
 * Đọc root template trong tenant của current Admin sau session admission.
 *
 * # Input
 * Param: state — auth và template service.
 * Param: headers — credential cùng workspace selector chưa được tin cậy.
 * Param: id — UUID root trong path.
 *
 * # Output
 * HTTP 200 root DTO scoped; đây không phải endpoint resolve device pin.
 *
 * # Errors
 * Session/workspace/Admin, malformed UUID, not-found hoặc storage.
 */
async fn read(
    State(state): State<HttpState>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Response, HttpError> {
    let scope = scope(&state, &headers, false).await?;
    let id = exact_uuid(&id, "/id", 400)?;
    let result = state
        .templates
        .get(&scope.proof, scope.workspace_id, id)
        .await
        .map_err(api_error)?;
    Ok(json_response(
        StatusCode::OK,
        RootDto::from_snapshot(&result)?,
    ))
}

/**
 * Áp PATCH dưới root lock và If-Match CAS; mỗi array được gửi thay toàn bộ array cũ.
 *
 * # Input
 * Param: state — auth, template service và model policy.
 * Param: headers — session/workspace/CSRF cùng If-Match bắt buộc.
 * Param: id — root UUID trong path.
 * Param: request — chỉ các field được phép; omission giữ nguyên, array có mặt thay thế nguyên mảng.
 *
 * # Output
 * HTTP 200 root mới sau audit/commit xác nhận.
 *
 * # Errors
 * Precondition 428, stale 412, immutable 409, validation/authority hoặc storage.
 */
async fn patch(
    State(state): State<HttpState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    request: Request,
) -> Result<Response, HttpError> {
    let scope = scope(&state, &headers, true).await?;
    let id = exact_uuid(&id, "/id", 400)?;
    let revision = member_if_match(&headers)?;
    let fields = template_wire::read_fields(request).await?;
    let correlation = Uuid::new_v4();
    let result = state
        .templates
        .patch(
            &scope.proof,
            scope.workspace_id,
            id,
            revision,
            correlation,
            |before| {
                let draft = template_wire::candidate(&fields, Some(before.draft.draft()))
                    .map_err(PatchError)?;
                if before.latest_published_version_id.is_none()
                    && draft.draft().model != before.draft.draft().model
                {
                    approved_model(&state, &draft.draft().model).map_err(PatchError::from)?;
                }
                Ok::<_, PatchError>(draft)
            },
        )
        .await
        .map_err(|error| error.0.correlated(correlation))?;
    Ok(json_response(
        StatusCode::OK,
        RootDto::from_snapshot(&result)?,
    ))
}

/**
 * Clone version UUID thuộc cùng family thành draft dưới CAS mà không sửa version/pin cũ.
 *
 * # Input
 * Param: state — auth và template service.
 * Param: headers — current workspace/Admin, CSRF và If-Match.
 * Param: id — family UUID cần clone.
 * Param: request — exact published version UUID đã chọn.
 *
 * # Output
 * HTTP 201 draft mới sau required audit/commit.
 *
 * # Errors
 * Version foreign/unknown, draft đã tồn tại, stale, immutable, authority hoặc storage.
 */
async fn clone_draft(
    State(state): State<HttpState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    request: Request,
) -> Result<Response, HttpError> {
    let scope = scope(&state, &headers, true).await?;
    let id = exact_uuid(&id, "/id", 400)?;
    let revision = member_if_match(&headers)?;
    let fields = template_wire::read_fields(request).await?;
    fields.allow(&["sourceVersionId"], "")?;
    let source = exact_uuid(
        &fields.required::<String>("sourceVersionId", "")?,
        "/sourceVersionId",
        422,
    )?;
    let correlation = Uuid::new_v4();
    let result = state
        .templates
        .clone_draft(
            &scope.proof,
            scope.workspace_id,
            id,
            revision,
            source,
            correlation,
        )
        .await
        .map_err(|error| api_error(error).correlated(correlation))?;
    Ok(json_response(
        StatusCode::OK,
        RootDto::from_snapshot(&result)?,
    ))
}

/**
 * Đọc published snapshot theo UUID chính xác trong family, không fallback sang latest.
 *
 * # Input
 * Param: state — auth và version read service.
 * Param: headers — session/workspace selectors chưa được tin cậy.
 * Param: id — family UUID.
 * Param: version_id — published UUID thuộc family được yêu cầu.
 *
 * # Output
 * HTTP 200 immutable DTO; legacy `sourceRevision` vẫn null.
 *
 * # Errors
 * Foreign/missing UUID, malformed selector, authority hoặc storage.
 */
async fn version(
    State(state): State<HttpState>,
    headers: HeaderMap,
    Path((id, version_id)): Path<(String, String)>,
) -> Result<Response, HttpError> {
    let scope = scope(&state, &headers, false).await?;
    let id = exact_uuid(&id, "/id", 400)?;
    let version_id = exact_uuid(&version_id, "/versionId", 400)?;
    let result = state
        .templates
        .version_in_family(&scope.proof, scope.workspace_id, id, version_id)
        .await
        .map_err(api_error)?;
    Ok(json_response(
        StatusCode::OK,
        VersionDto::from_snapshot(&result)?,
    ))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ListQuery {
    status: Option<String>,
    limit: Option<i64>,
    cursor: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct VersionQuery {
    source_revision: Option<i64>,
    limit: Option<i64>,
    cursor: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct Cursor {
    actor: Uuid,
    workspace: Uuid,
    filter: String,
    after: Uuid,
}

/**
 * Decode cursor keyset sau khi ràng buộc chữ ký với actor, workspace và filter hiện hành.
 *
 * # Input
 * Param: state — signing key chỉ ở memory của server.
 * Param: scope — session/workspace đã xác thực cho request hiện tại.
 * Param: filter — shape filter do route dựng từ query hiện tại.
 * Param: token — cursor client gửi, chưa được tin cậy.
 *
 * # Output
 * UUID keyset cuối của trang trước hoặc `None`.
 *
 * # Errors
 * Cursor sai chữ ký, phiên, workspace, filter, version hoặc format.
 */
fn decode_cursor(
    state: &HttpState,
    scope: &Scope,
    filter: &str,
    cursor: Option<&str>,
) -> Result<Option<Uuid>, HttpError> {
    let invalid = || HttpError::code(422, "CURSOR_INVALID");
    let Some(cursor) = cursor else {
        return Ok(None);
    };
    if cursor.len() > 512 {
        return Err(invalid());
    }
    let (payload, tag) = cursor.split_once('.').ok_or_else(invalid)?;
    let bytes = URL_SAFE_NO_PAD.decode(payload).map_err(|_| invalid())?;
    if !security::verify(&state.signing_key, b"template-keyset-v1:", &bytes, tag) {
        return Err(invalid());
    }
    let cursor: Cursor = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    if cursor.actor != scope.actor_id
        || cursor.workspace != scope.workspace_id
        || cursor.filter != filter
    {
        return Err(invalid());
    }
    Ok(Some(cursor.after))
}

/**
 * Ký keyset cursor bằng scope/filter do server đã resolve, không nhận quyền từ token.
 *
 * # Input
 * Param: state — signing key trong memory.
 * Param: scope — actor/workspace đã xác thực.
 * Param: filter — shape query server đã canonicalize.
 * Param: last_id — UUID cuối đã trả ở trang trước.
 *
 * # Output
 * Cursor URL-safe có MAC cho lần đọc tiếp.
 *
 * # Errors
 * Encode/MAC failure được lọc thành lỗi dependency.
 */
fn encode_cursor(
    state: &HttpState,
    scope: &Scope,
    filter: String,
    after: Uuid,
) -> Result<String, HttpError> {
    let bytes = serde_json::to_vec(&Cursor {
        actor: scope.actor_id,
        workspace: scope.workspace_id,
        filter,
        after,
    })
    .map_err(|_| HttpError::unavailable())?;
    let tag = security::sign(&state.signing_key, b"template-keyset-v1:", &bytes);
    Ok(format!("{}.{tag}", URL_SAFE_NO_PAD.encode(bytes)))
}

/**
 * Chọn page size bounded để giới hạn truy vấn và xác định có trang tiếp hay không.
 *
 * # Input
 * Param: value — limit tùy chọn từ query, chưa được tin cậy.
 *
 * # Output
 * Limit từ 1 đến 100; mặc định 20.
 *
 * # Errors
 * Validation error khi limit ngoài miền.
 */
fn page_limit(value: Option<i64>) -> Result<i64, HttpError> {
    let limit = value.unwrap_or(20);
    if !(1..=100).contains(&limit) {
        return Err(HttpError::validation(422, "/limit", "FORMAT"));
    }
    Ok(limit)
}

/**
 * Liệt kê root template trong workspace để Admin đối soát candidate sau response create bị mất.
 *
 * # Input
 * Param: state — auth/template services và signing key cursor.
 * Param: headers — current session/workspace.
 * Param: query — status, limit và cursor keyset.
 *
 * # Output
 * Trang DTO scoped cùng cursor tiếp theo nếu còn dữ liệu.
 *
 * # Errors
 * Query/cursor, authority, UUID hoặc storage được lọc.
 */
async fn list(
    State(state): State<HttpState>,
    headers: HeaderMap,
    query: Result<Query<ListQuery>, QueryRejection>,
) -> Result<Response, HttpError> {
    let scope = scope(&state, &headers, false).await?;
    let Query(query) = query.map_err(|_| HttpError::validation(422, "/query", "FORMAT"))?;
    let status = match query.status.as_deref() {
        None => None,
        Some("DRAFT") => Some(TemplateStatus::Draft),
        Some("PUBLISHED") => Some(TemplateStatus::Published),
        Some("ARCHIVED") => Some(TemplateStatus::Archived),
        _ => return Err(HttpError::validation(422, "/status", "FORMAT")),
    };
    let limit = page_limit(query.limit)?;
    let filter = format!("roots:{}", query.status.as_deref().unwrap_or(""));
    let after = decode_cursor(&state, &scope, &filter, query.cursor.as_deref())?;
    let results = state
        .templates
        .list(&scope.proof, scope.workspace_id, status, after, limit + 1)
        .await
        .map_err(api_error)?;
    let count = usize::try_from(limit).map_err(|_| HttpError::unavailable())?;
    let next_cursor = if results.len() > count {
        Some(encode_cursor(
            &state,
            &scope,
            filter,
            results[count - 1].template_id,
        )?)
    } else {
        None
    };
    let items = results
        .iter()
        .take(count)
        .map(RootDto::from_snapshot)
        .collect::<Result<Vec<_>, _>>()?;
    Ok(json_response(StatusCode::OK, Page { items, next_cursor }))
}

/**
 * Liệt kê immutable versions theo family; chỉ provenance filter bị fail-closed đến khi có migration.
 *
 * # Input
 * Param: state — auth/version read services và signing key cursor.
 * Param: headers — current session/workspace selector.
 * Param: id — family root UUID.
 * Param: query — keyset/limit; sourceRevision không được giả lập khi schema chưa hỗ trợ.
 *
 * # Output
 * Trang snapshot đúng family; mỗi legacy `sourceRevision` được giữ null.
 *
 * # Errors
 * Invalid query/cursor, foreign UUID, authority, unavailable provenance hoặc storage.
 */
async fn versions(
    State(state): State<HttpState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    query: Result<Query<VersionQuery>, QueryRejection>,
) -> Result<Response, HttpError> {
    let scope = scope(&state, &headers, false).await?;
    let id = exact_uuid(&id, "/id", 400)?;
    let Query(query) = query.map_err(|_| HttpError::validation(422, "/query", "FORMAT"))?;
    if query.source_revision.is_some_and(|revision| revision < 1) {
        return Err(HttpError::validation(422, "/sourceRevision", "FORMAT"));
    }
    let limit = page_limit(query.limit)?;
    let filter = format!("versions:{id}:{}", query.source_revision.unwrap_or(0));
    let after = decode_cursor(&state, &scope, &filter, query.cursor.as_deref())?;
    let results = state
        .templates
        .versions(
            &scope.proof,
            scope.workspace_id,
            id,
            query.source_revision,
            after,
            limit + 1,
        )
        .await
        .map_err(api_error)?;
    let count = usize::try_from(limit).map_err(|_| HttpError::unavailable())?;
    let next_cursor = if results.len() > count {
        Some(encode_cursor(
            &state,
            &scope,
            filter,
            results[count - 1].template_version_id,
        )?)
    } else {
        None
    };
    let items = results
        .iter()
        .take(count)
        .map(VersionDto::from_snapshot)
        .collect::<Result<Vec<_>, _>>()?;
    Ok(json_response(StatusCode::OK, Page { items, next_cursor }))
}
