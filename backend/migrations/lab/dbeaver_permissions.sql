/* Policy inspection tái áp sau clean build; chạy bởi schema owner, không tạo hoặc nâng role.
 * Cấp từng cột để credential/verifier/proof/ciphertext không bị đọc qua SELECT *.
 * History view có security_invoker; cùng policy cột như bảng nguồn, không mở đường đọc thay thế.
 */
GRANT USAGE ON SCHEMA public,migration_control TO iot_dbeaver_reader;
REVOKE ALL ON ALL TABLES IN SCHEMA public,migration_control FROM iot_dbeaver_reader;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM iot_dbeaver_reader;
DO $$ DECLARE relation_row record; safe_columns text; BEGIN
 FOR relation_row IN SELECT namespace.nspname AS schema_name,relation.relname AS relation_name
   FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
   WHERE namespace.nspname IN ('public','migration_control') AND relation.relkind IN ('r','p','v')
   ORDER BY namespace.nspname,relation.relname LOOP
  SELECT string_agg(quote_ident(column_name),',' ORDER BY ordinal_position) INTO safe_columns
  FROM information_schema.columns
  WHERE table_schema=relation_row.schema_name AND table_name=relation_row.relation_name
    AND column_name !~ '(password|verifier|token_digest|ticket_digest|proof_digest|ciphertext|raw_body|sanitized_result)';
  IF safe_columns IS NOT NULL THEN
   EXECUTE format('GRANT SELECT (%s) ON TABLE %I.%I TO iot_dbeaver_reader',safe_columns,relation_row.schema_name,relation_row.relation_name);
  END IF;
 END LOOP;
END $$;
