//! Recorder đo stage auth có cận; không nhận credential, identity, SQL hoặc label từ request.

use iot_application::auth_diagnostics::{AuthDiagnostics, AuthTimingOutcome, AuthTimingStage};
use std::{
    sync::{Mutex, MutexGuard},
    time::Duration,
};

/// Cận bộ nhớ của một window lab; không coi số sample này là load target hoặc SLO.
pub const MAX_WINDOW_SAMPLES: usize = 4096;

/// Một số đo chỉ có enum và elapsed; không chứa timestamps hoặc dữ liệu định danh.
#[derive(Clone, Copy, Debug)]
pub struct AuthTimingSample {
    pub stage: AuthTimingStage,
    pub outcome: AuthTimingOutcome,
    pub elapsed: Duration,
}

/// Window đã đóng, không còn span; exporter phải kiểm validity trước khi dùng các số đo.
#[derive(Debug)]
pub struct AuthTimingSnapshot {
    pub window_id: u64,
    pub samples: Vec<AuthTimingSample>,
    pub dropped_samples: u64,
    pub stale_samples: u64,
    pub poisoned: bool,
    invalid: bool,
}

impl AuthTimingSnapshot {
    /// Evidence mất sample/poison hoặc callback cũ không được coi hoàn chỉnh dù auth vẫn hoạt động.
    #[must_use]
    pub const fn is_valid(&self) -> bool {
        !self.invalid && !self.poisoned && self.dropped_samples == 0 && self.stale_samples == 0
    }
}

/// Lỗi control chỉ tác động phép đo; không trả các lỗi này từ use case hoặc handler auth.
#[derive(Debug, PartialEq, Eq)]
pub enum AuthTimingControlError {
    WindowActive,
    NoWindow,
    SpansActive,
    GenerationExhausted,
}

/// State bounded nằm sau mutex đồng bộ; không giữ lock qua await hoặc I/O.
#[derive(Default)]
struct RecorderState {
    window_id: u64,
    recording: bool,
    active_spans: u64,
    samples: Vec<AuthTimingSample>,
    dropped_samples: u64,
    stale_samples: u64,
    poisoned: bool,
    invalid: bool,
}

/// Sink mặc định inactive; mọi clone qua Arc chia sẻ đúng một window process.
#[derive(Default)]
pub struct AuthTimingRecorder {
    state: Mutex<RecorderState>,
}

impl AuthTimingRecorder {
    /// Recover poison để telemetry không panic auth; evidence giữ dấu invalid thay vì che lỗi.
    fn lock_state(&self) -> MutexGuard<'_, RecorderState> {
        match self.state.lock() {
            Ok(state) => state,
            Err(poisoned) => {
                let mut state = poisoned.into_inner();
                state.poisoned = true;
                state.invalid = true;
                state
            }
        }
    }

    /**
     * Bắt đầu window mới khi không còn window active, cấp generation không quay vòng.
     * Output: generation cho control harness.
     * # Errors
     * window đang mở hoặc counter hết miền u64.
     * Side effects: cấp buffer bounded trước traffic; không reset work active để che span đang chạy.
     */
    pub fn begin_window(&self) -> Result<u64, AuthTimingControlError> {
        let mut state = self.lock_state();
        if state.recording {
            return Err(AuthTimingControlError::WindowActive);
        }
        let window_id = state
            .window_id
            .checked_add(1)
            .ok_or(AuthTimingControlError::GenerationExhausted)?;
        *state = RecorderState {
            window_id,
            recording: true,
            samples: Vec::with_capacity(MAX_WINDOW_SAMPLES),
            poisoned: state.poisoned,
            invalid: state.poisoned,
            ..RecorderState::default()
        };
        Ok(window_id)
    }

    /**
     * Đóng window chỉ khi mọi span đã finish/drop, giữ nguyên state nếu còn work.
     * Output: số đo bounded và cờ completeness.
     * # Errors
     * không có window hoặc active spans chưa về0.
     * Side effects: chuyển buffer ra snapshot, không giữ mutex lúc exporter serialize hoặc ghi I/O.
     */
    pub fn end_window(&self) -> Result<AuthTimingSnapshot, AuthTimingControlError> {
        let mut state = self.lock_state();
        if !state.recording {
            return Err(AuthTimingControlError::NoWindow);
        }
        if state.active_spans != 0 {
            return Err(AuthTimingControlError::SpansActive);
        }
        state.recording = false;
        Ok(AuthTimingSnapshot {
            window_id: state.window_id,
            samples: std::mem::take(&mut state.samples),
            dropped_samples: state.dropped_samples,
            stale_samples: state.stale_samples,
            poisoned: state.poisoned,
            invalid: state.invalid,
        })
    }
}

impl AuthDiagnostics for AuthTimingRecorder {
    /**
     * Giữ chỗ span khi window mở; counter không mang authority hoặc metadata request.
     * Input
     * Param: `_stage` — enum do adapter cung cấp, chưa sinh sample cho tới finish.
     * Output: generation hiện hành hoặc None khi inactive/counter overflow; overflow làm invalid.
     */
    fn start_span(&self, _stage: AuthTimingStage) -> Option<u64> {
        let mut state = self.lock_state();
        if !state.recording {
            return None;
        }
        if let Some(next) = state.active_spans.checked_add(1) {
            state.active_spans = next;
            Some(state.window_id)
        } else {
            state.invalid = true;
            None
        }
    }

    /**
     * Ghi sample hữu hạn và giải phóng đúng chỗ của window, không làm I/O dưới mutex.
     * Input
     * Param: `window_id` — generation đã chụp tại start; stale không được trừ active count mới.
     * Param: `stage` — enum hữu hạn, không gắn nhãn theo account/key/client input.
     * Param: `outcome` — kết quả kỹ thuật của stage, không là quyết định quyền/session.
     * Param: `elapsed` — duration monotonic giữ trong snapshot, không timestamp định danh.
     */
    fn finish_span(
        &self,
        window_id: u64,
        stage: AuthTimingStage,
        outcome: AuthTimingOutcome,
        elapsed: Duration,
    ) {
        let mut recorder = self.lock_state();
        if !recorder.recording {
            return;
        }
        if recorder.window_id != window_id {
            recorder.stale_samples = recorder.stale_samples.saturating_add(1);
            return;
        }
        if recorder.active_spans == 0 {
            recorder.invalid = true;
            return;
        }
        recorder.active_spans -= 1;
        if recorder.samples.len() == MAX_WINDOW_SAMPLES {
            recorder.dropped_samples = recorder.dropped_samples.saturating_add(1);
            return;
        }
        recorder.samples.push(AuthTimingSample {
            stage,
            outcome,
            elapsed,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use iot_application::auth_diagnostics::{
        AuthDiagnostics, AuthTimingOutcome, AuthTimingSpan, AuthTimingStage,
    };
    use std::{sync::Arc, time::Duration};

    /// Recorder inactive không tạo span hoặc dữ liệu đo giả trước khi operator mở window.
    #[test]
    fn inactive_recorder_does_not_capture() {
        let recorder = AuthTimingRecorder::default();
        assert_eq!(recorder.start_span(AuthTimingStage::HashWork), None);
    }

    /// End khi còn work phải từ chối, giữ window để caller không che span chưa hoàn tất.
    #[test]
    fn active_span_prevents_window_end_and_reset() {
        let recorder = Arc::new(AuthTimingRecorder::default());
        recorder.begin_window().expect("test window");
        let sink: Arc<dyn AuthDiagnostics> = recorder.clone();
        let span = AuthTimingSpan::start(Some(&sink), AuthTimingStage::HashQueue);
        assert!(recorder.end_window().is_err());
        assert!(recorder.begin_window().is_err());
        span.finish(AuthTimingOutcome::Completed);
        let snapshot = recorder.end_window().expect("settled window");
        assert!(snapshot.is_valid());
        assert_eq!(snapshot.samples.len(), 1);
        assert_eq!(snapshot.samples[0].outcome, AuthTimingOutcome::Completed);
    }

    /// Future bị drop chỉ được ghi Abandoned, không biến cancellation thành stage hoàn tất.
    #[test]
    fn dropped_span_records_abandoned() {
        let recorder = Arc::new(AuthTimingRecorder::default());
        recorder.begin_window().expect("test window");
        let sink: Arc<dyn AuthDiagnostics> = recorder.clone();
        drop(AuthTimingSpan::start(
            Some(&sink),
            AuthTimingStage::HashQueue,
        ));
        let snapshot = recorder.end_window().expect("dropped span settled");
        assert_eq!(snapshot.samples.len(), 1);
        assert_eq!(snapshot.samples[0].outcome, AuthTimingOutcome::Abandoned);
    }

    /// Cận4096 không được âm thầm bỏ sample rồi tiếp tục gọi evidence hợp lệ.
    #[test]
    fn overflowing_window_is_bounded_and_invalid() {
        let recorder = AuthTimingRecorder::default();
        recorder.begin_window().expect("test window");
        for _ in 0..=MAX_WINDOW_SAMPLES {
            let window = recorder
                .start_span(AuthTimingStage::HashWork)
                .expect("active window");
            recorder.finish_span(
                window,
                AuthTimingStage::HashWork,
                AuthTimingOutcome::Completed,
                Duration::from_micros(42),
            );
        }
        let snapshot = recorder.end_window().expect("settled window");
        assert_eq!(snapshot.samples.len(), MAX_WINDOW_SAMPLES);
        assert_eq!(snapshot.dropped_samples, 1);
        assert!(!snapshot.is_valid());
    }

    /// Callback window cũ không được nhập vào số đo mới hoặc làm giảm active count của window mới.
    #[test]
    fn stale_window_is_visible_and_cannot_contaminate_samples() {
        let recorder = AuthTimingRecorder::default();
        let previous = recorder.begin_window().expect("first window");
        recorder.end_window().expect("empty settled window");
        recorder.begin_window().expect("second window");
        recorder.finish_span(
            previous,
            AuthTimingStage::HashWork,
            AuthTimingOutcome::Completed,
            Duration::from_millis(99),
        );
        let snapshot = recorder.end_window().expect("settled current window");
        assert!(snapshot.samples.is_empty());
        assert_eq!(snapshot.stale_samples, 1);
        assert!(!snapshot.is_valid());
    }

    /// Nhiều worker cùng ghi vẫn giữ đủ sample, không dùng sleep hoặc nhãn theo identity.
    #[test]
    fn concurrent_recording_preserves_sample_count() {
        let recorder = Arc::new(AuthTimingRecorder::default());
        recorder.begin_window().expect("test window");
        let mut workers = Vec::new();
        for _ in 0..4 {
            let worker_recorder = recorder.clone();
            // Mỗi worker chỉ giữ lock đồng bộ trong callback ngắn, không qua await hoặc I/O.
            workers.push(std::thread::spawn(move || {
                for _ in 0..100 {
                    let window = worker_recorder
                        .start_span(AuthTimingStage::HashWork)
                        .expect("active window");
                    worker_recorder.finish_span(
                        window,
                        AuthTimingStage::HashWork,
                        AuthTimingOutcome::Completed,
                        Duration::from_micros(1),
                    );
                }
            }));
        }
        for worker in workers {
            worker.join().expect("test worker");
        }
        let snapshot = recorder.end_window().expect("joined workers");
        assert_eq!(snapshot.samples.len(), 400);
        assert!(snapshot.is_valid());
    }

    /// Poison của telemetry phải làm evidence invalid, không panic thêm trong luồng auth.
    #[test]
    fn poisoned_recorder_is_invalid_without_panicking_auth_callbacks() {
        let recorder = Arc::new(AuthTimingRecorder::default());
        recorder.begin_window().expect("test window");
        let worker_recorder = recorder.clone();
        // Test cố ý làm poison mutex; không có input hoặc credential trong panic tổng hợp.
        assert!(
            std::thread::spawn(move || {
                let _guard = worker_recorder.state.lock().expect("test lock");
                panic!("synthetic telemetry panic");
            })
            .join()
            .is_err()
        );
        let window = recorder
            .start_span(AuthTimingStage::HashWork)
            .expect("active poisoned window");
        recorder.finish_span(
            window,
            AuthTimingStage::HashWork,
            AuthTimingOutcome::Error,
            Duration::ZERO,
        );
        let snapshot = recorder
            .end_window()
            .expect("poison does not alter auth outcome");
        assert!(!snapshot.is_valid());
        assert!(snapshot.poisoned);
    }

    /// Disabled span không gọi clock/sink hoặc cần recorder; dùng được trong constructor mặc định.
    #[test]
    fn disabled_span_can_finish_or_drop() {
        AuthTimingSpan::start(None, AuthTimingStage::HashQueue).finish(AuthTimingOutcome::Error);
        drop(AuthTimingSpan::start(None, AuthTimingStage::HashWork));
    }
}
