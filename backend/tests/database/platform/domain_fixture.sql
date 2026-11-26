/* Dữ liệu tổng hợp cho graph hai tenant; caller rollback, không có secret dùng thật. */
SET CONSTRAINTS ALL DEFERRED;
INSERT INTO templates(workspace_id,template_id,name,model,created_by_user_id)
 SELECT workspace_id,pg_temp.fixture_id(200+row_number() OVER(ORDER BY workspace_id)::int),'Room','ESP32',created_by_user_id FROM workspaces;
INSERT INTO template_versions(workspace_id,template_version_id,template_id,version_number,name,model,published_by_user_id,content_digest,source_revision,published_root_revision)
 SELECT workspace_id,pg_temp.fixture_id(210+row_number() OVER(ORDER BY workspace_id)::int),template_id,1,name,model,created_by_user_id,decode(repeat('01',32),'hex'),1,2 FROM templates;
INSERT INTO datastream_definitions(workspace_id,template_version_id,stream_key,display_name,data_type,direction,channel_kind,min_value,max_value)
 SELECT workspace_id,template_version_id,stream_key,stream_key,data_type,direction,channel_kind,min_value,max_value FROM template_versions CROSS JOIN
 (VALUES('fan','BOOLEAN','READ_WRITE','STATE',NULL::float8,NULL::float8),('temperature','NUMBER','READ','TELEMETRY',-20::float8,100::float8),('mode','ENUM','READ_WRITE','STATE',NULL::float8,NULL::float8)) AS stream(stream_key,data_type,direction,channel_kind,min_value,max_value);
INSERT INTO datastream_enum_values SELECT workspace_id,template_version_id,'mode',enum_value FROM template_versions CROSS JOIN(VALUES('"on"'::jsonb),('"off"'::jsonb)) AS enumeration(enum_value);
INSERT INTO datastream_capabilities SELECT workspace_id,template_version_id,'fan','SET_VALUE','false'::jsonb FROM template_versions;
INSERT INTO datastream_capabilities SELECT workspace_id,template_version_id,'mode','SET_VALUE','"off"'::jsonb FROM template_versions;
INSERT INTO devices(device_id,workspace_id,serial_number,template_version_id,owner_user_id,name,model,hardware_revision,lifecycle_status)
 SELECT pg_temp.fixture_id(300+device_number),pg_temp.fixture_id(101),'SYNTHETIC-'||device_number,pg_temp.fixture_id(211),pg_temp.fixture_id(1),'Fan','ESP32','1','ACTIVE' FROM generate_series(1,6) AS device_number;
INSERT INTO devices(device_id,workspace_id,serial_number,template_version_id,owner_user_id,name,model,hardware_revision,lifecycle_status) VALUES
 (pg_temp.fixture_id(321),pg_temp.fixture_id(102),'SYNTHETIC-B',pg_temp.fixture_id(212),pg_temp.fixture_id(2),'Fan B','ESP32','1','ACTIVE');
INSERT INTO device_runtime(workspace_id,device_id,presence_state) SELECT workspace_id,device_id,'ONLINE' FROM devices;
INSERT INTO device_credentials(workspace_id,device_id,credential_generation,credential_identifier,verifier_digest,credential_state)
 SELECT workspace_id,device_id,1,'synthetic-'||device_id,decode(repeat('02',32),'hex'),'ACTIVE' FROM devices;
INSERT INTO device_boot_sessions(workspace_id,device_id,boot_id,credential_generation,connection_generation,started_at)
 SELECT workspace_id,device_id,'boot-test',1,1,now() FROM devices;
INSERT INTO actuator_states(workspace_id,device_id,stream_key,pinned_template_version_id) SELECT workspace_id,device_id,'fan',template_version_id FROM devices;
INSERT INTO rules(workspace_id,rule_id,owner_user_id,name,lifecycle_status)
 SELECT pg_temp.fixture_id(101),pg_temp.fixture_id(700+rule_number),pg_temp.fixture_id(1),'Rule '||rule_number,'DISABLED' FROM generate_series(1,11) AS rule_number;
INSERT INTO rule_versions(workspace_id,rule_version_id,rule_id,version_number,trigger_type,trigger_config,condition_ast,cooldown_seconds,priority,on_failure,content_digest)
 SELECT workspace_id,pg_temp.fixture_id(800+row_number() OVER(ORDER BY rule_id)::int),rule_id,1,'MANUAL','{}','{"op":"AND","children":[]}',60,'NORMAL','STOP',decode(repeat('03',32),'hex') FROM rules;
INSERT INTO rule_version_actions(workspace_id,rule_version_id,action_position,action_type,wait_seconds) SELECT workspace_id,rule_version_id,0,'WAIT',5 FROM rule_versions;
INSERT INTO sessions(session_id,user_id,token_digest,auth_context_id,limited,client_type,issued_at,expires_at) VALUES
 (pg_temp.fixture_id(411),pg_temp.fixture_id(1),decode(repeat('11',32),'hex'),pg_temp.fixture_id(412),false,'ANDROID',now(),now()+interval '24 hours');
INSERT INTO push_installations(installation_id,installation_proof_digest,platform,token_generation,binding_generation,permission_state,active_user_id,active_session_id) VALUES
 (pg_temp.fixture_id(1301),decode(repeat('12',32),'hex'),'ANDROID',1,1,'GRANTED',pg_temp.fixture_id(1),pg_temp.fixture_id(411));
INSERT INTO events(workspace_id,event_id,source_kind,source_device_id,episode_key,severity,title,safe_message,created_at) VALUES
 (pg_temp.fixture_id(101),pg_temp.fixture_id(1101),'DEVICE',pg_temp.fixture_id(301),'episode-1','INFO','Synthetic event','Synthetic message',now());
INSERT INTO event_occurrences(workspace_id,occurrence_id,source_kind,event_id,event_revision,occurrence_type,public_event_type,occurred_at,committed_at,immutable_payload) VALUES
 (pg_temp.fixture_id(101),pg_temp.fixture_id(1201),'EVENT',pg_temp.fixture_id(1101),1,'CREATED','event.opened',now(),now(),'{}'),
 (pg_temp.fixture_id(101),pg_temp.fixture_id(1202),'EVENT',pg_temp.fixture_id(1101),2,'RESOLVED','event.resolved',now(),now(),'{}');
INSERT INTO notifications(workspace_id,notification_id,recipient_user_id,kind,event_id,target_type,created_at) VALUES
 (pg_temp.fixture_id(101),pg_temp.fixture_id(1211),pg_temp.fixture_id(1),'EVENT',pg_temp.fixture_id(1101),'EVENT',now());
INSERT INTO webhook_subscriptions(workspace_id,webhook_subscription_id,owner_user_id,endpoint_url,lifecycle_status,active_secret_version) VALUES
 (pg_temp.fixture_id(101),pg_temp.fixture_id(1001),pg_temp.fixture_id(1),'https://receiver.example.invalid/hook','PAUSED',1);
INSERT INTO webhook_secret_versions(workspace_id,webhook_subscription_id,secret_version,secret_ciphertext,encryption_key_reference,created_at)
 SELECT workspace_id,webhook_subscription_id,secret_number,decode('0000','hex'),'SYNTHETIC-NONFUNCTIONAL-KEY',now() FROM webhook_subscriptions CROSS JOIN generate_series(1,3) AS secret_number;
INSERT INTO firmware_packages(workspace_id,firmware_package_id,artifact_digest,raw_manifest,signature,artifact_reference,artifact_size_bytes,signing_key_fingerprint,signing_key_identifier,manifest_schema_version,board_model,hardware_revision,firmware_version,build_identifier,validation_state,created_at) VALUES
 (pg_temp.fixture_id(101),pg_temp.fixture_id(1401),decode(repeat('13',32),'hex'),decode('00','hex'),decode('00','hex'),'SYNTHETIC-ARTIFACT',1,decode(repeat('14',32),'hex'),'SYNTHETIC-KEY',1,'ESP32','1','1.0','test','VERIFIED',now());
INSERT INTO firmware_package_templates VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1401),pg_temp.fixture_id(211));
INSERT INTO api_keys(api_key_id,workspace_id,owner_user_id,owner_grant_generation,verifier_digest,name,prefix,issued_at,expires_at) VALUES
 (pg_temp.fixture_id(1701),pg_temp.fixture_id(101),pg_temp.fixture_id(1),1,decode(repeat('17',32),'hex'),'Synthetic key','synthetic',now(),now()+interval '30 days');
INSERT INTO api_key_devices SELECT workspace_id,pg_temp.fixture_id(1701),device_id FROM devices WHERE workspace_id=pg_temp.fixture_id(101) AND serial_number IN ('SYNTHETIC-1','SYNTHETIC-2','SYNTHETIC-3','SYNTHETIC-4');
INSERT INTO api_key_scopes VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1701),'devices:read');
SET CONSTRAINTS ALL IMMEDIATE;
