/* Sửa race settle lease hết hạn trong khi chờ khóa: khóa consumption trước rồi mới đọc clock.
 * CREATE OR REPLACE giữ signature/ACL và dữ liệu hiện hành; không ALTER TABLE, backfill hoặc reset generation.
 * Migration cần khóa catalog function ngắn; worker đã chạy lời gọi cũ phải drain trước rollout production.
 * Không sửa migration0009 đã áp; quyền invoker không đổi, caller vẫn cần SELECT/UPDATE consumption.
 */

/* Hoàn tất riêng một consumer bằng epoch sống sau khi đã lấy row lock theo identity cố định.
 * Input
 * Param: target_event — UUID event đã claim, không tự tạo nghĩa vụ mới khi retry.
 * Param: target_consumer — pipeline nội bộ cấu hình tại worker.
 * Param: expected_generation — epoch receipt phải khớp generation hiện hành.
 * Output: true khi chuyển COMPLETED; false với thiếu row, stale, terminal hoặc lease hết hạn.
 * Side effects: khóa consumption đến commit; chỉ cập nhật state/completed_at/lease_until nếu CAS hợp lệ.
 * Không giữ transaction qua network; clock được đọc trong statement sau khóa, kể cả locker rollback không thay tuple.
 */
CREATE OR REPLACE FUNCTION public.complete_outbox(target_event uuid,target_consumer text,expected_generation bigint)
RETURNS boolean LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 -- Khóa bằng khóa chính, tuyệt đối không dùng predicate clock trước khi chờ row lock.
 PERFORM 1 FROM public.outbox_consumptions
 WHERE outbox_event_id=target_event AND consumer_code=target_consumer FOR UPDATE;
 IF NOT FOUND THEN RETURN false; END IF;
 -- Sau khóa mới xét state/epoch/thời gian; một winner, không cho stale worker settle sau takeover.
 UPDATE public.outbox_consumptions SET state='COMPLETED',completed_at=clock_timestamp(),lease_until=NULL
 WHERE outbox_event_id=target_event AND consumer_code=target_consumer AND state='PROCESSING'
 AND lease_generation=expected_generation AND lease_until>clock_timestamp();
 RETURN FOUND;
END $$;
COMMENT ON FUNCTION public.complete_outbox(uuid,text,bigint) IS 'Khóa consumption trước khi kiểm clock/epoch; complete một consumer chỉ khi lease còn sống sau chờ khóa, stale/expired/terminal trả false và không đổi nghĩa vụ.';
