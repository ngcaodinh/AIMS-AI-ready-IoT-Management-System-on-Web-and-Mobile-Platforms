/* Automation/command/dashboard phụ thuộc device pin0002; cycle FK được đóng cuối migration.
 * Không dispatch mạng, không reset dữ liệu; writer bị khóa ở0007 trước mở ứng dụng.
 */
CREATE TABLE actuator_states (
 workspace_id uuid NOT NULL, device_id uuid NOT NULL, stream_key text NOT NULL, pinned_template_version_id uuid NOT NULL,
 manual_epoch bigint NOT NULL DEFAULT 0 CHECK(manual_epoch>=0), last_reported_value jsonb, last_reported_at timestamptz,
 reported_source text NOT NULL DEFAULT 'NONE' CHECK(reported_source IN ('NONE','DEVICE_RESULT','TELEMETRY','HELLO')),
 unresolved_command_id uuid,
 PRIMARY KEY(workspace_id,device_id,stream_key),
 FOREIGN KEY(workspace_id,device_id,pinned_template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),
 FOREIGN KEY(workspace_id,pinned_template_version_id,stream_key) REFERENCES datastream_definitions
);
CREATE TABLE dashboards (
 workspace_id uuid NOT NULL, dashboard_id uuid NOT NULL, owner_user_id uuid NOT NULL, title text NOT NULL,
 schema_version integer NOT NULL DEFAULT 1 CHECK(schema_version=1), revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),
 lifecycle_status text NOT NULL DEFAULT 'ACTIVE' CHECK(lifecycle_status IN ('ACTIVE','ARCHIVED')),
 created_at timestamptz NOT NULL DEFAULT transaction_timestamp(), updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
 PRIMARY KEY(workspace_id,dashboard_id), FOREIGN KEY(workspace_id,owner_user_id) REFERENCES memberships
);
CREATE TABLE dashboard_widgets (
 workspace_id uuid NOT NULL, dashboard_id uuid NOT NULL, widget_id uuid NOT NULL,
 widget_type text NOT NULL CHECK(widget_type IN ('VALUE','GAUGE','STATUS','SWITCH','BUTTON','CHART')),
 position integer NOT NULL CHECK(position BETWEEN 0 AND 19), presentation jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(presentation)='object'),
 layout_x integer NOT NULL CHECK(layout_x BETWEEN 0 AND 11), layout_y integer NOT NULL CHECK(layout_y>=0),
 layout_width integer NOT NULL CHECK(layout_width>0), layout_height integer NOT NULL CHECK(layout_height>0),
 PRIMARY KEY(workspace_id,dashboard_id,widget_id), UNIQUE(workspace_id,dashboard_id,position),
 FOREIGN KEY(workspace_id,dashboard_id) REFERENCES dashboards, CHECK(layout_x+layout_width<=12)
);
/* Presence không có stream; tuple pin/stream cùng NULL hoặc cùng có, device luôn scoped. */
CREATE TABLE dashboard_widget_bindings (
 workspace_id uuid NOT NULL, dashboard_id uuid NOT NULL, widget_id uuid NOT NULL, binding_slot text NOT NULL,
 device_id uuid NOT NULL, template_version_id uuid, stream_key text,
 PRIMARY KEY(workspace_id,dashboard_id,widget_id,binding_slot),
 FOREIGN KEY(workspace_id,dashboard_id,widget_id) REFERENCES dashboard_widgets,
 FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id),
 FOREIGN KEY(workspace_id,device_id,template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),
 FOREIGN KEY(workspace_id,template_version_id,stream_key) REFERENCES datastream_definitions,
 CHECK((template_version_id IS NULL)=(stream_key IS NULL))
);
CREATE TABLE rules (
 workspace_id uuid NOT NULL, rule_id uuid NOT NULL, owner_user_id uuid NOT NULL, name text NOT NULL,
 lifecycle_status text NOT NULL DEFAULT 'DRAFT' CHECK(lifecycle_status IN ('DRAFT','ENABLED','DISABLED','ARCHIVED','ERROR_DISABLED')),
 revision bigint NOT NULL DEFAULT 1 CHECK(revision>0), draft_revision bigint NOT NULL DEFAULT 1 CHECK(draft_revision>0), active_rule_version_id uuid,
 created_at timestamptz NOT NULL DEFAULT transaction_timestamp(), updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
 PRIMARY KEY(workspace_id,rule_id), FOREIGN KEY(workspace_id,owner_user_id) REFERENCES memberships
);
CREATE TABLE rule_drafts (
 workspace_id uuid NOT NULL, rule_id uuid NOT NULL,
 trigger_type text NOT NULL CHECK(trigger_type IN ('THRESHOLD','SCHEDULE','CONNECTIVITY','MANUAL')),
 trigger_config jsonb NOT NULL CHECK(jsonb_typeof(trigger_config)='object'), condition_ast jsonb NOT NULL CHECK(jsonb_typeof(condition_ast)='object'),
 schema_version integer NOT NULL DEFAULT 1 CHECK(schema_version=1), cooldown_seconds integer NOT NULL CHECK(cooldown_seconds BETWEEN 10 AND 3600),
 priority text NOT NULL CHECK(priority IN ('HIGH','NORMAL','LOW')), on_failure text NOT NULL CHECK(on_failure IN ('STOP','CONTINUE')),
 PRIMARY KEY(workspace_id,rule_id), FOREIGN KEY(workspace_id,rule_id) REFERENCES rules
);
CREATE TABLE rule_draft_actions (
 workspace_id uuid NOT NULL, rule_id uuid NOT NULL, action_position integer NOT NULL CHECK(action_position BETWEEN 0 AND 4),
 action_type text NOT NULL CHECK(action_type IN ('SET_VALUE','WAIT','NOTIFY')), wait_seconds integer,
 target_device_id uuid, target_template_version_id uuid, target_stream_key text, target_value jsonb, notification_config jsonb,
 PRIMARY KEY(workspace_id,rule_id,action_position), FOREIGN KEY(workspace_id,rule_id) REFERENCES rule_drafts,
 FOREIGN KEY(workspace_id,target_device_id,target_template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),
 FOREIGN KEY(workspace_id,target_template_version_id,target_stream_key) REFERENCES datastream_definitions,
 CONSTRAINT ck_rule_draft_action_shape CHECK(
  (action_type='WAIT' AND wait_seconds IS NOT NULL AND wait_seconds BETWEEN 5 AND 600 AND num_nonnulls(target_device_id,target_template_version_id,target_stream_key,target_value,notification_config)=0) OR
  (action_type='SET_VALUE' AND wait_seconds IS NULL AND notification_config IS NULL AND num_nonnulls(target_device_id,target_template_version_id,target_stream_key,target_value)=4 AND jsonb_typeof(target_value) IN ('boolean','number','string')) OR
  (action_type='NOTIFY' AND notification_config IS NOT NULL AND jsonb_typeof(notification_config)='object' AND num_nonnulls(wait_seconds,target_device_id,target_template_version_id,target_stream_key,target_value)=0))
);
CREATE TABLE rule_draft_references (
 workspace_id uuid NOT NULL, rule_id uuid NOT NULL, reference_path text NOT NULL, device_id uuid NOT NULL,
 template_version_id uuid NOT NULL, stream_key text, reference_kind text NOT NULL CHECK(reference_kind IN ('TRIGGER','CONDITION','ACTION')),
 PRIMARY KEY(workspace_id,rule_id,reference_path), FOREIGN KEY(workspace_id,rule_id) REFERENCES rule_drafts,
 FOREIGN KEY(workspace_id,device_id,template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),
 FOREIGN KEY(workspace_id,template_version_id,stream_key) REFERENCES datastream_definitions
);
CREATE TABLE rule_versions (
 workspace_id uuid NOT NULL, rule_version_id uuid NOT NULL, rule_id uuid NOT NULL, version_number integer NOT NULL CHECK(version_number>0),
 trigger_type text NOT NULL CHECK(trigger_type IN ('THRESHOLD','SCHEDULE','CONNECTIVITY','MANUAL')),
 trigger_config jsonb NOT NULL CHECK(jsonb_typeof(trigger_config)='object'), condition_ast jsonb NOT NULL CHECK(jsonb_typeof(condition_ast)='object'),
 schema_version integer NOT NULL DEFAULT 1 CHECK(schema_version=1), cooldown_seconds integer NOT NULL CHECK(cooldown_seconds BETWEEN 10 AND 3600),
 priority text NOT NULL CHECK(priority IN ('HIGH','NORMAL','LOW')), on_failure text NOT NULL CHECK(on_failure IN ('STOP','CONTINUE')),
 published_at timestamptz NOT NULL DEFAULT transaction_timestamp(), content_digest bytea NOT NULL CHECK(octet_length(content_digest)=32),
 PRIMARY KEY(workspace_id,rule_version_id), UNIQUE(workspace_id,rule_id,version_number), UNIQUE(workspace_id,rule_id,rule_version_id),
 FOREIGN KEY(workspace_id,rule_id) REFERENCES rules
);
ALTER TABLE rules ADD CONSTRAINT fk_rules_active_version FOREIGN KEY(workspace_id,rule_id,active_rule_version_id) REFERENCES rule_versions(workspace_id,rule_id,rule_version_id) DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE rule_version_actions (
 workspace_id uuid NOT NULL, rule_version_id uuid NOT NULL, action_position integer NOT NULL CHECK(action_position BETWEEN 0 AND 4),
 action_type text NOT NULL CHECK(action_type IN ('SET_VALUE','WAIT','NOTIFY')), wait_seconds integer,
 target_device_id uuid, target_template_version_id uuid, target_stream_key text, target_value jsonb, notification_config jsonb,
 PRIMARY KEY(workspace_id,rule_version_id,action_position), FOREIGN KEY(workspace_id,rule_version_id) REFERENCES rule_versions,
 FOREIGN KEY(workspace_id,target_device_id,target_template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),
 FOREIGN KEY(workspace_id,target_template_version_id,target_stream_key) REFERENCES datastream_definitions,
 CONSTRAINT ck_rule_version_action_shape CHECK(
  (action_type='WAIT' AND wait_seconds IS NOT NULL AND wait_seconds BETWEEN 5 AND 600 AND num_nonnulls(target_device_id,target_template_version_id,target_stream_key,target_value,notification_config)=0) OR
  (action_type='SET_VALUE' AND wait_seconds IS NULL AND notification_config IS NULL AND num_nonnulls(target_device_id,target_template_version_id,target_stream_key,target_value)=4 AND jsonb_typeof(target_value) IN ('boolean','number','string')) OR
  (action_type='NOTIFY' AND notification_config IS NOT NULL AND jsonb_typeof(notification_config)='object' AND num_nonnulls(wait_seconds,target_device_id,target_template_version_id,target_stream_key,target_value)=0))
);
/* Tối đa một NOTIFY; tổng WAIT và contiguity kiểm tại publish boundary. */
CREATE UNIQUE INDEX uq_rule_version_notify ON rule_version_actions(workspace_id,rule_version_id) WHERE action_type='NOTIFY';
CREATE UNIQUE INDEX uq_rule_draft_notify ON rule_draft_actions(workspace_id,rule_id) WHERE action_type='NOTIFY';
CREATE TABLE rule_version_references (
 workspace_id uuid NOT NULL, rule_version_id uuid NOT NULL, reference_path text NOT NULL, device_id uuid NOT NULL,
 template_version_id uuid NOT NULL, stream_key text, reference_kind text NOT NULL CHECK(reference_kind IN ('TRIGGER','CONDITION','ACTION')),
 PRIMARY KEY(workspace_id,rule_version_id,reference_path), FOREIGN KEY(workspace_id,rule_version_id) REFERENCES rule_versions,
 FOREIGN KEY(workspace_id,device_id,template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),
 FOREIGN KEY(workspace_id,template_version_id,stream_key) REFERENCES datastream_definitions
);
CREATE TABLE rule_runtime (
 workspace_id uuid NOT NULL, rule_id uuid NOT NULL, active_generation bigint NOT NULL CHECK(active_generation>0),
 cooldown_until timestamptz, error_disabled_reason text, current_rule_version_id uuid,
 PRIMARY KEY(workspace_id,rule_id), FOREIGN KEY(workspace_id,rule_id) REFERENCES rules,
 FOREIGN KEY(workspace_id,rule_id,current_rule_version_id) REFERENCES rule_versions(workspace_id,rule_id,rule_version_id)
);
CREATE TABLE rule_trigger_states (
 workspace_id uuid NOT NULL, rule_version_id uuid NOT NULL, trigger_key text NOT NULL, is_armed boolean NOT NULL,
 hold_started_at timestamptz, last_fresh_at timestamptz, episode_sequence bigint NOT NULL DEFAULT 0 CHECK(episode_sequence>=0),
 last_marker_sequence bigint CHECK(last_marker_sequence>0), PRIMARY KEY(workspace_id,rule_version_id,trigger_key),
 FOREIGN KEY(workspace_id,rule_version_id) REFERENCES rule_versions
);
CREATE TABLE rule_executions (
 workspace_id uuid NOT NULL, rule_execution_id uuid NOT NULL, rule_id uuid NOT NULL, rule_version_id uuid NOT NULL, trigger_key text NOT NULL,
 state text NOT NULL CHECK(state IN ('RUNNING','WAITING','SUCCEEDED','PARTIAL','FAILED','CANCELLED','NEEDS_ATTENTION','NO_MATCH')),
 admitted_at timestamptz NOT NULL, deadline_at timestamptz NOT NULL, ended_at timestamptz,
 next_action_position integer NOT NULL DEFAULT 0 CHECK(next_action_position BETWEEN 0 AND 5), owner_user_id_snapshot uuid NOT NULL, failure_reason text,
 PRIMARY KEY(workspace_id,rule_execution_id), UNIQUE(workspace_id,rule_execution_id,rule_version_id),
 UNIQUE(workspace_id,rule_version_id,trigger_key), FOREIGN KEY(workspace_id,rule_id,rule_version_id) REFERENCES rule_versions(workspace_id,rule_id,rule_version_id),
 FOREIGN KEY(workspace_id,owner_user_id_snapshot) REFERENCES memberships, CHECK(deadline_at=admitted_at+interval '15 minutes')
);
/* Unicité active par rule; quota workspace serialisé par trigger0007. */
CREATE UNIQUE INDEX uq_rule_executions_active_rule ON rule_executions(workspace_id,rule_id) WHERE state IN ('RUNNING','WAITING');
CREATE INDEX ix_rule_executions_history ON rule_executions(workspace_id,rule_id,admitted_at DESC,rule_execution_id);
CREATE TABLE rule_execution_snapshots (
 workspace_id uuid NOT NULL, rule_execution_id uuid NOT NULL, input_snapshot jsonb NOT NULL, condition_trace jsonb NOT NULL, definition_snapshot jsonb,
 PRIMARY KEY(workspace_id,rule_execution_id), FOREIGN KEY(workspace_id,rule_execution_id) REFERENCES rule_executions
);
CREATE TABLE schedule_occurrences (
 workspace_id uuid NOT NULL, rule_version_id uuid NOT NULL, occurrence_key text NOT NULL,
 scheduled_at timestamptz NOT NULL, timezone_snapshot text NOT NULL,
 state text NOT NULL CHECK(state IN ('PENDING','ADMITTED','SKIPPED','CANCELLED')), rule_execution_id uuid,
 PRIMARY KEY(workspace_id,rule_version_id,occurrence_key), FOREIGN KEY(workspace_id,rule_version_id) REFERENCES rule_versions,
 FOREIGN KEY(workspace_id,rule_execution_id,rule_version_id) REFERENCES rule_executions(workspace_id,rule_execution_id,rule_version_id)
);
/* Lịch đến hạn sau scope, không dùng now() trong partial predicate. */
CREATE INDEX ix_schedule_due ON schedule_occurrences(scheduled_at,workspace_id,rule_version_id) WHERE state='PENDING';
CREATE TABLE rule_trigger_receipts (
 workspace_id uuid NOT NULL, rule_version_id uuid NOT NULL, trigger_key text NOT NULL,
 decision text NOT NULL CHECK(decision IN ('ADMITTED','NO_MATCH','SUPPRESSED','REJECTED')), decided_at timestamptz NOT NULL, rule_execution_id uuid,
 PRIMARY KEY(workspace_id,rule_version_id,trigger_key), FOREIGN KEY(workspace_id,rule_version_id) REFERENCES rule_versions,
 FOREIGN KEY(workspace_id,rule_execution_id,rule_version_id) REFERENCES rule_executions(workspace_id,rule_execution_id,rule_version_id)
);
CREATE TABLE execution_actuator_snapshots (
 workspace_id uuid NOT NULL, rule_execution_id uuid NOT NULL, device_id uuid NOT NULL, stream_key text NOT NULL,
 manual_epoch_at_start bigint NOT NULL CHECK(manual_epoch_at_start>=0),
 PRIMARY KEY(workspace_id,rule_execution_id,device_id,stream_key), FOREIGN KEY(workspace_id,rule_execution_id) REFERENCES rule_executions,
 FOREIGN KEY(workspace_id,device_id,stream_key) REFERENCES actuator_states
);
CREATE TABLE action_executions (
 workspace_id uuid NOT NULL, rule_execution_id uuid NOT NULL, action_position integer NOT NULL,
 action_execution_id uuid NOT NULL, rule_version_id uuid NOT NULL,
 state text NOT NULL CHECK(state IN ('BLOCKED','READY','WAITING','DISPATCHING','AWAITING_RESULT','SUCCEEDED','FAILED','CANCELLED','NEEDS_ATTENTION')),
 started_at timestamptz, ended_at timestamptz, command_id uuid, reason_code text,
 PRIMARY KEY(workspace_id,rule_execution_id,action_position), UNIQUE(workspace_id,action_execution_id), UNIQUE(workspace_id,action_execution_id,command_id),
 FOREIGN KEY(workspace_id,rule_execution_id,rule_version_id) REFERENCES rule_executions(workspace_id,rule_execution_id,rule_version_id),
 FOREIGN KEY(workspace_id,rule_version_id,action_position) REFERENCES rule_version_actions
);
CREATE TABLE action_jobs (
 workspace_id uuid NOT NULL, rule_execution_id uuid NOT NULL, action_position integer NOT NULL,
 state text NOT NULL CHECK(state IN ('BLOCKED','READY','WAITING','DISPATCHING','AWAITING_RESULT','SUCCEEDED','FAILED','CANCELLED','NEEDS_ATTENTION')),
 due_at timestamptz NOT NULL, lease_until timestamptz, lease_generation bigint NOT NULL DEFAULT 0 CHECK(lease_generation>=0),
 attempt_count integer NOT NULL DEFAULT 0 CHECK(attempt_count>=0),
 PRIMARY KEY(workspace_id,rule_execution_id,action_position), FOREIGN KEY(workspace_id,rule_execution_id,action_position) REFERENCES action_executions
);
/* Một bước READY/execution; claim theo due_at và lease_generation, không giữ lock qua mạng. */
CREATE UNIQUE INDEX uq_action_jobs_ready ON action_jobs(workspace_id,rule_execution_id) WHERE state='READY';
CREATE INDEX ix_action_jobs_due ON action_jobs(due_at,workspace_id,rule_execution_id) WHERE state IN ('READY','WAITING');
CREATE TABLE commands (
 workspace_id uuid NOT NULL, command_id uuid NOT NULL, device_id uuid NOT NULL, stream_key text NOT NULL,
 origin_type text NOT NULL CHECK(origin_type IN ('MANUAL','AUTOMATION','INTEGRATION')), actor_user_id uuid, api_key_id uuid, action_execution_id uuid,
 value_type text NOT NULL CHECK(value_type IN ('NUMBER','BOOLEAN','ENUM')), numeric_value double precision, boolean_value boolean, text_value text,
 state text NOT NULL DEFAULT 'ADMITTED' CHECK(state IN ('ADMITTED','DISPATCHING','DISPATCHED','ACCEPTED','SUCCEEDED','FAILED','TIMED_OUT','EXPIRED_BEFORE_DISPATCH','CANCELLED')),
 outcome text NOT NULL DEFAULT 'PENDING' CHECK(outcome IN ('PENDING','SUCCEEDED','FAILED','UNKNOWN')),
 admitted_at timestamptz NOT NULL, deadline_at timestamptz NOT NULL, dispatch_intent_at timestamptz, terminal_at timestamptz,
 manual_epoch_snapshot bigint NOT NULL CHECK(manual_epoch_snapshot>=0), revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),
 PRIMARY KEY(workspace_id,command_id), UNIQUE(workspace_id,command_id,device_id), UNIQUE(workspace_id,device_id,stream_key,command_id),
 UNIQUE(workspace_id,command_id,action_execution_id),
 FOREIGN KEY(workspace_id,device_id,stream_key) REFERENCES actuator_states, FOREIGN KEY(workspace_id,actor_user_id) REFERENCES memberships,
 FOREIGN KEY(workspace_id,action_execution_id) REFERENCES action_executions(workspace_id,action_execution_id),
 CHECK(deadline_at=admitted_at+interval '10 seconds'),
 CONSTRAINT ck_command_origin CHECK(
  (origin_type='MANUAL' AND actor_user_id IS NOT NULL AND api_key_id IS NULL AND action_execution_id IS NULL) OR
  (origin_type='AUTOMATION' AND action_execution_id IS NOT NULL AND actor_user_id IS NULL AND api_key_id IS NULL) OR
  (origin_type='INTEGRATION' AND api_key_id IS NOT NULL AND actor_user_id IS NULL AND action_execution_id IS NULL)),
 CONSTRAINT ck_command_value CHECK(num_nonnulls(numeric_value,boolean_value,text_value)=1 AND
  ((value_type='NUMBER' AND numeric_value IS NOT NULL) OR (value_type='BOOLEAN' AND boolean_value IS NOT NULL) OR (value_type='ENUM' AND (numeric_value IS NOT NULL OR text_value IS NOT NULL)))),
 CHECK(numeric_value IS NULL OR (numeric_value>'-Infinity'::float8 AND numeric_value<'Infinity'::float8)),
 CONSTRAINT ck_command_state_outcome CHECK(
  (state IN ('ADMITTED','DISPATCHING','DISPATCHED','ACCEPTED') AND outcome='PENDING' AND terminal_at IS NULL) OR
  (state='SUCCEEDED' AND outcome='SUCCEEDED' AND terminal_at IS NOT NULL) OR
  (state IN ('FAILED','EXPIRED_BEFORE_DISPATCH','CANCELLED') AND outcome='FAILED' AND terminal_at IS NOT NULL) OR
  (state='TIMED_OUT' AND outcome='UNKNOWN' AND terminal_at IS NOT NULL))
);
/* Guard active không đủ cho UNKNOWN; actuator.unresolved_command_id giữ fence sau timeout. */
CREATE UNIQUE INDEX uq_commands_active_actuator ON commands(workspace_id,device_id,stream_key) WHERE state IN ('ADMITTED','DISPATCHING','DISPATCHED','ACCEPTED');
/* Stable action chỉ tạo một command kể cả command đã terminal. */
CREATE UNIQUE INDEX uq_commands_action ON commands(workspace_id,action_execution_id) WHERE action_execution_id IS NOT NULL;
CREATE INDEX ix_commands_history ON commands(workspace_id,device_id,admitted_at DESC,command_id);
ALTER TABLE actuator_states ADD CONSTRAINT fk_actuator_unresolved_command FOREIGN KEY(workspace_id,device_id,stream_key,unresolved_command_id) REFERENCES commands(workspace_id,device_id,stream_key,command_id) DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE action_executions ADD CONSTRAINT fk_action_command FOREIGN KEY(workspace_id,command_id,action_execution_id) REFERENCES commands(workspace_id,command_id,action_execution_id) DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE command_result_receipts (
 workspace_id uuid NOT NULL, command_id uuid NOT NULL, result_phase text NOT NULL CHECK(result_phase IN ('ACCEPTED','SUCCEEDED','FAILED')),
 device_id uuid NOT NULL, boot_id text NOT NULL, credential_generation bigint NOT NULL,
 payload_digest bytea NOT NULL CHECK(octet_length(payload_digest)=32), received_at timestamptz NOT NULL, result_snapshot jsonb NOT NULL,
 PRIMARY KEY(workspace_id,command_id,result_phase), FOREIGN KEY(workspace_id,command_id,device_id) REFERENCES commands(workspace_id,command_id,device_id),
 FOREIGN KEY(workspace_id,device_id,boot_id,credential_generation) REFERENCES device_boot_sessions(workspace_id,device_id,boot_id,credential_generation)
);
CREATE TABLE command_evidence (
 workspace_id uuid NOT NULL, command_evidence_id uuid NOT NULL, command_id uuid NOT NULL,
 evidence_type text NOT NULL CHECK(evidence_type IN ('LATE_RESULT','CONFLICTING_RESULT','DEVICE_OBSERVATION')),
 received_at timestamptz NOT NULL, payload_digest bytea NOT NULL CHECK(octet_length(payload_digest)=32), sanitized_payload jsonb NOT NULL,
 PRIMARY KEY(workspace_id,command_evidence_id), UNIQUE(workspace_id,command_id,command_evidence_id), FOREIGN KEY(workspace_id,command_id) REFERENCES commands
);
/* Timeline bằng chứng theo tenant/command và thời điểm quan sát. */
CREATE INDEX ix_command_evidence_timeline ON command_evidence(workspace_id,command_id,received_at,command_evidence_id);
CREATE TABLE command_resolutions (
 workspace_id uuid NOT NULL, command_id uuid NOT NULL,
 resolution_status text NOT NULL CHECK(resolution_status IN ('UNRESOLVED','ACKNOWLEDGED_UNKNOWN','DEVICE_CONFIRMED_LATE')),
 resolved_by_user_id uuid, resolved_at timestamptz, manual_observation jsonb, device_evidence_id uuid, reason_code text,
 PRIMARY KEY(workspace_id,command_id), FOREIGN KEY(workspace_id,command_id) REFERENCES commands,
 FOREIGN KEY(workspace_id,resolved_by_user_id) REFERENCES memberships,
 FOREIGN KEY(workspace_id,command_id,device_evidence_id) REFERENCES command_evidence(workspace_id,command_id,command_evidence_id)
);
