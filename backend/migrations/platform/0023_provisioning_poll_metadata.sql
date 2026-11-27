/* Lưu bộ đếm retry và mã lỗi public tách khỏi ciphertext/receipt broker của operation.
 * ALTER TABLE có khóa metadata; default 0 cho baseline chưa có worker retry, không đổi trạng thái operation.
 */
ALTER TABLE public.provisioning_operations ADD COLUMN retry_count integer NOT NULL DEFAULT 0
 CONSTRAINT ck_provisioning_retry_count CHECK(retry_count>=0);
ALTER TABLE public.provisioning_operations ADD COLUMN error_code text
 CONSTRAINT ck_provisioning_public_error CHECK(error_code IN ('CREDENTIAL_ESCROW_EXPIRED','BROKER_UNAVAILABLE','BROKER_ACK_REJECTED'));

COMMENT ON COLUMN public.provisioning_operations.retry_count IS 'Số lần adapter retry đã ghi bền vững; không gồm attempt đầu và không chứa raw diagnostics.';
COMMENT ON COLUMN public.provisioning_operations.error_code IS 'Mã lỗi public đã lọc cho status poll; không dùng lỗi broker hoặc giá trị credential làm nội dung.';
