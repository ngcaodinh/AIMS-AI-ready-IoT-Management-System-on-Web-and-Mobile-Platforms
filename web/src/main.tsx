import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { HomePage } from './HomePage';
import './styles.css';

const rootElement = document.getElementById('root');
if (!rootElement) throw new Error('Không tìm thấy phần tử gốc của ứng dụng Web.');

createRoot(rootElement).render(
  <StrictMode>
    <HomePage />
  </StrictMode>,
);
