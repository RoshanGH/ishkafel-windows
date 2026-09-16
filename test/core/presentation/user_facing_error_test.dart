import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/presentation/user_facing_error.dart';

class _ChineseException implements Exception {
  final String message;
  const _ChineseException(this.message);

  @override
  String toString() => '_ChineseException: $message';
}

void main() {
  group('userFacingError', () {
    test('保留可操作的中文消息但不暴露异常类名', () {
      expect(
        userFacingError(
          const _ChineseException('素材库未登录，请先完成登录'),
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
        _ChineseException('失败\n${'细节' * 200}'),
        fallback: '操作失败',
      );
      expect(text, isNot(contains('\n')));
      expect(text.length, lessThanOrEqualTo(220));
    });
  });
}
