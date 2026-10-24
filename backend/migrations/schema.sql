/* Snapshot schema-only của iot_database_lab trên PostgreSQL17; không có dữ liệu/credential.
 * Nguồn chuẩn:0001_auth.sql +0002_auth_integrity.sql, runner/ và lab/.
 * Snapshot gồm public/migration_control và ACL; bootstrap role ở lab/bootstrap.sql.
 * Không chạy snapshot nối tiếp numbered migration; runner chỉ áp danh sách version tường minh.
 * Có thể dựng DB trống bằng psql/migrator sau bootstrap; lịch sử applied_migrations không có dữ liệu.
 */
--
-- PostgreSQL database dump
--

\restrict VhL7rAhH5YhQxpPvxcPptUhbOJySNSTNc1J1N2xa3EObau2clwpiXEj1UdZdg3C

-- Dumped from database version 17.11 (Debian 17.11-1.pgdg12+2)
-- Dumped by pg_dump version 17.11 (Debian 17.11-1.pgdg12+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: migration_control; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA migration_control;


--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA IF NOT EXISTS public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: assert_workspace_capable_admin(uuid); Type: FUNCTION; Schema: public; Owner: -
--

/* Kiểm workspace còn Admin ACTIVE có account ACTIVE/full ở trạng thái cuối transaction. */
CREATE FUNCTION public.assert_workspace_capable_admin(target_workspace_id uuid) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
BEGIN
    IF EXISTS(SELECT 1 FROM public.workspaces WHERE id=target_workspace_id)
       AND NOT EXISTS (
           SELECT 1 FROM public.memberships AS membership
           JOIN public.users AS account ON account.id=membership.user_id
           WHERE membership.workspace_id=target_workspace_id
             AND membership.role='ADMIN' AND membership.status='ACTIVE'
             AND account.status='ACTIVE' AND NOT account.must_change_password
       ) THEN
        RAISE EXCEPTION 'Workspace requires a capable active administrator'
            USING ERRCODE='23514', CONSTRAINT='ck_workspaces_capable_admin';
    END IF;
END $$;


--
-- Name: enforce_session_immutability(); Type: FUNCTION; Schema: public; Owner: -
--

/* Giữ identity/admission của phiên và không đảo revocation; chi tiết nguồn0002. */
CREATE FUNCTION public.enforce_session_immutability() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
BEGIN
    IF ROW(NEW.id,NEW.user_id,NEW.token_digest,NEW.auth_context_id,NEW.client_type,
           NEW.limited,NEW.created_at,NEW.expires_at)
       IS DISTINCT FROM
       ROW(OLD.id,OLD.user_id,OLD.token_digest,OLD.auth_context_id,OLD.client_type,
           OLD.limited,OLD.created_at,OLD.expires_at) THEN
        RAISE EXCEPTION 'Session identity and admission mode are immutable'
            USING ERRCODE='23514', CONSTRAINT='ck_sessions_identity_immutable';
    END IF;
    IF OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN
        RAISE EXCEPTION 'Session revocation cannot be rewritten'
            USING ERRCODE='23514', CONSTRAINT='ck_sessions_revocation_monotonic';
    END IF;
    RETURN NEW;
END $$;


--
-- Name: fence_membership_administrators(); Type: FUNCTION; Schema: public; Owner: -
--

/* Ghi MVCC fence trên User/Workspace cũ và mới để chống write skew, kể cả RR snapshot cũ. */
CREATE FUNCTION public.fence_membership_administrators() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
    affected_user_ids uuid[];
    affected_workspace_ids uuid[];
    target_user_id uuid;
    target_workspace_id uuid;
BEGIN
    IF TG_OP='INSERT' THEN
        affected_user_ids:=ARRAY[NEW.user_id];
        affected_workspace_ids:=ARRAY[NEW.workspace_id];
    ELSIF TG_OP='DELETE' THEN
        affected_user_ids:=ARRAY[OLD.user_id];
        affected_workspace_ids:=ARRAY[OLD.workspace_id];
    ELSE
        affected_user_ids:=ARRAY[OLD.user_id,NEW.user_id];
        affected_workspace_ids:=ARRAY[OLD.workspace_id,NEW.workspace_id];
    END IF;
    FOR target_user_id IN
        SELECT DISTINCT member_id FROM pg_catalog.unnest(affected_user_ids) AS scope(member_id)
        ORDER BY member_id
    LOOP
        -- Write fence trên User đóng phantom grant khi transaction RR chưa thấy membership mới.
        UPDATE public.users AS account SET status=account.status WHERE account.id=target_user_id;
    END LOOP;
    FOR target_workspace_id IN
        SELECT DISTINCT workspace_id FROM pg_catalog.unnest(affected_workspace_ids) AS scope(workspace_id)
        ORDER BY workspace_id
    LOOP
        -- Write fence trên Workspace serialize count/check cuối TX mà không đổi revision wire.
        UPDATE public.workspaces AS workspace SET authz_version=workspace.authz_version
        WHERE workspace.id=target_workspace_id;
    END LOOP;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;


--
-- Name: fence_user_administrator_workspaces(); Type: FUNCTION; Schema: public; Owner: -
--

/* Đồng bộ account-state mutation với workspace khi quyền quản trị có thể mất hiệu lực. */
CREATE FUNCTION public.fence_user_administrator_workspaces() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE target_workspace_id uuid;
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status
       OR OLD.must_change_password IS DISTINCT FROM NEW.must_change_password THEN
        FOR target_workspace_id IN
            SELECT workspace_id FROM public.memberships
            WHERE user_id=OLD.id AND role='ADMIN' AND status='ACTIVE'
            ORDER BY workspace_id
        LOOP
            UPDATE public.workspaces AS workspace SET authz_version=workspace.authz_version
            WHERE workspace.id=target_workspace_id;
        END LOOP;
    END IF;
    RETURN NEW;
END $$;


--
-- Name: reject_membership_truncate(); Type: FUNCTION; Schema: public; Owner: -
--

/* Chặn TRUNCATE vì lệnh này không phát row trigger và có thể né last-Admin guard. */
CREATE FUNCTION public.reject_membership_truncate() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
BEGIN
    RAISE EXCEPTION 'TRUNCATE memberships bypasses administrator integrity'
        USING ERRCODE='23514', CONSTRAINT='ck_workspaces_capable_admin';
END $$;


--
-- Name: validate_membership_administrators(); Type: FUNCTION; Schema: public; Owner: -
--

/* Kiểm các workspace hai phía membership bằng deferred trigger sau batch cuối. */
CREATE FUNCTION public.validate_membership_administrators() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
BEGIN
    IF TG_OP<>'INSERT' THEN
        PERFORM public.assert_workspace_capable_admin(OLD.workspace_id);
    END IF;
    IF TG_OP<>'DELETE' THEN
        PERFORM public.assert_workspace_capable_admin(NEW.workspace_id);
    END IF;
    RETURN NULL;
END $$;


--
-- Name: validate_user_administrator_workspaces(); Type: FUNCTION; Schema: public; Owner: -
--

/* Kiểm capable Admin sau thay đổi status/must_change_password của account. */
CREATE FUNCTION public.validate_user_administrator_workspaces() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE target_workspace_id uuid;
BEGIN
    FOR target_workspace_id IN
        SELECT workspace_id FROM public.memberships
        WHERE user_id=NEW.id AND role='ADMIN' AND status='ACTIVE'
        ORDER BY workspace_id
    LOOP
        PERFORM public.assert_workspace_capable_admin(target_workspace_id);
    END LOOP;
    RETURN NULL;
END $$;


--
-- Name: validate_workspace_administrators(); Type: FUNCTION; Schema: public; Owner: -
--

/* Buộc workspace mới có Admin đầu tiên cùng commit và kiểm parent fence. */
CREATE FUNCTION public.validate_workspace_administrators() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
BEGIN
    PERFORM public.assert_workspace_capable_admin(NEW.id);
    RETURN NULL;
END $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: applied_migrations; Type: TABLE; Schema: migration_control; Owner: -
--

CREATE TABLE migration_control.applied_migrations (
    version text NOT NULL,
    checksum text NOT NULL,
    applied_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT applied_migrations_checksum_check CHECK ((checksum ~ '^[0-9a-f]{64}$'::text))
);


--
-- Name: restore_probe; Type: TABLE; Schema: migration_control; Owner: -
--

CREATE TABLE migration_control.restore_probe (
    probe_id integer NOT NULL,
    note text NOT NULL
);


--
-- Name: audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events (
    id uuid NOT NULL,
    actor_id uuid,
    session_id uuid,
    workspace_id uuid,
    event_type text NOT NULL,
    outcome text NOT NULL,
    client_type text NOT NULL,
    correlation_id uuid NOT NULL,
    occurred_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT audit_events_client_type_check CHECK ((client_type = ANY (ARRAY['WEB'::text, 'ANDROID'::text, 'IOS'::text, 'UNKNOWN'::text]))),
    CONSTRAINT ck_audit_events_session_actor CHECK (((session_id IS NULL) OR (actor_id IS NOT NULL)))
);


--
-- Name: auth_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_settings (
    singleton boolean DEFAULT true NOT NULL,
    signing_key bytea NOT NULL,
    CONSTRAINT auth_settings_signing_key_check CHECK ((octet_length(signing_key) = 32)),
    CONSTRAINT auth_settings_singleton_check CHECK (singleton)
);


--
-- Name: login_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.login_attempts (
    email_digest bytea NOT NULL,
    failure_count integer DEFAULT 0 NOT NULL,
    window_started_at timestamp with time zone,
    CONSTRAINT ck_login_attempts_window_coherence CHECK ((((failure_count = 0) AND (window_started_at IS NULL)) OR ((failure_count > 0) AND (window_started_at IS NOT NULL)))),
    CONSTRAINT login_attempts_email_digest_check CHECK ((octet_length(email_digest) = 32)),
    CONSTRAINT login_attempts_failure_count_check CHECK (((failure_count >= 0) AND (failure_count <= 5)))
);


--
-- Name: memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memberships (
    workspace_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role text NOT NULL,
    status text DEFAULT 'ACTIVE'::text NOT NULL,
    authz_version bigint DEFAULT 1 NOT NULL,
    CONSTRAINT memberships_authz_version_check CHECK ((authz_version > 0)),
    CONSTRAINT memberships_role_check CHECK ((role = ANY (ARRAY['ADMIN'::text, 'USER'::text]))),
    CONSTRAINT memberships_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'SUSPENDED'::text, 'REMOVED'::text])))
);


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    token_digest bytea NOT NULL,
    auth_context_id uuid NOT NULL,
    client_type text NOT NULL,
    limited boolean NOT NULL,
    created_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone,
    CONSTRAINT sessions_check CHECK ((expires_at = (created_at + '24:00:00'::interval))),
    CONSTRAINT sessions_client_type_check CHECK ((client_type = ANY (ARRAY['WEB'::text, 'ANDROID'::text, 'IOS'::text]))),
    CONSTRAINT sessions_token_digest_check CHECK ((octet_length(token_digest) = 32))
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid NOT NULL,
    email_normalized character varying(254) NOT NULL,
    password_hash text NOT NULL,
    status text NOT NULL,
    must_change_password boolean DEFAULT false NOT NULL,
    display_timezone text DEFAULT 'UTC'::text NOT NULL,
    preferences_revision bigint DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT users_preferences_revision_check CHECK ((preferences_revision > 0)),
    CONSTRAINT users_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'DISABLED'::text])))
);


--
-- Name: workspaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspaces (
    id uuid NOT NULL,
    name character varying(100) NOT NULL,
    status text DEFAULT 'ACTIVE'::text NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    authz_version bigint DEFAULT 1 NOT NULL,
    created_by uuid NOT NULL,
    CONSTRAINT workspaces_authz_version_check CHECK ((authz_version > 0)),
    CONSTRAINT workspaces_name_check CHECK (((length(btrim((name)::text)) >= 1) AND (length(btrim((name)::text)) <= 100))),
    CONSTRAINT workspaces_revision_check CHECK ((revision > 0)),
    CONSTRAINT workspaces_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'SUSPENDED'::text, 'ARCHIVED'::text])))
);


--
-- Name: applied_migrations applied_migrations_pkey; Type: CONSTRAINT; Schema: migration_control; Owner: -
--

ALTER TABLE ONLY migration_control.applied_migrations
    ADD CONSTRAINT applied_migrations_pkey PRIMARY KEY (version);


--
-- Name: restore_probe restore_probe_pkey; Type: CONSTRAINT; Schema: migration_control; Owner: -
--

ALTER TABLE ONLY migration_control.restore_probe
    ADD CONSTRAINT restore_probe_pkey PRIMARY KEY (probe_id);


--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_pkey PRIMARY KEY (id);


--
-- Name: auth_settings auth_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_settings
    ADD CONSTRAINT auth_settings_pkey PRIMARY KEY (singleton);


--
-- Name: login_attempts login_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.login_attempts
    ADD CONSTRAINT login_attempts_pkey PRIMARY KEY (email_digest);


--
-- Name: memberships memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_pkey PRIMARY KEY (workspace_id, user_id);


--
-- Name: sessions sessions_auth_context_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_auth_context_id_key UNIQUE (auth_context_id);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: sessions sessions_token_digest_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_token_digest_key UNIQUE (token_digest);


--
-- Name: sessions uq_sessions_user_identity; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT uq_sessions_user_identity UNIQUE (user_id, id);


--
-- Name: users users_email_normalized_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_normalized_key UNIQUE (email_normalized);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: workspaces workspaces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT workspaces_pkey PRIMARY KEY (id);


--
-- Name: audit_events_retention; Type: INDEX; Schema: public; Owner: -
--

/* Phục vụ purge theo occurred_at/id với cutoff và FK đã kiểm riêng. */
CREATE INDEX audit_events_retention ON public.audit_events USING btree (occurred_at, id);


--
-- Name: memberships_picker; Type: INDEX; Schema: public; Owner: -
--

/* Phục vụ picker ACTIVE theo user_id/workspace_id, giữ đúng scope principal. */
CREATE INDEX memberships_picker ON public.memberships USING btree (user_id, workspace_id) WHERE (status = 'ACTIVE'::text);


--
-- Name: sessions_by_user; Type: INDEX; Schema: public; Owner: -
--

/* Phục vụ revoke/list session theo user_id trước session identity. */
CREATE INDEX sessions_by_user ON public.sessions USING btree (user_id, id);


--
-- Name: memberships ct_memberships_capable_admin; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER ct_memberships_capable_admin AFTER INSERT OR DELETE OR UPDATE ON public.memberships DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.validate_membership_administrators();


--
-- Name: users ct_users_capable_admin; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER ct_users_capable_admin AFTER UPDATE ON public.users DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (((old.status IS DISTINCT FROM new.status) OR (old.must_change_password IS DISTINCT FROM new.must_change_password))) EXECUTE FUNCTION public.validate_user_administrator_workspaces();


--
-- Name: workspaces ct_workspaces_capable_admin; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER ct_workspaces_capable_admin AFTER INSERT OR UPDATE ON public.workspaces DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.validate_workspace_administrators();


--
-- Name: memberships tr_memberships_admin_fence; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_memberships_admin_fence BEFORE INSERT OR DELETE OR UPDATE ON public.memberships FOR EACH ROW EXECUTE FUNCTION public.fence_membership_administrators();


--
-- Name: memberships tr_memberships_reject_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_memberships_reject_truncate BEFORE TRUNCATE ON public.memberships FOR EACH STATEMENT EXECUTE FUNCTION public.reject_membership_truncate();


--
-- Name: sessions tr_sessions_immutability; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_sessions_immutability BEFORE UPDATE ON public.sessions FOR EACH ROW EXECUTE FUNCTION public.enforce_session_immutability();


--
-- Name: users tr_users_admin_fence; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_users_admin_fence BEFORE UPDATE OF status, must_change_password ON public.users FOR EACH ROW EXECUTE FUNCTION public.fence_user_administrator_workspaces();


--
-- Name: audit_events audit_events_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.users(id);


--
-- Name: audit_events audit_events_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.sessions(id);


--
-- Name: audit_events audit_events_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: audit_events fk_audit_events_actor_session; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_audit_events_actor_session FOREIGN KEY (actor_id, session_id) REFERENCES public.sessions(user_id, id);


--
-- Name: memberships memberships_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: memberships memberships_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: sessions sessions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: workspaces workspaces_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT workspaces_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO iot_runtime;


--
-- Name: FUNCTION assert_workspace_capable_admin(target_workspace_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.assert_workspace_capable_admin(target_workspace_id uuid) FROM PUBLIC;


--
-- Name: FUNCTION enforce_session_immutability(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.enforce_session_immutability() FROM PUBLIC;


--
-- Name: FUNCTION fence_membership_administrators(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fence_membership_administrators() FROM PUBLIC;


--
-- Name: FUNCTION fence_user_administrator_workspaces(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fence_user_administrator_workspaces() FROM PUBLIC;


--
-- Name: FUNCTION reject_membership_truncate(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reject_membership_truncate() FROM PUBLIC;


--
-- Name: FUNCTION validate_membership_administrators(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.validate_membership_administrators() FROM PUBLIC;


--
-- Name: FUNCTION validate_user_administrator_workspaces(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.validate_user_administrator_workspaces() FROM PUBLIC;


--
-- Name: FUNCTION validate_workspace_administrators(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.validate_workspace_administrators() FROM PUBLIC;


--
-- Name: TABLE memberships; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.memberships TO iot_runtime;


--
-- Name: TABLE users; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.users TO iot_runtime;


--
-- Name: TABLE workspaces; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.workspaces TO iot_runtime;


--
-- PostgreSQL database dump complete
--

\unrestrict VhL7rAhH5YhQxpPvxcPptUhbOJySNSTNc1J1N2xa3EObau2clwpiXEj1UdZdg3C
