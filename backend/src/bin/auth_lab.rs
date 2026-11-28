//! Server lab loopback; cấu hình/credential chỉ qua stdin launcher, không đọc env hoặc secret file.

use axum::{
    Json, Router,
    body::to_bytes,
    extract::{Request, State},
    http::{HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::post,
};
use hmac::{Hmac, Mac};
#[cfg(feature = "integrated-lab")]
use iot_platform_backend::domain::device::ApprovedDeviceModels;
#[cfg(not(feature = "integrated-lab"))]
use iot_platform_backend::http::auth_router;
#[cfg(feature = "integrated-lab")]
use iot_platform_backend::http::integrated_lab_router;
use iot_platform_backend::{
    adapters::{auth_diagnostics::AuthTimingRecorder, security::PasswordService},
    application::{error::ApplicationError, identity::IdentityService},
    domain::{idempotency::IdempotencyKey, identity::ClientType},
    http::HttpState,
    postgres::connection::connect_local_probe,
};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::Sha256;
use sqlx::PgPool;
use std::{
    io::{self, Read},
    sync::Arc,
    time::Duration,
};
use uuid::Uuid;

#[path = "auth_lab/pool_budget.rs"]
mod pool_budget;

/// Domain separator cố định; proof chỉ dùng control lab, không dùng key hoặc token auth sản phẩm.
const MEASUREMENT_LABEL: &[u8] = b"auth-lab-measurement-v1";

/// State chỉ tồn tại trong binary loopback đã opt-in; không Debug/Serialize key control.
#[derive(Clone)]
struct MeasurementControl {
    recorder: Arc<AuthTimingRecorder>,
    key: Arc<[u8; 32]>,
}

/**
 * Chọn router của Auth Lab theo feature compile-time để chỉ bật API 005–008 sau opt-in.
 *
 * # Input
 * Param: state — state auth và các dịch vụ lab đã được dựng từ pool/origin của launcher.
 *
 * # Output
 * Router auth hiện hành; chỉ feature integrated-lab ghép thêm template, device và poll metadata.
 *
 * # Side effects
 * Router ở cả hai chế độ dùng reconciler bounded hiện hành thông qua auth_router.
 */
fn auth_lab_router(state: HttpState) -> Router {
    #[cfg(feature = "integrated-lab")]
    {
        integrated_lab_router(state)
    }
    #[cfg(not(feature = "integrated-lab"))]
    {
        auth_router(state)
    }
}

/**
 * Apply the single synthetic model fixture only to the explicitly enabled integrated lab.
 *
 * # Input
 * Param: state - loopback state with fail-closed mutation policy by default.
 *
 * # Output
 * State allowing only the G1 model fixture used by the lab workbench tests.
 */
#[cfg(feature = "integrated-lab")]
fn integrated_lab_state(state: HttpState) -> Result<HttpState, ApplicationError> {
    let models = ApprovedDeviceModels::new(vec!["G1_TEST_MODEL".to_owned()])
        .map_err(|_| ApplicationError::Unavailable)?;
    Ok(state.with_approved_device_models(models))
}

/**
 * Gắn hai route control riêng của binary khi launcher opt-in, không đổi `auth_router` sản phẩm.
 * Input
 * Param: `router` — router auth hiện có, không chứa quyền mở window mặc định.
 * Param: `control` — recorder/key chỉ do trusted stdin composition cấp; None không tạo route.
 * Output: router cùng state auth, thêm control có no-store khi enabled.
 */
fn attach_measurements(router: Router, control: Option<MeasurementControl>) -> Router {
    let Some(control) = control else {
        return router;
    };
    router.merge(
        Router::new()
            .route("/__auth_lab/measurements/begin", post(begin_measurements))
            .route("/__auth_lab/measurements/end", post(end_measurements))
            .layer(axum::middleware::map_response(measurement_no_store))
            .with_state(control),
    )
}

/**
 * Áp header cho cả success/error/405 của control để browser không lưu hoặc diễn giải nội dung tùy ý.
 * Input
 * Param: `response` — response đã được routing/handler tạo, không log nội dung.
 * Output: response no-store/nosniff, không thêm cookie/CORS.
 */
async fn measurement_no_store(mut response: Response) -> Response {
    response
        .headers_mut()
        .insert("cache-control", HeaderValue::from_static("no-store"));
    response.headers_mut().insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );
    response
}

/**
 * Parse proof HMAC hex có đúng32byte; lỗi encoding được từ chối trước so sánh secret.
 * Input
 * Param: `value` — header không tin cậy, không được echo/log hoặc dùng làm metric label.
 * Output: MAC32 byte hoặc None khi length/hex sai; không thay đổi recorder.
 */
fn parse_measurement_proof(value: &str) -> Option<[u8; 32]> {
    if value.len() != 64 || !value.as_bytes().iter().all(u8::is_ascii_hexdigit) {
        return None;
    }
    let mut proof = [0; 32];
    for (index, pair) in value.as_bytes().chunks_exact(2).enumerate() {
        proof[index] = u8::from_str_radix(std::str::from_utf8(pair).ok()?, 16).ok()?;
    }
    Some(proof)
}

/**
 * Kiểm capability/Origin trước body để caller không giữ handler bằng body chưa EOF hoặc mở window trái phép.
 * Input
 * Param: `control` — key runtime của đúng lab process, không lấy từ request.
 * Param: `request` — header/body chưa tin cậy; chỉ chấp nhận một proof và body rỗng.
 * Output: quyền thực hiện đúng control mutation sau khi body đã kết thúc.
 * Errors:403 header/Origin/proof,413 nonempty,408 body quá1s; không echo lỗi nội bộ hoặc đổi window.
 */
async fn validate_measurement_request(
    control: &MeasurementControl,
    request: Request,
) -> Result<(), StatusCode> {
    let headers = request.headers();
    if headers.contains_key("origin") {
        return Err(StatusCode::FORBIDDEN);
    }
    let mut values = headers.get_all("x-auth-lab-measurement").iter();
    let proof = values
        .next()
        .and_then(|value| value.to_str().ok())
        .and_then(parse_measurement_proof)
        .ok_or(StatusCode::FORBIDDEN)?;
    if values.next().is_some() {
        return Err(StatusCode::FORBIDDEN);
    }
    let mut verifier = Hmac::<Sha256>::new_from_slice(control.key.as_ref())
        .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
    verifier.update(MEASUREMENT_LABEL);
    // verify_slice dùng constant-time equality; không tự so secret bằng chuỗi hoặc vòng lặp early-exit.
    verifier
        .verify_slice(&proof)
        .map_err(|_| StatusCode::FORBIDDEN)?;
    /* Limit0 từ chối ngay frame nonempty thay vì chờ EOF của body1byte bị giữ mãi.
    Deadline1s bao toàn body; mọi nhánh reject đều trước mutation recorder. */
    match tokio::time::timeout(Duration::from_secs(1), to_bytes(request.into_body(), 0)).await {
        Ok(Ok(_)) => Ok(()),
        Ok(Err(_)) => Err(StatusCode::PAYLOAD_TOO_LARGE),
        Err(_) => Err(StatusCode::REQUEST_TIMEOUT),
    }
}

/**
 * Tạo lỗi control generic theo status, không tiết lộ key, span hoặc lỗi mutex vào response.
 * Input
 * Param: `status` — literal HTTP từ validation hoặc window state conflict.
 * Output: JSON generic, header no-store được layer control áp cho mọi response.
 */
fn measurement_error(status: StatusCode) -> Response {
    (
        status,
        Json(json!({"error":"MEASUREMENT_CONTROL_REJECTED"})),
    )
        .into_response()
}

/**
 * Mở window chỉ sau capability/body hợp lệ, không reset window đang chứa work.
 * Input
 * Param: `control` — state do binary composition giữ, không authority từ body.
 * Param: `request` — HTTP control không được có payload hoặc Origin.
 * Output: generation số hoặc lỗi generic; Side effects: begin recorder, không tác động DB/auth policy.
 */
async fn begin_measurements(
    State(control): State<MeasurementControl>,
    request: Request,
) -> Response {
    if let Err(status) = validate_measurement_request(&control, request).await {
        return measurement_error(status);
    }
    match control.recorder.begin_window() {
        Ok(window_id) => Json(json!({"windowId":window_id})).into_response(),
        Err(_) => measurement_error(StatusCode::CONFLICT),
    }
}

/**
 * Đóng window khi hết active spans và export snapshot bounded sau khi recorder đã nhả mutex.
 * Input
 * Param: `control` — recorder/key của process đang được kiểm chứng.
 * Param: `request` — capability/body phải hợp lệ trước mutation end.
 * Output: enum/numeric samples cùng validity, không timestamp/SQL/identity; active work trả409 giữ state.
 */
async fn end_measurements(State(control): State<MeasurementControl>, request: Request) -> Response {
    if let Err(status) = validate_measurement_request(&control, request).await {
        return measurement_error(status);
    }
    let Ok(snapshot) = control.recorder.end_window() else {
        return measurement_error(StatusCode::CONFLICT);
    };
    let samples: Vec<Value> = snapshot.samples.iter().map(
        /* Chỉ chuyển stage/outcome literal và duration monotonic sang JSON.
        Input Param: sample — observation đã bounded; Output: không chứa dữ liệu request. */
        |sample| json!({"stage":sample.stage.label(),"outcome":sample.outcome.label(),"elapsedUs":sample.elapsed.as_micros()}),
    ).collect();
    Json(json!({"windowId":snapshot.window_id,"valid":snapshot.is_valid(),"droppedSamples":snapshot.dropped_samples,"staleSamples":snapshot.stale_samples,"poisoned":snapshot.poisoned,"samples":samples})).into_response()
}

/// Payload không Debug/Serialize; launcher cấp password/key tạm và UUID fixture trước khi ghi DB.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Config {
    database_port: u16,
    database_password: String,
    signing_key: [u8; 32],
    http_port: u16,
    run_id: Uuid,
    user_ids: [Uuid; 5],
    emails: [String; 5],
    fixture_password: String,
    // Peer dùng cùng graph của primary; chỉ launcher stdin cấp cờ, không có HTTP seed endpoint.
    #[serde(default)]
    skip_fixture_seed: bool,
    // Chỉ launcher verify bật measurement; false/None là mặc định và cặp cấu hình phải đồng nhất.
    #[serde(default)]
    enable_measurements: bool,
    #[serde(default)]
    measurement_key: Option<[u8; 32]>,
}

/** Seed đúng UUID mới của launcher; Input: pool probe, config không secret log. Errors: SQL/crypto đã lọc. */
async fn seed(pool: &PgPool, config: &Config) -> Result<(), ApplicationError> {
    let verifier = PasswordService::default()
        .hash(config.fixture_password.clone())
        .await?;
    let mut transaction = pool
        .begin()
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    for index in 0..5 {
        // UUID/email/provenance thuộc lượt chạy, mọi value bind; không UPDATE account đang có.
        sqlx::query("INSERT INTO users(user_id,email_normalized,password_hash,account_status,must_change_password,activation_provenance) VALUES($1,$2,$3,$4,$5,$6)")
            .bind(config.user_ids[index]).bind(&config.emails[index]).bind(&verifier)
            .bind(if index == 1 { "DISABLED" } else { "ACTIVE" }).bind(index == 2)
            .bind(format!("AUTH_HTTP_LAB:{}", config.run_id)).execute(&mut *transaction).await.map_err(|_| ApplicationError::Unavailable)?;
    }
    transaction
        .commit()
        .await
        .map_err(|_| ApplicationError::CommitUnknown)?;
    Ok(())
}

/** Dựng hai workspace qua core thật rồi thêm USER vào B bằng fixture transaction; không cấp role từ HTTP body. */
async fn seed_workspaces(pool: &PgPool, config: &Config) -> Result<(), ApplicationError> {
    // Core không public qua HttpState; composition dùng adapter/key chung, không tạo implementation policy thứ hai.
    let crypto = iot_platform_backend::adapters::security::CryptoService::new(
        PasswordService::default(),
        config.signing_key,
    )
    .await?;
    let auth = IdentityService::new(
        iot_platform_backend::postgres::PgIdentityStore::new(pool.clone()),
        crypto,
    );
    for (index, name) in [(0, "Phòng vận hành A"), (4, "Nhà kính B")] {
        let issued = auth
            .login(
                &config.emails[index],
                config.fixture_password.clone(),
                ClientType::Android,
                config.run_id,
            )
            .await?;
        let proof = auth.session_proof(issued.token.expose(), None);
        let key = IdempotencyKey::new(&Uuid::new_v4().to_string())
            .ok_or(ApplicationError::InvalidInput)?;
        let workspace_id = auth
            .create_workspace(
                &proof,
                name,
                Some(&format!("AUTH_HTTP_LAB:{}", config.run_id)),
                "Asia/Ho_Chi_Minh",
                &key,
                config.run_id,
            )
            .await?;
        if index == 4 {
            // Membership và current grant phải cùng commit vì deferred foreign key của canonical schema.
            let mut transaction = pool
                .begin()
                .await
                .map_err(|_| ApplicationError::Unavailable)?;
            sqlx::query("INSERT INTO memberships(workspace_id,user_id,role,current_grant_generation) VALUES($1,$2,'USER',1)").bind(workspace_id).bind(config.user_ids[0]).execute(&mut *transaction).await.map_err(|_| ApplicationError::Unavailable)?;
            sqlx::query("INSERT INTO membership_grants(workspace_id,user_id,grant_generation) VALUES($1,$2,1)").bind(workspace_id).bind(config.user_ids[0]).execute(&mut *transaction).await.map_err(|_| ApplicationError::Unavailable)?;
            transaction
                .commit()
                .await
                .map_err(|_| ApplicationError::CommitUnknown)?;
        }
    }
    Ok(())
}

/**
 * Chạy server loopback; primary seed graph, peer dùng lại graph để kiểm nhiều process cùng DB/key.
 * Input: JSON stdin do launcher tin cậy cấp, normal đọc tới EOF; opt-in pool budget dùng framed stdin.
 * Output: server sống sau marker READY, không trả credential vào stdout.
 * # Errors
 * Lỗi input, bind, seed hoặc DB được ánh xạ an toàn; không in config/error SQL thô.
 */
async fn run() -> Result<(), ApplicationError> {
    // Chỉ đọc argv của chính child để opt-in literal; không đọc biến environment hoặc secret file.
    let special = pool_budget::enabled(std::env::args_os().skip(1))?;
    let (config, pool_input) = if special {
        let (config, input) = pool_budget::read_config().await?;
        (config, Some(input))
    } else {
        // Giữ nguyên normal contract: JSON nhiều dòng được phép, EOF kết thúc config.
        let mut input = String::new();
        io::stdin()
            .take(16_385)
            .read_to_string(&mut input)
            .map_err(|_| ApplicationError::InvalidInput)?;
        if input.len() > 16_384 {
            return Err(ApplicationError::InvalidInput);
        }
        let config: Config =
            serde_json::from_str(&input).map_err(|_| ApplicationError::InvalidInput)?;
        (config, None)
    };
    if config.enable_measurements != config.measurement_key.is_some() {
        return Err(ApplicationError::InvalidInput);
    }
    if special && !config.enable_measurements {
        return Err(ApplicationError::InvalidInput);
    }
    iot_platform_backend::domain::input::validate_new_password(
        &config.fixture_password,
        "/password",
    )
    .map_err(
        // Không seed password lab sai policy hoặc đưa giá trị stdin vào lỗi cấu hình.
        |_| ApplicationError::InvalidInput,
    )?;
    // Bind trước seed để cổng đã chiếm không tạo fixture hoặc ghi đè server khác.
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, config.http_port))
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    let pool = connect_local_probe(
        config.database_port,
        "iot_repository_probe",
        &config.database_password,
    )
    .await?;
    if !config.skip_fixture_seed {
        seed(&pool, &config).await?;
    }
    // Recorder mới còn inactive; seed/startup không được đi vào window mà verifier mở sau READY.
    let control = config.measurement_key.map(
        /* Input Param: key — capability riêng của launcher trong RAM.
        Output: một recorder/key process-local, không Debug/Serialize hoặc chia sẻ auth signing key. */
        |key| MeasurementControl { recorder: Arc::default(), key: Arc::new(key) },
    );
    let diagnostics = control.as_ref().map(
        /* Input Param: control — composition state của đúng process.
        Output: cùng Arc observer cho PasswordService và PgIdentityStore; chưa mở window. */
        |control| {
            control.recorder.clone()
                as Arc<dyn iot_platform_backend::application::auth_diagnostics::AuthDiagnostics>
        },
    );
    let state = HttpState::new_with_diagnostics(
        pool.clone(),
        config.signing_key,
        "http://localhost:5173",
        diagnostics,
    )
    .await?;
    #[cfg(feature = "integrated-lab")]
    let state = integrated_lab_state(state)?;
    if !config.skip_fixture_seed {
        seed_workspaces(&pool, &config).await?;
    }
    println!("AUTH_LAB_READY");
    let router = attach_measurements(auth_lab_router(state), control);
    if let Some(input) = pool_input {
        return pool_budget::serve(listener, router, pool, input).await;
    }
    axum::serve(listener, router)
        .await
        .map_err(|_| ApplicationError::Unavailable)
}

/** Entrypoint Tokio cho lab; chỉ báo lifecycle an toàn, không in credential hay lỗi SQL. */
#[tokio::main]
async fn main() {
    if run().await.is_err() {
        eprintln!("AUTH_LAB_FAILED");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod lab_router_tests {
    use super::*;
    use axum::{
        body::Body,
        http::{Method, Request, StatusCode},
    };
    use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
    use tower::ServiceExt;

    /**
     * Verify the explicit lab feature mounts registry and poll routes while fallback remains auth-first.
     *
     * GET remains protected in both modes; DELETE distinguishes a mounted path without calling its handler.
     */
    #[tokio::test]
    async fn workbench_routes_follow_explicit_integrated_lab_feature() {
        let pool = PgPoolOptions::new().connect_lazy_with(
            PgConnectOptions::new()
                .host("127.0.0.1")
                .port(1)
                .username("lab_router_test")
                .database("lab_router_test"),
        );
        let state = HttpState::new(pool, [17; 32], "http://localhost:5173")
            .await
            .expect("synthetic router state");
        let app = attach_measurements(auth_lab_router(state), None);

        for path in [
            "/api/v1/templates?limit=1",
            "/api/v1/devices?serial=runtime-availability-probe",
            "/api/v1/provisioning-operations/00000000-0000-0000-0000-000000000001",
        ] {
            let response = app
                .clone()
                .oneshot(
                    Request::get(path)
                        .header("x-workspace-id", "00000000-0000-0000-0000-000000000001")
                        .body(Body::empty())
                        .expect("valid synthetic request"),
                )
                .await
                .expect("in-process router response");

            assert_eq!(response.status(), StatusCode::UNAUTHORIZED, "GET {path}");
        }

        let expected_mounted_method = if cfg!(feature = "integrated-lab") {
            StatusCode::METHOD_NOT_ALLOWED
        } else {
            StatusCode::UNAUTHORIZED
        };
        for path in [
            "/api/v1/templates",
            "/api/v1/devices",
            "/api/v1/provisioning-operations/00000000-0000-0000-0000-000000000001",
        ] {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method(Method::DELETE)
                        .uri(path)
                        .body(Body::empty())
                        .expect("valid synthetic request"),
                )
                .await
                .expect("in-process router response");

            assert_eq!(response.status(), expected_mounted_method, "DELETE {path}");
        }

        // These writer paths are out of scope; DELETE detects registration without credentials.
        for path in [
            "/api/v1/templates/00000000-0000-0000-0000-000000000001/publish",
            "/api/v1/devices/00000000-0000-0000-0000-000000000001/credentials",
            "/api/v1/provisioning-operations/00000000-0000-0000-0000-000000000001/claim-credential",
        ] {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method(Method::DELETE)
                        .uri(path)
                        .body(Body::empty())
                        .expect("valid synthetic request"),
                )
                .await
                .expect("in-process router response");

            assert_eq!(response.status(), StatusCode::UNAUTHORIZED, "DELETE {path}");
        }
    }
}

#[cfg(all(test, feature = "integrated-lab"))]
#[path = "auth_lab/integrated_policy_tests.rs"]
mod integrated_policy_tests;

#[cfg(test)]
mod measurement_tests {
    use super::*;
    use axum::{
        Router,
        body::Body,
        http::{Request, StatusCode},
    };
    use iot_platform_backend::adapters::auth_diagnostics::AuthTimingRecorder;
    use std::sync::Arc;
    use tower::ServiceExt;

    /// Dấu cộng được numeric parser chấp nhận không phải hex wire hợp lệ; proof chỉ nhận64ASCII hex.
    #[test]
    fn measurement_proof_is_strict_ascii_hex() {
        assert!(parse_measurement_proof(&"+a".repeat(32)).is_none());
        assert!(parse_measurement_proof(&"é".repeat(32)).is_none());
        assert_eq!(parse_measurement_proof(&"aF".repeat(32)), Some([175; 32]));
    }

    /**
     * Tạo proof đúng wire protocol từ key tổng hợp để test kiểm header độc lập với parser server.
     * Input
     * Param: `path` — một trong hai route control, không tự thêm prefix auth API.
     * Param: `body` — payload test có thể rỗng hoặc cố tình sai policy.
     * Output: request có proof hợp lệ từ key test, không dùng credential hay env của máy.
     */
    fn signed_request(path: &str, body: Body) -> Request<Body> {
        let mut mac = Hmac::<Sha256>::new_from_slice(&[3; 32]).unwrap();
        mac.update(MEASUREMENT_LABEL);
        let mut proof = String::with_capacity(64);
        for byte in mac.finalize().into_bytes() {
            use std::fmt::Write;
            write!(&mut proof, "{byte:02x}").unwrap();
        }
        Request::post(path)
            .header("x-auth-lab-measurement", proof)
            .body(body)
            .unwrap()
    }

    /// Bắt đầu/trùng begin/end khi active không được reset state; snapshot chỉ có số đo đã kết thúc.
    #[tokio::test]
    async fn control_windows_preserve_active_work() {
        use iot_platform_backend::application::auth_diagnostics::{
            AuthDiagnostics, AuthTimingOutcome, AuthTimingSpan, AuthTimingStage,
        };
        let recorder = Arc::new(AuthTimingRecorder::default());
        let control = MeasurementControl {
            recorder: recorder.clone(),
            key: Arc::new([3; 32]),
        };
        let app = attach_measurements(Router::new(), Some(control));
        let begin = app
            .clone()
            .oneshot(signed_request(
                "/__auth_lab/measurements/begin",
                Body::empty(),
            ))
            .await
            .unwrap();
        assert_eq!(begin.status(), StatusCode::OK);
        let sink: Arc<dyn AuthDiagnostics> = recorder.clone();
        let work = AuthTimingSpan::start(Some(&sink), AuthTimingStage::HashWork);
        for path in [
            "/__auth_lab/measurements/begin",
            "/__auth_lab/measurements/end",
        ] {
            let response = app
                .clone()
                .oneshot(signed_request(path, Body::empty()))
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::CONFLICT);
            assert_eq!(response.headers()["cache-control"], "no-store");
        }
        work.finish(AuthTimingOutcome::Completed);
        let end = app
            .oneshot(signed_request(
                "/__auth_lab/measurements/end",
                Body::empty(),
            ))
            .await
            .unwrap();
        assert_eq!(end.status(), StatusCode::OK);
        let bytes = to_bytes(end.into_body(), 1_048_576).await.unwrap();
        let snapshot: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(snapshot["windowId"], 1);
        assert_eq!(snapshot["valid"], true);
        assert_eq!(snapshot["samples"].as_array().unwrap().len(), 1);
        assert_eq!(snapshot["samples"][0]["stage"], "hash_work");
        assert_eq!(snapshot["samples"][0]["outcome"], "completed");
    }

    /// Origin, duplicate proof, payload và method sai không được thay window dù capability đúng.
    #[tokio::test]
    async fn control_rejections_preserve_existing_window() {
        let recorder = Arc::new(AuthTimingRecorder::default());
        let app = attach_measurements(
            Router::new(),
            Some(MeasurementControl {
                recorder: recorder.clone(),
                key: Arc::new([3; 32]),
            }),
        );
        recorder.begin_window().unwrap();
        for (case, expected) in [
            ("origin", 403),
            ("duplicate", 403),
            ("body", 413),
            ("method", 405),
        ] {
            let mut request = signed_request(
                "/__auth_lab/measurements/end",
                if case == "body" {
                    Body::from("x")
                } else {
                    Body::empty()
                },
            );
            match case {
                "origin" => {
                    request
                        .headers_mut()
                        .insert("origin", HeaderValue::from_static("http://localhost:5173"));
                }
                "duplicate" => {
                    request.headers_mut().append(
                        "x-auth-lab-measurement",
                        HeaderValue::from_static("invalid"),
                    );
                }
                "method" => {
                    *request.method_mut() = axum::http::Method::GET;
                }
                _ => {}
            }
            let response = app.clone().oneshot(request).await.unwrap();
            assert_eq!(response.status().as_u16(), expected);
            assert_eq!(response.headers()["cache-control"], "no-store");
            assert!(response.headers().get("set-cookie").is_none());
            assert_eq!(recorder.begin_window().unwrap_err(), iot_platform_backend::adapters::auth_diagnostics::AuthTimingControlError::WindowActive);
        }
        let snapshot = recorder.end_window().unwrap();
        assert_eq!(snapshot.window_id, 1);
        assert!(snapshot.samples.is_empty());
    }

    /// Test TCP sở hữu task server riêng để timeout/assertion đều hủy đúng server, không để port sống sau test.
    struct TestServer(tokio::task::JoinHandle<()>);
    impl Drop for TestServer {
        /// Abort task do chính helper tạo; runtime thu hồi socket khi future server bị drop.
        fn drop(&mut self) {
            self.0.abort();
        }
    }

    /**
     * Giữ body chunked chưa EOF trên TCP thật để kiểm timeout handler và early rejection.
     * Input
     * Param: `origin` — thêm Origin khi cần chứng minh reject trước khi chờ body.
     * Output: status cùng elapsed; Errors: timeout/read/parse assertion làm test FAIL và guard thu hồi server.
     */
    async fn stalled_chunked_request(origin: bool) -> (u16, Duration) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let recorder = Arc::new(AuthTimingRecorder::default());
        let app = attach_measurements(
            Router::new(),
            Some(MeasurementControl {
                recorder: recorder.clone(),
                key: Arc::new([3; 32]),
            }),
        );
        let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
            .await
            .unwrap();
        let address = listener.local_addr().unwrap();
        // Task chỉ phục vụ listener loopback test; guard abort kể cả khi bước TCP sau đó panic.
        let _server = TestServer(tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        }));
        let request = signed_request("/__auth_lab/measurements/begin", Body::empty());
        let proof = request.headers()["x-auth-lab-measurement"]
            .to_str()
            .unwrap();
        let headers = format!(
            "POST /__auth_lab/measurements/begin HTTP/1.1\r\nHost: {address}\r\nx-auth-lab-measurement: {proof}\r\nTransfer-Encoding: chunked\r\n{}\r\n",
            if origin {
                "Origin: http://localhost:5173\r\n"
            } else {
                ""
            }
        );
        let mut stream = tokio::net::TcpStream::connect(address).await.unwrap();
        let started = std::time::Instant::now();
        stream.write_all(headers.as_bytes()).await.unwrap();
        let mut status_line = Vec::new();
        // Deadline đọc bao toàn status line, không reset theo từng byte khi peer cố giữ connection.
        let status = tokio::time::timeout(Duration::from_secs(2), async {
            while !status_line.ends_with(b"\r\n") {
                assert!(status_line.len() < 128);
                status_line.push(stream.read_u8().await.unwrap());
            }
            std::str::from_utf8(&status_line)
                .unwrap()
                .split_whitespace()
                .nth(1)
                .unwrap()
                .parse()
                .unwrap()
        })
        .await
        .unwrap();
        let elapsed = started.elapsed();
        recorder.begin_window().unwrap();
        assert!(recorder.end_window().unwrap().samples.is_empty());
        (status, elapsed)
    }

    /// Body chunked không kết thúc phải408 sau1s, không mở window hoặc chờ EOF vô hạn.
    #[tokio::test]
    async fn chunked_body_has_total_deadline() {
        let (status, elapsed) = stalled_chunked_request(false).await;
        assert_eq!(status, 408);
        assert!(elapsed >= Duration::from_millis(900));
        assert!(elapsed < Duration::from_secs(2));
    }

    /// Origin bị chặn trên TCP ngay cả khi body chưa EOF; không đợi hết body budget1s rồi mới kiểm quyền.
    #[tokio::test]
    async fn origin_is_rejected_before_stalled_body() {
        let (status, elapsed) = stalled_chunked_request(true).await;
        assert_eq!(status, 403);
        assert!(elapsed < Duration::from_millis(900));
    }

    /// Route control phải vắng mặt khi composition không opt-in, kể cả trên lab binary.
    #[tokio::test]
    async fn control_routes_are_absent_by_default() {
        let app = attach_measurements(Router::new(), None);
        let response = app
            .oneshot(
                Request::post("/__auth_lab/measurements/begin")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }

    /// Key thiếu/sai và body khác rỗng không được mở window hoặc phát cookie, kể cả khi route enabled.
    #[tokio::test]
    async fn denied_control_does_not_mutate_window() {
        let recorder = Arc::new(AuthTimingRecorder::default());
        let control = MeasurementControl {
            recorder: recorder.clone(),
            key: Arc::new([3; 32]),
        };
        let app = attach_measurements(Router::new(), Some(control));
        for header in [None, Some("00".repeat(32))] {
            let mut request = Request::post("/__auth_lab/measurements/begin");
            if let Some(value) = header {
                request = request.header("x-auth-lab-measurement", value);
            }
            let response = app
                .clone()
                .oneshot(request.body(Body::from("untrusted")).unwrap())
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::FORBIDDEN);
            assert_eq!(response.headers()["cache-control"], "no-store");
            assert!(response.headers().get("set-cookie").is_none());
            recorder.begin_window().unwrap();
            recorder.end_window().unwrap();
        }
    }
}
