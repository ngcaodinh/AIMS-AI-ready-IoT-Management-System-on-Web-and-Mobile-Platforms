/* Registry chưa có hello không được bịa hardware metadata; identity cloud vẫn bất biến. */
INSERT INTO devices(device_id,workspace_id,serial_number,template_version_id,owner_user_id,name,model)
VALUES(pg_temp.fixture_id(390),pg_temp.fixture_id(101),'REGISTRATION-UNKNOWN-HARDWARE',pg_temp.fixture_id(211),pg_temp.fixture_id(1),'Registration','ESP32');
SELECT CASE WHEN hardware_revision IS NULL AND firmware_version IS NULL AND lifecycle_status='REGISTERED'
 THEN 'PASS:device_registration_unknown_hardware' ELSE 'FAIL:device_registration_unknown_hardware' END
FROM devices WHERE device_id=pg_temp.fixture_id(390);
SELECT pg_temp.rejects('registration_owner_immutable', $$UPDATE devices SET owner_user_id=pg_temp.fixture_id(2) WHERE device_id=pg_temp.fixture_id(390)$$,'23514','ck_resource_identity_immutable');
/* Authenticated hello adapter mới được cập nhật observation; không khóa nó như identity do registry cấp. */
UPDATE devices SET hardware_revision='REV-A' WHERE device_id=pg_temp.fixture_id(390);
SELECT CASE WHEN hardware_revision='REV-A' THEN 'PASS:device_hardware_observation_can_follow_registration' ELSE 'FAIL:device_hardware_observation_can_follow_registration' END
FROM devices WHERE device_id=pg_temp.fixture_id(390);
