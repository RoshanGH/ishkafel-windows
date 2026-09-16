import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/process_runner.dart';
import 'package:ishkafel/core/miaoa/miaoa_exception.dart';
import 'package:ishkafel/core/miaoa/miaoa_failure.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';

void main() {
  test('解析型进程执行器报告工具缺失时仍统一成 MiaoaException', () async {
    final gateway = MiaoaGateway(
      binary: 'miaoa',
      run: (_, _) async => throw const MediaToolMissingException(
        'miaoa',
        operatingSystem: 'windows',
      ),
    );

    await expectLater(
      gateway.text(const ['tag', 'group', 'list'], what: '读取标签组'),
      throwsA(
        isA<MiaoaException>()
            .having((error) => error.kind, 'kind', MiaoaFailureKind.cliMissing)
            .having(
              (error) => error.message,
              'message',
              allOf(contains('miaoa'), isNot(contains('MediaToolMissingException'))),
            ),
      ),
    );
  });

  test('原始 ProcessException 也保持同一用户合同', () async {
    final gateway = MiaoaGateway(
      binary: 'miaoa',
      run: (_, _) async => throw const ProcessException('miaoa', []),
    );

    await expectLater(
      gateway.raw(const ['auth', 'status']),
      throwsA(
        isA<MiaoaException>().having(
          (error) => error.kind,
          'kind',
          MiaoaFailureKind.cliMissing,
        ),
      ),
    );
  });
}
