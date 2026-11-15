//! Kênh điều khiển riêng cho kiểm pool exhaustion; không thuộc router sản phẩm.

use super::{ApplicationError, Config};
use axum::Router;
use sqlx::PgPool;
use std::{
    ffi::OsString,
    io::{self, BufRead, Read, Write},
    thread::JoinHandle,
    time::Duration,
};
use tokio::sync::{mpsc, oneshot};

// Factory hiện hành dùng8connection/acquire5s; kiểm lại để harness không che thay đổi policy.
const LEASE_COUNT: u32 = 8;
const ACQUIRE_TIMEOUT: Duration = Duration::from_secs(5);

pub(super) struct InputChannel {
    receiver: mpsc::Receiver<Result<Command, ApplicationError>>,
    reader: JoinHandle<()>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Command {
    Hold,
    CheckHeld,
    Release,
    Stop,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    Ready,
    Held,
    Released,
    Stopped,
}

/**
 * Chỉ nhận opt-in literal từ argv do launcher sở hữu, không đọc environment.
 * Input
 * Param: arguments — tham số riêng của child, không chứa credential.
 * Output: bật mode riêng hoặc lỗi nếu argv ngoài contract.
 */
pub(super) fn enabled(
    mut arguments: impl Iterator<Item = OsString>,
) -> Result<bool, ApplicationError> {
    match (arguments.next(), arguments.next()) {
        (None, None) => Ok(false),
        (Some(argument), None) if argument == "--pool-budget" => Ok(true),
        _ => Err(ApplicationError::InvalidInput),
    }
}

/**
 * Đọc một frame bounded để pipe sống không chờ EOF và không giữ input vô hạn.
 * Input
 * Param: reader — cùng reader được sở hữu suốt config và commands.
 * Param: limit — số byte payload tối đa, không gồm LF/CRLF.
 * Output: payload UTF-8 không newline; Errors: EOF/oversize/encoding sai.
 */
fn read_frame(reader: &mut impl BufRead, limit: usize) -> Result<String, ApplicationError> {
    // Take giới hạn trước allocation; cộng2 chỉ dành LF hoặc CRLF trên pipe Windows.
    let mut bytes = Vec::new();
    reader
        .take((limit + 2) as u64)
        .read_until(b'\n', &mut bytes)
        .map_err(|_| ApplicationError::InvalidInput)?;
    if bytes.pop() != Some(b'\n') {
        return Err(ApplicationError::InvalidInput);
    }
    if bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    if bytes.len() > limit {
        return Err(ApplicationError::InvalidInput);
    }
    String::from_utf8(bytes).map_err(|_| ApplicationError::InvalidInput)
}

impl Phase {
    /**
     * Giới hạn thứ tự fault để không nhả pool sớm rồi ghi evidence thành công.
     * Input
     * Param: self — trạng thái hiện tại của đúng actor.
     * Param: command — literal đã parse từ pipe.
     * Output: trạng thái kế hoặc lỗi cho command lặp/sai thứ tự.
     */
    fn next(self, command: Command) -> Result<Self, ApplicationError> {
        match (self, command) {
            (Self::Ready, Command::Hold) | (Self::Held, Command::CheckHeld) => Ok(Self::Held),
            (Self::Held, Command::Release) => Ok(Self::Released),
            (Self::Ready | Self::Held | Self::Released, Command::Stop) => Ok(Self::Stopped),
            _ => Err(ApplicationError::InvalidInput),
        }
    }
}

/**
 * Parse chỉ bốn literal, không trim input hoặc nhận SQL/địa chỉ từ pipe.
 * Input
 * Param: frame — payload bounded đã bỏ đúng newline.
 * Output: command nội bộ; Errors: mọi giá trị ngoài allowlist đều bị từ chối.
 */
fn parse_command(frame: &str) -> Result<Command, ApplicationError> {
    match frame {
        "HOLD" => Ok(Command::Hold),
        "CHECK_HELD" => Ok(Command::CheckHeld),
        "RELEASE" => Ok(Command::Release),
        "STOP" => Ok(Command::Stop),
        _ => Err(ApplicationError::InvalidInput),
    }
}

/**
 * Một thread sở hữu stdin từ config tới STOP, tránh mất buffered read-ahead hoặc chặn HTTP worker.
 * Output: config trong RAM và ownership reader/channel; Errors: config phải đến trong5s.
 * Side effects: thread sống tới STOP/EOF; failure cuối cùng làm owned child exit1, không giả abort read.
 */
pub(super) async fn read_config() -> Result<(Config, InputChannel), ApplicationError> {
    let (sender, receiver) = mpsc::channel(1);
    let (config_sender, config_receiver) = oneshot::channel();
    let reader = std::thread::Builder::new().name("auth-pool-input".into()).spawn(
        /* Reader không log input; bounded channel giữ tối đa một command chờ actor. */
        move || {
            let mut input = io::stdin().lock();
            let config = read_frame(&mut input, 16_384).and_then(
                /* Param: frame — JSON chỉ RAM; Output: Config deny-unknown-fields hoặc lỗi generic. */
                |frame| serde_json::from_str::<Config>(&frame).map_err(|_| ApplicationError::InvalidInput),
            );
            let valid = config.is_ok();
            if config_sender.send(config).is_err() || !valid { return; }
            loop {
                let command = read_frame(&mut input, 16).and_then(
                    /* Param: frame — literal không newline; Output: command allowlisted. */
                    |frame| parse_command(&frame),
                );
                let terminal = matches!(command, Ok(Command::Stop) | Err(_));
                if sender.blocking_send(command).is_err() || terminal { return; }
            }
        },
    ).map_err(|_| ApplicationError::Unavailable)?;
    let config = tokio::time::timeout(Duration::from_secs(5), config_receiver)
        .await
        .map_err(|_| ApplicationError::InvalidInput)?
        .map_err(|_| ApplicationError::InvalidInput)??;
    Ok((config, InputChannel { receiver, reader }))
}

/**
 * Kiểm bằng giá trị pool thật để partial acquire/closed pool không bị gọi là exhaustion8.
 * Input
 * Param: pool — chính pool clone vào `HttpState`, không tạo pool mới.
 * Param: held — số owned leases đang còn trong vector actor.
 * Output: lỗi nếu factory hoặc snapshot không còn đúng8held/8size/0idle/open.
 */
fn require_held(pool: &PgPool, held: usize) -> Result<(), ApplicationError> {
    if held != LEASE_COUNT as usize
        || pool.is_closed()
        || pool.size() != LEASE_COUNT
        || pool.num_idle() != 0
        || pool.options().get_max_connections() != LEASE_COUNT
        || pool.options().get_acquire_timeout() != ACQUIRE_TIMEOUT
    {
        return Err(ApplicationError::Unavailable);
    }
    Ok(())
}

/**
 * Flush duy nhất marker cố định để parent không chờ buffer stdout hoặc nhận dữ liệu nhạy cảm.
 * Input
 * Param: marker — literal do actor chọn, không truyền input/config.
 * Errors: pipe lỗi phải FAIL child thay vì tiếp tục mà parent mất quyền quan sát.
 */
fn acknowledge(marker: &str) -> Result<(), ApplicationError> {
    let mut output = io::stdout().lock();
    writeln!(output, "{marker}")
        .and_then(
            /* Output: marker đã tới pipe trước khi actor nhận command tiếp. */
            |()| output.flush(),
        )
        .map_err(|_| ApplicationError::Unavailable)
}

/**
 * Giữ cùng8leases xuyên hai HTTP windows, chỉ RELEASE rõ ràng mới cho pool phục hồi.
 * Input
 * Param: pool — cùng pool đã cấp router, factory8/acquire5s giữ nguyên.
 * Param: receiver — command bounded từ owned stdin reader.
 * Param: server — handle server thật để không ACK nếu server đã chết.
 * Output: STOP hợp lệ; Errors: idle30s, acquire10s, sai thứ tự/proof hoặc server chết đều FAIL.
 */
async fn control(
    pool: &PgPool,
    receiver: &mut mpsc::Receiver<Result<Command, ApplicationError>>,
    server: &tokio::task::JoinHandle<Result<(), std::io::Error>>,
) -> Result<(), ApplicationError> {
    let mut phase = Phase::Ready;
    let mut leases = Vec::new();
    loop {
        if server.is_finished() {
            return Err(ApplicationError::Unavailable);
        }
        let command = tokio::time::timeout(Duration::from_secs(30), receiver.recv())
            .await
            .map_err(|_| ApplicationError::Unavailable)?
            .ok_or(ApplicationError::InvalidInput)??;
        let next = phase.next(command)?;
        match command {
            Command::Hold => {
                // Một total deadline cho cả8acquire; vector RAII nhả partial leases nếu bất kỳ acquire lỗi.
                tokio::time::timeout(Duration::from_secs(10), async {
                    for _ in 0..LEASE_COUNT {
                        leases.push(
                            pool.acquire()
                                .await
                                .map_err(|_| ApplicationError::Unavailable)?,
                        );
                    }
                    Ok::<(), ApplicationError>(())
                })
                .await
                .map_err(|_| ApplicationError::Unavailable)??;
                require_held(pool, leases.len())?;
                acknowledge("POOL_HELD|8")?;
            }
            Command::CheckHeld => {
                require_held(pool, leases.len())?;
                acknowledge("POOL_STILL_HELD|8")?;
            }
            Command::Release => {
                require_held(pool, leases.len())?;
                leases.clear();
                acknowledge("POOL_RELEASED|8")?;
            }
            Command::Stop => return Ok(()), // Drop leases trước pool.close kể cả STOP ở Held.
        }
        phase = next;
    }
}

/**
 * Chạy real TCP router với private stdin actor; graceful proof chỉ sau reader/server/pool đều dừng sạch.
 * Input
 * Param: listener — listener loopback bind trước seed, thuộc đúng child.
 * Param: router — auth router thật kèm recorder riêng, không thêm fault HTTP endpoint.
 * Param: pool — cùng pool dùng bởi `HttpState` và holder vector.
 * Param: input — quyền sở hữu reader và channel, không detach task khi success.
 * Output: exit0 sau STOPPED; Errors: mọi failure giữ nonzero để launcher thu hồi/reap trước DB cleanup.
 */
pub(super) async fn serve(
    listener: tokio::net::TcpListener,
    router: Router,
    pool: PgPool,
    input: InputChannel,
) -> Result<(), ApplicationError> {
    let (shutdown_sender, shutdown_receiver) = oneshot::channel();
    let mut server = tokio::spawn(
        /* Owned server dùng chính router; shutdown signal chỉ cleanup, không gây pool fault. */
        async move {
            axum::serve(listener, router)
                .with_graceful_shutdown(
                    /* Đợi capability nội bộ, không thêm public control route. */
                    async move {
                        let _ = shutdown_receiver.await;
                    },
                )
                .await
        },
    );
    let InputChannel {
        mut receiver,
        reader,
    } = input;
    let result = control(&pool, &mut receiver, &server).await;
    drop(receiver); // Mở lối thoát cho blocking_send trước khi chờ reader trên mọi failure.
    let _ = shutdown_sender.send(());
    let shutdown = tokio::time::timeout(Duration::from_secs(5), async {
        // Không join thread đang blocked read; STOP terminal bảo đảm reader không đọc thêm frame.
        while !reader.is_finished() {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        reader.join().map_err(|_| ApplicationError::Unavailable)?;
        let response = (&mut server)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        pool.close().await;
        if !pool.is_closed() || pool.size() != 0 {
            return Err(ApplicationError::Unavailable);
        }
        response.map_err(|_| ApplicationError::Unavailable)
    })
    .await;
    if !server.is_finished() {
        server.abort();
        let _ = server.await;
    }
    shutdown.map_err(|_| ApplicationError::Unavailable)??;
    result?;
    acknowledge("POOL_STOPPED")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    /// Normal argv giữ mode tắt; chỉ một literal opt-in hợp lệ, không nhận giá trị tùy ý.
    #[test]
    fn mode_is_default_off_and_rejects_unknown_arguments() {
        assert!(!enabled(std::iter::empty()).unwrap());
        assert!(enabled([OsString::from("--pool-budget")].into_iter()).unwrap());
        assert!(enabled([OsString::from("--other")].into_iter()).is_err());
        assert!(enabled(vec![OsString::from("--pool-budget"); 2].into_iter()).is_err());
    }

    /// Một reader giữ read-ahead qua config/command và nhận newline Windows mà không trim input khác.
    #[test]
    fn frames_keep_buffered_following_commands() {
        let mut reader = Cursor::new(b"{}\r\nHOLD\nSTOP\r\n");
        assert_eq!(read_frame(&mut reader, 16).unwrap(), "{}");
        assert_eq!(read_frame(&mut reader, 16).unwrap(), "HOLD");
        assert_eq!(read_frame(&mut reader, 16).unwrap(), "STOP");
        assert!(read_frame(&mut reader, 16).is_err());
    }

    /// Oversize, EOF giữa record và UTF-8 lỗi phải dừng mode, không bị hiểu thành command hợp lệ.
    #[test]
    fn invalid_frames_fail_closed() {
        for bytes in [b"HOLD".as_slice(), b"12345678901234567\n", b"\xff\n"] {
            assert!(read_frame(&mut Cursor::new(bytes), 16).is_err());
        }
        assert_eq!(
            read_frame(&mut Cursor::new(b"1234567890123456\n"), 16).unwrap(),
            "1234567890123456"
        );
    }

    /// Chỉ giữ một lần, proof khi held và release sau đó; STOP vẫn dọn được từ mọi phase sống.
    #[test]
    fn phase_order_rejects_early_or_duplicate_release() {
        assert_eq!(Phase::Ready.next(Command::Hold).unwrap(), Phase::Held);
        assert_eq!(Phase::Held.next(Command::CheckHeld).unwrap(), Phase::Held);
        assert_eq!(Phase::Held.next(Command::Release).unwrap(), Phase::Released);
        for phase in [Phase::Ready, Phase::Held, Phase::Released] {
            assert_eq!(phase.next(Command::Stop).unwrap(), Phase::Stopped);
        }
        for (phase, command) in [
            (Phase::Ready, Command::Release),
            (Phase::Ready, Command::CheckHeld),
            (Phase::Held, Command::Hold),
            (Phase::Released, Command::Hold),
            (Phase::Released, Command::Release),
            (Phase::Released, Command::CheckHeld),
            (Phase::Stopped, Command::Stop),
        ] {
            assert!(phase.next(command).is_err());
        }
    }

    /// Chỉ bốn literal đúng byte mới cấp command; không trim khoảng trắng hoặc nhận prefix/suffix tùy ý.
    #[test]
    fn commands_require_exact_literals() {
        for (frame, expected) in [
            ("HOLD", Command::Hold),
            ("CHECK_HELD", Command::CheckHeld),
            ("RELEASE", Command::Release),
            ("STOP", Command::Stop),
        ] {
            assert_eq!(parse_command(frame).unwrap(), expected);
        }
        for frame in [
            "",
            "hold",
            " HOLD",
            "HOLD ",
            "STOP\r",
            "STOP\n",
            "STOP\0",
            "STOP_EXTRA",
        ] {
            assert!(parse_command(frame).is_err());
        }
    }

    /// Frame quá dài phải bị chặn trước khi đọc tới newline xa; biên LF/CRLF vẫn giữ command kế tiếp.
    #[test]
    fn frame_limits_bound_consumption_before_newline() {
        for limit in [16, 16_384] {
            // Dòng dài hơn gấp đôi giới hạn bắt regression đọc hết record rồi mới kiểm kích thước.
            let mut oversized = vec![b'x'; limit * 2];
            oversized.push(b'\n');
            let mut reader = Cursor::new(oversized);
            assert!(read_frame(&mut reader, limit).is_err());
            assert!(reader.position() <= u64::try_from(limit + 2).unwrap());

            // Payload đúng biên cộng CRLF không được ăn mất STOP đã buffered ở frame tiếp theo.
            let mut bounded = vec![b'x'; limit];
            bounded.extend_from_slice(b"\r\nSTOP\n");
            let mut reader = Cursor::new(bounded);
            assert_eq!(read_frame(&mut reader, limit).unwrap(), "x".repeat(limit));
            assert_eq!(read_frame(&mut reader, 16).unwrap(), "STOP");
        }
    }
}
