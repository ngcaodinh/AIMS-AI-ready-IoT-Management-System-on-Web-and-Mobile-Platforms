//! Provider tests cho draft, snapshot read, registry và credential poll trên DB disposable.

use axum::{
    Router,
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use iot_platform_backend::{
    adapters::security::{CryptoService, PasswordService, generate_token},
    application::{error::ApplicationError, identity::IdentityService, template::TemplateService},
    domain::{device::ApprovedDeviceModels, identity::SecretString},
    http::{HttpState, integrated_lab_router},
    postgres::PgIdentityStore,
};
use serde_json::{Value, json};
use sqlx::{
    PgPool,
    postgres::{PgConnectOptions, PgPoolOptions},
};
use tower::ServiceExt;
use uuid::Uuid;

struct Actor {
    user: Uuid,
    workspace: Uuid,
    token: SecretString,
}

/// Tạo account, Admin grant và Android session tổng hợp bên trong DB test duy nhất.
async fn seed(pool: &PgPool, identity: &IdentityService<PgIdentityStore, CryptoService>) -> Actor {
    let user = Uuid::new_v4();
    let workspace = Uuid::new_v4();
    let token = generate_token();
    let digest = identity.session_proof(token.expose(), None).token_digest;
    let mut transaction = pool.begin().await.unwrap();
    sqlx::query("INSERT INTO users(user_id,email_normalized,password_hash,account_status,activation_provenance)
        VALUES($1,$2,'invalid-test-verifier','ACTIVE','TEST_FIXTURE')")
        .bind(user).bind(format!("{user}@example.invalid")).execute(&mut *transaction).await.unwrap();
    sqlx::query(
        "INSERT INTO workspaces(workspace_id,name,created_by_user_id) VALUES($1,'G1 fixture',$2)",
    )
    .bind(workspace)
    .bind(user)
    .execute(&mut *transaction)
    .await
    .unwrap();
    sqlx::query("INSERT INTO memberships(workspace_id,user_id,role,current_grant_generation) VALUES($1,$2,'ADMIN',1)")
        .bind(workspace).bind(user).execute(&mut *transaction).await.unwrap();
    sqlx::query(
        "INSERT INTO membership_grants(workspace_id,user_id,grant_generation) VALUES($1,$2,1)",
    )
    .bind(workspace)
    .bind(user)
    .execute(&mut *transaction)
    .await
    .unwrap();
    sqlx::query("INSERT INTO sessions(session_id,user_id,token_digest,auth_context_id,limited,client_type,issued_at,expires_at)
        VALUES($1,$2,$3,$4,false,'ANDROID',transaction_timestamp(),transaction_timestamp()+interval '24 hours')")
        .bind(Uuid::new_v4()).bind(user).bind(digest.as_slice()).bind(Uuid::new_v4())
        .execute(&mut *transaction).await.unwrap();
    transaction.commit().await.unwrap();
    Actor {
        user,
        workspace,
        token,
    }
}

/// Gọi provider HTTP qua router in-process, chỉ assert status/mã lỗi đã lọc và header no-store.
async fn call(
    router: &Router,
    actor: &Actor,
    method: &str,
    path: &str,
    headers: &[(&str, &str)],
    body: Option<Value>,
) -> (StatusCode, Value) {
    let mut request = Request::builder()
        .method(method)
        .uri(path)
        .header("authorization", format!("Bearer {}", actor.token.expose()))
        .header("x-workspace-id", actor.workspace.to_string());
    for &(name, value) in headers {
        request = request.header(name, value);
    }
    let body = body.map_or_else(Body::empty, |value| Body::from(value.to_string()));
    let request = request
        .header("content-type", "application/json")
        .body(body)
        .unwrap();
    let response = router.clone().oneshot(request).await.unwrap();
    assert_eq!(response.headers()["cache-control"], "no-store");
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 65_536).await.unwrap();
    let value = serde_json::from_slice(&bytes).expect("provider response shape");
    (status, value)
}

/// Kiểm status mong đợi, chỉ in mã lỗi và correlation khi có mismatch.
fn status(result: &(StatusCode, Value), expected: u16) {
    assert_eq!(
        result.0.as_u16(),
        expected,
        "provider code {}",
        result.1["error"]["code"]
    );
}

/// Lấy UUID từ field fixture đã kiểm thay vì suy version sequence.
fn uuid(value: &Value) -> Uuid {
    value.as_str().unwrap().parse().unwrap()
}

/// Dựng draft có cả STATE/READ legacy lossless và capability với default khác safeValue.
fn room_draft() -> Value {
    json!({
        "name":"G1 synthetic",
        "model":"G1_TEST_MODEL",
        "streams":[
            {"key":"fan","type":"BOOLEAN","channelKind":"STATE","direction":"READ_WRITE","default":true},
            {"key":"reported","type":"BOOLEAN","mode":"STATE","direction":"READ"}
        ],
        "commands":[{"type":"SET_VALUE","stream":"fan","safeValue":false}]
    })
}

/// Kiểm provider mới trên source profile, giữ snapshot pin và poll metadata trong DB test riêng.
#[tokio::test]
#[ignore = "requires disposable PostgreSQL iot_g1_contract_test and its loopback port on stdin"]
async fn provider_preserves_draft_pin_registry_and_poll() {
    let mut input = String::new();
    std::io::stdin().read_line(&mut input).unwrap();
    let port = input.trim().parse().expect("isolated PostgreSQL port");
    let pool = PgPoolOptions::new()
        .max_connections(6)
        .connect_with(
            PgConnectOptions::new()
                .host("127.0.0.1")
                .port(port)
                .username("postgres")
                .database("iot_g1_contract_test"),
        )
        .await
        .unwrap();
    let scratch: String = sqlx::query_scalar("SELECT current_database()")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(scratch, "iot_g1_contract_test");
    let key = [37; 32];
    let store = PgIdentityStore::new(pool.clone());
    let crypto = CryptoService::new(PasswordService::default(), key)
        .await
        .unwrap();
    let identity = IdentityService::new(store.clone(), crypto.clone());
    let admin = seed(&pool, &identity).await;
    let mut other = seed(&pool, &identity).await;
    let state = HttpState::new(pool.clone(), key, "https://g1.example.invalid")
        .await
        .unwrap()
        .with_approved_device_models(
            ApprovedDeviceModels::new(vec!["G1_TEST_MODEL".to_owned()]).unwrap(),
        );
    let router = integrated_lab_router(state);

    let created = call(
        &router,
        &admin,
        "POST",
        "/api/v1/templates",
        &[],
        Some(room_draft()),
    )
    .await;
    status(&created, 201);
    let template = uuid(&created.1["id"]);
    assert_eq!(created.1["streams"][0]["default"], true);
    assert_eq!(created.1["commands"][0]["safeValue"], false);
    assert_eq!(created.1["streams"][1]["channelKind"], "STATE");
    assert_eq!(created.1["streams"][1]["direction"], "READ");
    assert!(created.1["streams"][1].get("mode").is_none());
    let root = format!("/api/v1/templates/{template}");
    status(&call(&router, &other, "GET", &root, &[], None).await, 404);
    let bad_patch = call(
        &router,
        &admin,
        "PATCH",
        &root,
        &[("if-match", "\"1\"")],
        Some(json!({"streams":[]})),
    )
    .await;
    status(&bad_patch, 422);
    let patched = call(
        &router,
        &admin,
        "PATCH",
        &root,
        &[("if-match", "\"1\"")],
        Some(json!({"name":"G1 updated"})),
    )
    .await;
    status(&patched, 200);
    assert_eq!(patched.1["revision"], 2);
    assert_eq!(patched.1["streams"][0]["default"], true);

    // Dùng lại serial cho đăng ký thật sau publish để xác nhận lần bị từ chối không giữ chỗ.
    let serial = format!("g1-{template}");
    let unpublished = call(
        &router,
        &admin,
        "POST",
        "/api/v1/devices",
        &[],
        Some(json!({
            "serial": &serial, "name": "G1 device", "model": "G1_TEST_MODEL",
            "ownerId": admin.user, "templateVersionId": template,
        })),
    )
    .await;
    status(&unpublished, 422);
    assert_eq!(unpublished.1["error"]["code"], "TEMPLATE_NOT_PUBLISHED");

    // Core publication chạy dưới CAS thật nhưng không mount HTTP publish thiếu provenance.
    let publisher = TemplateService::new(store, crypto);
    let proof = identity.session_proof(admin.token.expose(), None);
    let (first, second) = tokio::join!(
        publisher.publish(&proof, admin.workspace, template, 2, Uuid::new_v4()),
        publisher.publish(&proof, admin.workspace, template, 2, Uuid::new_v4()),
    );
    let (winner, loser) = if first.is_ok() {
        (first, second)
    } else {
        (second, first)
    };
    let publication = winner.unwrap();
    assert!(matches!(loser, Err(ApplicationError::StaleRevision)));
    assert_eq!(publication.template_revision, 3);
    let version = publication.template_version_id;

    let read_version = format!("{root}/versions/{version}");
    let pinned = call(&router, &admin, "GET", &read_version, &[], None).await;
    status(&pinned, 200);
    assert_eq!(pinned.1.get("sourceRevision"), Some(&Value::Null));
    assert_eq!(pinned.1["streams"][0]["default"], true);
    assert_eq!(pinned.1["commands"][0]["safeValue"], false);
    let list = call(
        &router,
        &admin,
        "GET",
        &format!("{root}/versions"),
        &[],
        None,
    )
    .await;
    status(&list, 200);
    assert_eq!(uuid(&list.1["items"][0]["id"]), version);
    let recovery = call(
        &router,
        &admin,
        "GET",
        &format!("{root}/versions?sourceRevision=2"),
        &[],
        None,
    )
    .await;
    status(&recovery, 503);

    let clone = call(
        &router,
        &admin,
        "POST",
        &format!("{root}/draft"),
        &[("if-match", "\"3\"")],
        Some(json!({"sourceVersionId":version})),
    )
    .await;
    status(&clone, 200);
    assert_eq!(clone.1["status"], "DRAFT");
    assert_eq!(uuid(&clone.1["latestPublishedVersionId"]), version);
    assert_eq!(clone.1["streams"][0]["default"], true);

    // Legacy replace đi chung invariant model dù transport G1 chỉ cho PATCH trên draft hiện tại.
    let current = publisher
        .get(&proof, admin.workspace, template)
        .await
        .unwrap();
    let mut wrong_model = current.draft.draft().clone();
    wrong_model.model = "G1_OTHER_MODEL".to_owned();
    assert!(matches!(
        publisher
            .replace(
                &proof,
                admin.workspace,
                template,
                4,
                wrong_model,
                Uuid::new_v4()
            )
            .await,
        Err(ApplicationError::TemplateInvalid(_))
    ));

    let registration = json!({
        "serial": serial, "name": "G1 device", "model": "G1_TEST_MODEL",
        "ownerId": admin.user, "templateVersionId": version,
    });
    let (first, second) = tokio::join!(
        call(
            &router,
            &admin,
            "POST",
            "/api/v1/devices",
            &[],
            Some(registration.clone())
        ),
        call(
            &router,
            &admin,
            "POST",
            "/api/v1/devices",
            &[],
            Some(registration)
        ),
    );
    let (device, duplicate) = if first.0.is_success() {
        (first, second)
    } else {
        (second, first)
    };
    status(&device, 201);
    status(&duplicate, 409);
    let device_id = uuid(&device.1["id"]);
    assert_eq!(uuid(&device.1["templateVersionId"]), version);
    assert_eq!(device.1["lifecycle"], "REGISTERED");
    assert_eq!(device.1["connectivity"], "UNKNOWN");
    assert_eq!(device.1["credentialStatus"], "PROVISIONING");
    let recovery = format!("/api/v1/devices?serial={serial}");
    let device_read = call(&router, &admin, "GET", &recovery, &[], None).await;
    status(&device_read, 200);
    assert_eq!(uuid(&device_read.1["items"][0]["id"]), device_id);
    assert_eq!(
        call(&router, &other, "GET", &recovery, &[], None).await.1["items"],
        json!([])
    );

    let id = seed_pending_poll(&pool, &admin, device_id).await;
    let url = format!("/api/v1/provisioning-operations/{id}");
    let poll = call(&router, &admin, "GET", &url, &[], None).await;
    status(&poll, 200);
    assert_eq!(poll.1["kind"], "STATUS");
    let op = &poll.1["operation"];
    assert_eq!(op["kind"], "CREDENTIAL");
    assert_eq!(op["status"], "PENDING");
    assert_eq!(op["retryCount"], 2);
    assert_eq!(op["errorCode"], "BROKER_UNAVAILABLE");
    assert_eq!(op["secretAvailable"], false);
    assert!(poll.1.get("credential").is_none());
    assert!(op.get("password").is_none() && op.get("escrowCiphertext").is_none());
    status(&call(&router, &other, "GET", &url, &[], None).await, 404);

    // Admin thứ hai trong cùng workspace vẫn không có quyền đọc operation của initiator.
    sqlx::query(
        "WITH added AS (
        INSERT INTO memberships(workspace_id,user_id,role,current_grant_generation)
        VALUES($1,$2,'ADMIN',1) RETURNING workspace_id,user_id,current_grant_generation
    ) INSERT INTO membership_grants(workspace_id,user_id,grant_generation)
      SELECT workspace_id,user_id,current_grant_generation FROM added",
    )
    .bind(admin.workspace)
    .bind(other.user)
    .execute(&pool)
    .await
    .unwrap();
    other.workspace = admin.workspace;
    status(&call(&router, &other, "GET", &url, &[], None).await, 404);
}

/**
 * Seed một operation PENDING chỉ để đọc cột metadata trên DB disposable.
 * Input
 * Param: pool — pool fixture đã kiểm database name.
 * Param: admin — initiator có membership hiện tại.
 * Param: device_id — Device REGISTERED được tạo bởi test.
 * Output: UUID operation. Ciphertext/verifier tổng hợp không thể dùng với broker.
 */
async fn seed_pending_poll(pool: &PgPool, admin: &Actor, device_id: Uuid) -> Uuid {
    let operation = Uuid::new_v4();
    let mut tx = pool.begin().await.unwrap();
    // FK cần hàng generation; dữ liệu tổng hợp chỉ kiểm query metadata sau commit.
    sqlx::query("INSERT INTO device_credentials(workspace_id,device_id,credential_generation,credential_identifier,verifier_digest,credential_state,issued_at)
        VALUES($1,$2,1,$3,decode(repeat('00',32),'hex'),'PROVISIONING',transaction_timestamp())")
        .bind(admin.workspace).bind(device_id).bind(Uuid::new_v4().to_string())
        .execute(&mut *tx).await.unwrap();
    sqlx::query("INSERT INTO provisioning_operations(workspace_id,provisioning_operation_id,device_id,credential_generation,
        delivery_channel,state,delivery_status,actor_user_id,intent_at,expires_at,secret_ciphertext,encryption_key_reference,error_code,retry_count)
        VALUES($1,$2,$3,1,'USB_ONE_TIME','PENDING','PENDING',$4,transaction_timestamp(),
        transaction_timestamp()+interval '10 minutes',decode('00','hex'),'fixture-only','BROKER_UNAVAILABLE',2)")
        .bind(admin.workspace).bind(operation).bind(device_id).bind(admin.user)
        .execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    operation
}
