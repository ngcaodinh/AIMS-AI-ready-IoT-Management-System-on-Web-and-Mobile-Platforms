/* So cấu trúc và ACL của main/clean-build/restore mà không đọc dữ liệu ứng dụng.
 * Chỉ metadata schema public/migration_control: cột, default, index, FK/CHECK,
 * trigger, routine và ACL được normalize thành các entry rồi hash có thứ tự.
 * Không dùng OID object giữa hai DB; tên/definition/role name mới là authority so sánh.
 */
WITH inventory(entry) AS (
    SELECT 'column:'||namespace.nspname||'.'||relation.relname||':'||attribute.attnum||':'||
        attribute.attname||':'||pg_catalog.format_type(attribute.atttypid,attribute.atttypmod)||':'||
        attribute.attnotnull||':'||coalesce(pg_get_expr(default_value.adbin,default_value.adrelid),'')
    FROM pg_class AS relation
    JOIN pg_namespace AS namespace ON namespace.oid=relation.relnamespace
    JOIN pg_attribute AS attribute ON attribute.attrelid=relation.oid AND attribute.attnum>0 AND NOT attribute.attisdropped
    LEFT JOIN pg_attrdef AS default_value ON default_value.adrelid=relation.oid AND default_value.adnum=attribute.attnum
    WHERE namespace.nspname IN ('public','migration_control') AND relation.relkind IN ('r','p')
    UNION ALL
    SELECT 'constraint:'||conrelid::regclass::text||':'||conname||':'||pg_get_constraintdef(oid)
    FROM pg_constraint WHERE connamespace IN ('public'::regnamespace,'migration_control'::regnamespace)
    UNION ALL
    SELECT 'index:'||schemaname||'.'||indexname||':'||indexdef
    FROM pg_indexes WHERE schemaname IN ('public','migration_control')
    UNION ALL
    SELECT 'trigger:'||trigger.tgrelid::regclass::text||':'||trigger.tgname||':'||trigger.tgenabled::text||':'||pg_get_triggerdef(trigger.oid)
    FROM pg_trigger AS trigger JOIN pg_class AS relation ON relation.oid=trigger.tgrelid
    WHERE NOT trigger.tgisinternal AND relation.relnamespace IN ('public'::regnamespace,'migration_control'::regnamespace)
    UNION ALL
    SELECT 'function:'||routine.oid::regprocedure::text||':'||pg_get_functiondef(routine.oid)
    FROM pg_proc AS routine WHERE routine.pronamespace IN ('public'::regnamespace,'migration_control'::regnamespace)
    UNION ALL
    SELECT 'table_acl:'||relation.oid::regclass::text||':'||acl.grantor::regrole::text||':'||
        CASE WHEN acl.grantee=0 THEN 'PUBLIC' ELSE acl.grantee::regrole::text END||':'||acl.privilege_type||':'||acl.is_grantable
    FROM pg_class AS relation
    CROSS JOIN LATERAL aclexplode(coalesce(relation.relacl,acldefault('r',relation.relowner))) AS acl
    WHERE relation.relnamespace IN ('public'::regnamespace,'migration_control'::regnamespace) AND relation.relkind IN ('r','p')
    UNION ALL
    SELECT 'function_acl:'||routine.oid::regprocedure::text||':'||acl.grantor::regrole::text||':'||
        CASE WHEN acl.grantee=0 THEN 'PUBLIC' ELSE acl.grantee::regrole::text END||':'||acl.privilege_type||':'||acl.is_grantable
    FROM pg_proc AS routine
    CROSS JOIN LATERAL aclexplode(coalesce(routine.proacl,acldefault('f',routine.proowner))) AS acl
    WHERE routine.pronamespace IN ('public'::regnamespace,'migration_control'::regnamespace)
    UNION ALL
    SELECT 'schema_acl:'||namespace.nspname||':'||acl.grantor::regrole::text||':'||
        CASE WHEN acl.grantee=0 THEN 'PUBLIC' ELSE acl.grantee::regrole::text END||':'||acl.privilege_type||':'||acl.is_grantable
    FROM pg_namespace AS namespace
    CROSS JOIN LATERAL aclexplode(coalesce(namespace.nspacl,acldefault('n',namespace.nspowner))) AS acl
    WHERE namespace.nspname IN ('public','migration_control')
)
SELECT md5(string_agg(entry,E'\n' ORDER BY entry)) FROM inventory;
