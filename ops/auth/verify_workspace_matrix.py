"""Kiểm Given bốn workspace bằng fixture sở hữu; giữ nguyên hai workspace seed của provider."""

from urllib.parse import quote
from uuid import UUID, uuid4

import verify_provider as provider


def workspace_matrix_fixture(run_id, user_id, owner_id, workspace_ids, create):
    """Tạo hoặc dọn riêng B/C với Admin/grant hợp lệ, trong transaction giữ provenance của run.

    Input
    Param: run_id — UUID launcher dùng chứng minh quyền sở hữu role và account tổng hợp.
    Param: user_id — fixture0 có hai membership ACTIVE A/D trước khi thêm B/C.
    Param: owner_id — fixture4 ACTIVE làm Admin của hai workspace tạm, tránh last-admin violation.
    Param: workspace_ids — hai UUID mới B/C do verifier sinh, không được trùng user hoặc nhau.
    Param: create — True tạo B SUSPENDED/C REMOVED; False dọn đúng graph đã đánh dấu.
    Errors: role/provenance/count/SQL sai đều fail bằng lỗi cố định, không xuất SQL hoặc dữ liệu auth.
    Side effects: tối đa hai workspace và bốn membership/grant, cùng commit hoặc rollback.
    """
    import verify_database as lab
    import verify_repositories as repository
    run, subject, owner = (str(UUID(str(value))) for value in (run_id, user_id, owner_id))
    suspended, removed = (str(UUID(str(value))) for value in workspace_ids)
    if len({subject, owner, suspended, removed}) != 4 or not repository.owns_probe(run):
        raise RuntimeError('Four-workspace fixture rejected')
    marker = 'AUTH_HTTP_LAB_MATRIX:' + run
    identities = "'" + suspended + "'::uuid,'" + removed + "'::uuid"
    # Chỉ UUID đã parse và literal nội bộ được nội suy. User/provenance/description phải khớp trước cả INSERT lẫn DELETE.
    statement = f"""BEGIN;
    DO $matrix$ BEGIN
      PERFORM user_id FROM users WHERE user_id IN ('{subject}'::uuid,'{owner}'::uuid) ORDER BY user_id FOR UPDATE;
      IF (SELECT count(*) FROM users WHERE activation_provenance='AUTH_HTTP_LAB:{run}'
          AND account_status='ACTIVE' AND NOT must_change_password
          AND ((user_id='{subject}'::uuid AND email_normalized='probe-{run}-0@example.invalid')
            OR (user_id='{owner}'::uuid AND email_normalized='probe-{run}-4@example.invalid')))<>2
      THEN RAISE EXCEPTION 'Four-workspace fixture account mismatch'; END IF;
      IF EXISTS(SELECT 1 FROM workspaces WHERE workspace_id IN ({identities})
          AND (created_by_user_id<>'{owner}'::uuid OR description IS DISTINCT FROM '{marker}'))
      THEN RAISE EXCEPTION 'Four-workspace fixture ownership mismatch'; END IF;
    END $matrix$;
    """
    if create:
        # Không sao chép grant cũ: mỗi membership mới có generation1 và revoked_at đúng trạng thái REMOVED.
        statement += f"""
        INSERT INTO workspaces(workspace_id,name,description,created_by_user_id)
          VALUES('{suspended}'::uuid,'Synthetic B','{marker}','{owner}'::uuid),
                ('{removed}'::uuid,'Synthetic C','{marker}','{owner}'::uuid);
        INSERT INTO memberships(workspace_id,user_id,role,status,current_grant_generation,removed_at)
          VALUES('{suspended}'::uuid,'{owner}'::uuid,'ADMIN','ACTIVE',1,NULL),
                ('{removed}'::uuid,'{owner}'::uuid,'ADMIN','ACTIVE',1,NULL),
                ('{suspended}'::uuid,'{subject}'::uuid,'USER','SUSPENDED',1,NULL),
                ('{removed}'::uuid,'{subject}'::uuid,'USER','REMOVED',1,transaction_timestamp());
        INSERT INTO membership_grants(workspace_id,user_id,grant_generation,revoked_at)
          SELECT workspace_id,user_id,1,CASE WHEN status='REMOVED' THEN transaction_timestamp() ELSE NULL END
          FROM memberships WHERE workspace_id IN ({identities});
        SELECT (SELECT count(*) FROM workspaces WHERE workspace_id IN ({identities})),
               (SELECT count(*) FROM memberships WHERE workspace_id IN ({identities})),
               (SELECT count(*) FROM membership_grants WHERE workspace_id IN ({identities})),
               (SELECT string_agg(status,',' ORDER BY status) FROM memberships WHERE user_id='{subject}'::uuid);
        """
        expected = '2|4|4|ACTIVE,ACTIVE,REMOVED,SUSPENDED'
    else:
        # Graph không có resource/audit/idempotency mới; deferred current-grant FK được kiểm sau khi xóa cả hai đầu.
        statement += f"""
        DELETE FROM membership_grants WHERE workspace_id IN ({identities});
        DELETE FROM memberships WHERE workspace_id IN ({identities});
        DELETE FROM workspaces WHERE workspace_id IN ({identities}) AND created_by_user_id='{owner}'::uuid
          AND description='{marker}';
        SELECT (SELECT count(*) FROM workspaces WHERE workspace_id IN ({identities})),
               (SELECT count(*) FROM memberships WHERE workspace_id IN ({identities})),
               (SELECT count(*) FROM membership_grants WHERE workspace_id IN ({identities}));
        """
        expected = '0|0|0'
    statement += 'SET CONSTRAINTS ALL IMMEDIATE; COMMIT;'
    result = lab.sql(statement, database='iot_platform_lab', check=False)
    if result.returncode or result.stdout.strip() != expected:
        raise RuntimeError('Four-workspace fixture rejected')


def read_active_pair(port, headers, expected, checks, label):
    """Đọc tối đa ba page limit1 để bắt missing/duplicate/cursor loop và giữ cursor đầu làm stale control.

    Input
    Param: port — listener loopback do launcher sở hữu.
    Param: headers — credential/context hiện hành, chỉ giữ trong RAM.
    Param: expected — hai summary A/D từ baseline trước khi thêm membership bị chặn.
    Param: checks — ledger chỉ nhận check ID tĩnh.
    Param: label — tên hữu hạn do hai call site nội bộ chọn cho stable/restart.
    Output: cursor đầu đã ký; terminal phải rỗng sau đúng hai summary, không gọi resource.
    """
    rows = []
    cursors = []
    path = '/workspaces?limit=1'
    for _ in range(3):
        status, _, page = provider.request(port, 'GET', path, headers=headers)
        provider.expect(status == 200 and provider.has_workspace_page(page) and len(page['items']) <= 1,
                        label + '-page-contract', checks)
        rows.extend(page['items'])
        cursor = page['nextCursor']
        if cursor is None:
            break
        provider.expect(cursor not in cursors, label + '-cursor-progress', checks)
        cursors.append(cursor)
        path = '/workspaces?limit=1&cursor=' + quote(cursor, safe='')
    provider.expect(cursor is None and rows == expected and len(cursors) == 2,
                    label + '-exact-active-pair', checks)
    return cursors[0]


def verify_workspace_matrix(port, headers, baseline, run_id, user_id, owner_id, checks):
    """Kiểm A/D ACTIVE, B SUSPENDED, C REMOVED và restart sau authority change trước provider suite còn lại.

    Input
    Param: port — server lab đang giữ fixture5accounts và hai workspace seed.
    Param: headers — Web session/context của fixture0 đã được xác nhận.
    Param: baseline — page hai workspace ACTIVE ban đầu, dùng oracle exact identity/summary.
    Param: run_id — UUID provenance của launcher, không đọc secret hoặc ownership journal.
    Param: user_id — fixture0 là subject của cả bốn membership.
    Param: owner_id — fixture4 giữ Admin hiện hành cho B/C.
    Param: checks — check ID tĩnh cho evidence, không chứa account/workspace UUID.
    Errors: mọi projection/status/traversal sai đều fail closed; finally dọn B/C kể cả setup hoặc HTTP lỗi.
    Side effects: hai workspace tạm, B đổi SUSPENDED→REMOVED để invalidate cursor; originals A/D không bị mutate.
    """
    provider.expect(provider.has_workspace_page(baseline) and len(baseline['items']) == 2
                    and baseline['nextCursor'] is None, 'four-workspace-original-active-pair', checks)
    expected = [dict(item) for item in baseline['items']]
    extras = (uuid4(), uuid4())
    try:
        workspace_matrix_fixture(run_id, user_id, owner_id, extras, True)
        checks.append('four-workspace-exact-given-active-suspended-removed-active')
        status, _, page = provider.request(port, 'GET', '/workspaces', headers=headers)
        provider.expect(status == 200 and page == baseline, 'four-workspace-exact-active-pair', checks)
        cursor = read_active_pair(port, headers, expected, checks, 'four-workspace-stable')
        for workspace in extras:
            status, _, body = provider.request(port, 'GET', '/workspaces/' + str(workspace), headers=headers)
            provider.expect(status == 404 and provider.has_error_only_payload(body, 'RESOURCE_NOT_FOUND'),
                            'four-workspace-inactive-detail-denied-no-data', checks)
        # Đổi B dù B không có trong page trước: fingerprint phải phản ánh toàn current authority, không chỉ items visible.
        provider.set_owned_membership_status(run_id, user_id, owner_id, extras[0], 'REMOVED')
        status, _, body = provider.request(port, 'GET', '/workspaces?limit=1&cursor=' + quote(cursor, safe=''), headers=headers)
        provider.expect(status == 400 and provider.has_error_only_payload(body, 'CURSOR_INVALID'),
                        'four-workspace-authority-change-invalidates-cursor', checks)
        read_active_pair(port, headers, expected, checks, 'four-workspace-restart')
    finally:
        workspace_matrix_fixture(run_id, user_id, owner_id, extras, False)
    checks.append('four-workspace-fixture-removed')
