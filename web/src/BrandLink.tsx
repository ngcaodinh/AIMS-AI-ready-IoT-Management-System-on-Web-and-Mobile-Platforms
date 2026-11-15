/**
 * Giữ một logo Nexa IoT cho trang chủ và màn xác thực, dùng đúng sprite và kiểu chữ gốc.
 * Input
 * Param: href — điểm điều hướng nội bộ; trang chủ dùng #top, các trang khác dùng /.
 * Output: liên kết thương hiệu có tên truy cập và vùng chạm tối thiểu44px; icon không bị đọc lặp.
 */
export function BrandLink({ href }: { href: string }) {
  return (
    <a href={href} className="logo flex min-h-11 items-center gap-[.65rem] font-display text-[1.3rem] leading-normal font-extrabold tracking-[-.03em]" aria-label="Nexa IoT — trang chủ" translate="no">
      <span className="logo-mark grid size-[34px] place-items-center rounded-[11px] text-white [background:var(--grad)]">
        <svg className="i" aria-hidden="true" focusable="false" style={{ strokeWidth: 2.2 }}><use href="#i-radio" /></svg>
      </span>
      Nexa IoT
    </a>
  );
}
