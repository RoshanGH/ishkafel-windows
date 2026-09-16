import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/presentation/user_facing_error.dart';
import 'package:ishkafel/core/presentation/user_facing_exception.dart';

class _ChineseException implements Exception {
  final String message;
  const _ChineseException(this.message);

  @override
  String toString() => '_ChineseException: $message';
}

class _TrustedChineseException implements UserFacingException {
  @override
  final String message;
  const _TrustedChineseException(this.message);
}

void main() {
  group('userFacingError', () {
    test('保留可操作的中文消息但不暴露异常类名', () {
      expect(
        userFacingError(
          const _TrustedChineseException('素材库未登录，请先完成登录'),
          fallback: '操作失败，请稍后重试',
        ),
        '素材库未登录，请先完成登录',
      );
    });

    test('英文内部异常使用稳定中文兜底', () {
      expect(
        userFacingError(
          const FormatException('Unexpected token at offset 19'),
          fallback: '操作失败，请稍后重试',
        ),
        '操作失败，请稍后重试',
      );
    });

    test('去除换行并限制过长消息', () {
      final text = userFacingError(
        _TrustedChineseException('失败\n${'细节' * 200}'),
        fallback: '操作失败',
      );
      expect(text, isNot(contains('\n')));
      expect(text.length, lessThanOrEqualTo(220));
    });

    test('含中文的未知异常也不得泄漏令牌、URL 或本地路径', () {
      final text = userFacingError(
        StateError(
          '请求失败 token=secret-value '
          'https://example.test/api?signature=private '
          r'C:\Users\张三\Videos\input.mp4',
        ),
        fallback: '操作失败，请稍后重试',
      );

      expect(text, '操作失败，请稍后重试');
      expect(text, isNot(contains('secret-value')));
      expect(text, isNot(contains('example.test')));
      expect(text, isNot(contains(r'C:\Users')));
    });

    test('未知中文异常一律兜底，即使敏感值没有标准字段名', () {
      for (final error in <Object>[
        const _ChineseException('请求失败，访问密钥 sk-live-xxx'),
        const _ChineseException(
          '请求失败 eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.signature',
        ),
      ]) {
        expect(
          userFacingError(error, fallback: '操作失败，请稍后重试'),
          '操作失败，请稍后重试',
        );
      }
    });
  });
}
