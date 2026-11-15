import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  plugins: [react(), tailwindcss()],
  // Origin trình duyệt giữ nguyên; API không mở CORS để thay thế cookie/CSRF guard.
  server: {
    host: 'localhost', port: 5173, strictPort: true,
    proxy: { '/api/v1': { target: 'http://127.0.0.1:3000', changeOrigin: false } },
  },
});
