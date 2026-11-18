import { defineConfig } from '@playwright/test';

/** Cấu hình E2E auth chạy tuần tự trên Chrome cài sẵn, không ghi trace/video/screenshot chứa credential. */
export default defineConfig({
  testDir: './e2e',
  testMatch: '**/*.spec.mjs',
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: 'line',
  timeout: 1_230_000,
  expect: { timeout: 10_000 },
  outputDir: 'test-results/auth-e2e',
  preserveOutput: 'never',
  webServer: {
    command: 'npm.cmd run dev',
    url: 'http://localhost:5173/login',
    reuseExistingServer: true,
    timeout: 30_000,
  },
  use: {
    baseURL: 'http://localhost:5173',
    browserName: 'chromium',
    headless: true,
    launchOptions: { channel: 'chrome' },
    screenshot: 'off',
    trace: 'off',
    video: 'off',
  },
});
