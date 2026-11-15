//! Hash có giới hạn tài nguyên và capability ngẫu nhiên; không có khóa hardcode.

use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier, password_hash::SaltString};
use hmac::{Hmac, Mac};
use iot_application::auth_diagnostics::{
    AuthDiagnostics, AuthTimingOutcome, AuthTimingSpan, AuthTimingStage,
};
use iot_application::{error::ApplicationError, ports::IdentitySecurity};
use iot_domain::identity::SecretString;
use rand::{RngCore, rngs::OsRng};
use sha2::{Digest, Sha256};
use std::{sync::Arc, time::Duration};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

/// Sinh256 bit entropy bằng OS CSPRNG; core chỉ nhận `SecretString`, không biết RNG implementation.
#[must_use]
pub fn generate_token() -> SecretString {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut bytes = [0_u8; 32];
    OsRng.fill_bytes(&mut bytes);
    // Hex giữ đủ256 bit entropy; chỉ mã hóa byte ngẫu nhiên, không thay bằng UUID/PRNG thời gian.
    SecretString::new(
        bytes
            .iter()
            .flat_map(|byte| {
                [
                    char::from(HEX[usize::from(byte >> 4)]),
                    char::from(HEX[usize::from(byte & 15)]),
                ]
            })
            .collect(),
    )
}

/// Password hasher dùng hai slot; permit sống trong blocking task kể cả caller bị cancel.
#[derive(Clone)]
pub struct PasswordService {
    slots: Arc<Semaphore>,
    diagnostics: Option<Arc<dyn AuthDiagnostics>>,
}

impl Default for PasswordService {
    /// Giới hạn hai phép Argon2id đồng thời cho `PoC`, tránh blocking pool tăng RAM vô hạn.
    fn default() -> Self {
        Self {
            slots: Arc::new(Semaphore::new(2)),
            diagnostics: None,
        }
    }
}

impl PasswordService {
    /**
     * Nhận observer do composition cấp, giữ nguyên semaphore/policy của service hiện hành.
     * Input
     * Param: `diagnostics` — sink chỉ nhận stage/outcome/duration, không nhận credential.
     * Output: service dùng chung slot và observer qua các clone; mặc định constructor vẫn disabled.
     */
    #[must_use]
    pub fn with_diagnostics(mut self, diagnostics: Arc<dyn AuthDiagnostics>) -> Self {
        self.diagnostics = Some(diagnostics);
        self
    }

    /**
     * Chờ slot tối đa5s và chuyển guard sang hàng đợi blocking trước khi kết thúc queue guard.
     * Output: permit và guard được worker sở hữu, không có khoảng trống `active_spans` giữa hai stage.
     * Errors: queue timeout/semaphore đóng trả unavailable như policy hiện có.
     */
    async fn prepare_worker(
        &self,
    ) -> Result<(OwnedSemaphorePermit, AuthTimingSpan), ApplicationError> {
        let queue = AuthTimingSpan::start(self.diagnostics.as_ref(), AuthTimingStage::HashQueue);
        let acquired =
            tokio::time::timeout(Duration::from_secs(5), self.slots.clone().acquire_owned()).await;
        if let Ok(Ok(permit)) = acquired {
            // Giữ liên tục span active để end_window không che worker chưa bắt đầu.
            let blocking =
                AuthTimingSpan::start(self.diagnostics.as_ref(), AuthTimingStage::BlockingQueue);
            queue.finish(AuthTimingOutcome::Completed);
            Ok((permit, blocking))
        } else {
            queue.finish(AuthTimingOutcome::Error);
            Err(ApplicationError::Unavailable)
        }
    }

    /**
     * Băm Argon2id ngoài executor I/O với salt riêng; use case vẫn quyết định phạm vi transaction.
     * Input
     * Param: `password` — mật khẩu đã validate, được chuyển quyền sở hữu vào blocking task.
     * Output: PHC verifier; Errors: unavailable khi queue quá 5 giây hoặc hasher lỗi.
     * # Errors
     * Trả lỗi từ chối hoặc lỗi đã mô tả ở trên; không chứa dữ liệu nhạy cảm.
     */
    pub async fn hash(&self, password: String) -> Result<String, ApplicationError> {
        let (permit, blocking) = self.prepare_worker().await?;
        let diagnostics = self.diagnostics.clone();
        // Permit nằm trong closure để timeout/cancel không giải phóng sớm ngân sách RAM của Argon2.
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            // Work bắt đầu trong blocking thread; guard mới được mở trước khi kết thúc queue guard.
            let work = AuthTimingSpan::start(diagnostics.as_ref(), AuthTimingStage::HashWork);
            blocking.finish(AuthTimingOutcome::Completed);
            let result = Argon2::default()
                .hash_password(password.as_bytes(), &SaltString::generate(&mut OsRng))
                .map(
                    // Chuyển verifier đã băm sang PHC để lưu; không log hoặc serialize password đầu vào.
                    |hash| hash.to_string(),
                )
                .map_err(hash_unavailable);
            work.finish(if result.is_ok() {
                AuthTimingOutcome::Completed
            } else {
                AuthTimingOutcome::Error
            });
            result
        })
        .await
        .map_err(hash_unavailable)?
    }

    /**
     * Kiểm credential bằng PHC đã chọn dưới fence, phân biệt sai password với verifier hỏng.
     * Input
     * Param: `password` — input nguyên bản; không trim hoặc đổi Unicode.
     * Param: `verifier` — PHC từ storage tin cậy hoặc dummy verifier cùng chi phí.
     * Output: đúng/sai; Errors: unavailable khi storage verifier hỏng hoặc hết budget.
     * # Errors
     * Trả lỗi từ chối hoặc lỗi đã mô tả ở trên; không chứa dữ liệu nhạy cảm.
     */
    pub async fn verify(
        &self,
        password: String,
        verifier: String,
    ) -> Result<bool, ApplicationError> {
        let (permit, blocking) = self.prepare_worker().await?;
        let diagnostics = self.diagnostics.clone();
        // Closure giữ permit và diagnostic guard khi caller hủy JoinHandle; không capture request metadata.
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let work = AuthTimingSpan::start(diagnostics.as_ref(), AuthTimingStage::HashWork);
            blocking.finish(AuthTimingOutcome::Completed);
            let result = verify_stored_password(&password, &verifier);
            work.finish(if result.is_ok() {
                AuthTimingOutcome::Completed
            } else {
                AuthTimingOutcome::Error
            });
            result
        })
        .await
        .map_err(hash_unavailable)?
    }
}

/**
 * Lọc lỗi hasher/worker, không truyền PHC hoặc thông báo provider ra application.
 * Input
 * Param: `_error` — lỗi nội bộ chỉ quyết định unavailable, không được log hoặc giữ trong error envelope.
 * Output: mã lỗi kỹ thuật cố định, không giả password mismatch.
 */
fn hash_unavailable<T>(_error: T) -> ApplicationError {
    ApplicationError::Unavailable
}

/**
 * Kiểm PHC đúng policy trước allocation rồi phân biệt password mismatch với verifier hỏng.
 * Input
 * Param: `password` — credential nguyên bản trong worker, không trim/normalize hoặc log.
 * Param: `verifier` — PHC từ storage/dummy cùng policy đã pin.
 * Output: true/false khi đã verify; Errors: unavailable nếu PHC/thuật toán/chi phí không hợp lệ.
 */
fn verify_stored_password(password: &str, verifier: &str) -> Result<bool, ApplicationError> {
    let parsed = PasswordHash::new(verifier).map_err(hash_unavailable)?;
    /* PHC có thể yêu cầu chi phí riêng; semaphore không chặn RAM/job. Chỉ nhận Argon2id
     * v1.3 m19456KiB/t2/p1/output32byte đã pin; legacy khác policy cần migration được review. */
    if parsed.algorithm.as_str() != "argon2id"
        || parsed.version != Some(19)
        || parsed.params.get_decimal("m") != Some(19_456)
        || parsed.params.get_decimal("t") != Some(2)
        || parsed.params.get_decimal("p") != Some(1)
        || parsed.hash.as_ref().map(argon2::password_hash::Output::len) != Some(32)
    {
        return Err(ApplicationError::Unavailable);
    }
    match Argon2::default().verify_password(password.as_bytes(), &parsed) {
        Ok(()) => Ok(true),
        Err(argon2::password_hash::Error::Password) => Ok(false),
        Err(_) => Err(ApplicationError::Unavailable),
    }
}

/**
 * HMAC email chuẩn hóa để limiter không lưu địa chỉ hay digest dễ dò bằng dictionary.
 * Input
 * Param: `key` — khóa 256 bit do deployment cấp, chung giữa các instance và ổn định qua restart.
 * Param: `email` — email đã qua `normalize_email`.
 * Output: bucket identity 32 byte; Errors: unavailable nếu khởi tạo MAC lỗi.
 * # Errors
 * Trả lỗi từ chối hoặc lỗi đã mô tả ở trên; không chứa dữ liệu nhạy cảm.
 */
pub fn email_bucket_digest(key: &[u8; 32], email: &str) -> Result<Vec<u8>, ApplicationError> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).map_err(|_| ApplicationError::Unavailable)?;
    mac.update(email.as_bytes());
    Ok(mac.finalize().into_bytes().to_vec())
}

/// Implementation crypto của application port; key/dummy verifier không được derive Debug.
#[derive(Clone)]
pub struct CryptoService {
    passwords: PasswordService,
    limiter_key: [u8; 32],
    dummy_verifier: Arc<SecretString>,
}

impl CryptoService {
    /**
     * Chuẩn bị dummy verifier một lần; key phải do deployment cấp ổn định giữa các replica/restart.
     * Input
     * Param: `passwords` — hasher có semaphore dùng chung trong process.
     * Param: `limiter_key` — key `HMAC256bit` do launcher/secret manager cung cấp, không tự đọc env.
     * Output: adapter crypto hoặc unavailable nếu khởi tạo verifier lỗi.
     * # Errors
     * Trả lỗi từ chối hoặc lỗi đã mô tả ở trên; không chứa dữ liệu nhạy cảm.
     */
    pub async fn new(
        passwords: PasswordService,
        limiter_key: [u8; 32],
    ) -> Result<Self, ApplicationError> {
        let verifier = passwords.hash(generate_token().expose().to_owned()).await?;
        Ok(Self {
            passwords,
            limiter_key,
            dummy_verifier: Arc::new(SecretString::new(verifier)),
        })
    }
}

impl IdentitySecurity for CryptoService {
    /// Chuyển secret vào bounded hasher; PHC trả về core vẫn được che Debug.
    async fn hash_password(
        &self,
        password: SecretString,
    ) -> Result<SecretString, ApplicationError> {
        Ok(SecretString::new(
            self.passwords.hash(password.expose().to_owned()).await?,
        ))
    }
    /// Kiểm password/verifier ngoài executor I/O; lỗi verifier không biến thành success.
    async fn verify_password(
        &self,
        password: SecretString,
        verifier: SecretString,
    ) -> Result<bool, ApplicationError> {
        self.passwords
            .verify(password.expose().to_owned(), verifier.expose().to_owned())
            .await
    }
    /// Cấp bản sao dummy PHC cho unknown email; không trả raw dummy password.
    fn dummy_verifier(&self) -> SecretString {
        SecretString::new(self.dummy_verifier.expose().to_owned())
    }
    /// HMAC email bằng key deployment, không dùng SHA256 email dễ bị dictionary attack.
    fn bucket_digest(&self, email: &str) -> Result<[u8; 32], ApplicationError> {
        email_bucket_digest(&self.limiter_key, email)?
            .try_into()
            .map_err(|_| ApplicationError::Unavailable)
    }
    /// Trả token CSPRNG và SHA256 digest; application quyết định thời điểm phát sau commit.
    fn issue_token(&self) -> (SecretString, [u8; 32]) {
        let token = generate_token();
        let digest = self.token_digest(token.expose());
        (token, digest)
    }
    /// Băm capability entropy cao để lookup, không coi digest là chứng cứ session còn quyền.
    fn token_digest(&self, token: &str) -> [u8; 32] {
        Sha256::digest(token.as_bytes()).into()
    }
    /// Hash canonical request bytes để body guard độc lập JSON key order/HTTP formatting.
    fn request_digest(&self, payload: &[u8]) -> [u8; 32] {
        Sha256::digest(payload).into()
    }
}

impl iot_application::template_ports::TemplateDigest for CryptoService {
    /// Băm SHA256 canonical snapshot bytes đã validate, không dùng HMAC limiter hoặc log nội dung template.
    fn content_digest(&self, canonical: &[u8]) -> [u8; 32] {
        Sha256::digest(canonical).into()
    }
}

#[cfg(test)]
mod diagnostic_tests {
    use super::*;
    use crate::adapters::auth_diagnostics::AuthTimingRecorder;
    use iot_application::auth_diagnostics::{AuthDiagnostics, AuthTimingOutcome, AuthTimingStage};
    use std::sync::{Mutex, mpsc};
    use tokio::sync::Notify;

    /// Test observer dùng barrier có cận để tái hiện cancellation, không dùng để đo performance.
    struct TestObserver {
        recorder: Arc<AuthTimingRecorder>,
        queued: Arc<Notify>,
        working: Arc<Notify>,
        work_release: Option<Mutex<mpsc::Receiver<()>>>,
    }

    impl AuthDiagnostics for TestObserver {
        /**
         * Báo mốc stage và giữ worker tại barrier test có timeout, không giữ password/PHC.
         * Input
         * Param: `stage` — enum kỹ thuật quyết định thông báo queue/worker và barrier test.
         * Output: generation do recorder thật giữ chỗ, không tự tạo identity của span.
         */
        fn start_span(&self, stage: AuthTimingStage) -> Option<u64> {
            if stage == AuthTimingStage::HashQueue {
                self.queued.notify_one();
            }
            if stage == AuthTimingStage::HashWork {
                if let Some(release) = &self.work_release {
                    self.working.notify_one();
                    // Chỉ test double cố ý block; timeout2s tránh worker kẹt nếu assertion của caller lỗi.
                    let _ = release
                        .lock()
                        .expect("test barrier lock")
                        .recv_timeout(Duration::from_secs(2));
                }
            }
            self.recorder.start_span(stage)
        }

        /**
         * Chuyển kết quả kỹ thuật tới recorder thật để kiểm queue/work cancellation tách biệt.
         * Input
         * Param: `window_id` — generation đã chụp khi bắt đầu span test.
         * Param: `stage` — ranh giới kỹ thuật thuộc cùng span.
         * Param: `outcome` — completed/error/abandoned được adapter quan sát.
         * Param: `elapsed` — duration monotonic, không timestamp hoặc credential.
         */
        fn finish_span(
            &self,
            window_id: u64,
            stage: AuthTimingStage,
            outcome: AuthTimingOutcome,
            elapsed: Duration,
        ) {
            self.recorder
                .finish_span(window_id, stage, outcome, elapsed);
        }
    }

    /// Hash/verify tách đủ ba stage; sai password vẫn là work hoàn tất, PHC hỏng là work error.
    #[tokio::test]
    async fn hash_and_verify_record_distinct_stage_outcomes() {
        let recorder = Arc::new(AuthTimingRecorder::default());
        let sink: Arc<dyn AuthDiagnostics> = recorder.clone();
        let service = PasswordService::default().with_diagnostics(sink);
        recorder.begin_window().expect("test window");
        let verifier = service
            .hash("Synthetic-password-123".into())
            .await
            .expect("test hash");
        assert!(
            service
                .verify("Synthetic-password-123".into(), verifier.clone())
                .await
                .expect("matching test verifier")
        );
        assert!(
            !service
                .verify("Synthetic-password-456".into(), verifier)
                .await
                .expect("wrong test password")
        );
        assert!(
            service
                .verify(
                    "Synthetic-password-123".into(),
                    "invalid-synthetic-phc".into()
                )
                .await
                .is_err()
        );
        let snapshot = recorder.end_window().expect("settled stages");
        assert!(snapshot.is_valid());
        for stage in [
            AuthTimingStage::HashQueue,
            AuthTimingStage::BlockingQueue,
            AuthTimingStage::HashWork,
        ] {
            assert_eq!(
                snapshot
                    .samples
                    .iter()
                    .filter(
                        // Input: sample chỉ enum/duration; đếm completeness cho đúng stage của cả4operation.
                        |sample| sample.stage == stage,
                    )
                    .count(),
                4
            );
        }
        assert_eq!(
            snapshot
                .samples
                .iter()
                .filter(
                    // PHC hỏng phải là lỗi HashWork duy nhất, không thành completed hoặc invalid credential.
                    |sample| sample.stage == AuthTimingStage::HashWork
                        && sample.outcome == AuthTimingOutcome::Error,
                )
                .count(),
            1
        );
    }

    /// Hủy future khi chưa có slot ghi queue Abandoned, không phát hash worker.
    #[tokio::test]
    async fn cancelling_queued_hash_records_abandoned() {
        let recorder = Arc::new(AuthTimingRecorder::default());
        let queued = Arc::new(Notify::new());
        let sink: Arc<dyn AuthDiagnostics> = Arc::new(TestObserver {
            recorder: recorder.clone(),
            queued: queued.clone(),
            working: Arc::new(Notify::new()),
            work_release: None,
        });
        let service = PasswordService::default().with_diagnostics(sink);
        let permits = service
            .slots
            .clone()
            .acquire_many_owned(2)
            .await
            .expect("hold test slots");
        recorder.begin_window().expect("test window");
        let worker_service = service.clone();
        // Worker chỉ có thể chờ slot vì test đang giữ đủ hai permit.
        let pending =
            tokio::spawn(async move { worker_service.hash("Synthetic-password-123".into()).await });
        tokio::time::timeout(Duration::from_secs(1), queued.notified())
            .await
            .expect("queue reached");
        pending.abort();
        assert!(pending.await.expect_err("cancelled caller").is_cancelled());
        drop(permits);
        let snapshot = recorder.end_window().expect("cancelled queue settled");
        assert_eq!(snapshot.samples.len(), 1);
        assert_eq!(snapshot.samples[0].stage, AuthTimingStage::HashQueue);
        assert_eq!(snapshot.samples[0].outcome, AuthTimingOutcome::Abandoned);
    }

    /// Hết budget slot5s phải trả unavailable và chỉ ghi queue Error, không tạo hash worker.
    #[tokio::test]
    async fn hash_queue_timeout_records_error_without_worker() {
        let recorder = Arc::new(AuthTimingRecorder::default());
        let sink: Arc<dyn AuthDiagnostics> = recorder.clone();
        let service = PasswordService::default().with_diagnostics(sink);
        let permits = service
            .slots
            .clone()
            .acquire_many_owned(2)
            .await
            .expect("hold test slots");
        recorder.begin_window().expect("test window");
        assert!(matches!(
            service.hash("Synthetic-password-123".into()).await,
            Err(ApplicationError::Unavailable)
        ));
        drop(permits);
        let snapshot = recorder.end_window().expect("timed out queue settled");
        assert!(snapshot.is_valid());
        assert_eq!(snapshot.samples.len(), 1);
        assert_eq!(snapshot.samples[0].stage, AuthTimingStage::HashQueue);
        assert_eq!(snapshot.samples[0].outcome, AuthTimingOutcome::Error);
        assert!(snapshot.samples[0].elapsed >= Duration::from_secs(5));
    }

    /// Hủy caller không được nhả permit của blocking worker còn thực thi hoặc giả stage đã dừng.
    #[tokio::test]
    async fn cancelling_caller_keeps_worker_permit_until_completion() {
        let recorder = Arc::new(AuthTimingRecorder::default());
        let working = Arc::new(Notify::new());
        let (release, receiver) = mpsc::channel();
        let sink: Arc<dyn AuthDiagnostics> = Arc::new(TestObserver {
            recorder: recorder.clone(),
            queued: Arc::new(Notify::new()),
            working: working.clone(),
            work_release: Some(Mutex::new(receiver)),
        });
        let service = PasswordService::default().with_diagnostics(sink);
        recorder.begin_window().expect("test window");
        let worker_service = service.clone();
        // Barrier nằm trong worker sau khi đã nhận permit, caller không dựa vào tốc độ Argon2 để hủy.
        let pending =
            tokio::spawn(async move { worker_service.hash("Synthetic-password-123".into()).await });
        tokio::time::timeout(Duration::from_secs(1), working.notified())
            .await
            .expect("worker reached barrier");
        assert!(recorder.end_window().is_err());
        pending.abort();
        assert!(pending.await.expect_err("cancelled caller").is_cancelled());
        assert_eq!(service.slots.available_permits(), 1);
        release.send(()).expect("release owned worker");
        let permits = tokio::time::timeout(
            Duration::from_secs(5),
            service.slots.clone().acquire_many_owned(2),
        )
        .await
        .expect("worker completes")
        .expect("slots open");
        drop(permits);
        let snapshot = recorder
            .end_window()
            .expect("worker has completed despite caller cancellation");
        assert_eq!(snapshot.samples.len(), 3);
        assert!(snapshot.samples.iter().all(
            // Mỗi stage CPU thực sự đã chạy xong; không suy caller auth đã thành công từ outcome này.
            |sample| sample.outcome == AuthTimingOutcome::Completed,
        ));
    }

    /**
     * Kiểm nhánh verify hết budget hai slot thật trước khi worker hoặc PHC parser được chạy.
     * Output: unavailable sau ít nhất5s trong cận8s, chỉ một queue Error và snapshot không mất mẫu.
     * Side effects: giữ permit bằng RAII; assertion lỗi vẫn nhả cả hai slot khi test unwind.
     */
    #[tokio::test]
    async fn verify_queue_timeout_records_error_without_worker() {
        let recorder = Arc::new(AuthTimingRecorder::default());
        let sink: Arc<dyn AuthDiagnostics> = recorder.clone();
        let service = PasswordService::default().with_diagnostics(sink);
        let permits = service
            .slots
            .clone()
            .acquire_many_owned(2)
            .await
            .expect("hold verify test slots");
        recorder.begin_window().expect("verify timeout window");

        /* PHC cố ý hỏng chỉ làm sentinel: queue phải timeout trước parsing, không phải
        bằng chứng kiểm credential. Clock thật bắt mutation timeout tức thời mà không đổi policy. */
        let started = std::time::Instant::now();
        let result = tokio::time::timeout(
            Duration::from_secs(8),
            service.verify(
                "Synthetic-password-123".into(),
                "invalid-synthetic-phc".into(),
            ),
        )
        .await;
        let elapsed = started.elapsed();
        assert!(matches!(result, Ok(Err(ApplicationError::Unavailable))));
        assert!(elapsed >= Duration::from_secs(5));
        assert!(elapsed < Duration::from_secs(8));
        drop(permits);

        let snapshot = recorder.end_window().expect("verify queue settled");
        assert!(snapshot.is_valid());
        assert_eq!(snapshot.dropped_samples, 0);
        assert_eq!(snapshot.stale_samples, 0);
        assert!(!snapshot.poisoned);
        assert_eq!(snapshot.samples.len(), 1);
        assert_eq!(snapshot.samples[0].stage, AuthTimingStage::HashQueue);
        assert_eq!(snapshot.samples[0].outcome, AuthTimingOutcome::Error);
        assert!(snapshot.samples[0].elapsed >= Duration::from_secs(5));
        assert!(snapshot.samples[0].elapsed < Duration::from_secs(8));
    }

    /**
     * Hủy caller verify tại worker barrier để kiểm closure giữ permit tới khi CPU thật hoàn tất.
     * Output: caller cancelled, window active trước/sau abort, ba stage Completed riêng và không mất mẫu.
     * Side effects: release worker và đợi đủ permit trước assertions; channel drop/timeout2s vẫn mở barrier khi unwind.
     */
    #[tokio::test]
    async fn cancelling_verify_caller_keeps_worker_permit_until_completion() {
        use crate::adapters::auth_diagnostics::AuthTimingControlError;

        // Tạo PHC hợp lệ trước observer/window để hash chuẩn bị không lẫn vào ba stage của verify.
        let service = PasswordService::default();
        let verifier = service
            .hash("Synthetic-password-123".into())
            .await
            .expect("prepare synthetic verify PHC");
        let recorder = Arc::new(AuthTimingRecorder::default());
        let working = Arc::new(Notify::new());
        let (release, receiver) = mpsc::channel();
        let sink: Arc<dyn AuthDiagnostics> = Arc::new(TestObserver {
            recorder: recorder.clone(),
            queued: Arc::new(Notify::new()),
            working: working.clone(),
            work_release: Some(Mutex::new(receiver)),
        });
        let service = service.with_diagnostics(sink);
        recorder.begin_window().expect("verify cancellation window");
        let worker_service = service.clone();
        let started = std::time::Instant::now();
        // Task chỉ sở hữu input tổng hợp; abort caller không được nhả permit đang nằm trong blocking closure.
        let pending = tokio::spawn(async move {
            worker_service
                .verify("Synthetic-password-123".into(), verifier)
                .await
        });
        let barrier_reached =
            tokio::time::timeout(Duration::from_secs(1), working.notified()).await;
        let window_before_abort = recorder.end_window();
        pending.abort();
        let cancellation = pending.await;
        let window_after_abort = recorder.end_window();
        let available_permits = service.slots.available_permits();

        /* Thu thập quan sát trước rồi luôn release/join bằng permit trước khi assert để
        mutation thất bại không giữ worker. Cận2s phân biệt explicit release với failsafe barrier tự hết hạn. */
        let released = release.send(());
        let released_before_failsafe = started.elapsed() < Duration::from_secs(2);
        drop(release);
        let permits = tokio::time::timeout(
            Duration::from_secs(5),
            service.slots.clone().acquire_many_owned(2),
        )
        .await
        .expect("verify worker completes")
        .expect("verify slots open");
        drop(permits);

        assert!(barrier_reached.is_ok());
        assert!(matches!(
            window_before_abort,
            Err(AuthTimingControlError::SpansActive)
        ));
        assert!(
            cancellation
                .expect_err("cancelled verify caller")
                .is_cancelled()
        );
        assert!(matches!(
            window_after_abort,
            Err(AuthTimingControlError::SpansActive)
        ));
        assert_eq!(available_permits, 1);
        assert!(released.is_ok());
        assert!(released_before_failsafe);
        let snapshot = recorder.end_window().expect("verify worker settled");
        assert!(snapshot.is_valid());
        assert_eq!(snapshot.dropped_samples, 0);
        assert_eq!(snapshot.stale_samples, 0);
        assert!(!snapshot.poisoned);
        assert_eq!(snapshot.samples.len(), 3);
        for stage in [
            AuthTimingStage::HashQueue,
            AuthTimingStage::BlockingQueue,
            AuthTimingStage::HashWork,
        ] {
            assert_eq!(
                snapshot
                    .samples
                    .iter()
                    .filter(
                        // Đúng một Completed cho từng stage ngăn ba mẫu trùng stage che mất boundary còn thiếu.
                        |sample| {
                            sample.stage == stage && sample.outcome == AuthTimingOutcome::Completed
                        },
                    )
                    .count(),
                1
            );
        }
    }
}
