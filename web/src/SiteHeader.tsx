import { useEffect, useRef, useState } from 'react';
import { BrandLink } from './BrandLink';

type Theme = 'light' | 'dark';

/** Khôi phục lựa chọn giao diện, hoặc dùng tùy chọn màu của hệ thống khi chưa lưu. */
function getInitialTheme(): Theme {
  try {
    const savedTheme = window.localStorage.getItem('nexa-theme');
    if (savedTheme === 'light' || savedTheme === 'dark') return savedTheme;
  } catch {
    // Trình duyệt có thể chặn storage; theme vẫn hoạt động trong phiên hiện tại.
  }
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

/** Hiển thị logo, điều hướng và các nút điều khiển đầu trang. */
export function SiteHeader() {
  const [theme, setTheme] = useState<Theme>(getInitialTheme);
  const [menuOpen, setMenuOpen] = useState(false);
  const [scrolled, setScrolled] = useState(false);
  const linksRef = useRef<HTMLElement>(null);
  const menuRef = useRef<HTMLButtonElement>(null);

  // Đồng bộ theme lên thẻ gốc và ghi lựa chọn khi trình duyệt cho phép lưu.
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    try {
      window.localStorage.setItem('nexa-theme', theme);
    } catch {
      // Không phụ thuộc khả năng ghi storage để đổi giao diện.
    }
  }, [theme]);

  // Lắng nghe cuộn chỉ trong vòng đời header để giữ trạng thái nền kính.
  useEffect(() => {
    /** Giữ hiệu ứng nền kính của header khi trang đã cuộn khỏi đầu. */
    function handleScroll(): void {
      setScrolled(window.scrollY > 8);
    }
    handleScroll();
    window.addEventListener('scroll', handleScroll, { passive: true });
    /** Gỡ listener khi rời trang để header không giữ cập nhật thừa. */
    return () => window.removeEventListener('scroll', handleScroll);
  }, []);

  // Listener Escape phụ thuộc trạng thái menu và được thay đúng lúc menu đổi trạng thái.
  useEffect(() => {
    /** Đóng menu di động bằng Escape và trả tiêu điểm về nút mở menu. */
    function handleEscape(event: KeyboardEvent): void {
      if (event.key !== 'Escape' || !menuOpen) return;
      setMenuOpen(false);
      menuRef.current?.focus();
    }
    document.addEventListener('keydown', handleEscape);
    /** Bỏ listener cũ trước khi menu đổi trạng thái hoặc header bị hủy. */
    return () => document.removeEventListener('keydown', handleEscape);
  }, [menuOpen]);

  // Chỉ chuyển tiêu điểm sau khi React đã công bố menu ở đúng trạng thái mở.
  useEffect(() => {
    if (menuOpen) linksRef.current?.querySelector('a')?.focus();
  }, [menuOpen]);

  /** Đảo theme khi người dùng nhấn nút trong thanh điều hướng. */
  function toggleTheme(): void {
    setTheme(
      /** Đảo từ lựa chọn mới nhất khi React gộp nhiều cập nhật trong cùng lượt. */
      (current) => current === 'dark' ? 'light' : 'dark',
    );
  }

  /** Mở menu di động và chuyển tiêu điểm tới liên kết đầu tiên. */
  function toggleMenu(): void {
    setMenuOpen(
      /** Đảo trạng thái menu hiện hành, không phụ thuộc giá trị render trước. */
      (current) => !current,
    );
  }

  /** Thu menu sau khi người dùng chọn một mục điều hướng. */
  function closeMenu(): void {
    setMenuOpen(false);
  }

  return (
    <>
      <header className={`nav sticky top-0 z-50 border-b border-transparent [background:color-mix(in_srgb,var(--surface)_62%,transparent)] backdrop-blur-[16px] backdrop-saturate-[1.4] transition-[border-color] duration-300${scrolled ? ' scrolled' : ''}`} id="nav">
          <div className="wrap mx-auto flex h-[72px] w-[min(1200px,calc(100%-48px))] items-center justify-between gap-4">
            <BrandLink href="#top" />
            <nav className={`links flex gap-8 text-[.95rem] font-medium text-muted${menuOpen ? ' open' : ''}`} id="links" aria-label="Điều hướng chính" ref={linksRef} onClick={closeMenu}>
              <a href="#features">Tính năng</a>
              <a href="#automation">Tự động hóa</a>
              <a href="#architecture">Cách hoạt động</a>
              <a href="#start">Bắt đầu</a>
              <a href="#security">Bảo mật</a>
            </nav>
            <div className="nav-actions flex items-center gap-[.6rem]">
              <button className="icon-btn grid size-11 place-items-center rounded-full border-[1.5px] border-line bg-surface text-ink cursor-pointer transition-all duration-[250ms] hover:rotate-[18deg] hover:border-teal" id="theme" type="button" aria-label="Đổi giao diện sáng/tối" onClick={toggleTheme}><svg className="i" aria-hidden="true"
                  id="theme-i">
                  <use href={theme === 'dark' ? '#i-sun' : '#i-moon'} />
                </svg></button>
              <a href="/login" className="btn btn-ghost">Đăng nhập</a>
              <button className="icon-btn menu-btn grid size-11 place-items-center rounded-full border-[1.5px] border-line bg-surface text-ink cursor-pointer transition-all duration-[250ms] hover:rotate-[18deg] hover:border-teal hidden max-[760px]:grid" id="menu" type="button" ref={menuRef}
                aria-label={menuOpen ? 'Đóng menu' : 'Mở menu'} aria-controls="links" aria-expanded={menuOpen}
                onClick={toggleMenu}><svg className="i" aria-hidden="true">
                  <use href="#i-menu" />
                </svg></button>
            </div>
          </div>
        </header>
    </>
  );
}
