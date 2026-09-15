import 'dart:io';

import 'package:path/path.dart' as p;

import 'subtitle_style.dart';

const int subtitleRendererProtocolVersion = 1;
const String subtitleRendererFontFamily = 'Ishkafel Subtitle';

class SubtitleRendererItem {
  final String text;
  final String out;

  const SubtitleRendererItem({required this.text, required this.out});

  Map<String, String> toJson() => {'text': text, 'out': out};
}

Map<String, Object> buildSubtitleRendererSpec({
  required int width,
  required int height,
  required SubtitleStyle style,
  required List<SubtitleRendererItem> items,
}) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('字幕画布尺寸必须为正数：${width}x$height');
  }
  if (items.any((item) => item.out.trim().isEmpty)) {
    throw ArgumentError('字幕输出路径不能为空');
  }

  final custom = style.colorHex;
  final (r, g, b) = custom != null
      ? (
          int.parse(custom.substring(0, 2), radix: 16) / 255,
          int.parse(custom.substring(2, 4), radix: 16) / 255,
          int.parse(custom.substring(4, 6), radix: 16) / 255,
        )
      : switch (style.preset) {
          SubtitlePreset.yellowOutline => (1.0, 0.85, 0.0),
          _ => (1.0, 1.0, 1.0),
        };
  final blur = style.preset == SubtitlePreset.blurBox;
  return {
    'protocolVersion': subtitleRendererProtocolVersion,
    'width': width,
    'height': height,
    'fontFamily': subtitleRendererFontFamily,
    'fontSize': (height * style.fontRatio).round(),
    'marginV': (height * style.bottomRatio).round(),
    'strokePercent': style.preset == SubtitlePreset.whiteBox || blur ? 3 : 9,
    'r': r,
    'g': g,
    'b': b,
    'box': style.preset == SubtitlePreset.whiteBox,
    'emitBox': blur,
    'items': items.map((item) => item.toJson()).toList(growable: false),
  };
}

String resolveSubtitleRendererExecutable({
  String? operatingSystem,
  Map<String, String>? environment,
  String? resolvedExecutable,
}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  final env = environment ?? Platform.environment;
  final override = env['ISHKAFEL_RENDERER']?.trim();
  if (override != null && override.isNotEmpty) return override;
  final context = p.Context(
    style: os == 'windows' ? p.Style.windows : p.Style.posix,
  );
  final executable = resolvedExecutable ?? Platform.resolvedExecutable;
  return context.join(
    context.dirname(executable),
    os == 'windows' ? 'ishkafel_renderer.exe' : 'ishkafel_renderer',
  );
}
