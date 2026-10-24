/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
{{ledger_sql}}
SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
{{migration_sql}}
INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;
