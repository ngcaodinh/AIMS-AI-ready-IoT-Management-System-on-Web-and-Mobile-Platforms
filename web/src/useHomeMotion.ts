import { useEffect } from 'react';

/** Gắn các hiệu ứng trang trí không ảnh hưởng dữ liệu React và gỡ chúng khi rời trang. */
export function useHomeMotion(): void {
  // DOM ở đây chỉ dùng cho hiệu ứng thị giác; dữ liệu và hành động demo do React quản lý.
  useEffect(() => {
    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    const progress = document.getElementById('progress');
    const cards = Array.from(document.querySelectorAll<HTMLElement>('.card'));
    const stage = document.getElementById('stage');
    const previewWindow = document.getElementById('win');
    const revealItems = Array.from(document.querySelectorAll<HTMLElement>(
      '.sec-head,.card,.row,.an,.tl,.fact,.flow,.panel,.cta,.stat',
    ));
    const counterTimers: number[] = [];

    /** Cập nhật thanh tiến trình cuộn theo chiều cao nội dung hiện tại. */
    function updateProgress(): void {
      const scrollableHeight = document.documentElement.scrollHeight - window.innerHeight;
      if (progress) progress.style.width = `${scrollableHeight > 0 ? window.scrollY / scrollableHeight * 100 : 0}%`;
    }

    /** Theo vị trí con trỏ để giữ hiệu ứng ánh sáng trên thẻ tính năng. */
    function moveSpotlight(event: PointerEvent): void {
      const card = event.currentTarget as HTMLElement;
      const bounds = card.getBoundingClientRect();
      card.style.setProperty('--mx', `${event.clientX - bounds.left}px`);
      card.style.setProperty('--my', `${event.clientY - bounds.top}px`);
    }

    /** Nghiêng cửa sổ xem trước nhẹ theo con trỏ trên thiết bị có hover. */
    function tiltPreview(event: PointerEvent): void {
      if (!stage || !previewWindow) return;
      const bounds = stage.getBoundingClientRect();
      const horizontal = (event.clientX - bounds.left) / bounds.width - 0.5;
      const vertical = (event.clientY - bounds.top) / bounds.height - 0.5;
      previewWindow.style.transform = `rotateY(${horizontal * 7}deg) rotateX(${-vertical * 6}deg)`;
    }

    /** Đưa cửa sổ xem trước về vị trí mặc định khi con trỏ rời khu vực demo. */
    function resetPreview(): void {
      if (previewWindow) previewWindow.style.transform = '';
    }

    /** Đếm số liệu khi thẻ thống kê đi vào khung nhìn. */
    function animateCounter(element: HTMLElement): void {
      const target = Number(element.dataset.n);
      let current = 0;
      const timer = window.setInterval(() => {
        current += 1;
        element.textContent = String(current);
        if (current >= target) window.clearInterval(timer);
      }, Math.max(60, 500 / target));
      counterTimers.push(timer);
    }

    window.addEventListener('scroll', updateProgress, { passive: true });
    updateProgress();
    cards.forEach((card) => card.addEventListener('pointermove', moveSpotlight));
    if (!reducedMotion && window.matchMedia('(hover:hover)').matches) {
      stage?.addEventListener('pointermove', tiltPreview);
      stage?.addEventListener('pointerleave', resetPreview);
    }

    let observer: IntersectionObserver | undefined;
    if (reducedMotion || !('IntersectionObserver' in window)) {
      document.querySelectorAll<HTMLElement>('[data-n]').forEach((element) => {
        element.textContent = element.dataset.n ?? '';
      });
    } else {
      revealItems.forEach((element) => {
        element.classList.add('rv');
        const siblingIndex = Array.from(element.parentElement?.children ?? []).indexOf(element);
        element.style.setProperty('--d', `${Math.min(siblingIndex, 5) * 0.08}s`);
      });
      observer = new IntersectionObserver((entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          entry.target.classList.add('in');
          observer?.unobserve(entry.target);
          const counter = entry.target.querySelector<HTMLElement>('[data-n]');
          if (counter) animateCounter(counter);
        });
      }, { threshold: 0.15, rootMargin: '0px 0px -6% 0px' });
      revealItems.forEach((element) => observer?.observe(element));
    }

    // Dọn listener, observer và timer để React StrictMode không nhân đôi hiệu ứng.
    return () => {
      window.removeEventListener('scroll', updateProgress);
      cards.forEach((card) => card.removeEventListener('pointermove', moveSpotlight));
      stage?.removeEventListener('pointermove', tiltPreview);
      stage?.removeEventListener('pointerleave', resetPreview);
      observer?.disconnect();
      counterTimers.forEach((timer) => window.clearInterval(timer));
      revealItems.forEach((element) => {
        element.classList.remove('rv', 'in');
        element.style.removeProperty('--d');
      });
      resetPreview();
    };
  }, []);
}
