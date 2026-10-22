import { useEffect, useRef, useState, type ChangeEvent } from 'react';

interface TraceEntry {
  message: string;
  warning: boolean;
}

interface DryRunState {
  firstResult: 'Chưa chạy' | 'Đang kiểm tra' | 'ĐÚNG';
  secondResult: 'Chưa chạy' | 'Đang kiểm tra' | 'ĐÚNG' | 'CHƯA RÕ';
  activeActions: number;
  trace: TraceEntry[];
}

const initialDryRun: DryRunState = {
  firstResult: 'Chưa chạy',
  secondResult: 'Chưa chạy',
  activeActions: 0,
  trace: [],
};

/** Minh họa luồng đánh giá kịch bản tự động và phần chạy thử. */
export function AutomationSection() {
  const [staleSensor, setStaleSensor] = useState(false);
  const [dryRun, setDryRun] = useState(initialDryRun);
  const timers = useRef<number[]>([]);

  // Chỉ cần một cleanup khi component bị tháo; các lượt chạy lại tự hủy timer trước đó.
  useEffect(() => {
    // Dừng các bước chạy thử còn hẹn giờ khi rời trang để tránh cập nhật giao diện đã bị tháo.
    return () => timers.current.forEach((timer) => window.clearTimeout(timer));
  }, []);

  /** Cập nhật lựa chọn mất tín hiệu của cảm biến cửa sổ trong lần chạy thử tiếp theo. */
  function handleStaleChange(event: ChangeEvent<HTMLInputElement>): void {
    setStaleSensor(event.target.checked);
  }

  /** Chạy mô phỏng hai nhánh đúng và chưa rõ mà không gửi bất kỳ lệnh thiết bị nào. */
  function handleDryRun(): void {
    timers.current.forEach((timer) => window.clearTimeout(timer));
    timers.current = [];
    setDryRun({ firstResult: 'Đang kiểm tra', secondResult: 'Đang kiểm tra', activeActions: 0, trace: [] });

    /** Giữ các bước hiện dần đúng nhịp của nguyên mẫu và cho phép hủy khi chạy lại. */
    function queueStep(delay: number, update: (current: DryRunState) => DryRunState): void {
      timers.current.push(window.setTimeout(() => setDryRun(update), delay));
    }

    queueStep(500, (current) => ({
      ...current,
      firstResult: 'ĐÚNG',
      trace: [...current.trace, { message: 'Nhiệt độ 31.4°C, đã giữ trên 30°C đủ 2 phút.', warning: false }],
    }));
    queueStep(1100, (current) => ({
      ...current,
      secondResult: staleSensor ? 'CHƯA RÕ' : 'ĐÚNG',
      trace: [...current.trace, staleSensor
        ? { message: 'Cảm biến cửa sổ mất tín hiệu quá lâu, không thể kết luận.', warning: true }
        : { message: 'Cửa sổ đang đóng, dữ liệu vừa cập nhật.', warning: false }],
    }));
    queueStep(1700, (current) => ({
      ...current,
      activeActions: staleSensor ? 0 : 1,
      trace: [...current.trace, staleSensor
        ? { message: 'Kết quả chung là “chưa rõ”: không có hành động nào được gửi.', warning: true }
        : { message: 'Cả hai điều kiện đúng, kịch bản sẽ chạy.', warning: false }],
    }));
    if (!staleSensor) {
      queueStep(2300, (current) => ({
        ...current,
        activeActions: 2,
        trace: [...current.trace, { message: 'Bước 1: bật quạt phòng ngay.', warning: false }],
      }));
      queueStep(2900, (current) => ({
        ...current,
        activeActions: 3,
        trace: [...current.trace, { message: 'Bước 2 và 3: chờ 10 phút rồi gửi thông báo.', warning: false }],
      }));
    }
  }

  return (
    <>
      <section className="auto relative mx-6 overflow-hidden rounded-[40px] bg-navy py-[88px] text-[#E7F2F1] max-[760px]:mx-3 max-[760px]:rounded-[28px]" id="automation">
            <div className="wrap mx-auto w-[min(1200px,calc(100%-48px))]">
              <div className="sec-head mb-14 max-w-[46rem]">
                <h2>Tự động hóa bằng kịch bản bạn đọc là hiểu</h2>
                <p>Kết hợp nhiều điều kiện, đặt lịch, chờ giữa các bước và thử trước khi bật. Dữ liệu cũ hoặc mất tín hiệu thì
                  luật đứng yên, không tự ra lệnh.</p>
              </div>
              <div className="auto-grid relative z-[1] grid grid-cols-[minmax(0,1.15fr)_minmax(0,.85fr)] gap-7 max-[1020px]:grid-cols-1">
                <div className="flow rounded-card border border-[rgba(255,255,255,.08)] bg-[#12324A] p-[26px]" id="flow">
                  <div className="node relative rounded-2xl border border-white/10 bg-[rgba(255,255,255,.035)] px-4 py-[14px] transition-[border-color,background] duration-[400ms]">
                    <h4><svg className="i" aria-hidden="true">
                        <use href="#i-clock" />
                      </svg>Khi có số đo mới từ cảm biến</h4>
                  </div>
                  <div className="node relative rounded-2xl border border-white/10 bg-[rgba(255,255,255,.035)] px-4 py-[14px] transition-[border-color,background] duration-[400ms]">
                    <h4><svg className="i" aria-hidden="true">
                        <use href="#i-pulse" />
                      </svg>Nếu đồng thời thỏa</h4>
                    <div className="cond flex items-center justify-between gap-[10px] border-t border-dashed border-white/10 first-of-type:border-t-0 py-2 text-[.92rem]"><span>Nhiệt độ lớn hơn 30°C, giữ 2 phút</span><span className={`res${dryRun.firstResult === 'ĐÚNG' ? ' t' : ''}`} id="r1">{dryRun.firstResult}</span>
                    </div>
                    <div className="cond flex items-center justify-between gap-[10px] border-t border-dashed border-white/10 first-of-type:border-t-0 py-2 text-[.92rem]"><span>Cửa sổ đang đóng</span><span className={`res${dryRun.secondResult === 'ĐÚNG' ? ' t' : dryRun.secondResult === 'CHƯA RÕ' ? ' u' : ''}`} id="r2">{dryRun.secondResult}</span></div>
                  </div>
                  <div className="node relative rounded-2xl border border-white/10 bg-[rgba(255,255,255,.035)] px-4 py-[14px] transition-[border-color,background] duration-[400ms]">
                    <h4><svg className="i" aria-hidden="true">
                        <use href="#i-bolt" />
                      </svg>Thì thực hiện lần lượt</h4>
                    <div className={`act${dryRun.activeActions >= 1 ? ' run' : ''}`} id="a1"><svg className="i" aria-hidden="true">
                        <use href="#i-fan" />
                      </svg>Bật quạt phòng<time>ngay</time></div>
                    <div className={`act${dryRun.activeActions >= 2 ? ' run' : ''}`} id="a2"><svg className="i" aria-hidden="true">
                        <use href="#i-clock" />
                      </svg>Chờ 10 phút<time>+10 phút</time></div>
                    <div className={`act${dryRun.activeActions >= 3 ? ' run' : ''}`} id="a3"><svg className="i" aria-hidden="true">
                        <use href="#i-bell" />
                      </svg>Gửi thông báo cho quản trị viên<time>+10 phút</time></div>
                  </div>
                </div>
                <div className="side flex flex-col gap-[18px]">
                  <div className="panel rounded-card border border-[rgba(255,255,255,.08)] bg-[#12324A] p-6">
                    <h3>Chạy thử trước khi bật</h3>
                    <p>Dry-run cho bạn xem từng điều kiện đúng hay sai và chuỗi hành động sẽ diễn ra thế nào, mà không gửi
                      lệnh thật.</p>
                    <label className="toggle my-4 flex min-h-11 cursor-pointer items-center gap-[.7rem] text-[.9rem] text-[#C9DBE3]"><input type="checkbox" id="stale" checked={staleSensor} onChange={handleStaleChange} /> Giả lập cảm biến cửa sổ mất tín hiệu</label>
                    <button className="btn btn-primary" id="dry" type="button" onClick={handleDryRun}><svg className="i" aria-hidden="true">
                        <use href="#i-bolt" />
                      </svg>Chạy thử kịch bản</button>
                    <ul className="trace mt-4 min-h-28 list-none text-[.86rem] text-[#C9DBE3]" id="trace" aria-live="polite">{dryRun.trace.map((entry, index) => (
                      <li key={`${index}-${entry.message}`} className={entry.warning ? 'warn' : undefined}>
                        <svg className="i" aria-hidden="true"><use href={entry.warning ? '#i-help' : '#i-check'} /></svg>
                        <span>{entry.message}</span>
                      </li>
                    ))}</ul>
                    <div className="note mt-3 flex items-center gap-2 text-[.78rem] text-[#7FA3B2]"><svg className="i" aria-hidden="true" style={{ width: '15px', height: '15px' }}>
                        <use href="#i-shield" />
                      </svg>Chạy thử không gửi lệnh hay thông báo thật.</div>
                  </div>
                </div>
              </div>
            </div>
          </section>
    </>
  );
}
