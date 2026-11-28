use super::*;
use axum::{
    Router,
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use iot_platform_backend::{
    adapters::security::{CryptoService, PasswordService},
    application::{identity::IdentityService, template::TemplateService},
    domain::identity::SecretString,
    postgres::PgIdentityStore,
};
use serde_json::{Value, json};
use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use tower::ServiceExt;

struct Actor {
    user_id: Uuid,
    workspace_id: Uuid,
    token: SecretString,
}

async fn login_actor(
    identity: &IdentityService<PgIdentityStore, CryptoService>,
    user_id: Uuid,
    email: &str,
    password: &str,
    workspace_id: Uuid,
    run_id: Uuid,
) -> Actor {
    let issued = identity
        .login(email, password.to_owned(), ClientType::Android, run_id)
        .await
        .unwrap();
    Actor {
        user_id,
        workspace_id,
        token: issued.token,
    }
}

async fn call(
    router: &Router,
    actor: &Actor,
    method: &str,
    path: &str,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let request = Request::builder()
        .method(method)
        .uri(path)
        .header("authorization", format!("Bearer {}", actor.token.expose()))
        .header("x-workspace-id", actor.workspace_id.to_string());
    let body = body.map_or_else(Body::empty, |value| Body::from(value.to_string()));
    let request = request
        .header("content-type", "application/json")
        .body(body)
        .unwrap();
    let response = router.clone().oneshot(request).await.unwrap();
    assert_eq!(response.headers()["cache-control"], "no-store");
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 65_536).await.unwrap();
    (
        status,
        serde_json::from_slice(&bytes).expect("provider response shape"),
    )
}

fn room_draft(model: &str) -> Value {
    json!({
        "name":"Auth lab policy fixture",
        "model":model,
        "streams":[
            {"key":"fan","type":"BOOLEAN","channelKind":"STATE","direction":"READ_WRITE","default":true},
            {"key":"reported","type":"BOOLEAN","mode":"STATE","direction":"READ"}
        ],
        "commands":[{"type":"SET_VALUE","stream":"fan","safeValue":false}]
    })
}

fn registered_device(serial: &str, model: &str, actor: &Actor, version: Uuid) -> Value {
    json!({
        "serial":serial,
        "name":"Auth lab device",
        "model":model,
        "ownerId":actor.user_id,
        "templateVersionId":version
    })
}

fn uuid(value: &Value) -> Uuid {
    value.as_str().unwrap().parse().unwrap()
}

/**
 * Authenticated binary-composition regression for the opt-in model policy and fail-closed default.
 *
 * Requires a disposable iot_g1_contract_test database; provide its loopback port on stdin.
 */
#[tokio::test]
#[ignore = "requires disposable PostgreSQL iot_g1_contract_test and loopback port on stdin"]
async fn integrated_lab_policy_supports_authenticated_create_and_pinned_registration() {
    let mut input = String::new();
    std::io::stdin().read_line(&mut input).unwrap();
    let port = input.trim().parse().expect("isolated PostgreSQL port");
    let pool = PgPoolOptions::new()
        .max_connections(8)
        .connect_with(
            PgConnectOptions::new()
                .host("127.0.0.1")
                .port(port)
                .username("postgres")
                .database("iot_g1_contract_test"),
        )
        .await
        .unwrap();
    let database: String = sqlx::query_scalar("SELECT current_database()")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(database, "iot_g1_contract_test");

    let run_id = Uuid::new_v4();
    let config = Config {
        database_port: port,
        database_password: "disposable-test-only".to_owned(),
        signing_key: [37; 32],
        http_port: 0,
        run_id,
        user_ids: std::array::from_fn(|_| Uuid::new_v4()),
        emails: std::array::from_fn(|index| format!("auth-lab-{run_id}-{index}@example.invalid")),
        fixture_password: "AuthLab-Policy-Test-42!".to_owned(),
        skip_fixture_seed: false,
        enable_measurements: false,
        measurement_key: None,
    };
    iot_platform_backend::domain::input::validate_new_password(
        &config.fixture_password,
        "/password",
    )
    .unwrap();
    seed(&pool, &config).await.unwrap();
    seed_workspaces(&pool, &config).await.unwrap();

    let key = config.signing_key;
    let store = PgIdentityStore::new(pool.clone());
    let crypto = CryptoService::new(PasswordService::default(), key)
        .await
        .unwrap();
    let identity = IdentityService::new(store.clone(), crypto.clone());
    let admin_workspace: Uuid = sqlx::query_scalar(
        "SELECT workspace_id FROM workspaces WHERE created_by_user_id=$1 ORDER BY created_at LIMIT 1",
    )
    .bind(config.user_ids[0])
    .fetch_one(&pool)
    .await
    .unwrap();
    let other_workspace: Uuid = sqlx::query_scalar(
        "SELECT workspace_id FROM workspaces WHERE created_by_user_id=$1 ORDER BY created_at LIMIT 1",
    )
    .bind(config.user_ids[4])
    .fetch_one(&pool)
    .await
    .unwrap();
    let admin = login_actor(
        &identity,
        config.user_ids[0],
        &config.emails[0],
        &config.fixture_password,
        admin_workspace,
        run_id,
    )
    .await;
    let other_admin = login_actor(
        &identity,
        config.user_ids[4],
        &config.emails[4],
        &config.fixture_password,
        other_workspace,
        run_id,
    )
    .await;
    assert_ne!(admin.workspace_id, other_admin.workspace_id);

    let state = HttpState::new(pool.clone(), key, "http://localhost:5173")
        .await
        .unwrap();
    let no_policy_router = auth_lab_router(state.clone());
    let lab_router = auth_lab_router(integrated_lab_state(state).unwrap());

    let draft_body = room_draft("G1_TEST_MODEL");
    let fail_closed_create = call(
        &no_policy_router,
        &admin,
        "POST",
        "/api/v1/templates",
        Some(draft_body.clone()),
    )
    .await;
    assert_eq!(fail_closed_create.0, StatusCode::SERVICE_UNAVAILABLE);

    let invalid_draft = call(
        &lab_router,
        &admin,
        "POST",
        "/api/v1/templates",
        Some(room_draft("G1_UNAPPROVED_MODEL")),
    )
    .await;
    assert_eq!(invalid_draft.0, StatusCode::UNPROCESSABLE_ENTITY);

    let created = call(
        &lab_router,
        &admin,
        "POST",
        "/api/v1/templates",
        Some(draft_body),
    )
    .await;
    assert_eq!(
        created.0,
        StatusCode::CREATED,
        "{}",
        created.1["error"]["code"]
    );
    let template_id = uuid(&created.1["id"]);
    let root = format!("/api/v1/templates/{template_id}");
    let foreign_read = call(&lab_router, &other_admin, "GET", &root, None).await;
    assert_eq!(foreign_read.0, StatusCode::NOT_FOUND);

    let proof = identity.session_proof(admin.token.expose(), None);
    let publisher = TemplateService::new(store, crypto);
    let revision = created.1["revision"].as_i64().expect("root revision");
    let publication = publisher
        .publish(
            &proof,
            admin.workspace_id,
            template_id,
            revision,
            Uuid::new_v4(),
        )
        .await
        .unwrap();
    let version_id = publication.template_version_id;
    let version_path = format!("{root}/versions/{version_id}");
    let pinned = call(&lab_router, &admin, "GET", &version_path, None).await;
    assert_eq!(pinned.0, StatusCode::OK);
    assert_eq!(uuid(&pinned.1["id"]), version_id);
    assert_eq!(pinned.1["sourceRevision"], Value::Null);
    assert_eq!(pinned.1["streams"][0]["default"], true);
    assert_eq!(pinned.1["commands"][0]["safeValue"], false);

    let serial = format!("auth-lab-{run_id}");
    let registration = registered_device(&serial, "G1_TEST_MODEL", &admin, version_id);
    let fail_closed_registration = call(
        &no_policy_router,
        &admin,
        "POST",
        "/api/v1/devices",
        Some(registration.clone()),
    )
    .await;
    assert_eq!(fail_closed_registration.0, StatusCode::SERVICE_UNAVAILABLE);

    let invalid_model_registration = call(
        &lab_router,
        &admin,
        "POST",
        "/api/v1/devices",
        Some(registered_device(
            &serial,
            "G1_UNAPPROVED_MODEL",
            &admin,
            version_id,
        )),
    )
    .await;
    assert_eq!(
        invalid_model_registration.0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert_eq!(
        invalid_model_registration.1["error"]["code"],
        "MODEL_MISMATCH"
    );

    let foreign_registration = call(
        &lab_router,
        &other_admin,
        "POST",
        "/api/v1/devices",
        Some(registered_device(
            "foreign-pin",
            "G1_TEST_MODEL",
            &other_admin,
            version_id,
        )),
    )
    .await;
    assert_eq!(foreign_registration.0, StatusCode::NOT_FOUND);
    assert_eq!(
        foreign_registration.1["error"]["code"],
        "RESOURCE_NOT_FOUND"
    );

    let registered = call(
        &lab_router,
        &admin,
        "POST",
        "/api/v1/devices",
        Some(registration),
    )
    .await;
    assert_eq!(registered.0, StatusCode::CREATED);
    assert_eq!(uuid(&registered.1["templateVersionId"]), version_id);
    assert_eq!(registered.1["lifecycle"], "REGISTERED");
    assert_eq!(registered.1["connectivity"], "UNKNOWN");
    assert_eq!(registered.1["credentialStatus"], "PROVISIONING");
}
