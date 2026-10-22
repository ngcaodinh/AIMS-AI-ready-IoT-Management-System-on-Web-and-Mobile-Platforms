import { buildSparkline, useDeviceDemo } from './useDeviceDemo';

/** Giới thiệu nền tảng và mô phỏng đồng bộ Web với ứng dụng di động. */
export function HeroOverview() {
  const { state, sendFanCommand } = useDeviceDemo();
  const sparkline = buildSparkline(state.history);
  const gaugeProgress = (Math.min(40, Math.max(20, state.temperature)) - 20) / 20;
  const gaugeColor = state.temperature >= 32 ? 'var(--coral)' : state.temperature >= 30 ? 'var(--amber)' : 'var(--teal)';
  const fanLabel = state.stage === 1
    ? 'Đã tiếp nhận · chờ thiết bị'
    : state.stage === 2 ? 'Thiết bị đã xác nhận' : state.fanOn ? 'Đang chạy' : 'Đang tắt';
  const phoneFanLabel = state.stage > 0 ? 'Đang chờ…' : state.fanOn ? 'Đang chạy' : 'Đang tắt';

  /** Mô phỏng thao tác công tắc từ cả hai màn hình bằng cùng trạng thái React. */
  function handleFanToggle(): void {
    sendFanCommand(!state.fanOn);
  }

  return (
    <>
      {/* Khối giới thiệu và bản xem trước ứng dụng. */}
          <div className="hero relative overflow-hidden pt-[84px] pb-[150px] max-[1020px]:pb-[120px] max-[760px]:pt-10 max-[760px]:pb-16">
            <div className="blob a"></div>
            <div className="blob b"></div>
            <div className="blob c"></div>
            <div className="blob d"></div>
            <div className="wrap hero-grid mx-auto w-[min(1200px,calc(100%-48px))] relative grid grid-cols-[minmax(0,.9fr)_minmax(0,1.1fr)] items-center gap-14 max-[1020px]:grid-cols-1">
              <div>
                <div className="pill seq inline-flex items-center gap-[.55rem] rounded-full border border-line py-[.4rem] pr-[.9rem] pl-[.5rem] text-[.85rem] text-muted shadow-card backdrop-blur-[10px]"><b>Web + App</b> Một hệ thống, hai nền tảng</div>
                <h1 className="seq">Nhìn thấy, điều khiển và tự động hóa mọi thiết bị IoT.</h1>
                <p className="lead seq">Theo dõi cảm biến theo thời gian thực, bật tắt thiết bị từ xa và xác nhận kết quả từ chính
                  thiết bị. Kịch bản tự động vẫn chạy khi bạn không mở ứng dụng.</p>
                <div className="hero-cta seq mt-[2rem] mb-[2.2rem] flex flex-wrap gap-[.8rem]">
                  <a href="#start" className="btn btn-primary">Tạo workspace <svg className="i" aria-hidden="true">
                      <use href="#i-arrow" />
                    </svg></a>
                  <a href="#automation" className="btn btn-ghost">Xem kịch bản mẫu</a>
                </div>
                <div className="chips seq flex flex-wrap gap-2">
                  <span className="chip inline-flex items-center gap-[.45rem] rounded-full border border-line bg-surface px-[.8rem] py-[.4rem] text-[.82rem] font-medium text-muted"><svg className="i" aria-hidden="true">
                      <use href="#i-monitor" />
                    </svg>Web</span>
                  <span className="chip inline-flex items-center gap-[.45rem] rounded-full border border-line bg-surface px-[.8rem] py-[.4rem] text-[.82rem] font-medium text-muted"><svg className="i" aria-hidden="true">
                      <use href="#i-phone" />
                    </svg>Android</span>
                  <span className="chip inline-flex items-center gap-[.45rem] rounded-full border border-line bg-surface px-[.8rem] py-[.4rem] text-[.82rem] font-medium text-muted"><svg className="i" aria-hidden="true">
                      <use href="#i-cpu" />
                    </svg>ESP32</span>
                  <span className="chip inline-flex items-center gap-[.45rem] rounded-full border border-line bg-surface px-[.8rem] py-[.4rem] text-[.82rem] font-medium text-muted"><svg className="i" aria-hidden="true">
                      <use href="#i-pulse" />
                    </svg>Thời gian thực</span>
                </div>
              </div>

              {/* Số đo và công tắc dưới đây chỉ là mô phỏng trên trang giới thiệu. */}
              <div className="stage relative w-full pb-[30px] max-[1020px]:mx-auto max-[1020px]:max-w-[640px]" id="stage">
                <div className="hint mb-[14px] flex items-center justify-end gap-2 text-[.85rem] text-muted"><span className="dot"></span>Bản chạy thử: bấm công tắc quạt, Web và App đổi cùng lúc</div>
                <div className="win w-[calc(100%-70px)] overflow-hidden rounded-card border border-line max-[760px]:w-full" id="win">
                  <div className="win-bar flex items-center gap-2 border-b border-line bg-surface-soft px-4 py-3"><i></i><i></i><i></i><span>nexa.app/phong-thuc-hanh</span></div>
                  <div className="win-body grid grid-cols-2 gap-[14px] p-5 max-[760px]:grid-cols-1">
                    <div className="win-head col-span-full flex items-center justify-between">
                      <h3>Phòng thực hành A</h3><span className="status inline-flex items-center gap-[.4rem] rounded-full bg-teal-soft px-[.7rem] py-1 text-[.78rem] font-semibold text-teal-deep">Thiết bị trực tuyến</span>
                    </div>
                    <div className="tile rounded-[16px] border border-line px-4 py-[14px]"><small><svg className="i" aria-hidden="true">
                          <use href="#i-therm" />
                        </svg>Nhiệt độ</small>
                      <div className="val"><span id="w-temp">{state.temperature.toFixed(1)}</span><em>°C</em></div>
                    </div>
                    <div className="tile rounded-[16px] border border-line px-4 py-[14px]"><small><svg className="i" aria-hidden="true">
                          <use href="#i-drop" />
                        </svg>Độ ẩm</small>
                      <div className="val"><span id="w-hum">{Math.round(state.humidity)}</span><em>%</em></div>
                    </div>
                    <div className="tile wide rounded-[16px] border border-line px-4 py-[14px]"><small><svg className="i" aria-hidden="true">
                          <use href="#i-pulse" />
                        </svg>Nhiệt độ 2 phút gần nhất</small>
                      <svg className="spark mt-[6px] block h-[78px] w-full" id="spark" viewBox="0 0 400 78" preserveAspectRatio="none" aria-hidden="true">
                        <defs>
                          <linearGradient id="sg" x1="0" y1="0" x2="0" y2="1">
                            <stop offset="0" stopColor="var(--teal)" stopOpacity=".35" />
                            <stop offset="1" stopColor="var(--teal)" stopOpacity="0" />
                          </linearGradient>
                        </defs>
                        <path id="sp-area" d={sparkline.area} fill="url(#sg)" />
                        <path id="sp-line" d={sparkline.line} fill="none" stroke="var(--teal)" strokeWidth="2.5" strokeLinejoin="round"
                          strokeLinecap="round" />
                      </svg>
                    </div>
                    <div className={`tile wide${state.fanOn ? ' fan-on' : ''}`} id="ctl" data-stage={state.stage}>
                      <div className="ctl flex items-center justify-between gap-3">
                        <div className="ctl-l flex items-center gap-[.8rem]">
                          <div className="ctl-ico grid size-[42px] place-items-center rounded-[13px] bg-page-soft text-muted transition-all duration-[400ms]"><svg className="i" aria-hidden="true">
                              <use href="#i-fan" />
                            </svg></div>
                          <div><strong>Quạt phòng</strong><span className="sub" id="w-sub" aria-live="polite">{fanLabel}</span>
                          </div>
                        </div>
                        <button className={`sw${state.stage > 0 ? ' pending' : ''}`} id="w-sw" role="switch"
                          aria-checked={state.fanOn} aria-label="Bật tắt quạt phòng" onClick={handleFanToggle}></button>
                      </div>
                      <ul className="steps mt-3 flex gap-[6px]" aria-hidden="true">
                        <li id="s1" className={state.stage >= 1 ? state.stage === 1 ? 'wait' : 'on' : ''}></li>
                        <li id="s2" className={state.stage >= 2 ? state.stage === 2 ? 'wait' : 'on' : ''}></li>
                        <li id="s3" className={state.stage === 3 ? 'on' : ''}></li>
                      </ul>
                      <div className="steps-l mt-[5px] flex gap-[6px] text-[.68rem] text-muted" aria-hidden="true"><span>Đã tiếp nhận</span><span>Thiết bị xác nhận</span><span>Đã
                          cập nhật</span></div>
                    </div>
                    <div className="rule col-span-full flex items-center gap-[.6rem] rounded-xl border border-dashed border-line px-[.8rem] py-[.6rem] text-[.8rem] text-muted"><svg className="i" aria-hidden="true">
                        <use href="#i-bolt" />
                      </svg><span>Luật <b>Làm mát phòng</b>: nhiệt độ ≥ 32°C thì tự bật quạt</span></div>
                  </div>
                  <div className={`toast${state.toastMessage ? ' show' : ''}`} id="toast"><svg className="i" aria-hidden="true">
                      <use href="#i-bolt" />
                    </svg><span id="toast-t">{state.toastMessage}</span></div>
                </div>

                <div className="float f1" aria-hidden="true">
                  <div className="ico"><svg className="i" aria-hidden="true">
                      <use href="#i-radio" />
                    </svg></div>
                  <div>MQTT trực tuyến<small>Phản hồi dưới 1 giây</small></div>
                </div>
                <div className="float f2" aria-hidden="true">
                  <div className="ico amber grid size-[46px] place-items-center rounded-[14px] text-teal-deep"><svg className="i" aria-hidden="true">
                      <use href="#i-check" />
                    </svg></div>
                  <div>Web và App đồng bộ<small>Cùng một nguồn dữ liệu</small></div>
                </div>
                <div className="phone absolute right-0 bottom-0 z-[3] aspect-[9/18.6] w-[198px] rotate-[2.5deg] rounded-[34px] bg-navy p-2 max-[760px]:relative max-[760px]:ml-auto max-[760px]:-mt-10 max-[760px]:block" aria-hidden="true">
                  <div className="phone-in relative flex size-full flex-col overflow-hidden rounded-[27px] bg-page" id="phone">
                    <div className="p-top px-[14px] pt-[30px] pb-[6px] font-display text-[.85rem] leading-normal font-bold"><small>Phòng thực hành A</small>Dashboard</div>
                    <div className="gauge relative mx-auto mt-1 mb-[2px] w-[104px]">
                      <svg viewBox="0 0 100 100">
                        <circle className="g-bg" cx="50" cy="50" r="40" />
                        <circle className="g-fg" id="g-fg" cx="50" cy="50" r="40" strokeDasharray="251.3"
                          strokeDashoffset={251.3 * (1 - gaugeProgress)} style={{ stroke: gaugeColor }} />
                      </svg>
                      <div><span id="p-temp">{state.temperature.toFixed(1)}°</span><small>Nhiệt độ</small></div>
                    </div>
                    <div className="p-card mx-[10px] my-[6px] flex items-center justify-between gap-[6px] rounded-[14px] border border-line bg-surface px-[10px] py-2 text-[.68rem]">
                      <div><b>Quạt phòng</b><span className="sub" id="p-sub">{phoneFanLabel}</span></div><button
                        className={`sw${state.stage > 0 ? ' pending' : ''}`} id="p-sw" role="switch"
                        aria-checked={state.fanOn} aria-label="Bật tắt quạt phòng trên bản xem trước điện thoại"
                        tabIndex={-1} onClick={handleFanToggle}></button>
                    </div>
                    <div className="p-card mx-[10px] my-[6px] flex items-center justify-between gap-[6px] rounded-[14px] border border-line bg-surface px-[10px] py-2 text-[.68rem]">
                      <div><b>Độ ẩm</b><span className="sub">Cập nhật vừa xong</span></div><b id="p-hum">{Math.round(state.humidity)}%</b>
                    </div>
                    <div className="tabs mt-auto grid grid-cols-4 border-t border-line bg-surface px-[2px] pt-[7px] pb-[9px]">
                      <div><svg className="i" aria-hidden="true">
                          <use href="#i-cpu" />
                        </svg>Thiết bị</div>
                      <div className="on"><svg className="i" aria-hidden="true">
                          <use href="#i-grid" />
                        </svg>Dashboard</div>
                      <div><svg className="i" aria-hidden="true">
                          <use href="#i-bolt" />
                        </svg>Tự động</div>
                      <div><svg className="i" aria-hidden="true">
                          <use href="#i-bell" />
                        </svg>Thông báo</div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>


          <div className="wrap stats-wrap mx-auto w-[min(1200px,calc(100%-48px))] relative z-[6] mt-[-84px]">
            <div className="stats grid grid-cols-4 rounded-[28px] border border-line p-[10px] shadow-card backdrop-blur-[18px] max-[1020px]:grid-cols-2">
              <div className="stat relative flex flex-col gap-[.2rem] px-[26px] py-[22px] max-[760px]:px-[18px] max-[760px]:py-4"><b data-n="2">0</b><span>Nền tảng dùng chung một hệ thống: Web và App</span></div>
              <div className="stat relative flex flex-col gap-[.2rem] px-[26px] py-[22px] max-[760px]:px-[18px] max-[760px]:py-4"><b data-n="6">0</b><span>Loại widget cho dashboard</span></div>
              <div className="stat relative flex flex-col gap-[.2rem] px-[26px] py-[22px] max-[760px]:px-[18px] max-[760px]:py-4"><b data-n="8">0</b><span>Điều kiện tối đa trong một luật</span></div>
              <div className="stat relative flex flex-col gap-[.2rem] px-[26px] py-[22px] max-[760px]:px-[18px] max-[760px]:py-4"><b data-n="5">0</b><span>Hành động tối đa trong một luật</span></div>
            </div>
          </div>
          <div className="marq overflow-hidden pt-14">
            <p>Xây dựng trên bộ công nghệ hiện đại</p>
            <div className="mask">
              <div className="track flex w-max gap-[14px]"><span className="tech flex items-center gap-[.6rem] whitespace-nowrap rounded-full border border-line bg-surface px-[1.2rem] py-[.7rem] font-display text-[.95rem] leading-normal font-semibold text-ink"><svg className="i" aria-hidden="true">
                    <use href="#i-cpu" />
                  </svg>ESP32</span><span className="tech flex items-center gap-[.6rem] whitespace-nowrap rounded-full border border-line bg-surface px-[1.2rem] py-[.7rem] font-display text-[.95rem] leading-normal font-semibold text-ink"><svg className="i" aria-hidden="true">
                    <use href="#i-radio" />
                  </svg>MQTT</span><span className="tech flex items-center gap-[.6rem] whitespace-nowrap rounded-full border border-line bg-surface px-[1.2rem] py-[.7rem] font-display text-[.95rem] leading-normal font-semibold text-ink"><svg className="i" aria-hidden="true">
                    <use href="#i-server" />
                  </svg>Rust</span><span className="tech flex items-center gap-[.6rem] whitespace-nowrap rounded-full border border-line bg-surface px-[1.2rem] py-[.7rem] font-display text-[.95rem] leading-normal font-semibold text-ink"><svg className="i" aria-hidden="true">
                    <use href="#i-monitor" />
                  </svg>React</span><span className="tech flex items-center gap-[.6rem] whitespace-nowrap rounded-full border border-line bg-surface px-[1.2rem] py-[.7rem] font-display text-[.95rem] leading-normal font-semibold text-ink"><svg className="i" aria-hidden="true">
                    <use href="#i-phone" />
                  </svg>Flutter</span><span className="tech flex items-center gap-[.6rem] whitespace-nowrap rounded-full border border-line bg-surface px-[1.2rem] py-[.7rem] font-display text-[.95rem] leading-normal font-semibold text-ink"><svg className="i" aria-hidden="true">
                    <use href="#i-layers" />
                  </svg>PostgreSQL</span><span className="tech flex items-center gap-[.6rem] whitespace-nowrap rounded-full border border-line bg-surface px-[1.2rem] py-[.7rem] font-display text-[.95rem] leading-normal font-semibold text-ink"><svg className="i" aria-hidden="true">
                    <use href="#i-bolt" />
                  </svg>Rule engine</span><span className="tech flex items-center gap-[.6rem] whitespace-nowrap rounded-full border border-line bg-surface px-[1.2rem] py-[.7rem] font-display text-[.95rem] leading-normal font-semibold text-ink"><svg className="i" aria-hidden="true">
                    <use href="#i-shield" />
                  </svg>ESP-IDF</span><span className="tech flex items-center gap-[.6rem] whitespace-nowrap rounded-full border border-line bg-surface px-[1.2rem] py-[.7rem] font-display text-[.95rem] leading-normal font-semibold text-ink"><svg className="i" aria-hidden="true">
                    <use href="#i-cpu" />
                  </svg>ESP32</span><span className="tech flex items-center gap-[.6rem] whitespace-nowrap rounded-full border border-line bg-surface px-[1.2rem] py-[.7rem] font-display text-[.95rem] leading-normal font-semibold text-ink"><svg className="i" aria-hidden="true">
                    <use href="#i-radio" />
                  </svg>MQTT</span><span className="tech flex items-center gap-[.6rem] whitespace-nowrap rounded-full border border-line bg-surface px-[1.2rem] py-[.7rem] font-display text-[.95rem] leading-normal font-semibold text-ink"><svg className="i" aria-hidden="true">
                    <use href="#i-server" />
                  </svg>Rust</span><span className="tech flex items-center gap-[.6rem] whitespace-nowrap rounded-full border border-line bg-surface px-[1.2rem] py-[.7rem] font-display text-[.95rem] leading-normal font-semibold text-ink"><svg className="i" aria-hidden="true">
                    <use href="#i-monitor" />
                  </svg>React</span><span className="tech flex items-center gap-[.6rem] whitespace-nowrap rounded-full border border-line bg-surface px-[1.2rem] py-[.7rem] font-display text-[.95rem] leading-normal font-semibold text-ink"><svg className="i" aria-hidden="true">
                    <use href="#i-phone" />
                  </svg>Flutter</span><span className="tech flex items-center gap-[.6rem] whitespace-nowrap rounded-full border border-line bg-surface px-[1.2rem] py-[.7rem] font-display text-[.95rem] leading-normal font-semibold text-ink"><svg className="i" aria-hidden="true">
                    <use href="#i-layers" />
                  </svg>PostgreSQL</span><span className="tech flex items-center gap-[.6rem] whitespace-nowrap rounded-full border border-line bg-surface px-[1.2rem] py-[.7rem] font-display text-[.95rem] leading-normal font-semibold text-ink"><svg className="i" aria-hidden="true">
                    <use href="#i-bolt" />
                  </svg>Rule engine</span><span className="tech flex items-center gap-[.6rem] whitespace-nowrap rounded-full border border-line bg-surface px-[1.2rem] py-[.7rem] font-display text-[.95rem] leading-normal font-semibold text-ink"><svg className="i" aria-hidden="true">
                    <use href="#i-shield" />
                  </svg>ESP-IDF</span></div>
            </div>
          </div>
    </>
  );
}
