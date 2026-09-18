"""内部诊断 API：无管理页面；数据库不接受客户端提供的文件路径。"""
import base64
import gzip
import hashlib
import hmac
import io
import json
import os
import re
import time
from pathlib import Path
from urllib.parse import parse_qs
from database import connect_database

MAX_BODY = 8 * 1024 * 1024


class ApiError(Exception):
    def __init__(self, code, message):
        self.code, self.message = code, message


class ReportApp:
    def __init__(self, root, submit_token, read_token, write_token,
                 retention_days=30, max_storage_bytes=2 * 1024 ** 3, mysql=None):
        tokens = [submit_token, read_token, write_token]
        if any(len(t) < 32 for t in tokens) or len(set(tokens)) != 3:
            raise ValueError('Three distinct tokens of at least 32 characters are required')
        self.tokens = tokens
        self.mysql = mysql
        self.retention = retention_days * 86400
        self.max_storage = max_storage_bytes
        Path(root).mkdir(parents=True, exist_ok=True)
        self.db = str(Path(root) / 'reports.sqlite3')
        with self.connect() as db:
            if mysql:
                db.execute('''CREATE TABLE IF NOT EXISTS reports (
                    seq BIGINT PRIMARY KEY AUTO_INCREMENT, id VARCHAR(32) UNIQUE NOT NULL,
                    received DOUBLE NOT NULL, version VARCHAR(80) NOT NULL, kind VARCHAR(40) NOT NULL,
                    digest VARCHAR(64) NOT NULL, payload MEDIUMBLOB NOT NULL,
                    status VARCHAR(24) NOT NULL DEFAULT 'new', analysis TEXT NOT NULL,
                    fixed_version VARCHAR(80) NOT NULL DEFAULT '', INDEX received_idx(received)
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4''')
                db.execute('CREATE TABLE IF NOT EXISTS report_lock (id INT PRIMARY KEY) ENGINE=InnoDB')
                db.execute('INSERT IGNORE INTO report_lock VALUES(1)')
            else:
                db.execute('PRAGMA journal_mode=WAL')
                db.execute('''CREATE TABLE IF NOT EXISTS reports (
                seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL,
                received REAL NOT NULL, version TEXT NOT NULL, kind TEXT NOT NULL,
                digest TEXT NOT NULL, payload BLOB NOT NULL,
                status TEXT NOT NULL DEFAULT 'new', analysis TEXT NOT NULL DEFAULT '',
                fixed_version TEXT NOT NULL DEFAULT '')''')
                db.execute('CREATE INDEX IF NOT EXISTS received_idx ON reports(received)')

    def connect(self):
        return connect_database(self.db, self.mysql)

    def __call__(self, env, start_response):
        try:
            code, result = self.handle(env)
        except ApiError as error:
            code, result = error.code, {'error': error.message}
        except (ValueError, TypeError, KeyError, UnicodeError, RecursionError):
            code, result = 400, {'error': 'invalid_request'}
        except Exception:
            # 不把路径、请求正文或 token 打到服务日志/响应。
            code, result = 503, {'error': 'storage_unavailable'}
        body = json.dumps(result, ensure_ascii=False).encode('utf-8')
        names = {200: 'OK', 201: 'Created', 400: 'Bad Request', 401: 'Unauthorized',
                 403: 'Forbidden', 404: 'Not Found', 409: 'Conflict',
                 413: 'Payload Too Large', 415: 'Unsupported Media Type',
                 429: 'Too Many Requests', 503: 'Service Unavailable'}
        start_response('{} {}'.format(code, names[code]), [
            ('Content-Type', 'application/json; charset=utf-8'),
            ('Content-Length', str(len(body))), ('Cache-Control', 'no-store'),
            ('X-Content-Type-Options', 'nosniff')])
        return [body]

    def body(self, env):
        if env.get('CONTENT_TYPE', '').split(';')[0] != 'application/json':
            raise ApiError(415, 'json_required')
        size = int(env.get('CONTENT_LENGTH') or '0')
        if size <= 0 or size > MAX_BODY:
            raise ApiError(413, 'body_size_limit')
        raw = env['wsgi.input'].read(size)
        if len(raw) != size:
            raise ApiError(400, 'incomplete_body')
        return json.loads(raw)

    def authorize(self, env, role):
        value = env.get('HTTP_AUTHORIZATION', '')
        matches = [hmac.compare_digest(value, 'Bearer ' + t) for t in self.tokens]
        if not any(matches):
            raise ApiError(401, 'unauthorized')
        if not matches[role]:
            raise ApiError(403, 'forbidden')

    def validate(self, report):
        if not isinstance(report, dict) or report.get('schema') != 1:
            raise ApiError(400, 'invalid_schema')
        if not re.fullmatch('[a-f0-9]{32}', report.get('id', '')):
            raise ApiError(400, 'invalid_id')
        for key, limit in [('version', 80), ('kind', 40), ('created_at', 80),
                           ('description', 2000), ('logs', 2 * 1024 * 1024)]:
            value = report.get(key)
            if not isinstance(value, str) or len(value.encode('utf-8')) > limit:
                raise ApiError(400, 'invalid_' + key)
        if report['kind'] not in ('manual', 'preview', 'audio', 'unresponsive', 'abnormal_exit'):
            raise ApiError(400, 'invalid_kind')
        if not isinstance(report.get('system'), dict):
            raise ApiError(400, 'invalid_system')
        allowed = {'schema', 'id', 'version', 'kind', 'created_at', 'description',
                   'logs', 'system', 'screenshot'}
        if set(report) - allowed:
            raise ApiError(400, 'unknown_fields')
        screenshot = report.get('screenshot')
        if screenshot is not None:
            if not isinstance(screenshot, dict) or set(screenshot) != {'type', 'data'}:
                raise ApiError(400, 'invalid_screenshot')
            image = base64.b64decode(screenshot['data'], validate=True)
            signatures = {'image/png': b'\x89PNG\r\n\x1a\n', 'image/jpeg': b'\xff\xd8\xff'}
            signature = signatures.get(screenshot['type'])
            if not signature or not image.startswith(signature) or len(image) > 4 * 1024 ** 2:
                raise ApiError(400, 'invalid_screenshot')
            # 不把仅伪造魔数/截断图片送给后续读取者；像素上限防解压炸弹。
            from PIL import Image
            try:
                with Image.open(io.BytesIO(image)) as decoded:
                    if (decoded.format not in ('PNG', 'JPEG') or
                            decoded.width * decoded.height > 9_000_000 or
                            max(decoded.size) > 8192):
                        raise ValueError('image_limit')
                    decoded.verify()
                with Image.open(io.BytesIO(image)) as decoded:
                    decoded.load()
            except (OSError, ValueError, SyntaxError, Image.DecompressionBombError):
                raise ApiError(400, 'invalid_screenshot')

    def handle(self, env):
        method, path = env['REQUEST_METHOD'], env['PATH_INFO']
        if method == 'GET' and path == '/healthz':
            return 200, {'ok': True}
        if method == 'POST' and path == '/v1/reports':
            self.authorize(env, 0)
            report = self.body(env)
            self.validate(report)
            raw = json.dumps(report, sort_keys=True, ensure_ascii=False).encode('utf-8')
            digest = hashlib.sha256(raw).hexdigest()
            payload = gzip.compress(raw)
            now = time.time()
            with self.connect() as db:
                db.execute('BEGIN IMMEDIATE')
                prior = db.execute('SELECT digest FROM reports WHERE id=?', (report['id'],)).fetchone()
                if prior:
                    if prior[0] != digest:
                        raise ApiError(409, 'id_content_conflict')
                    return 200, {'id': report['id'], 'stored': True}
                db.execute('DELETE FROM reports WHERE received < ?', (now - self.retention,))
                count = db.execute('SELECT COUNT(*) FROM reports WHERE received > ?', (now - 60,)).fetchone()[0]
                if count >= 60:
                    raise ApiError(429, 'rate_limit')
                used = db.execute('SELECT COALESCE(SUM(LENGTH(payload)), 0) FROM reports').fetchone()[0]
                if used + len(payload) > self.max_storage:
                    raise ApiError(503, 'storage_quota')
                db.execute('INSERT INTO reports(id,received,version,kind,digest,payload,analysis) VALUES(?,?,?,?,?,?,?)',
                           (report['id'], now, report['version'], report['kind'], digest, payload, ''))
            return 201, {'id': report['id'], 'stored': True}
        if method == 'GET' and path == '/v1/reports':
            self.authorize(env, 1)
            q = parse_qs(env.get('QUERY_STRING', ''))
            after = int(q.get('after', ['0'])[0])
            limit = int(q.get('limit', ['50'])[0])
            if after < 0 or not 1 <= limit <= 100:
                raise ApiError(400, 'invalid_pagination')
            sql, args = 'SELECT seq,id,received,version,kind,status,fixed_version FROM reports WHERE seq > ?', [after]
            for key in ('version', 'kind', 'status'):
                if key in q:
                    sql += ' AND ' + key + '=?'
                    args.append(q[key][0])
            sql += ' ORDER BY seq LIMIT ?'
            args.append(limit)
            with self.connect() as db:
                rows = db.execute(sql, args).fetchall()
            keys = ['seq', 'id', 'received', 'version', 'kind', 'status', 'fixed_version']
            return 200, {'reports': [dict(zip(keys, r)) for r in rows],
                         'next_after': rows[-1][0] if rows else after}
        match = re.fullmatch('/v1/reports/([a-f0-9]{32})', path)
        if match and method in ('GET', 'PATCH'):
            self.authorize(env, 1 if method == 'GET' else 2)
            report_id = match.group(1)
            with self.connect() as db:
                row = db.execute('SELECT payload,status,analysis,fixed_version FROM reports WHERE id=?',
                                 (report_id,)).fetchone()
                if not row:
                    raise ApiError(404, 'not_found')
                if method == 'GET':
                    return 200, dict(report=json.loads(gzip.decompress(row[0])),
                                     status=row[1], analysis=row[2], fixed_version=row[3])
                patch = self.body(env)
                if not isinstance(patch, dict) or set(patch) - {'status', 'analysis', 'fixed_version'}:
                    raise ApiError(400, 'invalid_patch')
                status = patch.get('status', row[1])
                analysis = patch.get('analysis', row[2])
                version = patch.get('fixed_version', row[3])
                if status not in ('new', 'investigating', 'fixed', 'needs_info'):
                    raise ApiError(400, 'invalid_status')
                if not isinstance(analysis, str) or len(analysis) > 10000 or not isinstance(version, str) or len(version) > 80:
                    raise ApiError(400, 'invalid_patch')
                db.execute('UPDATE reports SET status=?,analysis=?,fixed_version=? WHERE id=?',
                           (status, analysis, version, report_id))
            return 200, {'id': report_id, 'status': status}
        raise ApiError(404, 'not_found')


def main():
    from waitress import serve
    app = ReportApp(os.environ['REPORT_DATA_DIR'], os.environ['REPORT_SUBMIT_TOKEN'],
                    os.environ['REPORT_READ_TOKEN'], os.environ['REPORT_WRITE_TOKEN'],
                    mysql=dict(host=os.environ.get('REPORT_MYSQL_HOST', '127.0.0.1'),
                               port=int(os.environ.get('REPORT_MYSQL_PORT', '3306')),
                               user=os.environ['REPORT_MYSQL_USER'], password=os.environ['REPORT_MYSQL_PASSWORD'],
                               database=os.environ['REPORT_MYSQL_DATABASE']))
    serve(app, host=os.environ.get('REPORT_BIND', '127.0.0.1'),
          port=int(os.environ.get('REPORT_PORT', '8787')),
          max_request_body_size=MAX_BODY, channel_timeout=30, connection_limit=32,
          expose_tracebacks=False)


if __name__ == '__main__':
    main()
