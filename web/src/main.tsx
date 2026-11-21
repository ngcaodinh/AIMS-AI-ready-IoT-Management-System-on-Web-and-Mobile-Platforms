/// <reference types="vite/client" />
/** Khởi tạo điểm vào Web và chọn trang theo URL; chỉ mở route preview WB-03 trong bản dev. */
import { StrictMode, Suspense, lazy, type ComponentType, type ReactElement } from 'react';
import { createRoot } from 'react-dom/client';
import { HomePage } from './HomePage';
import { AuthPage } from './features/auth/AuthPage';
import './styles.css';

/**
 * Nạp lười trang preview WB-03 để bản build production không đóng gói kèm dữ liệu giả lập.
 * Output: promise module chứa default export là component `TemplatesPage`.
 */
async function loadTemplatesPreview(): Promise<{ default: ComponentType }> {
  const module = await import('./features/templates/TemplatesPage');
  return { default: module.TemplatesPage };
}

// Chỉ khởi tạo lazy component ở chế độ Vite dev; nhánh false bị loại bỏ khi build production.
const DevTemplatesPreview = import.meta.env.DEV ? lazy(loadTemplatesPreview) : null;

/**
 * Chọn màn hình hiển thị theo đường dẫn hiện tại mà giữ nguyên luồng trang chủ và auth ở production.
 * Output: phần tử React cho trang chủ `/`, preview dev `/dev/templates-preview`, hoặc luồng auth.
 */
function renderCurrentRoute(): ReactElement {
  if (import.meta.env.DEV && DevTemplatesPreview && window.location.pathname === '/dev/templates-preview') {
    return (
      <Suspense fallback={<p className="sr" role="status">Đang tải bản xem trước WB-03…</p>}>
        <DevTemplatesPreview />
      </Suspense>
    );
  }
  return window.location.pathname === '/' ? <HomePage /> : <AuthPage />;
}

const rootElement = document.getElementById('root');
if (!rootElement) throw new Error('Không tìm thấy phần tử gốc của ứng dụng Web.');

createRoot(rootElement).render(
  <StrictMode>
    {renderCurrentRoute()}
  </StrictMode>,
);
