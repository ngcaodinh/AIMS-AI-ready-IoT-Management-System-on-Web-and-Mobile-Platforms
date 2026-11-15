/** Khởi tạo điểm vào Web và chọn trang theo URL để tách luồng giới thiệu khỏi auth. */
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { HomePage } from './HomePage';
import { AuthPage } from './features/auth/AuthPage';
import './styles.css';

const rootElement = document.getElementById('root');
if (!rootElement) throw new Error('Không tìm thấy phần tử gốc của ứng dụng Web.');

createRoot(rootElement).render(
  <StrictMode>
    {window.location.pathname === '/' ? <HomePage /> : <AuthPage />}
  </StrictMode>,
);
