import assert from 'node:assert/strict';

/**
 * Cấp one-shot fault cho Vite lab để giữ cookie A khi response login B đã commit.
 * Output: arm/intercept/receipt với metadata boolean, không đọc hoặc trả cookie value.
 * Side effects: chỉ xóa header Set-Cookie của đúng một POST login200 sau ARM, body/context giữ nguyên.
 */
export function createBrowserCookieOmission() {
  let armed = false; let consumed = false;
  return Object.freeze({
    arm:
      /** ARM đúng một lần trước response, replay không cấp fault mới. */
      () => { assert.ok(!armed && !consumed, 'COOKIE_OMISSION_REPLAY'); armed = true; },
    intercept:
      /**
       * Chạy đồng bộ trước http-proxy forward headers, không giữ proxy response hoặc request body.
       * Input
       * Param: response — upstream response của proxy owned, chỉ xem status và sự có mặt của header.
       * Param: request — method/path do Vite chuyển tới backend loopback.
       */
      (response, request) => {
        if (!armed || request.method !== 'POST' || request.url !== '/api/v1/auth/login' || response.statusCode !== 200) return;
        assert.ok(response.headers && Object.hasOwn(response.headers, 'set-cookie'), 'COOKIE_OMISSION_HEADER_MISSING');
        delete response.headers['set-cookie']; armed = false; consumed = true;
      },
    receipt:
      /** Output: bản copy trạng thái fault, không header/context/credential. */
      () => ({ armed, consumed }),
  });
}
