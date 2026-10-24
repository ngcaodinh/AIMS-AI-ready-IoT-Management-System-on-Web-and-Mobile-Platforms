/* Quyền đã áp trên lab hiện tại, không phải app mutation policy production.
 * Chạy bằng migrator sau numbered migrations trên DB lab/clean-build đã định danh.
 * Runtime chỉ SELECT các bảng cần cho PoC; không DDL, key read, audit edit hoặc user update.
 */
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO iot_runtime;
GRANT SELECT ON TABLE public.users,public.workspaces,public.memberships TO iot_runtime;
REVOKE ALL ON TABLE public.auth_settings,public.audit_events FROM iot_runtime;
