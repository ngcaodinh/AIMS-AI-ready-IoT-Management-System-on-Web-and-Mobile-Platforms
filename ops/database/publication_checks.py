"""Probe qua COMMIT thật cho seal; fixture UUID ngẫu nhiên và cleanup có kiểm chứng dấu sở hữu."""

from uuid import uuid4
from pathlib import Path


# Hai transaction phải khác XID; rollback-only test không chứng minh parent đã commit không mở lại.
def verify(sql):
    """Kiểm UPDATE no-op và ON CONFLICT không mở parent đã commit trên DB canonical.
    Input
    Param: sql — adapter DB đã được runner kiểm namespace và container identity.
    Output: các ca PASS; Side effects: commit graph riêng rồi cleanup đúng UUID sau ownership check.
    Errors: RuntimeError nếu guard sai hoặc mất dấu sở hữu; không dọn dữ liệu khi không xác minh được.
    """
    user_id,workspace_id,template_id,version_id,device_id,key_id,rule_id,rule_version_id,package_id=(str(uuid4()) for _ in range(9))
    marker="PUBLICATION_PROBE_"+uuid4().hex
    committed=False
    try:
        # UUID sinh nội bộ, không nhận input; preflight dưới cùng transaction trước INSERT graph riêng.
        setup=f"""BEGIN; SET CONSTRAINTS ALL DEFERRED;
        INSERT INTO public.users(user_id,email_normalized,password_hash,account_status,activation_provenance)
        VALUES('{user_id}','publication-{user_id}@example.invalid','invalid-test-verifier','ACTIVE','{marker}');
        INSERT INTO public.workspaces(workspace_id,name,description,created_by_user_id)
        VALUES('{workspace_id}','Publication probe','{marker}','{user_id}');
        INSERT INTO public.memberships(workspace_id,user_id,role,current_grant_generation)
        VALUES('{workspace_id}','{user_id}','ADMIN',1);
        INSERT INTO public.membership_grants(workspace_id,user_id,grant_generation)
        VALUES('{workspace_id}','{user_id}',1);
        INSERT INTO public.templates(workspace_id,template_id,name,model,created_by_user_id)
        VALUES('{workspace_id}','{template_id}','Publication probe','TEST','{user_id}');
        INSERT INTO public.template_versions(workspace_id,template_version_id,template_id,version_number,name,model,published_by_user_id,content_digest)
        VALUES('{workspace_id}','{version_id}','{template_id}',1,'Publication probe','TEST','{user_id}',decode(repeat('55',32),'hex'));
        INSERT INTO public.datastream_definitions(workspace_id,template_version_id,stream_key,display_name,data_type,direction,channel_kind)
        VALUES('{workspace_id}','{version_id}','base','Base','BOOLEAN','READ','STATE');
        INSERT INTO public.devices(device_id,workspace_id,serial_number,template_version_id,owner_user_id,name,model,hardware_revision,lifecycle_status)
        VALUES('{device_id}','{workspace_id}','PROBE-{device_id}','{version_id}','{user_id}','Probe','TEST','1','ACTIVE');
        INSERT INTO public.api_keys(api_key_id,workspace_id,owner_user_id,owner_grant_generation,verifier_digest,name,prefix,issued_at,expires_at)
        VALUES('{key_id}','{workspace_id}','{user_id}',1,decode(replace('{key_id}','-','')||replace('{key_id}','-',''),'hex'),'Probe','probe',now(),now()+interval '720 hours');
        INSERT INTO public.api_key_devices VALUES('{workspace_id}','{key_id}','{device_id}');
        INSERT INTO public.api_key_scopes VALUES('{workspace_id}','{key_id}','devices:read');
        INSERT INTO public.rules(workspace_id,rule_id,owner_user_id,name,lifecycle_status)
        VALUES('{workspace_id}','{rule_id}','{user_id}','Probe','DISABLED');
        INSERT INTO public.rule_versions(workspace_id,rule_version_id,rule_id,version_number,trigger_type,trigger_config,condition_ast,cooldown_seconds,priority,on_failure,content_digest)
        VALUES('{workspace_id}','{rule_version_id}','{rule_id}',1,'MANUAL','{{}}','{{"op":"AND","children":[]}}',60,'NORMAL','STOP',decode(repeat('56',32),'hex'));
        INSERT INTO public.rule_version_actions(workspace_id,rule_version_id,action_position,action_type,wait_seconds)
        VALUES('{workspace_id}','{rule_version_id}',0,'WAIT',5);
        INSERT INTO public.firmware_packages(workspace_id,firmware_package_id,artifact_digest,raw_manifest,signature,artifact_reference,artifact_size_bytes,signing_key_fingerprint,signing_key_identifier,manifest_schema_version,board_model,hardware_revision,firmware_version,build_identifier,validation_state,created_at)
        VALUES('{workspace_id}','{package_id}',decode(repeat('57',32),'hex'),decode('00','hex'),decode('00','hex'),'SYNTHETIC-PROBE',1,decode(repeat('58',32),'hex'),'SYNTHETIC-PROBE',1,'TEST','1','1.0','probe','VERIFIED',now());
        INSERT INTO public.firmware_package_templates VALUES('{workspace_id}','{package_id}','{version_id}');
        SET CONSTRAINTS ALL IMMEDIATE; COMMIT;"""
        sql(setup)
        committed=True
        # Metadata assertion chỉ đọc dấu fixture, không in password/token hoặc hàng người dùng.
        append=f"""INSERT INTO public.datastream_definitions(workspace_id,template_version_id,stream_key,display_name,data_type,direction,channel_kind)
        VALUES('{workspace_id}','{version_id}','late','Late','BOOLEAN','READ','STATE');"""
        statements=(
            ("committed_parent_rejects_child_append",append),
            ("noop_update_cannot_reopen_publication",f"UPDATE public.template_versions SET name=name WHERE template_version_id='{version_id}';"+append),
            ("on_conflict_does_not_mint_publication",f"""INSERT INTO public.template_versions(workspace_id,template_version_id,template_id,version_number,name,model,published_by_user_id,content_digest)
             VALUES('{workspace_id}','{version_id}','{template_id}',1,'Publication probe','TEST','{user_id}',decode(repeat('55',32),'hex')) ON CONFLICT DO NOTHING;"""+append),
            ("api_key_metadata_update_cannot_extend_scopes",f"""UPDATE public.api_keys SET name='Updated probe',last_used_at=clock_timestamp() WHERE api_key_id='{key_id}';
              INSERT INTO public.api_key_scopes VALUES('{workspace_id}','{key_id}','telemetry:read');"""),
            ("rule_noop_update_cannot_extend_actions",f"""UPDATE public.rule_versions SET priority=priority WHERE rule_version_id='{rule_version_id}';
              INSERT INTO public.rule_version_actions(workspace_id,rule_version_id,action_position,action_type,wait_seconds) VALUES('{workspace_id}','{rule_version_id}',1,'WAIT',5);"""),
            ("firmware_noop_update_cannot_extend_compatibility",f"""UPDATE public.firmware_packages SET artifact_reference=artifact_reference WHERE firmware_package_id='{package_id}';
              INSERT INTO public.firmware_package_templates VALUES('{workspace_id}','{package_id}','{version_id}');"""),
        )
        results=[]
        for name,statement in statements:
            result=sql("\\set VERBOSITY verbose\nBEGIN;\n"+statement+"\nROLLBACK;",check=False)
            if result.returncode==0 or 'ck_published_child_sealed' not in result.stderr or '23514' not in result.stderr:
                raise RuntimeError("Publication boundary failed: "+name+" "+result.stderr)
            results.append("PASS:"+name)
        # Chạy chính migration trên graph có stream: adoption guard phải chặn trước mọi ALTER, không suy loại kênh cũ.
        adoption=(Path(__file__).resolve().parents[2]/"backend/migrations/platform/0018_channel_kind.sql").read_text(encoding="utf-8")
        rejected=sql("\\set VERBOSITY verbose\nBEGIN;\n"+adoption+"\nROLLBACK;",check=False)
        if rejected.returncode==0 or '23514' not in rejected.stderr or 'ck_channel_kind_adoption_required' not in rejected.stderr:
            raise RuntimeError("Channel kind migration did not preserve populated stream adoption boundary")
        results.append("PASS:channel_kind_existing_stream_requires_reviewed_adoption")
        return results
    finally:
        if committed:
            # Khóa fixture trước kiểm marker; DELETE chỉ có UUID đã sinh khi setup thành công.
            cleanup=f"""BEGIN; SET CONSTRAINTS ALL DEFERRED;
            SELECT 1 FROM public.users WHERE user_id='{user_id}' FOR UPDATE;
            SELECT 1 FROM public.workspaces WHERE workspace_id='{workspace_id}' FOR UPDATE;
            DO $$ BEGIN
             IF NOT EXISTS(SELECT 1 FROM public.users WHERE user_id='{user_id}' AND activation_provenance='{marker}')
              OR NOT EXISTS(SELECT 1 FROM public.workspaces WHERE workspace_id='{workspace_id}' AND created_by_user_id='{user_id}' AND description='{marker}') THEN
              RAISE EXCEPTION 'Publication fixture ownership cannot be verified';
             END IF;
            END $$;
            DELETE FROM public.firmware_package_templates WHERE workspace_id='{workspace_id}' AND firmware_package_id='{package_id}';
            DELETE FROM public.firmware_packages WHERE workspace_id='{workspace_id}' AND firmware_package_id='{package_id}';
            DELETE FROM public.rule_version_actions WHERE workspace_id='{workspace_id}' AND rule_version_id='{rule_version_id}';
            DELETE FROM public.rule_versions WHERE workspace_id='{workspace_id}' AND rule_version_id='{rule_version_id}';
            DELETE FROM public.rules WHERE workspace_id='{workspace_id}' AND rule_id='{rule_id}';
            DELETE FROM public.api_key_scopes WHERE workspace_id='{workspace_id}' AND api_key_id='{key_id}';
            DELETE FROM public.api_key_devices WHERE workspace_id='{workspace_id}' AND api_key_id='{key_id}';
            DELETE FROM public.api_keys WHERE workspace_id='{workspace_id}' AND api_key_id='{key_id}';
            DELETE FROM public.devices WHERE workspace_id='{workspace_id}' AND device_id='{device_id}';
            DELETE FROM public.datastream_definitions WHERE workspace_id='{workspace_id}' AND template_version_id='{version_id}';
            DELETE FROM public.template_versions WHERE workspace_id='{workspace_id}' AND template_version_id='{version_id}';
            DELETE FROM public.templates WHERE workspace_id='{workspace_id}' AND template_id='{template_id}';
            DELETE FROM public.membership_grants WHERE workspace_id='{workspace_id}' AND user_id='{user_id}';
            DELETE FROM public.memberships WHERE workspace_id='{workspace_id}' AND user_id='{user_id}';
            DELETE FROM public.workspaces WHERE workspace_id='{workspace_id}' AND created_by_user_id='{user_id}';
            DELETE FROM public.users WHERE user_id='{user_id}' AND activation_provenance='{marker}';
            SET CONSTRAINTS ALL IMMEDIATE; COMMIT;"""
            sql(cleanup)
