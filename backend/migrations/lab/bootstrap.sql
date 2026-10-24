/* Chỉ bootstrap cluster lab mới được định danh, chạy bằng iot_lab_owner tại DB postgres.
 * CREATE DATABASE nằm ngoài transaction; lab_database là identifier đã allowlist ở launcher.
 * Không password/env/default signing key; local Unix trust thuộc cấu hình container lab.
 */
SELECT pg_catalog.format(
    'CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', role_name
)
FROM (VALUES('iot_migrator'),('iot_runtime')) AS roles(role_name)
WHERE NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=role_name)
\gexec

/* Role có sẵn sai quyền thì dừng, không ALTER quyền của đối tượng chưa rõ provenance. */
DO $$
BEGIN
    IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname IN ('iot_migrator','iot_runtime')
              AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)) THEN
        RAISE EXCEPTION 'Lab role has unexpected elevated privileges';
    END IF;
END $$;

SELECT pg_catalog.format('CREATE DATABASE %I OWNER iot_migrator', :'lab_database')
WHERE NOT EXISTS(SELECT 1 FROM pg_database WHERE datname=:'lab_database')
\gexec

SELECT NOT EXISTS(
    SELECT 1 FROM pg_database WHERE datname=:'lab_database'
    AND datdba<>(SELECT oid FROM pg_roles WHERE rolname='iot_migrator')
) AS lab_owner_matches \gset
\if :lab_owner_matches
\else
DO $$ BEGIN RAISE EXCEPTION 'Existing lab database has an unexpected owner'; END $$;
\endif
