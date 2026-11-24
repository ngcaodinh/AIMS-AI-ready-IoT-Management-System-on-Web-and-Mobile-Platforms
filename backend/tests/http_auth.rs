//! Kiểm HTTP Router thật tại boundary; pool lazy không thay thế PostgreSQL integration.

use axum::{
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use iot_platform_backend::http::{HttpState, auth_router};
use serde_json::Value;
use sqlx::postgres::PgPoolOptions;
use tower::ServiceExt;

/** Dựng router với pool chưa kết nối; negative boundary phải trả lỗi trước mọi truy vấn. */
async fn router() -> axum::Router {
    let pool = PgPoolOptions::new()
        .connect_lazy("postgres://localhost/iot_http_boundary_test")
        .unwrap();
    auth_router(
        HttpState::new(pool, [7; 32], "http://localhost:5173")
            .await
            .unwrap(),
    )
}

/** Gửi JSON tới router thật; Input: body là dữ liệu tổng hợp, origin là header kiểm CSRF. */
async fn login_request(body: &str, origin: Option<&str>) -> axum::response::Response {
    let mut request =
        Request::post("/api/v1/auth/login").header("content-type", "application/json");
    if let Some(origin) = origin {
        request = request.header("origin", origin);
    }
    router()
        .await
        .oneshot(request.body(Body::from(body.to_owned())).unwrap())
        .await
        .unwrap()
}

/** Origin ngoài allowlist bị chặn cả khi browser tự khai Android; không phát credential. */
#[tokio::test]
async fn browser_cannot_bypass_origin_by_claiming_android() {
    let response = login_request(r#"{"email":"member@example.test","password":"synthetic-password-123","clientType":"ANDROID"}"#, Some("https://attacker.invalid")).await;
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert_eq!(response.headers()["cache-control"], "no-store");
    assert!(response.headers().get("set-cookie").is_none());
}

/** Duplicate JSON phải là400, null password là422 với path/code và không echo giá trị. */
#[tokio::test]
async fn malformed_and_typed_inputs_keep_contract_errors() {
    let duplicate = login_request(
        r#"{"email":"a@example.test","email":"b@example.test"}"#,
        Some("http://localhost:5173"),
    )
    .await;
    assert_eq!(duplicate.status(), StatusCode::BAD_REQUEST);
    let response = login_request(
        r#"{"email":"member@example.test","password":null,"clientType":"ANDROID"}"#,
        None,
    )
    .await;
    assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
    let body: Value =
        serde_json::from_slice(&to_bytes(response.into_body(), 65536).await.unwrap()).unwrap();
    assert_eq!(
        body["error"]["details"]["fieldErrors"][0]["path"],
        "/password"
    );
    assert_eq!(body["error"]["details"]["fieldErrors"][0]["code"], "TYPE");
    assert!(body["error"]["correlationId"].is_string());
}

/** Từ chối boolean và authority field lạ trước DB, đồng thời không phản chiếu dữ liệu đầu vào trong lỗi. */
#[tokio::test]
async fn login_boolean_and_unknown_authority_fields_do_not_echo_input() {
    let router = router().await;
    for (field, value, expected_path, expected_code) in [
        ("email", serde_json::json!(true), "/email", "TYPE"),
        ("email", serde_json::json!(false), "/email", "TYPE"),
        ("password", serde_json::json!(true), "/password", "TYPE"),
        ("password", serde_json::json!(false), "/password", "TYPE"),
        ("clientType", serde_json::json!(true), "/clientType", "TYPE"),
        (
            "clientType",
            serde_json::json!(false),
            "/clientType",
            "TYPE",
        ),
        (
            "expiresAt",
            serde_json::json!("attacker_canary_value"),
            "",
            "UNKNOWN_FIELD",
        ),
        (
            "attacker_canary_key",
            serde_json::json!("attacker_canary_value"),
            "",
            "UNKNOWN_FIELD",
        ),
    ] {
        let mut input = serde_json::json!({
            "email": "unit@example.test",
            "password": "synthetic-password-123",
            "clientType": "ANDROID"
        });
        input
            .as_object_mut()
            .unwrap()
            .insert(field.to_owned(), value);
        let response = router
            .clone()
            .oneshot(
                Request::post("/api/v1/auth/login")
                    .header("content-type", "application/json")
                    .body(Body::from(input.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::UNPROCESSABLE_ENTITY,
            "{field}"
        );
        assert!(response.headers().get("set-cookie").is_none());
        let bytes = to_bytes(response.into_body(), 65536).await.unwrap();
        let payload: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            payload["error"]["details"]["fieldErrors"][0]["path"],
            expected_path
        );
        assert_eq!(
            payload["error"]["details"]["fieldErrors"][0]["code"],
            expected_code
        );
        assert!(payload.get("token").is_none());
        let serialized = std::str::from_utf8(&bytes).unwrap();
        for canary in [
            "unit@example.test",
            "synthetic-password-123",
            "attacker_canary_key",
            "attacker_canary_value",
            "expiresAt",
        ] {
            assert!(
                !serialized.contains(canary),
                "error reflected a forbidden input"
            );
        }
    }
}

/** Policy đổi password chạy trước DB/hash/revoke, kể cả caller bỏ toàn bộ kiểm client; không echo credential. */
#[tokio::test]
async fn weak_new_password_is_rejected_before_database_access() {
    for (current, new, expected_code) in [
        ("legacy-current", "abcdefghi1", "FORMAT"),
        ("legacy-current", "ABCDEFGHI1", "FORMAT"),
        ("legacy-current", "Abcdefghij", "FORMAT"),
        ("legacy-current", "Abcdefg1", "LENGTH"),
        ("Abcdefg12", "Abcdefg12", "SAME_AS_CURRENT"),
    ] {
        let request = Request::post("/api/v1/auth/password")
            .header("content-type", "application/json")
            .body(Body::from(
                serde_json::json!({"currentPassword":current,"newPassword":new}).to_string(),
            ))
            .unwrap();
        let response = router().await.oneshot(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
        assert!(response.headers().get("set-cookie").is_none());
        let body: Value =
            serde_json::from_slice(&to_bytes(response.into_body(), 65536).await.unwrap()).unwrap();
        assert_eq!(
            body["error"]["details"]["fieldErrors"][0]["path"],
            "/newPassword"
        );
        assert_eq!(
            body["error"]["details"]["fieldErrors"][0]["code"],
            expected_code
        );
    }
    // New9 hợp lệ và current1 legacy phải qua validation rồi mới bị401 do thiếu credential phiên; không cần DB thật.
    let request = Request::post("/api/v1/auth/password")
        .header("content-type", "application/json")
        .body(Body::from(
            r#"{"currentPassword":"x","newPassword":"Abcdefg12"}"#,
        ))
        .unwrap();
    assert_eq!(
        router().await.oneshot(request).await.unwrap().status(),
        StatusCode::UNAUTHORIZED
    );
}

/** Chạy tất cả fixture validation âm qua handler thật; không gọi DB và không dùng expected để dựng response. */
#[tokio::test]
async fn negative_shared_login_fixtures_match_http_provider() {
    let fixtures: Value = serde_json::from_str(include_str!(
        "../../contracts/fixtures/auth/login-validation-scenarios.json"
    ))
    .unwrap();
    let router = router().await;
    for scenario in fixtures["scenarios"].as_array().unwrap() {
        if scenario["response"]["status"] == 200 {
            continue;
        }
        let expected_status = scenario["response"]["status"].as_u64().unwrap();
        let request_body = scenario["request"]["rawBody"].as_str().map_or_else(
            || serde_json::to_string(&scenario["request"]["body"]).unwrap(),
            str::to_owned,
        );
        let request = Request::post("/api/v1/auth/login")
            .header("content-type", "application/json")
            .body(Body::from(request_body))
            .unwrap();
        let response = router.clone().oneshot(request).await.unwrap();
        assert_eq!(
            u64::from(response.status().as_u16()),
            expected_status,
            "{}",
            scenario["id"]
        );
        assert_eq!(response.headers()["cache-control"], "no-store");
        assert!(response.headers().get("set-cookie").is_none());
        let body: Value =
            serde_json::from_slice(&to_bytes(response.into_body(), 65536).await.unwrap()).unwrap();
        assert_eq!(
            body["error"]["details"], scenario["response"]["body"]["error"]["details"],
            "{}",
            scenario["id"]
        );
    }
}

/** Mixed cookie/bearer và header context mơ hồ phải dừng trước pool lazy; mọi lỗi không cache/clear cookie. */
#[tokio::test]
async fn ambiguous_transport_is_rejected_before_storage() {
    let token = "a".repeat(64);
    let request = Request::get("/api/v1/me")
        .header("cookie", format!("iot_session={token}"))
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    let response = router().await.oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    assert!(response.headers().get("set-cookie").is_none());
}

/** Logout không credential là204, body policy theo frozen fixture; không cần pool hoặc clear cookie. */
#[tokio::test]
async fn logout_anonymous_and_body_policy_match_shared_fixtures() {
    let router = router().await;
    let response = router
        .clone()
        .oneshot(
            Request::post("/api/v1/auth/logout")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert!(response.headers().get("set-cookie").is_none());
    let fixtures: Value = serde_json::from_str(include_str!(
        "../../contracts/fixtures/auth/logout-scenarios.json"
    ))
    .unwrap();
    for scenario in fixtures["scenarios"].as_array().unwrap() {
        let Some(body) = scenario["request"]["rawBody"]
            .as_str()
            .filter(|body| !body.is_empty())
        else {
            continue;
        };
        if body.len() > 65536 {
            continue;
        }
        let content_type = scenario["request"]["headers"]["Content-Type"]
            .as_str()
            .unwrap_or("application/json");
        let response = router
            .clone()
            .oneshot(
                Request::post("/api/v1/auth/logout")
                    .header("content-type", content_type)
                    .body(Body::from(body.to_owned()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            u64::from(response.status().as_u16()),
            scenario["response"]["status"].as_u64().unwrap(),
            "{}",
            scenario["id"]
        );
        assert!(response.headers().get("set-cookie").is_none());
        let payload: Value =
            serde_json::from_slice(&to_bytes(response.into_body(), 65536).await.unwrap()).unwrap();
        assert_eq!(
            payload["error"]["details"], scenario["response"]["body"]["error"]["details"],
            "{}",
            scenario["id"]
        );
    }
}

/** Size/MIME/duplicate có mã riêng; field value không được phản chiếu qua error envelope. */
#[tokio::test]
async fn size_media_and_nested_duplicate_are_rejected_before_storage() {
    let router = router().await;
    for (body, media, status, code) in [
        (" ".repeat(65537), "application/json", 413, "BODY_TOO_LARGE"),
        ("{}".to_owned(), "text/plain", 415, "CONTENT_TYPE"),
        (
            r#"{"password":{"nested":1,"nested":2}}"#.to_owned(),
            "application/json",
            400,
            "DUPLICATE_FIELD",
        ),
    ] {
        let response = router
            .clone()
            .oneshot(
                Request::post("/api/v1/auth/login")
                    .header("content-type", media)
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), status);
        let payload: Value =
            serde_json::from_slice(&to_bytes(response.into_body(), 65536).await.unwrap()).unwrap();
        assert_eq!(payload["error"]["details"]["fieldErrors"][0]["code"], code);
    }
}

/** Khóa mapping OQ008 trên lỗi body và từng field, kiểm toàn envelope không phản chiếu canary trước DB. */
#[tokio::test]
async fn login_validation_matrix_never_echoes_input_or_issues_credentials() {
    let router = router().await;
    let mut cases = Vec::new();
    for field in ["email", "password", "clientType"] {
        for value in [
            Value::Null,
            serde_json::json!(17),
            serde_json::json!(true),
            serde_json::json!(false),
            serde_json::json!(""),
        ] {
            let mut body = serde_json::json!({
                "email": "boundary_canary@example.test",
                "password": "boundary_canary_password_Aa1",
                "clientType": "ANDROID"
            });
            body[field] = value;
            let expected_code = if body[field] == "" {
                match field {
                    "email" => "FORMAT",
                    "password" => "LENGTH",
                    _ => "ENUM",
                }
            } else {
                "TYPE"
            };
            cases.push((
                body.to_string(),
                "application/json",
                422,
                format!("/{field}"),
                expected_code,
            ));
        }
        let mut body = serde_json::json!({
            "email": "boundary_canary@example.test",
            "password": "boundary_canary_password_Aa1",
            "clientType": "ANDROID"
        });
        body.as_object_mut().unwrap().remove(field);
        cases.push((
            body.to_string(),
            "application/json",
            422,
            format!("/{field}"),
            "REQUIRED",
        ));
    }
    cases.extend([
        (
            r#"{"boundary_canary_key":"boundary_canary_value"}"#.to_owned(),
            "application/json",
            422,
            String::new(),
            "UNKNOWN_FIELD",
        ),
        (
            r#"{"boundary_canary_key":1,"boundary_canary_key":2}"#.to_owned(),
            "application/json",
            400,
            String::new(),
            "DUPLICATE_FIELD",
        ),
        (
            r#"{"boundary_canary_key":"boundary_canary_value""#.to_owned(),
            "application/json",
            400,
            String::new(),
            "MALFORMED_JSON",
        ),
        (
            "boundary_canary_value".repeat(4000),
            "application/json",
            413,
            String::new(),
            "BODY_TOO_LARGE",
        ),
        (
            "boundary_canary_value".to_owned(),
            "text/plain",
            415,
            String::new(),
            "CONTENT_TYPE",
        ),
    ]);
    for (body, media, status, path, code) in cases {
        let response = router
            .clone()
            .oneshot(
                Request::post("/api/v1/auth/login")
                    .header("content-type", media)
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), status, "{path}:{code}");
        assert_eq!(response.headers()["cache-control"], "no-store");
        assert!(response.headers().get("set-cookie").is_none());
        let bytes = to_bytes(response.into_body(), 65536).await.unwrap();
        let payload: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(payload["error"]["code"], "VALIDATION_ERROR");
        assert_eq!(payload["error"]["details"]["fieldErrors"][0]["path"], path);
        assert_eq!(payload["error"]["details"]["fieldErrors"][0]["code"], code);
        assert!(payload.get("token").is_none());
        assert!(payload.get("me").is_none());
        assert!(payload.get("expiresAt").is_none());
        assert!(
            !std::str::from_utf8(&bytes)
                .unwrap()
                .contains("boundary_canary")
        );
    }
}

/** IOS là metadata bearer theo OQ007; enum hợp lệ phải đi tiếp tới email validation, còn Origin giả vẫn bị chặn. */
#[tokio::test]
async fn ios_login_uses_app_contract_and_keeps_browser_origin_guard() {
    let body = r#"{"email":"invalid","password":"synthetic-password-123","clientType":"IOS"}"#;
    let response = login_request(body, None).await;
    assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert!(response.headers().get("set-cookie").is_none());
    let payload: Value =
        serde_json::from_slice(&to_bytes(response.into_body(), 65536).await.unwrap()).unwrap();
    assert_eq!(
        payload["error"]["details"]["fieldErrors"][0]["path"],
        "/email"
    );
    assert_eq!(
        payload["error"]["details"]["fieldErrors"][0]["code"],
        "FORMAT"
    );
    let denied = login_request(body, Some("https://attacker.invalid")).await;
    assert_eq!(denied.status(), StatusCode::FORBIDDEN);
    assert!(denied.headers().get("set-cookie").is_none());
}

/** Root JSON số thực/nguyên ở auth vẫn là root TYPE 422 và duplicate object vẫn 400 dù bật `raw_value` cho publish. */
#[tokio::test]
async fn login_preserves_root_numeric_type_and_duplicate_field_errors() {
    for scalar in ["1.5", "1", "-5"] {
        let response = login_request(scalar, None).await;
        assert_eq!(
            response.status(),
            StatusCode::UNPROCESSABLE_ENTITY,
            "scalar={scalar}"
        );
        let payload: Value =
            serde_json::from_slice(&to_bytes(response.into_body(), 65536).await.unwrap()).unwrap();
        assert_eq!(payload["error"]["code"], "VALIDATION_ERROR");
        assert_eq!(payload["error"]["details"]["fieldErrors"][0]["path"], "");
        assert_eq!(
            payload["error"]["details"]["fieldErrors"][0]["code"],
            "TYPE"
        );
    }

    let duplicate = login_request(r#"{"a":1.5,"a":2.5}"#, None).await;
    assert_eq!(duplicate.status(), StatusCode::BAD_REQUEST);
    let payload: Value =
        serde_json::from_slice(&to_bytes(duplicate.into_body(), 65536).await.unwrap()).unwrap();
    assert_eq!(
        payload["error"]["details"]["fieldErrors"][0]["code"],
        "DUPLICATE_FIELD"
    );

    let malformed_logout = router()
        .await
        .oneshot(
            Request::post("/api/v1/auth/logout")
                .header("content-type", "application/json")
                .body(Body::from("{"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(malformed_logout.status(), StatusCode::BAD_REQUEST);
}
