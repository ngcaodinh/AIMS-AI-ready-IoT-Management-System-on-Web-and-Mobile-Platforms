/* Fixture lời mời tenant A phục vụ CAS/terminal shape, mọi row rollback sau suite. */
INSERT INTO membership_admission_fences(workspace_id,email_digest,admission_generation)
VALUES(pg_temp.fixture_id(101),decode(repeat('61',32),'hex'),1);
INSERT INTO workspace_invitations(workspace_id,invitation_id,token_digest,email_normalized,email_digest,role,issued_by_user_id,issuer_grant_generation,issuer_authorization_version,admission_generation,issued_at,expires_at)
VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(960),decode(repeat('62',32),'hex'),'revision@example.invalid',decode(repeat('61',32),'hex'),'USER',pg_temp.fixture_id(1),1,1,1,now(),now()+interval '24 hours');
SELECT pg_temp.rejects('invitation_terminal_xor',
 $$UPDATE workspace_invitations SET used_at=now(),revoked_at=now() WHERE invitation_id='00000000-0000-0000-0000-000000000960'$$,'23514','ck_invitation_terminal_shape');
SELECT pg_temp.rejects('invitation_terminal_time',
 $$UPDATE workspace_invitations SET expired_at=now() WHERE invitation_id='00000000-0000-0000-0000-000000000960'$$,'23514','ck_invitation_terminal_shape');
SELECT CASE WHEN revision=1 THEN 'PASS:invitation_revision_default' ELSE 'FAIL:invitation_revision_default' END
FROM workspace_invitations WHERE invitation_id=pg_temp.fixture_id(960);
SELECT pg_temp.rejects('invitation_revision_override',
 $$UPDATE workspace_invitations SET revision=revision+7 WHERE invitation_id='00000000-0000-0000-0000-000000000960'$$,'23514','ck_invitation_revision_override');
SELECT pg_temp.rejects('invitation_primary_identity',
 $$UPDATE workspace_invitations SET invitation_id='00000000-0000-0000-0000-000000000961' WHERE invitation_id='00000000-0000-0000-0000-000000000960'$$,'23514','ck_resource_identity_immutable');
/* SQL no-op không tạo revision mới; terminal mutation do engine tự tăng đúng một. */
UPDATE workspace_invitations SET revoked_at=revoked_at WHERE invitation_id=pg_temp.fixture_id(960);
SELECT CASE WHEN revision=1 THEN 'PASS:invitation_revision_noop' ELSE 'FAIL:invitation_revision_noop' END
FROM workspace_invitations WHERE invitation_id=pg_temp.fixture_id(960);
UPDATE workspace_invitations SET revoked_at=now() WHERE invitation_id=pg_temp.fixture_id(960);
SELECT CASE WHEN revision=2 THEN 'PASS:invitation_revision_native_transition' ELSE 'FAIL:invitation_revision_native_transition' END
FROM workspace_invitations WHERE invitation_id=pg_temp.fixture_id(960);
SELECT pg_temp.rejects('invitation_terminal_irreversible',
 $$UPDATE workspace_invitations SET revoked_at=NULL WHERE invitation_id='00000000-0000-0000-0000-000000000960'$$,'23514','ck_one_way_timestamp');
