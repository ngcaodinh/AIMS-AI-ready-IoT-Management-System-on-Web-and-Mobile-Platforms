/** Giới thiệu các khả năng quản lý thiết bị và dashboard. */
export function FeaturesSection() {
  return (
    <>
      <section id="features" className="py-[120px] max-[760px]:py-[76px]">
            <div className="wrap mx-auto w-[min(1200px,calc(100%-48px))]">
              <div className="sec-head mb-14 max-w-[46rem]">
                <h2>Mọi việc với thiết bị, gọn trong một nơi</h2>
                <p>Từ xem số đo đến ra lệnh và nhận kết quả, bạn luôn biết chuyện gì đang xảy ra với thiết bị của mình.</p>
              </div>
              <div className="bento grid grid-cols-6 gap-[18px]">
                <article className="card c-a relative isolate overflow-hidden rounded-card border border-line p-7 transition-[transform,box-shadow,border-color] duration-[350ms] hover:-translate-y-1.5 hover:shadow-[var(--glow)] hover:border-[color-mix(in_srgb,var(--teal)_45%,var(--line))] col-span-4 max-[1020px]:col-span-6">
                  <div className="ico"><svg className="i" aria-hidden="true">
                      <use href="#i-check" />
                    </svg></div>
                  <h3>Điều khiển có xác nhận thật</h3>
                  <p>Hệ thống không báo thành công khi mới nhận lệnh. Bạn chỉ thấy “đã xác nhận” khi chính thiết bị trả kết
                    quả; nếu thiết bị im lặng, lệnh được đánh dấu rõ ràng và không tự gửi lại.</p>
                  <div className="states mt-[22px] grid grid-cols-4 gap-[10px] max-[760px]:grid-cols-2">
                    <div className="state st-wait flex flex-col gap-2 rounded-[14px] px-3 pt-3 pb-[14px] text-[.82rem] leading-[1.3] font-semibold transition-transform duration-300 hover:-translate-y-1 hover:-rotate-1 bg-amber-soft text-[#8A5A00] [[data-theme=dark]_&]:text-amber"><svg className="i" aria-hidden="true">
                        <use href="#i-clock" />
                      </svg>Đã tiếp nhận<small>Lệnh đang chờ thiết bị</small></div>
                    <div className="state st-ok flex flex-col gap-2 rounded-[14px] px-3 pt-3 pb-[14px] text-[.82rem] leading-[1.3] font-semibold transition-transform duration-300 hover:-translate-y-1 hover:-rotate-1 bg-teal-soft text-teal-deep"><svg className="i" aria-hidden="true">
                        <use href="#i-check" />
                      </svg>Thiết bị đã xác nhận<small>Trạng thái được cập nhật</small></div>
                    <div className="state st-bad flex flex-col gap-2 rounded-[14px] px-3 pt-3 pb-[14px] text-[.82rem] leading-[1.3] font-semibold transition-transform duration-300 hover:-translate-y-1 hover:-rotate-1 bg-coral-soft text-[#B23A2A] [[data-theme=dark]_&]:text-[#FF8D7C]"><svg className="i" aria-hidden="true">
                        <use href="#i-x" />
                      </svg>Thất bại<small>Kèm lý do cụ thể</small></div>
                    <div className="state st-unk flex flex-col gap-2 rounded-[14px] px-3 pt-3 pb-[14px] text-[.82rem] leading-[1.3] font-semibold transition-transform duration-300 hover:-translate-y-1 hover:-rotate-1 bg-page-soft text-muted"><svg className="i" aria-hidden="true">
                        <use href="#i-help" />
                      </svg>Chưa xác định<small>Hết hạn, chưa có phản hồi</small></div>
                  </div>
                </article>
                <article className="card c-b relative isolate overflow-hidden rounded-card border border-line p-7 transition-[transform,box-shadow,border-color] duration-[350ms] hover:-translate-y-1.5 hover:shadow-[var(--glow)] hover:border-[color-mix(in_srgb,var(--teal)_45%,var(--line))] col-span-2 max-[1020px]:col-span-6">
                  <div className="ico amber grid size-[46px] place-items-center rounded-[14px] text-teal-deep"><svg className="i" aria-hidden="true">
                      <use href="#i-grid" />
                    </svg></div>
                  <h3>Dashboard của riêng bạn</h3>
                  <p>Kéo thả trên Web, App tự sắp lại theo thứ tự màn hình nhỏ.</p>
                  <div className="widgets mt-5 grid grid-cols-3 gap-2"><span>Giá trị</span><span>Đồng hồ</span><span>Trạng thái</span><span>Công
                      tắc</span><span>Nút bấm</span><span>Biểu đồ</span></div>
                </article>
                <article className="card c-c relative isolate overflow-hidden rounded-card border border-line p-7 transition-[transform,box-shadow,border-color] duration-[350ms] hover:-translate-y-1.5 hover:shadow-[var(--glow)] hover:border-[color-mix(in_srgb,var(--teal)_45%,var(--line))] col-span-2 max-[1020px]:col-span-6">
                  <div className="ico"><svg className="i" aria-hidden="true">
                      <use href="#i-pulse" />
                    </svg></div>
                  <h3>Lịch sử rõ ràng</h3>
                  <p>Xem 1 giờ, 24 giờ hay 7 ngày. Chỗ thiếu dữ liệu hiện là khoảng trống, không bị tính thành số 0. Xuất CSV
                    tối đa 10.000 dòng.</p>
                  <div className="mini-chart mt-[18px] h-[70px]"><svg viewBox="0 0 200 70" preserveAspectRatio="none" aria-hidden="true">
                      <path d="M0 50 C20 20 40 55 60 35 S95 10 110 30" fill="none" stroke="var(--teal)" strokeWidth="3"
                        strokeLinecap="round" />
                      <path d="M135 38 C150 22 170 48 200 18" fill="none" stroke="var(--teal)" strokeWidth="3"
                        strokeLinecap="round" />
                      <path d="M110 30 L135 38" stroke="var(--line)" strokeWidth="2" strokeDasharray="4 5" />
                    </svg></div>
                </article>
                <article className="card c-d relative isolate overflow-hidden rounded-card border border-line p-7 transition-[transform,box-shadow,border-color] duration-[350ms] hover:-translate-y-1.5 hover:shadow-[var(--glow)] hover:border-[color-mix(in_srgb,var(--teal)_45%,var(--line))] col-span-2 max-[1020px]:col-span-6">
                  <div className="ico coral grid size-[46px] place-items-center rounded-[14px] text-teal-deep"><svg className="i" aria-hidden="true">
                      <use href="#i-bell" />
                    </svg></div>
                  <h3>Thông báo không bỏ sót</h3>
                  <p>Cảnh báo đẩy đến điện thoại ngay cả khi App đang đóng. Xác nhận một lần, mọi thiết bị của bạn cùng đồng
                    bộ.</p>
                  <div className="tags mt-[18px] flex flex-wrap gap-[.4rem]"><span>Android</span><span>Hộp thư sự kiện</span></div>
                </article>
                <article className="card c-e relative isolate overflow-hidden rounded-card border border-line p-7 transition-[transform,box-shadow,border-color] duration-[350ms] hover:-translate-y-1.5 hover:shadow-[var(--glow)] hover:border-[color-mix(in_srgb,var(--teal)_45%,var(--line))] col-span-2 max-[1020px]:col-span-6">
                  <div className="ico amber grid size-[46px] place-items-center rounded-[14px] text-teal-deep"><svg className="i" aria-hidden="true">
                      <use href="#i-layers" />
                    </svg></div>
                  <h3>Nhiều workspace</h3>
                  <p>Tách riêng nhà, lớp học hay xưởng. Mỗi nơi có thành viên, thiết bị và dữ liệu độc lập.</p>
                  <div className="tags mt-[18px] flex flex-wrap gap-[.4rem]"><span>Admin</span><span>User</span><span>Lời mời</span></div>
                </article>
              </div>
            </div>
          </section>
    </>
  );
}

/** Giới thiệu các tính năng mở rộng cho thiết bị và tích hợp. */
export function ExtensionsSection() {
  return (
    <>
      <section id="extend" className="pt-0 pb-[120px] max-[760px]:pb-[76px]">
            <div className="wrap split mx-auto w-[min(1200px,calc(100%-48px))] grid grid-cols-[minmax(0,.8fr)_minmax(0,1.2fr)] items-start gap-16 max-[1020px]:grid-cols-1">
              <div className="sec-head mb-14 max-w-[46rem]">
                <h2>Thêm thiết bị, cập nhật và kết nối ra ngoài</h2>
                <p>Những việc vận hành hằng ngày cũng được làm gọn, để bạn không phải cầm dây cáp hay viết lại cấu hình.</p>
              </div>
              <div className="rows border-t border-line">
                <div className="row relative grid grid-cols-[54px_1fr_auto] items-center gap-[18px] border-b border-line px-2 py-[26px] transition-[background,padding] duration-300 hover:rounded-2xl hover:bg-surface hover:px-5 hover:shadow-card max-[760px]:grid-cols-[48px_1fr]">
                  <div className="ico"><svg className="i" aria-hidden="true">
                      <use href="#i-qr" />
                    </svg></div>
                  <div>
                    <h3>Thêm thiết bị bằng QR và Bluetooth</h3>
                    <p>Quét mã trên thiết bị, gửi Wi-Fi qua BLE có mã xác thực, và theo dõi đến khi thiết bị lên mạng.</p>
                  </div><span className="tg whitespace-nowrap rounded-full bg-teal-soft px-[.7rem] py-1 text-[.76rem] font-semibold text-teal-deep max-[760px]:hidden">App</span>
                </div>
                <div className="row relative grid grid-cols-[54px_1fr_auto] items-center gap-[18px] border-b border-line px-2 py-[26px] transition-[background,padding] duration-300 hover:rounded-2xl hover:bg-surface hover:px-5 hover:shadow-card max-[760px]:grid-cols-[48px_1fr]">
                  <div className="ico amber grid size-[46px] place-items-center rounded-[14px] text-teal-deep"><svg className="i" aria-hidden="true">
                      <use href="#i-dl" />
                    </svg></div>
                  <div>
                    <h3>Cập nhật firmware từ xa</h3>
                    <p>Chọn gói đã kiểm tra, cập nhật từng thiết bị, xem tiến trình và tự quay về bản cũ nếu bản mới không
                      hoạt động.</p>
                  </div><span className="tg whitespace-nowrap rounded-full bg-teal-soft px-[.7rem] py-1 text-[.76rem] font-semibold text-teal-deep max-[760px]:hidden">Web &amp; App</span>
                </div>
                <div className="row relative grid grid-cols-[54px_1fr_auto] items-center gap-[18px] border-b border-line px-2 py-[26px] transition-[background,padding] duration-300 hover:rounded-2xl hover:bg-surface hover:px-5 hover:shadow-card max-[760px]:grid-cols-[48px_1fr]">
                  <div className="ico"><svg className="i" aria-hidden="true">
                      <use href="#i-key" />
                    </svg></div>
                  <div>
                    <h3>API key cho hệ thống khác</h3>
                    <p>Cấp khóa theo phạm vi để đọc dữ liệu hoặc điều khiển thiết bị. Khóa chỉ hiện một lần, thu hồi được bất
                      cứ lúc nào.</p>
                  </div><span className="tg whitespace-nowrap rounded-full bg-teal-soft px-[.7rem] py-1 text-[.76rem] font-semibold text-teal-deep max-[760px]:hidden">Web</span>
                </div>
                <div className="row relative grid grid-cols-[54px_1fr_auto] items-center gap-[18px] border-b border-line px-2 py-[26px] transition-[background,padding] duration-300 hover:rounded-2xl hover:bg-surface hover:px-5 hover:shadow-card max-[760px]:grid-cols-[48px_1fr]">
                  <div className="ico coral grid size-[46px] place-items-center rounded-[14px] text-teal-deep"><svg className="i" aria-hidden="true">
                      <use href="#i-link" />
                    </svg></div>
                  <div>
                    <h3>Webhook đẩy sự kiện ra ngoài</h3>
                    <p>Gửi sự kiện đến dịch vụ của bạn, tự thử lại khi lỗi và xem lịch sử từng lần gửi để đối soát.</p>
                  </div><span className="tg whitespace-nowrap rounded-full bg-teal-soft px-[.7rem] py-1 text-[.76rem] font-semibold text-teal-deep max-[760px]:hidden">Web</span>
                </div>
              </div>
            </div>
          </section>
    </>
  );
}

/** Giải thích các thành phần của nền tảng IoT. */
export function ArchitectureSection() {
  return (
    <>
      <section id="architecture" className="py-[120px] max-[760px]:py-[76px]">
            <div className="wrap mx-auto w-[min(1200px,calc(100%-48px))]">
              <div className="sec-head mb-14 max-w-[46rem]">
                <h2>Từ cảm biến đến màn hình trong vài bước</h2>
                <p>Web và App cùng dùng một máy chủ, một bộ quy tắc và một nguồn dữ liệu, nên số liệu và quyền luôn khớp nhau.
                </p>
              </div>
              <div className="arch relative grid grid-cols-5 items-stretch max-[1020px]:grid-cols-1 max-[1020px]:gap-[14px]">
                <div className="pipe"><i></i><i></i><i></i></div>
                <div className="an relative z-[1] rounded-[16px] border border-line p-[22px_16px] text-center transition-[transform,box-shadow,border-color] duration-[350ms] hover:-translate-y-2 hover:border-teal hover:shadow-[var(--glow)]">
                  <div className="ico"><svg className="i" aria-hidden="true">
                      <use href="#i-cpu" />
                    </svg></div>
                  <h3>Thiết bị ESP32</h3>
                  <p>Đo nhiệt độ, độ ẩm và nhận lệnh bật tắt</p>
                </div>
                <div className="an relative z-[1] rounded-[16px] border border-line p-[22px_16px] text-center transition-[transform,box-shadow,border-color] duration-[350ms] hover:-translate-y-2 hover:border-teal hover:shadow-[var(--glow)]">
                  <div className="ico amber grid size-[46px] place-items-center rounded-[14px] text-teal-deep"><svg className="i" aria-hidden="true">
                      <use href="#i-radio" />
                    </svg></div>
                  <h3>MQTT broker</h3>
                  <p>Mỗi thiết bị chỉ dùng đúng kênh của mình</p>
                </div>
                <div className="an relative z-[1] rounded-[16px] border border-line p-[22px_16px] text-center transition-[transform,box-shadow,border-color] duration-[350ms] hover:-translate-y-2 hover:border-teal hover:shadow-[var(--glow)]">
                  <div className="ico"><svg className="i" aria-hidden="true">
                      <use href="#i-server" />
                    </svg></div>
                  <h3>Backend</h3>
                  <p>Lưu dữ liệu, chạy luật và ghi nhật ký</p>
                </div>
                <div className="an relative z-[1] rounded-[16px] border border-line p-[22px_16px] text-center transition-[transform,box-shadow,border-color] duration-[350ms] hover:-translate-y-2 hover:border-teal hover:shadow-[var(--glow)]">
                  <div className="ico amber grid size-[46px] place-items-center rounded-[14px] text-teal-deep"><svg className="i" aria-hidden="true">
                      <use href="#i-monitor" />
                    </svg></div>
                  <h3>Web</h3>
                  <p>Quản trị, dashboard, trình tạo luật</p>
                </div>
                <div className="an relative z-[1] rounded-[16px] border border-line p-[22px_16px] text-center transition-[transform,box-shadow,border-color] duration-[350ms] hover:-translate-y-2 hover:border-teal hover:shadow-[var(--glow)]">
                  <div className="ico"><svg className="i" aria-hidden="true">
                      <use href="#i-phone" />
                    </svg></div>
                  <h3>App di động</h3>
                  <p>Giám sát, điều khiển, thông báo đẩy</p>
                </div>
              </div>
              <div className="arch-gap mt-[22px] flex flex-wrap justify-center gap-[14px]"><span className="chip inline-flex items-center gap-[.45rem] rounded-full border border-line bg-surface px-[.8rem] py-[.4rem] text-[.82rem] font-medium text-muted">Rust</span><span className="chip inline-flex items-center gap-[.45rem] rounded-full border border-line bg-surface px-[.8rem] py-[.4rem] text-[.82rem] font-medium text-muted">React + TypeScript</span><span
                  className="chip inline-flex items-center gap-[.45rem] rounded-full border border-line bg-surface px-[.8rem] py-[.4rem] text-[.82rem] font-medium text-muted">Flutter</span><span className="chip inline-flex items-center gap-[.45rem] rounded-full border border-line bg-surface px-[.8rem] py-[.4rem] text-[.82rem] font-medium text-muted">C++ / ESP-IDF</span><span className="chip inline-flex items-center gap-[.45rem] rounded-full border border-line bg-surface px-[.8rem] py-[.4rem] text-[.82rem] font-medium text-muted">PostgreSQL</span></div>
            </div>
          </section>
    </>
  );
}

/** Trình bày các bước bắt đầu sử dụng nền tảng. */
export function StartSection() {
  return (
    <>
      <section id="start" className="pt-6 pb-[120px] max-[760px]:pb-[76px]">
            <div className="wrap mx-auto w-[min(1200px,calc(100%-48px))]">
              <div className="sec-head mb-14 max-w-[46rem]">
                <h2>Bắt đầu trong bốn bước</h2>
                <p>Từ tài khoản trống đến thiết bị đầu tiên chạy kịch bản tự động.</p>
              </div>
              <div className="timeline relative grid grid-cols-4 gap-5 max-[1020px]:grid-cols-2 max-[1020px]:gap-x-5 max-[1020px]:gap-y-9 max-[760px]:grid-cols-1">
                <div className="tl relative pt-14 transition-transform duration-[350ms] hover:-translate-y-[5px]">
                  <h3>Tạo workspace</h3>
                  <p>Đặt tên, mời thành viên và chọn vai trò Admin hoặc User cho từng người.</p>
                </div>
                <div className="tl relative pt-14 transition-transform duration-[350ms] hover:-translate-y-[5px]">
                  <h3>Thêm thiết bị</h3>
                  <p>Quét QR, gửi Wi-Fi qua Bluetooth và chờ thiết bị báo trực tuyến.</p>
                </div>
                <div className="tl relative pt-14 transition-transform duration-[350ms] hover:-translate-y-[5px]">
                  <h3>Dựng dashboard</h3>
                  <p>Chọn thiết bị, kéo các widget vào vị trí và lưu để dùng trên cả App.</p>
                </div>
                <div className="tl relative pt-14 transition-transform duration-[350ms] hover:-translate-y-[5px]">
                  <h3>Bật kịch bản</h3>
                  <p>Tạo luật, chạy thử, rồi bật. Mỗi lần chạy đều có lịch sử để xem lại.</p>
                </div>
              </div>
            </div>
          </section>
    </>
  );
}

/** Trình bày ranh giới quyền và nhật ký thao tác. */
export function SecuritySection() {
  return (
    <>
      <section className="trust mx-6 rounded-[40px] bg-page-soft py-[120px] max-[760px]:mx-3 max-[760px]:rounded-[28px] max-[760px]:py-[76px]" id="security">
            <div className="wrap trust-grid mx-auto w-[min(1200px,calc(100%-48px))] grid grid-cols-[minmax(0,.9fr)_minmax(0,1.1fr)] items-center gap-14 max-[1020px]:grid-cols-1">
              <div>
                <h2>Đúng người, đúng thiết bị, có ghi lại</h2>
                <p className="lead">Quyền được kiểm tra ở máy chủ, không chỉ ẩn nút trên giao diện. Thiết bị nào, người nào cũng
                  chỉ thấy phần của mình.</p>
              </div>
              <div className="facts grid gap-[14px]">
                <div className="fact flex items-start gap-4 rounded-[16px] border border-line bg-surface px-5 py-[18px] transition-[transform,box-shadow,border-color] duration-300 hover:translate-x-2 hover:border-teal hover:shadow-card">
                  <div className="ico"><svg className="i" aria-hidden="true">
                      <use href="#i-layers" />
                    </svg></div>
                  <div><b>Vai trò theo từng workspace</b><span>Admin và User được cấp riêng ở mỗi nơi; tạm khóa ở workspace
                      này không ảnh hưởng workspace khác.</span></div>
                </div>
                <div className="fact flex items-start gap-4 rounded-[16px] border border-line bg-surface px-5 py-[18px] transition-[transform,box-shadow,border-color] duration-300 hover:translate-x-2 hover:border-teal hover:shadow-card">
                  <div className="ico amber grid size-[46px] place-items-center rounded-[14px] text-teal-deep"><svg className="i" aria-hidden="true">
                      <use href="#i-cpu" />
                    </svg></div>
                  <div><b>Thiết bị bị giới hạn kênh</b><span>Mỗi thiết bị chỉ gửi và nhận trên chủ đề của chính nó, thu hồi
                      được ngay khi cần.</span></div>
                </div>
                <div className="fact flex items-start gap-4 rounded-[16px] border border-line bg-surface px-5 py-[18px] transition-[transform,box-shadow,border-color] duration-300 hover:translate-x-2 hover:border-teal hover:shadow-card">
                  <div className="ico coral grid size-[46px] place-items-center rounded-[14px] text-teal-deep"><svg className="i" aria-hidden="true">
                      <use href="#i-shield" />
                    </svg></div>
                  <div><b>Ngoài quyền thì không thấy gì</b><span>Mở thiết bị không được gán sẽ nhận “không tìm thấy”, không lộ
                      dữ liệu.</span></div>
                </div>
                <div className="fact flex items-start gap-4 rounded-[16px] border border-line bg-surface px-5 py-[18px] transition-[transform,box-shadow,border-color] duration-300 hover:translate-x-2 hover:border-teal hover:shadow-card">
                  <div className="ico"><svg className="i" aria-hidden="true">
                      <use href="#i-check" />
                    </svg></div>
                  <div><b>Nhật ký cho mọi thao tác quan trọng</b><span>Cấu hình, điều khiển, luật và thu hồi đều ghi lại người
                      làm, thời điểm và kết quả.</span></div>
                </div>
              </div>
            </div>
          </section>
    </>
  );
}

/** Mời người dùng bắt đầu thiết lập thiết bị. */
export function CallToActionSection() {
  return (
    <>
      <section className="pt-[120px] pb-[72px] max-[760px]:pt-[76px]" >
            <div className="wrap mx-auto w-[min(1200px,calc(100%-48px))]">
              <div className="cta relative overflow-hidden rounded-[40px] px-14 py-[72px] text-center text-white max-[760px]:rounded-[28px] max-[760px]:px-6 max-[760px]:py-14">
                <h2>Sẵn sàng cho thiết bị đầu tiên?</h2>
                <p>Tạo workspace, thêm một cảm biến và xem số liệu chạy trên cả Web lẫn điện thoại.</p>
                <div className="cta-row flex flex-wrap justify-center gap-[.8rem]">
                  <a href="#" className="btn btn-primary">Tạo workspace <svg className="i" aria-hidden="true">
                      <use href="#i-arrow" />
                    </svg></a>
                  <a href="#" className="btn btn-ghost">Đăng nhập</a>
                </div>
              </div>
            </div>
          </section>
    </>
  );
}

/** Hiển thị liên kết và thông tin cuối trang. */
export function SiteFooter() {
  return (
    <>
      <footer className="pt-16 pb-10 text-[.92rem] text-muted">
          <div className="wrap mx-auto w-[min(1200px,calc(100%-48px))]">
            <div className="foot grid grid-cols-[1.4fr_repeat(3,1fr)] gap-10 max-[1020px]:grid-cols-2 max-[760px]:grid-cols-1">
              <div><a href="#top" className="logo flex items-center gap-[.65rem] font-display text-[1.3rem] leading-normal font-extrabold tracking-[-.03em]" style={{ padding: 0 }}><span className="logo-mark grid size-[34px] place-items-center rounded-[11px] text-white [background:var(--grad)]"><svg className="i" aria-hidden="true"
                      style={{ strokeWidth: 2.2 }}>
                      <use href="#i-radio" />
                    </svg></span>Nexa IoT</a>
                <p>Nền tảng giám sát, điều khiển và tự động hóa thiết bị IoT trên Web và ứng dụng di động.</p>
              </div>
              <div>
                <h4>Sản phẩm</h4><a href="#features">Tính năng</a><a href="#automation">Tự động hóa</a><a href="#extend">Tích
                  hợp</a>
              </div>
              <div>
                <h4>Tìm hiểu</h4><a href="#architecture">Cách hoạt động</a><a href="#start">Bắt đầu</a><a href="#security">Bảo
                  mật</a>
              </div>
              <div>
                <h4>Tài khoản</h4><a href="#">Đăng nhập</a><a href="#">Tạo workspace</a><a href="#">Liên hệ</a>
              </div>
            </div>
            <div className="copy mt-12 flex flex-wrap justify-between gap-2 border-t border-line pt-6 text-[.84rem]"><span>© 2026 Nexa IoT. Đồ án tốt nghiệp — bản thiết kế giao diện trang chủ.</span><span>Phiên
                bản tài liệu 3.0</span></div>
          </div>
        </footer>
    </>
  );
}
