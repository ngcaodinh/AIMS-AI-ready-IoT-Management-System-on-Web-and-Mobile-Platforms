//! HTTP ticket boundary, first-frame authentication và registry socket theo session.

use super::{
    AuthService, HttpError, HttpState, no_store, require_empty_body, security,
    sessions::{check_mutation, inspect},
};
use axum::{
    Json, Router,
    extract::{
        Request, State,
        ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade},
    },
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde_json::json;
use std::{
    collections::{HashMap, HashSet},
    future::{Future, poll_fn},
    pin::pin,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    task::Poll,
    time::Duration,
};
use tokio::{
    sync::{Mutex, OwnedSemaphorePermit, Semaphore, mpsc},
    time,
};
use uuid::Uuid;

// Giữ giới hạn server ở4 giây để chừa1giây cho event loop/network, bảo đảm client quan sát close trong5giây.
const FIRST_FRAME_TIMEOUT: Duration = Duration::from_secs(4);
// Giới hạn thời gian gửi close còn lại để tổng thời gian xác thực và từ chối không vượt5giây.
const POLICY_CLOSE_TIMEOUT: Duration = Duration::from_secs(1);
// Theo chính sách realtime đã duyệt: kiểm tra peer mỗi30giây, tối đa10giây chờ Pong.
const REALTIME_PING_INTERVAL: Duration = Duration::from_secs(30);
const REALTIME_PONG_TIMEOUT: Duration = Duration::from_secs(10);
// Giữ write control frame hữu hạn để một socket nghẽn không trì hoãn logout quá lâu.
const REALTIME_PING_SEND_TIMEOUT: Duration = Duration::from_secs(1);
const MAX_TICKET_FRAME_BYTES: usize = 64;
// Mỗi router instance tự đối soát registry của mình, không phụ thuộc lease consumer một-instance.
const SESSION_RECONCILIATION_INTERVAL: Duration = Duration::from_secs(1);
// Một giây polling + hai giây truy vấn + một giây gửi close vẫn chừa biên dưới giới hạn thu hồi năm giây.
const SESSION_RECONCILIATION_TIMEOUT: Duration = Duration::from_secs(2);
const AUTHENTICATION_CLOSE_REASON: &str = "Authentication required.";
// Giới hạn các upgrade đang chờ frame/ACK; handshake chưa xác thực chỉ có tối đa bốn giây.
const MAX_PENDING_REALTIME_HANDSHAKES: usize = 16;
// Cap tổng socket theo instance, bao gồm upgrade đang chờ, socket đã auth và socket đang đóng.
const MAX_ACTIVE_REALTIME_SOCKETS: usize = 16;
// Trần runtime: pool nhỏ hơn tự hạ quota để luôn chừa một connection cho auth/reconcile.
pub(super) const MAX_CONCURRENT_HANDSHAKE_DB_CHECKS: usize = 2;

/**
 * Tính quota DB handshake theo pool thực tế, luôn chừa một connection cho auth/reconciler.
 * Input
 * Param: max_connections — giới hạn connection đã cấu hình cho pool PostgreSQL này.
 * Output: số query handshake đồng thời, tối đa hai và bằng không nếu không thể chừa slot.
 */
pub(super) fn handshake_db_capacity(max_connections: u32) -> usize {
    max_connections
        .saturating_sub(1)
        .min(MAX_CONCURRENT_HANDSHAKE_DB_CHECKS as u32) as usize
}

type SessionConnections = HashMap<Uuid, HashMap<Uuid, mpsc::Sender<()>>>;

/** Permit tách biệt bảo đảm registry không thể nhận socket vượt giới hạn toàn instance. */
struct ActiveRealtimeSocketPermit {
    _permit: OwnedSemaphorePermit,
}

struct RealtimeHubInner {
    connections: Mutex<SessionConnections>,
    reconciler_started: AtomicBool,
    active_sockets: Arc<Semaphore>,
    pending_handshakes: Arc<Semaphore>,
    handshake_db_checks: Arc<Semaphore>,
}

impl RealtimeHubInner {
    /**
     * Tạo bộ đếm admission dùng chung cho mọi clone của hub trong cùng listener.
     * Input
     * Param: max_handshake_db_checks — quota DB còn lại sau khi composition chừa slot cho auth/reconcile.
     * Output: trạng thái registry cùng hai semaphore độc lập cho upgrade và truy vấn DB handshake.
     */
    fn new(max_handshake_db_checks: usize) -> Self {
        Self {
            connections: Mutex::new(HashMap::new()),
            reconciler_started: AtomicBool::new(false),
            active_sockets: Arc::new(Semaphore::new(MAX_ACTIVE_REALTIME_SOCKETS)),
            pending_handshakes: Arc::new(Semaphore::new(MAX_PENDING_REALTIME_HANDSHAKES)),
            handshake_db_checks: Arc::new(Semaphore::new(max_handshake_db_checks)),
        }
    }
}

/// Registry chỉ giữ handle đóng socket local; DB vẫn là nguồn sự thật cho session status.
#[derive(Clone)]
pub(super) struct RealtimeHub {
    inner: Arc<RealtimeHubInner>,
}

impl RealtimeHub {
    /**
     * Khởi tạo hub với giới hạn DB lấy từ pool để giữ slot cho luồng auth/reconcile.
     * Input
     * Param: max_handshake_db_checks — số truy vấn handshake được phép chạy đồng thời.
     * Output: hub có semaphore admission được chia sẻ an toàn qua các bản clone.
     */
    pub(super) fn with_handshake_db_capacity(max_handshake_db_checks: usize) -> Self {
        Self {
            inner: Arc::new(RealtimeHubInner::new(max_handshake_db_checks)),
        }
    }

    /** Giữ quota socket toàn instance từ trước upgrade tới khi WebSocket handler kết thúc. */
    fn try_admit_active_socket(&self) -> Option<ActiveRealtimeSocketPermit> {
        Arc::clone(&self.inner.active_sockets)
            .try_acquire_owned()
            .ok()
            .map(|permit| ActiveRealtimeSocketPermit { _permit: permit })
    }

    /**
     * Thử giữ slot handshake trước upgrade để burst không tạo task chưa xác thực vượt quota.
     * Output: permit RAII nếu còn chỗ; None ngay khi quota đầy, không xếp hàng chờ.
     */
    fn try_admit_handshake(&self) -> Option<OwnedSemaphorePermit> {
        Arc::clone(&self.inner.pending_handshakes)
            .try_acquire_owned()
            .ok()
    }

    /**
     * Thử giữ quota DB cho consume và recheck session trước khi cấp quyền socket.
     * Output: permit RAII nếu còn ngân sách; None ngay khi đầy để tránh queue thêm vào auth pool.
     */
    fn try_admit_handshake_db_check(&self) -> Option<OwnedSemaphorePermit> {
        Arc::clone(&self.inner.handshake_db_checks)
            .try_acquire_owned()
            .ok()
    }

    /**
     * Đăng ký socket sau khi ticket consume thành công và trả channel đóng bounded một phần tử.
     * Input
     * Param: session_id — session đã được ticket consume kiểm tra bởi application và PostgreSQL.
     * Param: active_socket_permit — bằng chứng admission còn sống, giữ registry trong giới hạn instance.
     * Output: ID socket local cùng receiver nhận tín hiệu đóng từ logout/reconciler.
     * Side effects: thêm đúng một handle vào registry của instance hiện tại.
     */
    async fn register(
        &self,
        session_id: Uuid,
        _active_socket_permit: &ActiveRealtimeSocketPermit,
    ) -> (Uuid, mpsc::Receiver<()>) {
        let connection_id = Uuid::new_v4();
        let (sender, receiver) = mpsc::channel(1);
        self.inner
            .connections
            .lock()
            .await
            .entry(session_id)
            .or_default()
            .insert(connection_id, sender);
        (connection_id, receiver)
    }

    /**
     * Đóng các socket gắn đúng session sau khi transaction logout đã commit.
     * Input
     * Param: session_id — ID lấy từ SessionInspection của credential hiện hành.
     * Output: số socket nhận được close signal; không ảnh hưởng phiên khác của cùng account.
     */
    pub(super) async fn close_session(&self, session_id: Uuid) -> usize {
        let senders = self
            .inner
            .connections
            .lock()
            .await
            .remove(&session_id)
            .unwrap_or_default();
        notify_close(senders.into_values())
    }

    /**
     * Bỏ handle đã kết thúc; không giữ registry lock khi handler chờ socket/network.
     * Input
     * Param: session_id — key của session local đã được bind lúc register.
     * Param: connection_id — ID ngẫu nhiên riêng của WebSocket connection.
     */
    async fn unregister(&self, session_id: Uuid, connection_id: Uuid) {
        let mut connections = self.inner.connections.lock().await;
        if let Some(session_connections) = connections.get_mut(&session_id) {
            session_connections.remove(&connection_id);
            if session_connections.is_empty() {
                connections.remove(&session_id);
            }
        }
    }

    /** Lấy snapshot ID riêng của registry local trước khi query DB, không đọc ID do client gửi. */
    async fn session_ids(&self) -> Vec<Uuid> {
        self.inner
            .connections
            .lock()
            .await
            .keys()
            .copied()
            .collect()
    }

    /**
     * Gửi close signal cho session absent trong tập active đã đọc từ DB.
     * Input
     * Param: active_sessions — subset DB trả về cho chính snapshot local vừa query.
     * Output: số connection cục bộ bị gỡ khỏi registry và được yêu cầu đóng.
     */
    async fn close_stale_sessions(
        &self,
        checked_sessions: &HashSet<Uuid>,
        active_sessions: &HashSet<Uuid>,
    ) -> usize {
        let stale_connections = {
            let mut connections = self.inner.connections.lock().await;
            let stale_session_ids: Vec<Uuid> = connections
                .keys()
                .filter(|session_id| {
                    checked_sessions.contains(session_id) && !active_sessions.contains(session_id)
                })
                .copied()
                .collect();
            stale_session_ids
                .into_iter()
                .filter_map(|session_id| connections.remove(&session_id))
                .flat_map(HashMap::into_values)
                .collect::<Vec<_>>()
        };
        notify_close(stale_connections)
    }

    /**
     * Gửi close signal cho mọi socket local khi DB không thể xác nhận quyền hiện hành.
     * Không giữ positive cache sống qua lỗi storage; instance tiếp tục nhận connection mới sau khi DB hồi phục.
     */
    async fn close_all(&self) -> usize {
        let connections = std::mem::take(&mut *self.inner.connections.lock().await);
        notify_close(connections.into_values().flat_map(HashMap::into_values))
    }

    /**
     * Chạy một reconciler bounded theo thời gian cho các socket của router instance này.
     * Input
     * Param: auth — service chỉ đọc subset session registry cục bộ bằng DB clock.
     * Side effects: task dừng khi router/hub bị drop; lỗi hoặc timeout DB đóng các socket hiện đang đăng ký.
     */
    pub(super) fn start_reconciliation(&self, auth: AuthService) {
        if self.inner.reconciler_started.swap(true, Ordering::AcqRel) {
            return;
        }
        // Worker chỉ giữ Weak để không níu router/pool sau shutdown; mỗi chu kỳ upgrade xong mới I/O DB.
        let inner = Arc::downgrade(&self.inner);
        let _ = tokio::spawn(async move {
            let mut interval = time::interval(SESSION_RECONCILIATION_INTERVAL);
            interval.set_missed_tick_behavior(time::MissedTickBehavior::Skip);
            loop {
                interval.tick().await;
                let Some(inner) = inner.upgrade() else {
                    break;
                };
                let hub = RealtimeHub { inner };
                let session_ids = hub.session_ids().await;
                if session_ids.is_empty() {
                    continue;
                }
                let checked_sessions: HashSet<Uuid> = session_ids.iter().copied().collect();
                // Chỉ đóng các ID thuộc snapshot đã query; socket mới đăng ký trong lúc await sẽ chờ chu kỳ sau.
                reconcile_session_check(
                    &hub,
                    &checked_sessions,
                    auth.active_realtime_sessions(&session_ids),
                )
                .await;
            }
        });
    }
}

/**
 * Fail-closed cho socket local khi DB tra cứu phiên lỗi hoặc vượt deadline ngắn.
 * Input
 * Param: hub — registry của router instance cần đóng socket nếu trạng thái không xác nhận được.
 * Param: checked_sessions — snapshot ID đã query, chỉ dùng lọc socket cũ khi DB trả kết quả thành công.
 * Param: active_sessions — future DB kiểm session theo nguồn trạng thái hiện hành.
 * Side effects: query chạy quá hai giây bị hủy; lỗi hoặc timeout phát close signal cho toàn bộ registry local.
 */
async fn reconcile_session_check<F, E>(
    hub: &RealtimeHub,
    checked_sessions: &HashSet<Uuid>,
    active_sessions: F,
) where
    F: Future<Output = Result<HashSet<Uuid>, E>> + Send,
    E: Send,
{
    // Timeout hủy await DB và đóng mọi socket thay vì để quyền positive tồn tại khi storage không phản hồi.
    match time::timeout(SESSION_RECONCILIATION_TIMEOUT, active_sessions).await {
        Ok(Ok(active_sessions)) => {
            hub.close_stale_sessions(checked_sessions, &active_sessions)
                .await;
        }
        Ok(Err(_)) | Err(_) => {
            hub.close_all().await;
        }
    }
}

/**
 * Cố gắng đánh thức receiver mà không await hoặc giữ mutex qua thao tác transport.
 * Input
 * Param: senders — bounded channels đã được gỡ khỏi registry, mỗi channel thuộc một socket local.
 * Output: số channel chấp nhận close signal; receiver cũng có thể đã disconnect.
 */
fn notify_close(senders: impl IntoIterator<Item = mpsc::Sender<()>>) -> usize {
    senders
        .into_iter()
        .filter(|sender| sender.try_send(()).is_ok())
        .count()
}

/**
 * Lắp ticket REST và WebSocket handshake vào cùng auth router.
 * Output: router có hai boundary realtime; chưa đăng ký subscription/event route.
 */
pub(super) fn routes() -> Router<HttpState> {
    Router::new()
        .route("/api/v1/realtime/tickets", post(create_ticket))
        .route("/api/v1/realtime", get(open_socket))
}

/**
 * Cấp ticket 30 giây từ session/workspace đã admit; body response là lần xuất ticket duy nhất.
 * Input
 * Param: state — service auth/ticket và hub socket cùng backend instance.
 * Param: headers — cookie/bearer, context, CSRF và workspace selector chưa tin cậy.
 * Param: request — body phải vắng hoặc dài0 byte.
 * Output: `201` với ticket/expiresAt sau commit; response luôn no-store.
 * Errors: session/context/CSRF/workspace/limited hoặc dependency mapping theo auth contract.
 */
async fn create_ticket(
    State(state): State<HttpState>,
    headers: HeaderMap,
    request: Request,
) -> Result<Response, HttpError> {
    require_empty_body(request).await?;
    let (proof, transport, session) = inspect(&state, &headers, false, false).await?;
    check_mutation(&state, &headers, transport, &session)?;
    let workspace_value = security::single_header(&headers, "x-workspace-id")?
        .ok_or_else(|| HttpError::validation(422, "/headers/X-Workspace-Id", "REQUIRED"))?;
    let workspace_id = Uuid::parse_str(workspace_value)
        .map_err(|_| HttpError::validation(422, "/headers/X-Workspace-Id", "FORMAT"))?;
    let correlation_id = Uuid::new_v4();
    let ticket = state
        .auth
        .issue_realtime_ticket(&proof, workspace_id, correlation_id)
        .await
        .map_err(|error| HttpError::from(error).correlated(correlation_id))?;
    let mut response = (
        StatusCode::CREATED,
        Json(json!({
            "ticket": ticket.token.expose(),
            "expiresAt": ticket.expires_at,
        })),
    )
        .into_response();
    no_store(&mut response);
    Ok(response)
}

/**
 * Kiểm origin browser nếu có rồi nâng cấp; auth capability chỉ được nhận ở frame text đầu tiên.
 * Input
 * Param: state — auth service và socket registry của instance sở hữu upgrade.
 * Param: headers — Origin có thể vắng ở client native, nếu có phải exact-match origin cấu hình.
 * Param: websocket — extractor HTTP/1.1 WebSocketUpgrade của Axum.
 * Output: response upgrade; không nhận ticket từ query, cookie hoặc subprotocol.
 * Errors: origin duplicate/mismatch trả ErrorEnvelope; quota socket hoặc handshake đầy trả503 no-store trước upgrade.
 */
async fn open_socket(
    State(state): State<HttpState>,
    headers: HeaderMap,
    websocket: WebSocketUpgrade,
) -> Result<Response, HttpError> {
    if security::single_header(&headers, "origin")?.is_some() {
        security::check_origin(&headers, &state.origin, false)?;
    }
    let Some(active_socket_permit) = state.realtime.try_admit_active_socket() else {
        // Từ chối trước upgrade để registry, task và file descriptor có cùng trần theo instance.
        let mut response = StatusCode::SERVICE_UNAVAILABLE.into_response();
        no_store(&mut response);
        return Ok(response);
    };
    let Some(handshake_permit) = state.realtime.try_admit_handshake() else {
        // Từ chối trước khi phát upgrade để burst không tạo thêm task/socket chưa được xác thực.
        let mut response = StatusCode::SERVICE_UNAVAILABLE.into_response();
        no_store(&mut response);
        return Ok(response);
    };
    let response = websocket
        .max_message_size(MAX_TICKET_FRAME_BYTES)
        .max_frame_size(MAX_TICKET_FRAME_BYTES)
        .on_upgrade(move |socket| async move {
            // Giữ active permit ngoài future handler để socket được drop xong rồi quota mới phục hồi.
            let active_socket_permit = active_socket_permit;
            handle_socket(socket, state, handshake_permit, &active_socket_permit).await;
        });
    Ok(response.into_response())
}

/**
 * Consume ticket trước mọi server frame, đăng ký phiên rồi đóng khi logout/reconcile báo hiệu.
 * Input
 * Param: socket — WebSocket đã upgrade; chưa được gửi event hoặc acknowledgment.
 * Param: state — application ticket consumer và registry của backend instance này.
 * Param: handshake_permit — quota RAII giữ tới khi socket xác thực hoặc handshake bị đóng.
 * Param: active_socket_permit — quota socket toàn instance do callback giữ đến sau khi socket drop.
 * Deadline: một thời điểm tuyệt đối bao trọn receive, consume, register, recheck và acknowledgment.
 * Side effects: consume ticket một lần, thêm/xóa socket local và kiểm tra liveness bằng ping/pong.
 */
async fn handle_socket(
    mut socket: WebSocket,
    state: HttpState,
    handshake_permit: OwnedSemaphorePermit,
    active_socket_permit: &ActiveRealtimeSocketPermit,
) {
    let deadline = time::Instant::now() + FIRST_FRAME_TIMEOUT;
    let binding = match within_handshake_deadline(deadline, async {
        let ticket = match socket.recv().await {
            Some(Ok(Message::Text(ticket))) if valid_ticket_shape(ticket.as_str()) => ticket,
            _ => return None,
        };
        let db_permit = state.realtime.try_admit_handshake_db_check()?;
        let auth = state.auth.clone();
        let consumed = run_handshake_db_operation(deadline, db_permit, async move {
            auth.consume_realtime_ticket(ticket.as_str()).await
        })
        .await?;
        let (binding, db_permit) = consumed;
        let binding = binding.ok()?;
        Some((binding, db_permit))
    })
    .await
    {
        Ok(Some(binding)) if time::Instant::now() < deadline => binding,
        _ => {
            close_with_policy(&mut socket).await;
            return;
        }
    };

    let (binding, db_permit) = binding;
    let session_id = binding.session_id;
    let (connection_id, mut close_receiver) = match within_handshake_deadline(
        deadline,
        state.realtime.register(session_id, active_socket_permit),
    )
    .await
    {
        Ok(registration) => registration,
        Err(_) => {
            close_with_policy(&mut socket).await;
            return;
        }
    };
    if time::Instant::now() >= deadline {
        close_with_policy(&mut socket).await;
        state.realtime.unregister(session_id, connection_id).await;
        return;
    }
    // Đăng ký trước recheck để logout local báo close trong cửa sổ consume→ACK; mọi bước vẫn dùng deadline gốc.
    let auth = state.auth.clone();
    let session_is_active = match run_handshake_db_operation(deadline, db_permit, async move {
        auth.active_realtime_session_for_handshake(session_id).await
    })
    .await
    {
        Some((Ok(is_active), db_permit)) => {
            drop(db_permit);
            time::Instant::now() < deadline && is_active
        }
        Some((Err(_), db_permit)) => {
            drop(db_permit);
            false
        }
        None => false,
    };
    if !session_is_active || close_receiver.try_recv().is_ok() {
        close_with_policy(&mut socket).await;
        state.realtime.unregister(session_id, connection_id).await;
        return;
    }

    // Chưa xác nhận socket nếu deadline chung đã hết hoặc transport không nhận ACK trong cùng ngân sách.
    if !matches!(
        within_handshake_deadline(deadline, socket.send(Message::Text("AUTHENTICATED".into())),)
            .await,
        Ok(Ok(())) if time::Instant::now() < deadline
    ) {
        close_with_policy(&mut socket).await;
        state.realtime.unregister(session_id, connection_id).await;
        return;
    }
    drop(handshake_permit);

    // Không giữ registry lock khi chờ socket hoặc nhận logout signal để worker có thể đóng đồng thời.
    let mut next_ping_at = time::Instant::now() + REALTIME_PING_INTERVAL;
    let mut pending_pong: Option<(Uuid, time::Instant)> = None;
    loop {
        let pong_deadline = pending_pong.as_ref().map(|(_, deadline)| *deadline);
        tokio::select! {
            close_signal = close_receiver.recv() => {
                if close_signal.is_some() {
                    close_with_policy(&mut socket).await;
                }
                break;
            }
            _ = time::sleep_until(next_ping_at), if pending_pong.is_none() => {
                let challenge = Uuid::new_v4();
                let ping_payload = challenge.as_bytes().to_vec().into();
                if !matches!(
                    time::timeout(
                        REALTIME_PING_SEND_TIMEOUT,
                        socket.send(Message::Ping(ping_payload)),
                    ).await,
                    Ok(Ok(()))
                ) {
                    break;
                }
                let sent_at = time::Instant::now();
                pending_pong = Some((challenge, sent_at + REALTIME_PONG_TIMEOUT));
                next_ping_at = sent_at + REALTIME_PING_INTERVAL;
            }
            _ = time::sleep_until(pong_deadline.unwrap_or(next_ping_at)), if pong_deadline.is_some() => {
                // Không giữ slot toàn instance cho transport im lặng; peer phải xác nhận đúng nonce.
                break;
            }
            incoming = socket.recv() => {
                match incoming {
                    Some(Ok(Message::Ping(_))) => {}
                    Some(Ok(Message::Pong(payload))) => {
                        let matching_pong = pending_pong
                            .as_ref()
                            .is_some_and(|(challenge, _)| payload.as_ref() == challenge.as_bytes());
                        if matching_pong {
                            pending_pong = None;
                        }
                    }
                    Some(Ok(Message::Close(_))) => {
                        // Axum/Tungstenite hàng đợi close reply khi nhận frame; lần recv kế tiếp flush reply trước khi drop.
                        let _ = time::timeout(POLICY_CLOSE_TIMEOUT, socket.recv()).await;
                        break;
                    }
                    None | Some(Err(_)) => break,
                    Some(Ok(Message::Text(_))) | Some(Ok(Message::Binary(_))) => {
                        close_with_policy(&mut socket).await;
                        break;
                    }
                }
            }
        }
    }
    state.realtime.unregister(session_id, connection_id).await;
}

/** Thực thi một bước handshake dưới cùng deadline tuyệt đối để thời gian DB không làm mới quota xác thực.
 * Input
 * Param: deadline — thời điểm hết hạn tính từ lúc socket được nâng cấp, dùng chung cho mọi bước.
 * Param: operation — future receive/DB/registry/send đang thuộc một handshake chưa xác thực.
 * Output: kết quả future hoặc `Elapsed` nếu deadline hết trước một lần poll của operation.
 * Errors: caller kiểm tra lại thời điểm completion; mọi ID/handle trả muộn phải được giữ để caller đóng và gỡ registry.
 */
async fn within_handshake_deadline<T>(
    deadline: time::Instant,
    operation: impl Future<Output = T>,
) -> Result<T, time::error::Elapsed> {
    let mut operation = pin!(operation);
    // Tokio cho future ready vượt deadline; gate từng poll rồi giữ output muộn để dọn side effect/handle.
    let bounded_operation = poll_fn(|context| {
        if time::Instant::now() >= deadline {
            return Poll::Pending;
        }
        operation.as_mut().poll(context)
    });
    time::timeout_at(deadline, bounded_operation).await
}

/**
 * Chạy DB ở worker giữ quota tới khi adapter hoàn tất query và đóng checkout tường minh.
 * Input
 * Param: deadline — thời điểm kết thúc handshake tuyệt đối của socket.
 * Param: permit — quota DB phải theo worker tới khi future storage thật sự hoàn tất.
 * Param: operation — future DB sở hữu dữ liệu cần thiết, không mượn state của request.
 * Output: kết quả cùng permit nếu xong trước deadline; None nếu socket hết hạn hoặc worker lỗi.
 * Side effects: quá hạn chỉ ngừng chờ ở socket; worker tiếp tục giữ permit tới khi operation adapter đóng checkout.
 */
async fn run_handshake_db_operation<T, F>(
    deadline: time::Instant,
    permit: OwnedSemaphorePermit,
    operation: F,
) -> Option<(T, OwnedSemaphorePermit)>
where
    T: Send + 'static,
    F: Future<Output = T> + Send + 'static,
{
    if time::Instant::now() >= deadline {
        return None;
    }

    let worker = tokio::spawn(async move {
        let result = operation.await;
        (result, permit)
    });

    let (result, permit) = time::timeout_at(deadline, worker).await.ok()?.ok()?;
    (time::Instant::now() < deadline).then_some((result, permit))
}

/**
 * Từ chối frame khác ticket lowercase64-hex trước lookup digest để chặn input tùy ý ở boundary.
 * Input
 * Param: ticket — text frame đầu tiên, chỉ được giữ tạm trong RAM.
 * Output: true đúng khi chuỗi byte có độ dài và alphabet theo contract ticket.
 */
fn valid_ticket_shape(ticket: &str) -> bool {
    ticket.len() == MAX_TICKET_FRAME_BYTES
        && ticket
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/**
 * Hoàn tất close policy/reason cố định để từ chối handshake hoặc session đã mất hiệu lực mà không bỏ phản hồi peer.
 * Input
 * Param: socket — WebSocket cục bộ đang thuộc handler, không ghi frame lý do từ request.
 * Side effects: gửi close code 1008 và chờ phản hồi peer trong tổng thời hạn một giây; transport lỗi hoặc quá hạn thì được drop.
 */
async fn close_with_policy(socket: &mut WebSocket) {
    let _ = time::timeout(POLICY_CLOSE_TIMEOUT, async {
        if socket
            .send(Message::Close(Some(CloseFrame {
                code: 1008,
                reason: AUTHENTICATION_CLOSE_REASON.into(),
            })))
            .await
            .is_err()
        {
            return;
        }
        loop {
            match socket.recv().await {
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => return,
                Some(Ok(_)) => {}
            }
        }
    })
    .await;
}

#[cfg(test)]
mod tests {
    use super::{
        MAX_ACTIVE_REALTIME_SOCKETS, MAX_CONCURRENT_HANDSHAKE_DB_CHECKS,
        MAX_PENDING_REALTIME_HANDSHAKES, RealtimeHub, handshake_db_capacity,
        reconcile_session_check, run_handshake_db_operation, valid_ticket_shape,
        within_handshake_deadline,
    };
    use iot_application::{error::ApplicationError, ports::RealtimeSessionStore};
    use iot_postgres::PgIdentityStore;
    use serde::Deserialize;
    use sqlx::{
        ConnectOptions,
        postgres::{PgConnectOptions, PgPoolOptions, PgSslMode},
    };
    use std::time::Duration;
    use std::{collections::HashSet, io::Read, sync::Arc};
    use tokio::sync::Semaphore;
    use tokio::time;
    use uuid::Uuid;

    /** Cấu hình test SQLx chỉ được Auth Lab chuyển qua stdin, không ghi vào argv hoặc bằng chứng. */
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct SqlxCheckoutProbeConfig {
        database_port: u16,
        database_password: String,
    }

    /** Probe giữ một checkout giả đến khi test cho phép close, dùng để mô phỏng I/O cleanup bị trễ. */
    struct CheckoutCleanupProbe {
        close_started: tokio::sync::oneshot::Sender<()>,
        close_release: tokio::sync::oneshot::Receiver<()>,
        close_finished: tokio::sync::oneshot::Sender<()>,
    }

    impl CheckoutCleanupProbe {
        /** Đợi tín hiệu đóng rồi báo hoàn tất để xác nhận quota không đi theo timer phỏng đoán. */
        async fn close(self) {
            let _ = self.close_started.send(());
            let _ = self.close_release.await;
            let _ = self.close_finished.send(());
        }
    }

    /** Quota DB realtime không chiếm connection cuối dành cho login/logout và reconciler. */
    #[test]
    fn handshake_database_budget_preserves_one_pool_connection() {
        assert_eq!(handshake_db_capacity(0), 0);
        assert_eq!(handshake_db_capacity(1), 0);
        assert_eq!(handshake_db_capacity(2), 1);
        assert_eq!(handshake_db_capacity(8), MAX_CONCURRENT_HANDSHAKE_DB_CHECKS);
    }

    /** Admission socket trước upgrade phải có giới hạn và nhả slot khi handshake kết thúc. */
    #[test]
    fn pending_handshake_admission_is_bounded_and_released() {
        let hub = RealtimeHub::with_handshake_db_capacity(MAX_CONCURRENT_HANDSHAKE_DB_CHECKS);
        let mut permits: Vec<_> = (0..MAX_PENDING_REALTIME_HANDSHAKES)
            .map(|_| {
                hub.try_admit_handshake()
                    .expect("slot trong giới hạn phải cấp được")
            })
            .collect();

        assert!(hub.try_admit_handshake().is_none());
        drop(permits.pop());
        assert!(hub.try_admit_handshake().is_some());
    }

    /** Socket active vượt cap phải bị chặn; close-signal chưa nhả slot trước khi owner handler thoát. */
    #[tokio::test]
    async fn active_socket_admission_is_bounded_until_handler_owner_exits() {
        let hub = RealtimeHub::with_handshake_db_capacity(MAX_CONCURRENT_HANDSHAKE_DB_CHECKS);
        let permits: Vec<_> = (0..MAX_ACTIVE_REALTIME_SOCKETS)
            .map(|_| {
                hub.try_admit_active_socket()
                    .expect("socket slot trong giới hạn phải cấp được")
            })
            .collect();

        assert!(hub.try_admit_active_socket().is_none());
        let session_id = Uuid::new_v4();
        let (connection_id, mut close_receiver) = hub.register(session_id, &permits[0]).await;
        assert_eq!(hub.close_session(session_id).await, 1);
        assert_eq!(close_receiver.recv().await, Some(()));
        hub.unregister(session_id, connection_id).await;
        assert!(hub.try_admit_active_socket().is_none());

        drop(permits);
        let recovered: Vec<_> = (0..MAX_ACTIVE_REALTIME_SOCKETS)
            .map(|_| {
                hub.try_admit_active_socket()
                    .expect("slot phải được khôi phục sau khi owner handler kết thúc")
            })
            .collect();
        assert!(hub.try_admit_active_socket().is_none());
        drop(recovered);
    }

    /** Admission DB chỉ cho phép số truy vấn ticket hữu hạn và nhả slot sau khi đối soát. */
    #[test]
    fn handshake_database_admission_is_bounded_and_released() {
        let hub = RealtimeHub::with_handshake_db_capacity(MAX_CONCURRENT_HANDSHAKE_DB_CHECKS);
        let mut permits: Vec<_> = (0..MAX_CONCURRENT_HANDSHAKE_DB_CHECKS)
            .map(|_| {
                hub.try_admit_handshake_db_check()
                    .expect("slot DB trong giới hạn phải cấp được")
            })
            .collect();

        assert!(hub.try_admit_handshake_db_check().is_none());
        drop(permits.pop());
        assert!(hub.try_admit_handshake_db_check().is_some());
    }

    /** Caller timeout phải giữ quota khi checkout close bị trễ và chỉ trả sau khi close hoàn tất. */
    #[tokio::test]
    async fn timed_out_handshake_discards_checkout_before_releasing_db_admission() {
        let hub = RealtimeHub::with_handshake_db_capacity(1);
        let permit = hub
            .try_admit_handshake_db_check()
            .expect("slot DB phải cấp được trước test");
        let (checkout_close_started, close_started) = tokio::sync::oneshot::channel();
        let (finish_close, close_release) = tokio::sync::oneshot::channel();
        let (checkout_close_finished, close_finished) = tokio::sync::oneshot::channel();
        let checkout = CheckoutCleanupProbe {
            close_started: checkout_close_started,
            close_release,
            close_finished: checkout_close_finished,
        };
        let operation = async move {
            let query =
                time::timeout(Duration::from_millis(40), std::future::pending::<u8>()).await;
            assert!(query.is_err(), "query mô phỏng phải qua deadline nghiệp vụ");
            checkout.close().await;
            23_u8
        };
        let caller_result = super::run_handshake_db_operation(
            time::Instant::now() + Duration::from_millis(20),
            permit,
            operation,
        )
        .await;
        assert!(
            caller_result.is_none(),
            "socket phải ngừng chờ đúng deadline"
        );

        time::timeout(Duration::from_secs(1), close_started)
            .await
            .expect("worker detached phải tiếp tục tới bước close checkout")
            .expect("probe phải quan sát được cleanup checkout");
        assert!(hub.try_admit_handshake_db_check().is_none());
        // Cố ý giữ close lâu hơn grace cũ của regression để bắt mọi release dựa trên sleep cố định.
        time::sleep(Duration::from_millis(350)).await;
        assert!(hub.try_admit_handshake_db_check().is_none());
        finish_close
            .send(())
            .expect("close checkout phải được tiếp tục sau khi bắt đầu");
        time::timeout(Duration::from_secs(1), close_finished)
            .await
            .expect("close checkout phải kết thúc trong giới hạn")
            .expect("probe phải xác nhận slot đã đóng");
        let recovered_permit = time::timeout(Duration::from_secs(1), async {
            loop {
                if let Some(permit) = hub.try_admit_handshake_db_check() {
                    break permit;
                }
                time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("quota phải phục hồi sau khi operation báo close checkout hoàn tất");
        drop(recovered_permit);
    }

    /**
     * Dùng PostgreSQL/SQLx thật để xác nhận query bị hủy và adapter production đóng checkout lỗi trước khi trả quota.
     * Input: cấu hình cổng/credential CSPRNG do Auth Lab đọc vào stdin; không chấp nhận config từ argv/env.
     * Output: test đạt khi query bị hủy an toàn, close tường minh giải phóng pool trước permit và handshake tiếp theo thành công.
     * Side effects: mở pool một connection, hủy `pg_sleep` chỉ-đọc, kiểm adapter khi ACL bị từ chối và giữ worker qua gate; không sửa dữ liệu.
     */
    #[tokio::test]
    #[ignore = "cần Auth Lab truyền role PostgreSQL dùng riêng qua stdin"]
    async fn sqlx_canceled_query_closes_checkout_before_permit_release() {
        let mut raw_config = String::new();
        std::io::stdin()
            .read_to_string(&mut raw_config)
            .expect("runner phải cấp cấu hình qua stdin");
        let config = serde_json::from_str::<SqlxCheckoutProbeConfig>(&raw_config)
            .unwrap_or_else(|_| panic!("cấu hình Auth Lab của test không hợp lệ"));
        drop(raw_config);
        assert!(
            (1024..=65535).contains(&config.database_port),
            "cổng PostgreSQL phải thuộc dải local hợp lệ"
        );
        assert_eq!(
            config.database_password.len(),
            64,
            "credential fixture phải là token hex CSPRNG đủ độ dài"
        );
        assert!(
            config
                .database_password
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        );
        // Marker cố định giúp runner xác định giai đoạn lỗi mà không in cấu hình hoặc lỗi DB thô.
        println!("REALTIME_SQLX_STAGE_CONFIG_VALID");

        let options = PgConnectOptions::new_without_pgpass()
            .host("127.0.0.1")
            .port(config.database_port)
            .username("iot_repository_probe")
            .password(&config.database_password)
            .database("iot_platform_lab")
            .ssl_mode(PgSslMode::Disable)
            .application_name("tn002-realtime-cancel-test")
            .disable_statement_logging();
        let pool = PgPoolOptions::new()
            .max_connections(1)
            .acquire_timeout(Duration::from_secs(3))
            .connect_with(options)
            .await
            .expect("pool test chỉ được nối Auth Lab local");
        drop(config);
        println!("REALTIME_SQLX_STAGE_POOL_CONNECTED");

        let handshake_capacity = Arc::new(Semaphore::new(1));
        let permit = Arc::clone(&handshake_capacity)
            .try_acquire_owned()
            .expect("test phải giữ quota trước khi query bắt đầu");
        let worker_pool = pool.clone();
        let (query_started_sender, query_started_receiver) = tokio::sync::oneshot::channel();
        let (close_started_sender, close_started_receiver) = tokio::sync::oneshot::channel();
        let (allow_close_sender, allow_close_receiver) = tokio::sync::oneshot::channel();
        let (checkout_closed_sender, checkout_closed_receiver) = tokio::sync::oneshot::channel();
        let (allow_worker_finish_sender, allow_worker_finish_receiver) =
            tokio::sync::oneshot::channel();
        let worker = tokio::spawn(async move {
            let operation = async move {
                let mut connection = worker_pool
                    .acquire()
                    .await
                    .expect("checkout PostgreSQL phải sẵn sàng trước query timeout");
                let _ = query_started_sender.send(());
                println!("REALTIME_SQLX_STAGE_QUERY_STARTED");
                // Timeout chỉ hủy query borrow; checkout nằm ngoài future bị hủy để có thể đóng tường minh.
                let query_result = time::timeout(
                    Duration::from_millis(250),
                    sqlx::query("SELECT pg_sleep(30)").execute(&mut *connection),
                )
                .await;
                assert!(
                    query_result.is_err(),
                    "pg_sleep phải vượt query timeout test"
                );
                println!("REALTIME_SQLX_STAGE_QUERY_CANCELED");
                let _ = close_started_sender.send(());
                println!("REALTIME_SQLX_STAGE_CHECKOUT_CLOSE_PENDING");
                allow_close_receiver
                    .await
                    .expect("test phải cho phép explicit close tiếp tục");
                time::timeout(Duration::from_secs(2), connection.close())
                    .await
                    .expect("explicit close phải có giới hạn")
                    .expect("SQLx phải đóng checkout PostgreSQL bị hủy");
                let _ = checkout_closed_sender.send(());
                println!("REALTIME_SQLX_STAGE_CHECKOUT_CLOSED");
                allow_worker_finish_receiver
                    .await
                    .expect("test phải cho worker hoàn tất sau khi xác minh pool");
                23_u8
            };

            run_handshake_db_operation(
                time::Instant::now() + Duration::from_millis(100),
                permit,
                operation,
            )
            .await
        });

        time::timeout(Duration::from_secs(2), query_started_receiver)
            .await
            .expect("checkout phải được mở trước query timeout")
            .expect("worker phải báo khi query bắt đầu");
        let caller_result = time::timeout(Duration::from_secs(2), worker)
            .await
            .expect("caller phải ngừng chờ sau socket deadline")
            .expect("caller task không được panic");
        assert!(caller_result.is_none());
        println!("REALTIME_SQLX_STAGE_CALLER_DETACHED");
        assert!(handshake_capacity.try_acquire().is_err());

        time::timeout(Duration::from_secs(2), close_started_receiver)
            .await
            .expect("query timeout phải chuyển qua bước explicit close")
            .expect("operation phải báo trạng thái close pending");
        assert_eq!(
            pool.size(),
            1,
            "checkout vẫn phải thuộc worker trong lúc close chờ"
        );
        assert!(handshake_capacity.try_acquire().is_err());
        // Chặn close đủ lâu để chứng minh permit/pool slot không phụ thuộc timer cleanup nền.
        time::sleep(Duration::from_millis(350)).await;
        assert_eq!(
            pool.size(),
            1,
            "checkout không được trả trước explicit close"
        );
        assert!(handshake_capacity.try_acquire().is_err());
        allow_close_sender
            .send(())
            .expect("worker close phải còn được giữ bởi test gate");
        time::timeout(Duration::from_secs(2), checkout_closed_receiver)
            .await
            .expect("SQLx explicit close phải hoàn tất trong giới hạn")
            .expect("worker phải xác nhận checkout đã đóng");
        assert_eq!(pool.size(), 0, "SQLx close phải giải phóng pool slot");
        let recovered_query = time::timeout(
            Duration::from_secs(1),
            sqlx::query_scalar::<_, i32>("SELECT 1").fetch_one(&pool),
        )
        .await
        .expect("pool phải nhận query độc lập sau khi checkout lỗi bị loại")
        .expect("query phục hồi chỉ-đọc phải thành công");
        assert_eq!(recovered_query, 1);
        println!("REALTIME_SQLX_STAGE_POOL_RECOVERED");
        assert!(
            handshake_capacity.try_acquire().is_err(),
            "quota route phải còn giữ cho tới khi worker hoàn tất sau explicit close"
        );
        println!("REALTIME_SQLX_STAGE_PERMIT_HELD_AFTER_RECOVERY");
        allow_worker_finish_sender
            .send(())
            .expect("worker phải còn giữ permit trước khi operation hoàn tất");
        let recovered_permit = time::timeout(Duration::from_secs(2), async {
            loop {
                if let Ok(permit) = Arc::clone(&handshake_capacity).try_acquire_owned() {
                    break permit;
                }
                time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("route quota phải được trả sau khi checkout close hoàn tất");
        println!("REALTIME_SQLX_STAGE_PERMIT_REACQUIRED");
        let recovered_pool = pool.clone();
        let recovered_handshake = run_handshake_db_operation(
            time::Instant::now() + Duration::from_secs(2),
            recovered_permit,
            async move {
                sqlx::query_scalar::<_, i32>("SELECT 1")
                    .fetch_one(&recovered_pool)
                    .await
                    .expect("handshake khỏe mạnh tiếp theo phải dùng được pool")
            },
        )
        .await
        .expect("handshake khỏe mạnh tiếp theo phải được admit");
        assert_eq!(recovered_handshake.0, 1);
        println!("REALTIME_SQLX_STAGE_FOLLOWUP_HANDSHAKE_PASSED");

        let adapter_capacity = Arc::new(Semaphore::new(1));
        let permit = Arc::clone(&adapter_capacity)
            .try_acquire_owned()
            .expect("test adapter phải giữ quota trước khi query bắt đầu");
        let adapter_store = PgIdentityStore::new(pool.clone());
        let (adapter_finished_sender, adapter_finished_receiver) = tokio::sync::oneshot::channel();
        let (allow_adapter_finish_sender, allow_adapter_finish_receiver) =
            tokio::sync::oneshot::channel();
        let adapter_worker = tokio::spawn(async move {
            let operation = async move {
                let adapter_result = adapter_store
                    .active_realtime_session_for_handshake(Uuid::new_v4())
                    .await;
                assert!(
                    matches!(adapter_result, Err(ApplicationError::Unavailable)),
                    "session SELECT permission denial phải fail-closed qua adapter"
                );
                let _ = adapter_finished_sender.send(());
                allow_adapter_finish_receiver
                    .await
                    .expect("test phải giữ operation sau khi adapter đã đóng checkout");
                29_u8
            };

            run_handshake_db_operation(
                time::Instant::now() + Duration::from_millis(100),
                permit,
                operation,
            )
            .await
        });

        let adapter_caller_result = time::timeout(Duration::from_secs(2), adapter_worker)
            .await
            .expect("socket caller phải dừng chờ sau deadline")
            .expect("adapter worker không được panic");
        assert!(adapter_caller_result.is_none());
        println!("REALTIME_SQLX_STAGE_ADAPTER_CALLER_DETACHED");
        time::timeout(Duration::from_secs(2), adapter_finished_receiver)
            .await
            .expect("adapter phải trả lỗi sau khi hoàn tất rollback và close")
            .expect("probe phải xác nhận adapter đã trả");
        assert_eq!(
            pool.size(),
            0,
            "adapter explicit close phải loại checkout khỏi pool trước khi trả"
        );
        assert!(
            adapter_capacity.try_acquire().is_err(),
            "worker phải giữ quota sau khi adapter đã đóng checkout"
        );
        println!("REALTIME_SQLX_STAGE_ADAPTER_CHECKOUT_CLOSED");
        let adapter_recovered_query = time::timeout(
            Duration::from_secs(1),
            sqlx::query_scalar::<_, i32>("SELECT 1").fetch_one(&pool),
        )
        .await
        .expect("pool phải cấp connection mới khi worker còn giữ quota")
        .expect("query chỉ-đọc phải phục hồi sau adapter close");
        assert_eq!(adapter_recovered_query, 1);
        println!("REALTIME_SQLX_STAGE_ADAPTER_POOL_RECOVERED");
        allow_adapter_finish_sender
            .send(())
            .expect("worker phải còn chờ gate trước khi nhả quota");
        let adapter_recovered_permit = time::timeout(Duration::from_secs(2), async {
            loop {
                if let Ok(permit) = Arc::clone(&adapter_capacity).try_acquire_owned() {
                    break permit;
                }
                time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("route quota phải được trả sau khi adapter close hoàn tất");
        println!("REALTIME_SQLX_STAGE_ADAPTER_PERMIT_REACQUIRED");
        let adapter_followup = run_handshake_db_operation(
            time::Instant::now() + Duration::from_secs(2),
            adapter_recovered_permit,
            async move {
                sqlx::query_scalar::<_, i32>("SELECT 1")
                    .fetch_one(&pool)
                    .await
                    .expect("handshake DB kế tiếp phải dùng được pool")
            },
        )
        .await
        .expect("handshake tiếp theo phải được nhận quota");
        assert_eq!(adapter_followup.0, 1);
        println!("REALTIME_SQLX_STAGE_ADAPTER_PROBE_PASSED");
    }

    /** Kiểm ticket chỉ chấp nhận đúng lowercase 64-hex để frame khác không đi tới ticket digest lookup. */
    #[test]
    fn ticket_shape_accepts_only_lowercase_hex_64_bytes() {
        assert!(valid_ticket_shape(&"a".repeat(64)));
        assert!(!valid_ticket_shape(&"A".repeat(64)));
        assert!(!valid_ticket_shape(&"0".repeat(63)));
        assert!(!valid_ticket_shape(&format!("{}g", "0".repeat(63))));
    }

    /** Kiểm thời hạn tuyệt đối còn hiệu lực sau khi frame đã nhận nhưng storage trì hoãn consume ticket. */
    #[tokio::test]
    async fn first_frame_deadline_includes_delayed_ticket_storage() {
        let deadline = time::Instant::now() + Duration::from_millis(500);
        let received = within_handshake_deadline(deadline, async {
            time::sleep(Duration::from_millis(100)).await;
            true
        })
        .await;
        assert!(received.is_ok());

        let storage = within_handshake_deadline(deadline, async {
            time::sleep(Duration::from_millis(500)).await;
            true
        })
        .await;
        assert!(storage.is_err());
    }

    /** Kiểm deadline đã hết thì không poll future ready và không cấp admission giả cho handshake. */
    #[tokio::test]
    async fn expired_handshake_deadline_rejects_immediately_ready_operations() {
        let deadline = time::Instant::now() - Duration::from_millis(1);
        let result = within_handshake_deadline(deadline, std::future::ready(true)).await;

        assert!(result.is_err());
    }

    /** Giữ registration ID sau scheduler stall để handler có thể gỡ socket đã thêm đúng hạn sát biên. */
    #[tokio::test]
    async fn late_handshake_registration_keeps_handle_for_registry_cleanup() {
        let hub = RealtimeHub::with_handshake_db_capacity(MAX_CONCURRENT_HANDSHAKE_DB_CHECKS);
        let session_id = Uuid::new_v4();
        let active_socket_permit = hub
            .try_admit_active_socket()
            .expect("socket slot phải được giữ trước khi đăng ký");
        let deadline = time::Instant::now() + Duration::from_millis(50);
        let registration = within_handshake_deadline(deadline, async {
            let registration = hub.register(session_id, &active_socket_permit).await;
            std::thread::sleep(Duration::from_millis(75));
            registration
        })
        .await
        .expect("ready registration keeps its handle for caller cleanup");

        assert!(time::Instant::now() >= deadline);
        hub.unregister(session_id, registration.0).await;
        assert!(hub.session_ids().await.is_empty());
    }

    /** Logout/reconcile chỉ đánh thức session được nhắm; socket cùng account ở session khác vẫn mở. */
    #[tokio::test]
    async fn close_stale_sessions_keeps_an_independent_session_registered() {
        let hub = RealtimeHub::with_handshake_db_capacity(MAX_CONCURRENT_HANDSHAKE_DB_CHECKS);
        let revoked_session = Uuid::new_v4();
        let active_session = Uuid::new_v4();
        let late_session = Uuid::new_v4();
        let active_permits: Vec<_> = (0..3)
            .map(|_| {
                hub.try_admit_active_socket()
                    .expect("socket slot phải được giữ trước khi đăng ký")
            })
            .collect();
        let (revoked_connection, mut revoked_receiver) =
            hub.register(revoked_session, &active_permits[0]).await;
        let (active_connection, mut active_receiver) =
            hub.register(active_session, &active_permits[1]).await;
        let (late_connection_id, mut late_receiver) =
            hub.register(late_session, &active_permits[2]).await;

        let checked = HashSet::from([revoked_session, active_session]);
        assert_eq!(
            hub.close_stale_sessions(&checked, &HashSet::from([active_session]))
                .await,
            1
        );
        assert_eq!(revoked_receiver.recv().await, Some(()));
        assert!(active_receiver.try_recv().is_err());
        assert!(late_receiver.try_recv().is_err());
        assert_eq!(hub.session_ids().await.len(), 2);

        hub.unregister(revoked_session, revoked_connection).await;
        hub.unregister(active_session, active_connection).await;
        hub.unregister(late_session, late_connection_id).await;
        assert!(hub.session_ids().await.is_empty());
    }

    /** Bảo đảm truy vấn DB treo phát close cho mọi socket local trong ngân sách fail-closed. */
    #[tokio::test]
    async fn stalled_reconciliation_query_closes_all_local_sockets_within_deadline() {
        let hub = RealtimeHub::with_handshake_db_capacity(MAX_CONCURRENT_HANDSHAKE_DB_CHECKS);
        let first_session = Uuid::new_v4();
        let second_session = Uuid::new_v4();
        let first_active_permit = hub
            .try_admit_active_socket()
            .expect("socket slot phải được giữ trước khi đăng ký");
        let second_active_permit = hub
            .try_admit_active_socket()
            .expect("socket slot phải được giữ trước khi đăng ký");
        let (_, mut first_receiver) = hub.register(first_session, &first_active_permit).await;
        let (_, mut second_receiver) = hub.register(second_session, &second_active_permit).await;
        let checked_sessions = HashSet::from([first_session, second_session]);

        time::timeout(
            Duration::from_secs(4),
            reconcile_session_check(
                &hub,
                &checked_sessions,
                std::future::pending::<Result<HashSet<Uuid>, ()>>(),
            ),
        )
        .await
        .expect("stalled DB check must fail closed within the socket budget");

        assert_eq!(first_receiver.try_recv(), Ok(()));
        assert_eq!(second_receiver.try_recv(), Ok(()));
        assert!(hub.session_ids().await.is_empty());
    }

    /** Logout same instance gỡ và đánh thức mọi socket của đúng phiên theo channel bounded. */
    #[tokio::test]
    async fn close_session_notifies_every_connection_for_only_that_session() {
        let hub = RealtimeHub::with_handshake_db_capacity(MAX_CONCURRENT_HANDSHAKE_DB_CHECKS);
        let target_session = Uuid::new_v4();
        let other_session = Uuid::new_v4();
        let active_permits: Vec<_> = (0..3)
            .map(|_| {
                hub.try_admit_active_socket()
                    .expect("socket slot phải được giữ trước khi đăng ký")
            })
            .collect();
        let (_, mut first) = hub.register(target_session, &active_permits[0]).await;
        let (_, mut second) = hub.register(target_session, &active_permits[1]).await;
        let (_, mut other) = hub.register(other_session, &active_permits[2]).await;

        assert_eq!(hub.close_session(target_session).await, 2);
        assert_eq!(first.recv().await, Some(()));
        assert_eq!(second.recv().await, Some(()));
        assert!(other.try_recv().is_err());
        assert_eq!(hub.session_ids().await, vec![other_session]);
    }
}
