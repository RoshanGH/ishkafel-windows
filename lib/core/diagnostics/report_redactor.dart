/// 上传前的文本脱敏；不读取任意凭据目录，不处理图片中的文字。
class ReportRedactor {
  final List<String> secrets;
  ReportRedactor(Iterable<String> values)
    : secrets = values.where((v) => v.length >= 4).toList()
        ..sort((a, b) => b.length.compareTo(a.length));

  String clean(String text) {
    var value = text;
    for (final secret in secrets) {
      value = value.replaceAll(secret, '[redacted]');
    }
    value = value.replaceAll(RegExp(r'https?://[^\s<>"\x27]+'), '[url]');
    value = value.replaceAll(
      RegExp(r'(?i:bearer)\s+[^\s,;]+'),
      'Bearer [redacted]',
    );
    value = value.replaceAll(
      RegExp(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'),
      '[jwt]',
    );
    value = value.replaceAllMapped(
      RegExp(
        r'((?:cookie|set-cookie|authorization)\s*:\s*)[^\r\n]*',
        caseSensitive: false,
      ),
      (m) => '${m[1]}[redacted]',
    );
    value = value.replaceAllMapped(
      RegExp(
        r'''((?:api[_-]?key|access[_-]?(?:key|token)|secret|password|authorization|cookie|token)["']?\s*[=:]\s*)(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\r\n,;]+)''',
        caseSensitive: false,
      ),
      (m) => '${m[1]}[redacted]',
    );
    value = value.replaceAll(
      RegExp(r'[A-Za-z]:[\\/]Users[\\/][^\\/\s]+', caseSensitive: false),
      r'C:\Users\[user]',
    );
    return value.replaceAll(RegExp(r'/(?:Users|home)/[^/\s]+'), '/home/[user]');
  }
}
