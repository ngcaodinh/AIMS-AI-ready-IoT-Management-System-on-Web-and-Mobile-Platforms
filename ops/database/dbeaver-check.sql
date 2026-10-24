-- Kiểm identity kết nối và chế độ chỉ đọc, không truy vấn dữ liệu tài khoản hoặc credential.
SELECT current_database() AS database_name,
       current_user AS role_name,
       current_setting('transaction_read_only') AS read_only,
       (SELECT count(*) FROM information_schema.tables
        WHERE table_schema='public' AND table_type='BASE TABLE') AS visible_table_count;

-- Xem công dụng từng cột của users từ metadata PostgreSQL, không SELECT hàng users.
SELECT attribute.attname AS column_name,
       format_type(attribute.atttypid,attribute.atttypmod) AS data_type,
       col_description(attribute.attrelid,attribute.attnum) AS purpose
FROM pg_attribute attribute
WHERE attribute.attrelid='public.users'::regclass
  AND attribute.attnum>0 AND NOT attribute.attisdropped
ORDER BY attribute.attnum;
