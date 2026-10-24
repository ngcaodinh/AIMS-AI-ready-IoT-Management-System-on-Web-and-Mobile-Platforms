/* Role kiểm tra từ DBeaver local; không cấp owner/runtime writer và không có password hardcoded.
 * Chỉ truy cập qua bridge loopback đã khóa user/database, Unix socket vẫn nằm trong container.
 * Không cấp SELECT cho verifier/token/proof/ciphertext; metadata bảng/cột vẫn xem được.
 */
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='iot_dbeaver_reader') THEN
  CREATE ROLE iot_dbeaver_reader LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='iot_dbeaver_reader'
   AND(rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls))
   OR EXISTS(SELECT 1 FROM pg_auth_members WHERE member='iot_dbeaver_reader'::regrole) THEN
  RAISE EXCEPTION 'Inspection role has unexpected authority';
 END IF;
END $$;
ALTER ROLE iot_dbeaver_reader SET default_transaction_read_only=on;
ALTER ROLE iot_dbeaver_reader SET statement_timeout='30s';
ALTER ROLE iot_dbeaver_reader SET lock_timeout='5s';
ALTER ROLE iot_dbeaver_reader SET search_path=public,pg_catalog;
COMMENT ON ROLE iot_dbeaver_reader IS 'IoT canonical local inspection role; no writer authority';
GRANT CONNECT ON DATABASE iot_platform_lab TO iot_dbeaver_reader;
