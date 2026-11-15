"""Kiểm oracle error-only bằng JSON synthetic, không mở API hoặc DB."""

import copy
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from uuid import UUID

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_provider import has_error_only_payload
import verify_provider as provider


class ProviderErrorProjectionTests(unittest.TestCase):
    """Status đúng vẫn phải bị từ chối nếu body chứa dữ liệu resource hoặc schema chưa xác nhận."""

    def envelope(self):
        """Output: error envelope synthetic có correlation public, không resource hoặc credential."""
        return {'error': {'code': 'PASSWORD_CHANGE_REQUIRED',
                          'message': 'Không thể hoàn tất yêu cầu. Vui lòng kiểm tra trạng thái và thử lại.',
                          'details': {}, 'correlationId': '10000000-0000-4000-8000-000000000001'}}

    def test_exact_error_only_is_accepted(self):
        """Projection đúng và code đúng mới cấp proof no-resource cho scenario provider."""
        self.assertTrue(has_error_only_payload(self.envelope(), 'PASSWORD_CHANGE_REQUIRED'))
        self.assertFalse(has_error_only_payload(self.envelope(), 'RESOURCE_NOT_FOUND'))

    def test_invalid_credentials_use_one_exact_public_projection(self):
        """Mọi nguyên nhân credential sai phải dùng cùng code/message/shape, correlation được sinh riêng."""
        body = self.envelope()
        body['error'].update(code='AUTH_INVALID', message='Thông tin đăng nhập không hợp lệ.')
        self.assertTrue(has_error_only_payload(body, 'AUTH_INVALID'))
        body['error']['message'] = 'Account disabled'
        self.assertFalse(has_error_only_payload(body, 'AUTH_INVALID'))

    def test_resource_data_and_untrusted_shapes_are_rejected(self):
        """Chặn data ở top-level, error hoặc details, thiếu fields và sai kiểu mà không throw raw payload."""
        for mode in ('top-data', 'nested-data', 'details', 'details-null', 'missing', 'not-object', 'error-type',
                     'message-type', 'message-leak', 'correlation-type', 'correlation-invalid'):
            with self.subTest(mode=mode):
                body = copy.deepcopy(self.envelope())
                if mode == 'top-data':
                    body['data'] = {'devices': []}
                elif mode == 'nested-data':
                    body['error']['data'] = {'devices': []}
                elif mode == 'details':
                    body['error']['details'] = {'devices': []}
                elif mode == 'details-null':
                    body['error']['details'] = None
                elif mode == 'missing':
                    del body['error']['correlationId']
                elif mode == 'not-object':
                    body = []
                elif mode == 'error-type':
                    body['error'] = 'PASSWORD_CHANGE_REQUIRED'
                elif mode == 'message-type':
                    body['error']['message'] = {'devices': []}
                elif mode == 'message-leak':
                    body['error']['message'] = 'synthetic-resource-canary'
                elif mode == 'correlation-type':
                    body['error']['correlationId'] = 1
                else:
                    body['error']['correlationId'] = 'synthetic-resource-canary'
                self.assertFalse(has_error_only_payload(body, 'PASSWORD_CHANGE_REQUIRED'))


class ProviderSessionProjectionTests(unittest.TestCase):
    """Kiểm oracle login và session readback bằng fixture không hoạt động, không mở DB hoặc HTTP."""

    def login(self, client='IOS', limited=True):
        """Tạo response tổng hợp theo client để kiểm field quyền, expiry và kênh credential."""
        body = {'me': {'id': '10000000-0000-4000-8000-000000000001',
                       'email': 'fixture@example.invalid', 'mustChangePassword': limited},
                'expiresAt': '2026-11-14T00:00:00Z', 'limited': limited}
        headers = {'Cache-Control': 'no-store'}
        if client == 'WEB':
            headers.update({'Set-Cookie': 'iot_session=synthetic-token; Secure; HttpOnly; SameSite=Lax; Path=/api/v1',
                            'X-Auth-Context-Id': '10000000-0000-4000-8000-000000000002', 'X-CSRF-Token': 'synthetic-csrf'})
        else:
            body['token'] = 'synthetic-token'
        return body, headers

    def test_exact_login_projection_for_each_transport_and_authority(self):
        """Web/Android/IOS full và limited chỉ được serialize summary đã duyệt và header đúng kênh."""
        for client in ('WEB', 'ANDROID', 'IOS'):
            for limited in (False, True):
                body, headers = self.login(client, limited)
                self.assertTrue(provider.has_login_projection(body, headers, client, body['me']['email'], body['me']['id'], limited))
                body['me']['role'] = 'ADMIN'
                self.assertFalse(provider.has_login_projection(body, headers, client, body['me']['email'], body['me']['id'], limited))

    def test_login_rejects_malformed_metadata_or_cross_transport_secret(self):
        """Expiry sai, UUID/context sai, bool bị coerce hoặc token lẫn kênh phải làm oracle từ chối."""
        for mode in ('expiry', 'uuid', 'limited-type', 'summary-type', 'token-type', 'cookie', 'context', 'cache'):
            body, headers = self.login()
            if mode == 'expiry':
                body['expiresAt'] = '2026-11-14'
            elif mode == 'uuid':
                body['me']['id'] = 'synthetic-user'
            elif mode == 'limited-type':
                body['limited'] = 1
            elif mode == 'summary-type':
                body['me']['mustChangePassword'] = 1
            elif mode == 'token-type':
                body['token'] = ['synthetic-token']
            elif mode == 'cookie':
                headers['Set-Cookie'] = 'iot_session=synthetic-token'
            elif mode == 'context':
                headers['X-Auth-Context-Id'] = '10000000-0000-4000-8000-000000000002'
            else:
                headers['Cache-Control'] = 'public'
            self.assertFalse(provider.has_login_projection(body, headers, 'IOS', 'fixture@example.invalid',
                                                           '10000000-0000-4000-8000-000000000001', True))

    def test_session_readback_checks_digest_ttl_metadata_and_raw_secret_absence(self):
        """Row lệch digest/client/TTL/expiry hoặc chứa raw secret không được xem là session durable đúng."""
        token = 'synthetic-nonfunctional-capability'
        row = {'session_id': '10000000-0000-4000-8000-000000000003',
               'user_id': '10000000-0000-4000-8000-000000000001',
               'auth_context_id': '10000000-0000-4000-8000-000000000002',
               'token_digest': '\\x' + provider.hashlib.sha256(token.encode()).hexdigest(),
               'client_type': 'IOS', 'limited': True, 'revoked_at': None,
               'issued_at': '2026-11-13T00:00:00+00:00', 'expires_at': '2026-11-14T00:00:00+00:00'}
        for mode in ('valid', 'missing', 'digest', 'client', 'ttl', 'expiry', 'raw', 'revoked'):
            value = dict(row)
            if mode == 'digest': value['token_digest'] = '\\x' + '0' * 64
            elif mode == 'client': value['client_type'] = 'ANDROID'
            elif mode == 'ttl': value['issued_at'] = '2026-11-12T00:00:00+00:00'
            elif mode == 'expiry': value['expires_at'] = '2026-11-14T00:00:01+00:00'
            elif mode == 'raw': value['raw_token'] = token
            elif mode == 'revoked': value['revoked_at'] = value['issued_at']
            database = SimpleNamespace(ADMIN='synthetic-owner', sql=None)
            with patch.dict(sys.modules, {'verify_database': database}), patch.object(database, 'sql', return_value=SimpleNamespace(
                    returncode=0, stdout=provider.json.dumps([] if mode == 'missing' else [value]))) as query:
                if mode == 'valid':
                    self.assertEqual(provider.read_persisted_session(token, row['user_id'], 'IOS', True, '2026-11-14T00:00:00Z'), UUID(row['session_id']))
                else:
                    with self.assertRaisesRegex(RuntimeError, '^Provider session metadata mismatch$'):
                        provider.read_persisted_session(token, row['user_id'], 'IOS', True, '2026-11-14T00:00:00Z')
                self.assertNotIn(token, query.call_args.args[0])


class ProviderWorkspaceProjectionTests(unittest.TestCase):
    """Chặn page thừa dữ liệu, membership không ACTIVE và traversal thiếu/lặp workspace."""

    def page(self):
        """Output: một summary ACTIVE synthetic theo đúng năm field picker public."""
        return {'items': [{'id': '10000000-0000-4000-8000-000000000001', 'name': 'Synthetic workspace',
                           'status': 'ACTIVE', 'role': 'USER', 'revision': 1}], 'nextCursor': None}

    def test_workspace_page_rejects_resource_data_and_invalid_authority_metadata(self):
        """Page chỉ hợp lệ với UUID duy nhất, role hữu hạn, revision integer dương và cursor đúng kiểu."""
        self.assertTrue(provider.has_workspace_page(self.page()))
        self.assertTrue(provider.has_workspace_page({'items': [], 'nextCursor': None}))
        for mode in ('extra', 'resource', 'suspended', 'removed', 'role', 'revision', 'uuid', 'duplicate', 'cursor'):
            body = self.page()
            item = body['items'][0]
            if mode == 'extra': body['devices'] = []
            elif mode == 'resource': item['deviceCount'] = 1
            elif mode == 'suspended': item['status'] = 'SUSPENDED'
            elif mode == 'removed': item['status'] = 'REMOVED'
            elif mode == 'role': item['role'] = 'OWNER'
            elif mode == 'revision': item['revision'] = True
            elif mode == 'uuid': item['id'] = 'malformed-uuid'
            elif mode == 'duplicate': body['items'].append(dict(item))
            else: body['nextCursor'] = []
            self.assertFalse(provider.has_workspace_page(body), mode)


if __name__ == '__main__':
    unittest.main()
