/* Fixture tổng hợp cho từng suite; runner luôn nối ROLLBACK, không seed account có thể đăng nhập. */
BEGIN;
INSERT INTO users(user_id,email_normalized,password_hash,account_status,activation_provenance) VALUES
 ('00000000-0000-0000-0000-000000000001','admin-a@example.invalid','invalid-test-verifier','ACTIVE','TEST_FIXTURE'),
 ('00000000-0000-0000-0000-000000000002','admin-b@example.invalid','invalid-test-verifier','ACTIVE','TEST_FIXTURE');
INSERT INTO workspaces(workspace_id,name,created_by_user_id) VALUES
 ('00000000-0000-0000-0000-000000000101','Workspace A','00000000-0000-0000-0000-000000000001'),
 ('00000000-0000-0000-0000-000000000102','Workspace B','00000000-0000-0000-0000-000000000002');
INSERT INTO memberships(workspace_id,user_id,role,current_grant_generation) VALUES
 ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000001','ADMIN',1),
 ('00000000-0000-0000-0000-000000000102','00000000-0000-0000-0000-000000000002','ADMIN',1);
INSERT INTO membership_grants(workspace_id,user_id,grant_generation) SELECT workspace_id,user_id,1 FROM memberships;
SET CONSTRAINTS ALL IMMEDIATE;

/* Chạy mutation trong subtransaction; chỉ PASS khi đúng SQLSTATE và constraint mong đợi.
 * Input: statement là SQL fixture cố định, expected_state/constraint là lỗi phải quan sát.
 * Output: PASS với test_name; Errors: mutation lọt hoặc sai lỗi sẽ abort toàn suite.
 */
CREATE FUNCTION pg_temp.rejects(test_name text, statement text, expected_state text, expected_constraint text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE actual_state text; actual_constraint text;
BEGIN
    BEGIN
        EXECUTE statement;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS actual_state=RETURNED_SQLSTATE, actual_constraint=CONSTRAINT_NAME;
        IF actual_state<>expected_state OR (expected_constraint IS NOT NULL AND actual_constraint<>expected_constraint) THEN
            RAISE EXCEPTION 'Unexpected guard for %: % / %',test_name,actual_state,actual_constraint;
        END IF;
        RETURN 'PASS:'||test_name;
    END;
    RAISE EXCEPTION 'Invalid mutation accepted: %',test_name;
END $$;

/* Tạo UUID tổng hợp ổn định để fixture dễ đọc, không phụ thuộc random hay extension.
 * Input: identity_number là số thứ tự test. Output:UUID không dùng làm credential.
 */
CREATE FUNCTION pg_temp.fixture_id(identity_number integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
 SELECT ('00000000-0000-0000-0000-'||lpad(identity_number::text,12,'0'))::uuid
$$;
