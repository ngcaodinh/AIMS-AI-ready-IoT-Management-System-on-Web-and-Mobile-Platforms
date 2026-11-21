import { expect, test } from '@playwright/test';

/** Chặn API trong các ca preview để chỉ quan sát adapter tổng hợp trong bộ nhớ.
 * Input
 * Param: page — trang Playwright cần chặn các route API trước khi điều hướng.
 * Output: các method/path API bị gọi, không giữ query hoặc nội dung request.
 * Side effects
 * Đăng ký route guard cục bộ và trả response 501 tổng hợp thay vì gửi request tới dịch vụ.
 */
async function installPreviewApiGuard(page) {
  const apiRequests = [];
  await page.route('**/api/v1/**',
    /** Chặn request API và chỉ lưu method/path để không để test thoát khỏi mock preview.
     * Input
     * Param: route — request cục bộ cần chặn trước khi gọi API thật.
     * Side effects
     * Ghi method/path và trả response 501 tổng hợp, không ghi body hoặc header.
     */
    async (route) => {
      const request = route.request();
      apiRequests.push({
        method: request.method(),
        path: new URL(request.url()).pathname,
      });
      await route.fulfill({ status: 501, body: 'API calls are blocked in this preview test.' });
    },
  );
  return apiRequests;
}

test(
  'WB-03 dev preview labels the synthetic memory-only boundary without calling template APIs',
  /** Kiểm tra nhãn phạm vi preview và bảo đảm danh sách mẫu không gọi API template thật.
   * Input
   * Param: page — trang Playwright cô lập dùng để mở route preview phát triển.
   * Side effects
   * Chặn mọi API cục bộ để không gửi request ra ngoài test rồi tải route preview.
   */
  async ({ page }) => {
    const apiRequests = [];
    await page.route('**/api/v1/**',
      /** Chặn và ghi nhận request API nếu preview vô tình thoát khỏi adapter trong bộ nhớ.
       * Input
       * Param: route — request cục bộ cần chặn để test không gọi dịch vụ API.
       * Side effects
       * Lưu method/path không nhạy cảm và trả phản hồi 501 tổng hợp.
       */
      async (route) => {
        const request = route.request();
        apiRequests.push({
          method: request.method(),
          path: new URL(request.url()).pathname,
        });
        await route.fulfill({ status: 501, body: 'API calls are blocked in this preview test.' });
      },
    );

    await page.goto('/dev/templates-preview');

    const previewBanner = page.getByRole('region', { name: 'Cảnh báo chế độ xem trước phát triển' });
    await expect(previewBanner).toContainText('Không lưu trên máy chủ');
    await expect(previewBanner).toContainText('không gửi API');
    await expect(page.getByRole('heading', { name: 'Templates', exact: true })).toBeVisible();
    expect(apiRequests).toEqual([]);
  },
);

test(
  'a dirty preview draft asks before switching synthetic workspaces and stays in memory',
  /** Kiểm tra người dùng giữ được bản nhập khi ở lại và chỉ bỏ nó sau khi xác nhận đổi workspace mẫu.
   * Input
   * Param: page — trang Playwright cô lập dùng để thao tác route preview phát triển.
   * Side effects
   * Chặn API cục bộ, mở bản nháp trống và chuyển sang fixture workspace tổng hợp khác.
   */
  async ({ page }) => {
    const apiRequests = [];
    await page.route('**/api/v1/**',
      /** Chặn request API để thao tác chỉ kiểm tra state của adapter in-memory.
       * Input
       * Param: route — request cục bộ cần chặn để test không gọi dịch vụ API.
       * Side effects
       * Lưu method/path không nhạy cảm và trả phản hồi 501 tổng hợp.
       */
      async (route) => {
        const request = route.request();
        apiRequests.push({
          method: request.method(),
          path: new URL(request.url()).pathname,
        });
        await route.fulfill({ status: 501, body: 'API calls are blocked in this preview test.' });
      },
    );

    await page.goto('/dev/templates-preview');
    const createButton = page.getByRole('button', { name: 'Tạo template', exact: true });
    await expect(createButton).toBeEnabled();
    await createButton.click();

    const templateName = page.getByRole('textbox', { name: 'Tên template' });
    await templateName.fill('Bản nháp cục bộ đang chỉnh sửa');

    const workspaceSelect = page.getByLabel('Ngữ cảnh workspace tổng hợp');
    await workspaceSelect.selectOption('ws-preview-empty-c');
    const discardDialog = page.getByRole('alertdialog');
    await expect(discardDialog).toContainText('chuyển sang workspace khác');
    await discardDialog.getByRole('button', { name: 'Ở lại trình chỉnh sửa', exact: true }).click();
    await expect(templateName).toHaveValue('Bản nháp cục bộ đang chỉnh sửa');

    await workspaceSelect.selectOption('ws-preview-empty-c');
    await page.getByRole('alertdialog')
      .getByRole('button', { name: 'Bỏ thay đổi và tiếp tục', exact: true })
      .click();

    await expect(page.getByText('Workspace này chưa có template nào', { exact: true })).toBeVisible();
    await expect(page.getByText('Kho thiết bị trống (Dữ liệu mẫu)', { exact: true })).toBeVisible();
    expect(apiRequests).toEqual([]);
  },
);

test(
  'mock validation maps a 422 model error to its field and preserves the draft input',
  /** Kiểm tra lỗi validation mock được gắn đúng path `/model` và không xóa nội dung người dùng.
   * Input
   * Param: page — trang Playwright cô lập dùng để gửi form preview không hợp lệ.
   * Side effects
   * Chặn API, mở form draft mới và gửi model không hợp lệ tới adapter trong bộ nhớ.
   */
  async ({ page }) => {
    const apiRequests = await installPreviewApiGuard(page);
    await page.goto('/dev/templates-preview');
    await page.getByRole('button', { name: 'Tạo template', exact: true }).click();

    const templateName = page.getByRole('textbox', { name: 'Tên template' });
    const modelField = page.getByRole('combobox', { name: /Mã model chuẩn/ });
    await templateName.fill('Draft model không hợp lệ');
    await modelField.fill('invalid model!');
    await page.getByRole('button', { name: 'Tạo bản nháp (chỉ preview)', exact: true }).click();

    const fieldErrorSummary = page.getByRole('alert');
    await expect(fieldErrorSummary).toContainText('/model');
    await expect(modelField).toHaveAttribute('aria-invalid', 'true');
    await expect(templateName).toHaveValue('Draft model không hợp lệ');
    await expect(modelField).toHaveValue('invalid model!');
    expect(apiRequests).toEqual([]);
  },
);

test(
  'mock 412 keeps local edits until the user reapplies them on the returned revision',
  /** Kiểm tra xử lý 412 của mock giữ riêng bản local và chỉ lưu sau thao tác reapply rõ ràng.
   * Input
   * Param: page — trang Playwright cô lập dùng để mở fixture draft và mô phỏng xung đột.
   * Side effects
   * Chặn API, sửa một fixture draft và kích hoạt rồi hòa giải scenario `stale_412`.
   */
  async ({ page }) => {
    const apiRequests = await installPreviewApiGuard(page);
    await page.goto('/dev/templates-preview');
    await page.getByRole('button', { name: 'Mở bản nháp', exact: true }).first().click();

    const templateName = page.getByRole('textbox', { name: 'Tên template' });
    await templateName.fill('Tên local cần giữ sau 412');
    await page.getByLabel('Kịch bản mô phỏng phản hồi (chỉ preview)').selectOption('stale_412');
    await page.getByRole('button', { name: 'Lưu cập nhật nháp (chỉ preview)', exact: true }).click();

    const conflictNotice = page.getByRole('alert');
    await expect(conflictNotice).toContainText('412 VERSION_CONFLICT');
    await expect(conflictNotice).toContainText('Tên local cần giữ sau 412');
    await conflictNotice.getByRole('button', { name: /Giữ bản cục bộ để áp dụng lại lên revision/ }).click();
    await expect(templateName).toHaveValue('Tên local cần giữ sau 412');

    await page.getByRole('button', { name: 'Lưu cập nhật nháp (chỉ preview)', exact: true }).click();
    await expect(page.getByRole('status')).toContainText('Đã cập nhật bản xem trước trong bộ nhớ tab');
    await expect(templateName).toHaveValue('Tên local cần giữ sau 412');
    expect(apiRequests).toEqual([]);
  },
);

test(
  'published mock remains read-only after its simulated 409 PATCH response',
  /** Kiểm tra fixture PUBLISHED không cho sửa và phản hồi 409 mock không làm đổi snapshot.
   * Input
   * Param: page — trang Playwright cô lập dùng để mở fixture PUBLISHED.
   * Side effects
   * Chặn API và nhấn hành động mô phỏng PATCH bất biến trong preview.
   */
  async ({ page }) => {
    const apiRequests = await installPreviewApiGuard(page);
    await page.goto('/dev/templates-preview');
    await page.getByRole('button', { name: 'Tải thêm template', exact: true }).click();
    await page.getByRole('button', { name: 'Xem chỉ đọc', exact: true }).click();

    const templateName = page.getByRole('textbox', { name: 'Tên template' });
    await expect(templateName).toHaveValue('Cấu hình phòng đã công bố (mẫu)');
    await expect(templateName).not.toBeEditable();
    await expect(page.getByRole('button', { name: /Tạo bản nháp \(chỉ preview\)/ })).toHaveCount(0);
    await page.getByRole('button', { name: 'Mô phỏng gửi PATCH để kiểm tra lỗi 409', exact: true }).click();

    await expect(page.getByRole('alert')).toContainText('409 IMMUTABLE_SCHEMA');
    await expect(templateName).toHaveValue('Cấu hình phòng đã công bố (mẫu)');
    await expect(templateName).not.toBeEditable();
    expect(apiRequests).toEqual([]);
  },
);

test(
  'unknown mock POST shows the created candidate once without automatic resubmission',
  /** Kiểm tra kết quả POST unknown mô phỏng đưa ứng viên vào danh sách để người dùng tự đối chiếu.
   * Input
   * Param: page — trang Playwright cô lập dùng để tạo draft fixture mới trong memory.
   * Side effects
   * Chặn API, tạo draft không có stream và chọn scenario unknown để mô phỏng mất xác nhận.
   */
  async ({ page }) => {
    const apiRequests = await installPreviewApiGuard(page);
    await page.goto('/dev/templates-preview');
    await page.getByRole('button', { name: 'Tạo template', exact: true }).click();

    const candidateName = 'Ứng viên unknown chỉ có trong tab';
    await page.getByRole('textbox', { name: 'Tên template' }).fill(candidateName);
    await page.getByRole('combobox', { name: /Mã model chuẩn/ }).fill('ESP32_PREVIEW_UNKNOWN_V1');
    await page.getByLabel('Kịch bản mô phỏng phản hồi (chỉ preview)').selectOption('pending_post_unknown');
    await page.getByRole('button', { name: 'Tạo bản nháp (chỉ preview)', exact: true }).click();

    const unknownNotice = page.getByRole('alert');
    await expect(unknownNotice).toContainText('không tự gửi lại POST');
    const candidateRow = unknownNotice.locator('li').filter({ hasText: candidateName });
    await expect(candidateRow).toHaveCount(1);
    await expect(candidateRow.getByRole('button', { name: 'Mở bản nháp này', exact: true })).toBeVisible();
    expect(apiRequests).toEqual([]);
  },
);

test(
  'USER preview scope returns 403 without rendering its synthetic template data',
  /** Kiểm tra list mock từ chối vai trò USER và không đưa fixture nội bộ ra nội dung trang.
   * Input
   * Param: page — trang Playwright cô lập dùng để đổi workspace fixture.
   * Side effects
   * Chặn API và chuyển từ workspace ADMIN mẫu sang workspace USER mẫu.
   */
  async ({ page }) => {
    const apiRequests = await installPreviewApiGuard(page);
    await page.goto('/dev/templates-preview');
    await page.getByLabel('Ngữ cảnh workspace tổng hợp').selectOption('ws-preview-user-b');

    const permissionNotice = page.getByRole('alert');
    await expect(permissionNotice).toContainText('Truy cập bị từ chối (403)');
    await expect(permissionNotice).toContainText('vai trò USER');
    await expect(page.getByText('Template nội bộ workspace B (mẫu bị khóa)', { exact: true })).toHaveCount(0);
    expect(apiRequests).toEqual([]);
  },
);

test(
  '404 detail scenario replaces the list with a scoped not-found notice',
  /** Kiểm tra lỗi 404 chi tiết mock không giữ lại tên/schema của template trong vùng danh sách.
   * Input
   * Param: page — trang Playwright cô lập dùng để mở fixture trong scenario 404.
   * Side effects
   * Chặn API, chọn scenario 404 và thử mở một draft tổng hợp.
   */
  async ({ page }) => {
    const apiRequests = await installPreviewApiGuard(page);
    await page.goto('/dev/templates-preview');
    await page.getByLabel('Kịch bản mô phỏng phản hồi (chỉ preview)').selectOption('not_found_404');
    await page.getByRole('button', { name: 'Mở bản nháp', exact: true }).first().click();

    const notFoundNotice = page.getByRole('alert');
    await expect(notFoundNotice).toContainText('Không tìm thấy tài nguyên trong workspace (404)');
    await expect(notFoundNotice).not.toContainText('Cảm biến phòng thực hành (mẫu)');
    expect(apiRequests).toEqual([]);
  },
);

test(
  'offline mock save preserves edits and retries only after the user requests it',
  /** Kiểm tra lỗi ngoại tuyến giữ form và chỉ tạo mock draft sau khi người dùng chủ động retry.
   * Input
   * Param: page — trang Playwright cô lập dùng để tạo draft và mô phỏng lỗi mạng.
   * Side effects
   * Chặn API, chuyển scenario ngoại tuyến rồi trở lại bình thường trước nút retry tường minh.
   */
  async ({ page }) => {
    const apiRequests = await installPreviewApiGuard(page);
    await page.goto('/dev/templates-preview');
    await page.getByRole('button', { name: 'Tạo template', exact: true }).click();

    const templateName = page.getByRole('textbox', { name: 'Tên template' });
    await templateName.fill('Draft giữ lại khi ngoại tuyến');
    await page.getByRole('combobox', { name: /Mã model chuẩn/ }).fill('ESP32_PREVIEW_OFFLINE_V1');
    const scenarioSelect = page.getByLabel('Kịch bản mô phỏng phản hồi (chỉ preview)');
    await scenarioSelect.selectOption('offline');
    await page.getByRole('button', { name: 'Tạo bản nháp (chỉ preview)', exact: true }).click();

    await expect(page.getByRole('alert')).toContainText('Bản nháp vẫn được giữ tại trình duyệt');
    await expect(templateName).toHaveValue('Draft giữ lại khi ngoại tuyến');
    await scenarioSelect.selectOption('normal');
    await page.getByRole('button', { name: 'Thử gửi lại thủ công', exact: true }).click();

    await expect(page.getByRole('status')).toContainText('Đã cập nhật bản xem trước trong bộ nhớ tab');
    await expect(templateName).toHaveValue('Draft giữ lại khi ngoại tuyến');
    expect(apiRequests).toEqual([]);
  },
);

test(
  'keyboard skip link moves focus to main with a visible focus indicator',
  /** Kiểm tra bàn phím đi từ liên kết bỏ qua nội dung tới main và giữ viền focus nhìn thấy.
   * Input
   * Param: page — trang Playwright cô lập dùng để mở preview Templates.
   * Side effects
   * Chặn API, mở route preview, dùng Tab chọn liên kết bỏ qua và Enter để chuyển tiêu điểm tới nội dung chính.
   */
  async ({ page }) => {
    const apiRequests = await installPreviewApiGuard(page);
    await page.goto('/dev/templates-preview');

    const skipLink = page.getByRole('link', { name: 'Chuyển đến nội dung chính' });
    await expect(skipLink).toBeVisible();
    await page.keyboard.press('Tab');
    const activeElementDescription = await page.evaluate(
      /** Mô tả ngắn phần tử đang nhận focus để chẩn đoán sai lệch điều hướng bàn phím.
       * Output: tên thẻ, ID và nhãn truy cập được của phần tử focus hiện tại.
       */
      () => {
        const activeElement = document.activeElement;
        if (!(activeElement instanceof HTMLElement)) return 'không có phần tử HTML nhận focus';
        const elementId = activeElement.id ? `#${activeElement.id}` : '';
        const accessibleLabel = activeElement.getAttribute('aria-label');
        const labelSuffix = accessibleLabel ? ` (aria-label: ${accessibleLabel})` : '';
        return `${activeElement.tagName.toLowerCase()}${elementId}${labelSuffix}`;
      },
    );
    await expect(
      skipLink,
      `Sau Tab đầu, phần tử đang nhận focus là: ${activeElementDescription}`,
    ).toBeFocused();
    await expect(skipLink).toBeVisible();

    await page.keyboard.press('Enter');
    const main = page.locator('#templates-main');
    await expect(main).toBeFocused();
    await expect(main).toHaveCSS('outline-style', 'solid');
    await expect(main).toHaveCSS('outline-width', '3px');
    expect(apiRequests).toEqual([]);
  },
);
