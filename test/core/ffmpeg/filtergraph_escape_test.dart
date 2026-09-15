import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/filtergraph_escape.dart';

void main() {
  test('Windows 盘符、反斜杠和 filtergraph 分隔符被转义', () {
    expect(
      escapeFfmpegFilterPath(r'C:\用户 A\片段,一;二[三].txt'),
      r'C\\:/用户 A/片段\,一\;二\[三\].txt',
    );
  });

  test('POSIX 路径不做多余 shell 引号处理', () {
    expect(
      escapeFfmpegFilterPath('/tmp/scene data.txt'),
      '/tmp/scene data.txt',
    );
  });

  test('单引号按 filtergraph 规则转义', () {
    expect(
      escapeFfmpegFilterPath("C:/it's/scene.txt"),
      r"C\\:/it\\\'s/scene.txt",
    );
  });
}
