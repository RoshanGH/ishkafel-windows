"""诊断报告的 Agent 入口。凭据只从私有目录读取，不接受命令行 token。"""
import argparse
import json
import ssl
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, build_opener, HTTPSHandler, ProxyHandler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--secrets-dir', required=True)
    sub = parser.add_subparsers(dest='command', required=True)
    listing = sub.add_parser('list')
    listing.add_argument('--after', type=int, default=0)
    listing.add_argument('--status', choices=['new', 'investigating', 'fixed', 'needs_info'])
    listing.add_argument('--version')
    detail = sub.add_parser('get')
    detail.add_argument('id')
    update = sub.add_parser('update')
    update.add_argument('id')
    update.add_argument('--patch-file', required=True, help='JSON: status / analysis / fixed_version')
    args = parser.parse_args()
    root = Path(args.secrets_dir)
    base = (root / 'report_api_url').read_text().strip()
    if not base.startswith('https://'):
        raise ValueError('HTTPS required')
    tokens = json.loads((root / 'report_agent_tokens.json').read_text())
    context = ssl.create_default_context(cafile=str(root / 'report_ca.pem'))
    opener = build_opener(ProxyHandler({}), HTTPSHandler(context=context))
    body = None
    path = '/v1/reports'
    if args.command == 'list':
        query = {'after': args.after}
        for key in ('status', 'version'):
            if getattr(args, key):
                query[key] = getattr(args, key)
        path += '?' + urlencode(query)
    else:
        import re
        if not re.fullmatch('[a-f0-9]{32}', args.id):
            raise ValueError('Invalid report id')
        path += '/' + args.id
    if args.command == 'update':
        body = json.dumps(json.loads(Path(args.patch_file).read_text(encoding='utf-8'))).encode()
    token = tokens['REPORT_WRITE_TOKEN' if body else 'REPORT_READ_TOKEN']
    request = Request(base.rstrip('/') + path, data=body,
                      method='PATCH' if body else 'GET',
                      headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    try:
        with opener.open(request, timeout=30) as response:
            print(response.read().decode('utf-8'))
    except HTTPError as error:
        print('HTTP {}: {}'.format(error.code, error.read().decode('utf-8')), file=sys.stderr)
        return 1
    except URLError:
        print('Network/TLS failure; check connectivity and trusted CA.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
