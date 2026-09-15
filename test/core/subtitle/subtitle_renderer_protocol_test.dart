import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/subtitle/subtitle_renderer_protocol.dart';
import 'package:ishkafel/core/subtitle/subtitle_style.dart';

void main() {
  test('协议包含固定版本、画布、样式与 UTF-8 文本项', () {
    final spec = buildSubtitleRendererSpec(
      width: 1080,
      height: 1920,
      style: const SubtitleStyle(
        preset: SubtitlePreset.blurBox,
        colorHex: '12ABEF',
      ),
      items: const [
        SubtitleRendererItem(text: '中文 subtitle', out: r'C:\输出\一.png'),
      ],
    );

    expect(spec['protocolVersion'], subtitleRendererProtocolVersion);
    expect(spec['width'], 1080);
    expect(spec['height'], 1920);
    expect(spec['fontFamily'], 'Ishkafel Subtitle');
    expect(spec['emitBox'], isTrue);
    expect(spec['items'], [
      {'text': '中文 subtitle', 'out': r'C:\输出\一.png'},
    ]);
    expect(utf8.decode(utf8.encode(jsonEncode(spec))), contains('中文'));
  });

  test('非法画布和空输出路径在启动原生进程前被拒绝', () {
    expect(
      () => buildSubtitleRendererSpec(
        width: 0,
        height: 1920,
        style: SubtitleStyle.standard,
        items: const [SubtitleRendererItem(text: 'x', out: 'x.png')],
      ),
      throwsArgumentError,
    );
    expect(
      () => buildSubtitleRendererSpec(
        width: 1080,
        height: 1920,
        style: SubtitleStyle.standard,
        items: const [SubtitleRendererItem(text: 'x', out: ' ')],
      ),
      throwsArgumentError,
    );
  });

  test('Windows renderer 优先接受显式环境覆盖', () {
    expect(
      resolveSubtitleRendererExecutable(
        operatingSystem: 'windows',
        environment: const {'ISHKAFEL_RENDERER': r'D:\工具\renderer.exe'},
        resolvedExecutable: r'C:\App\ishkafel.exe',
      ),
      r'D:\工具\renderer.exe',
    );
    expect(
      resolveSubtitleRendererExecutable(
        operatingSystem: 'windows',
        environment: const {},
        resolvedExecutable: r'C:\App\ishkafel.exe',
      ),
      r'C:\App\ishkafel_renderer.exe',
    );
  });
}
