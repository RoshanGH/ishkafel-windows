import base64
import io
import json
import tempfile
import unittest
from app import ReportApp


class ReportsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = ReportApp(self.temp.name, 's' * 32, 'r' * 32, 'w' * 32)

    def call(self, method, path, data=None, token='s' * 32, query=''):
        body = json.dumps(data).encode() if data is not None else b''
        env = dict(REQUEST_METHOD=method, PATH_INFO=path, QUERY_STRING=query,
                   CONTENT_LENGTH=str(len(body)), CONTENT_TYPE='application/json',
                   HTTP_AUTHORIZATION='Bearer ' + token)
        env['wsgi.input'] = io.BytesIO(body)
        status = []
        result = b''.join(self.app(env, lambda s, h: status.append(s)))
        return int(status[0].split()[0]), json.loads(result)

    def report(self, report_id='a' * 32):
        return dict(schema=1, id=report_id, version='0.1.243', kind='manual',
                    created_at='2026-09-18T00:00:00Z', system={'os': 'windows'},
                    logs='preview failed', description='', screenshot=None)

    def test_submit_read_idempotency_and_pagination(self):
        report = self.report()
        self.assertEqual(self.call('POST', '/v1/reports', report)[0], 201)
        self.assertEqual(self.call('POST', '/v1/reports', report)[0], 200)
        changed = dict(report, logs='different')
        self.assertEqual(self.call('POST', '/v1/reports', changed)[0], 409)
        code, detail = self.call('GET', '/v1/reports/' + report['id'], token='r' * 32)
        self.assertEqual(code, 200)
        self.assertEqual(detail['report']['logs'], 'preview failed')
        _, page = self.call('GET', '/v1/reports', token='r' * 32)
        self.assertEqual(len(page['reports']), 1)
        _, page2 = self.call('GET', '/v1/reports', token='r' * 32,
                            query='after=' + str(page['next_after']))
        self.assertEqual(page2['reports'], [])

    def test_client_cannot_read_or_update(self):
        self.call('POST', '/v1/reports', self.report())
        self.assertEqual(self.call('GET', '/v1/reports')[0], 403)
        self.assertEqual(self.call('PATCH', '/v1/reports/' + 'a' * 32,
                                   dict(status='fixed'))[0], 403)
        self.assertEqual(self.call('POST', '/v1/reports', self.report(), token='bad')[0], 401)

    def test_invalid_report_and_screenshot_rejected(self):
        for value in [[], {}, dict(self.report(), id='../escape'),
                      dict(self.report(), schema=2),
                      dict(self.report(), screenshot={'type': 'image/png', 'data': 'invalid'}),
                      dict(self.report(), logs='a' * (3 * 1024 * 1024))]:
            self.assertEqual(self.call('POST', '/v1/reports', value)[0], 400)

    def test_update_is_separate_and_survives_restart(self):
        self.call('POST', '/v1/reports', self.report())
        code, _ = self.call('PATCH', '/v1/reports/' + 'a' * 32,
                           dict(status='fixed', analysis='checked', fixed_version='0.1.244'),
                           token='w' * 32)
        self.assertEqual(code, 200)
        self.app = ReportApp(self.temp.name, 's' * 32, 'r' * 32, 'w' * 32)
        _, detail = self.call('GET', '/v1/reports/' + 'a' * 32, token='r' * 32)
        self.assertEqual(detail['status'], 'fixed')
        self.assertEqual(detail['fixed_version'], '0.1.244')

    def test_valid_image_and_filters(self):
        # 真实 1x1 PNG。
        from PIL import Image
        buffer = io.BytesIO()
        Image.new('RGB', (1, 1), 'white').save(buffer, format='PNG')
        png = base64.b64encode(buffer.getvalue()).decode()
        report = dict(self.report(), screenshot=dict(type='image/png', data=png))
        self.assertEqual(self.call('POST', '/v1/reports', report)[0], 201)
        _, page = self.call('GET', '/v1/reports', token='r' * 32, query='version=other')
        self.assertEqual(page['reports'], [])
        self.assertEqual(self.call('GET', '/v1/reports', token='r' * 32, query='after=no')[0], 400)

    def test_truncated_images_rejected(self):
        for raw, media in [(b'\x89PNG\r\n\x1a\n', 'image/png'),
                           (b'\xff\xd8\xff', 'image/jpeg')]:
            report = dict(self.report(), screenshot=dict(type=media, data=base64.b64encode(raw).decode()))
            self.assertEqual(self.call('POST', '/v1/reports', report)[0], 400)


if __name__ == '__main__':
    unittest.main()
