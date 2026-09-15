import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'subtitle_renderer_protocol.dart';

const String _fontAsset = 'assets/fonts/NotoSansCJKsc-Medium.otf';

Future<void> runSubtitleRenderer(List<String> args) async {
  stdout.encoding = utf8;
  stderr.encoding = utf8;
  try {
    if (args.length != 1) {
      throw const FormatException('用法：ishkafel_renderer <spec.json>');
    }
    WidgetsFlutterBinding.ensureInitialized();
    final loader = FontLoader(subtitleRendererFontFamily)
      ..addFont(rootBundle.load(_fontAsset));
    await loader.load();

    final raw = jsonDecode(
      await File(args.single).readAsString(encoding: utf8),
    );
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('字幕 spec 必须是 JSON 对象');
    }
    await _renderSpec(raw);
    stdout.writeln(
      jsonEncode({
        'protocolVersion': subtitleRendererProtocolVersion,
        'status': 'ok',
      }),
    );
    exit(0);
  } catch (error, stack) {
    stderr.writeln(
      jsonEncode({
        'protocolVersion': subtitleRendererProtocolVersion,
        'status': 'error',
        'message': '$error',
      }),
    );
    stderr.writeln(stack);
    exit(2);
  }
}

Future<void> _renderSpec(Map<String, dynamic> spec) async {
  if (spec['protocolVersion'] != subtitleRendererProtocolVersion) {
    throw FormatException('不支持的字幕协议版本：${spec['protocolVersion']}');
  }
  final width = _positiveInt(spec, 'width');
  final height = _positiveInt(spec, 'height');
  final fontSize = _positiveInt(spec, 'fontSize').toDouble();
  final marginV = _positiveInt(spec, 'marginV').toDouble();
  final strokePercent = _positiveInt(spec, 'strokePercent').toDouble();
  final color = ui.Color.fromARGB(
    255,
    (_unitDouble(spec, 'r') * 255).round(),
    (_unitDouble(spec, 'g') * 255).round(),
    (_unitDouble(spec, 'b') * 255).round(),
  );
  final drawBox = spec['box'] == true;
  final emitBox = spec['emitBox'] == true;
  final items = spec['items'];
  if (items is! List) throw const FormatException('items 必须是数组');

  for (final rawItem in items) {
    if (rawItem is! Map) throw const FormatException('字幕项必须是对象');
    final text = '${rawItem['text'] ?? ''}'.trim();
    final out = '${rawItem['out'] ?? ''}'.trim();
    if (text.isEmpty || out.isEmpty) {
      throw const FormatException('字幕文本和输出路径不能为空');
    }
    await _renderItem(
      text: text,
      out: out,
      width: width,
      height: height,
      fontSize: fontSize,
      marginV: marginV,
      strokeWidth: fontSize * strokePercent / 100,
      color: color,
      drawBox: drawBox,
      emitBox: emitBox,
    );
  }
}

Future<void> _renderItem({
  required String text,
  required String out,
  required int width,
  required int height,
  required double fontSize,
  required double marginV,
  required double strokeWidth,
  required ui.Color color,
  required bool drawBox,
  required bool emitBox,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final maxTextWidth = width * 0.88;
  final fill = _paragraph(
    text,
    fontSize,
    maxTextWidth,
    ui.Paint()..color = color,
  );
  final stroke = _paragraph(
    text,
    fontSize,
    maxTextWidth,
    ui.Paint()
      ..color = const ui.Color(0xFF000000)
      ..style = ui.PaintingStyle.stroke
      ..strokeJoin = ui.StrokeJoin.round
      ..strokeWidth = strokeWidth,
  );
  final x = (width - fill.width) / 2;
  final y = (height - marginV - fill.height)
      .clamp(0, height.toDouble())
      .toDouble();
  final padX = fontSize * 0.50;
  final padY = fontSize * 0.24;
  final box = ui.Rect.fromLTRB(
    (x - padX).clamp(0, width.toDouble()),
    (y - padY).clamp(0, height.toDouble()),
    (x + fill.width + padX).clamp(0, width.toDouble()),
    (y + fill.height + padY).clamp(0, height.toDouble()),
  );
  if (drawBox) {
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(box, ui.Radius.circular(fontSize * 0.22)),
      ui.Paint()..color = const ui.Color(0x99000000),
    );
  }
  canvas.drawParagraph(stroke, ui.Offset(x, y));
  canvas.drawParagraph(fill, ui.Offset(x, y));

  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  image.dispose();
  if (bytes == null) throw StateError('Skia 没有返回 PNG 数据');

  final output = File(out);
  await output.parent.create(recursive: true);
  final temporary = File('$out.part.$pid');
  await temporary.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
  await temporary.rename(output.path);
  if (emitBox) {
    await File('$out.box').writeAsString(
      '${box.left.floor()},${box.top.floor()},'
      '${box.width.ceil()},${box.height.ceil()}',
      encoding: utf8,
      flush: true,
    );
  }
}

ui.Paragraph _paragraph(
  String text,
  double fontSize,
  double maxWidth,
  ui.Paint foreground,
) {
  final builder =
      ui.ParagraphBuilder(
          ui.ParagraphStyle(
            textAlign: ui.TextAlign.center,
            fontFamily: subtitleRendererFontFamily,
            fontSize: fontSize,
            maxLines: 3,
          ),
        )
        ..pushStyle(
          ui.TextStyle(
            fontFamily: subtitleRendererFontFamily,
            fontSize: fontSize,
            foreground: foreground,
          ),
        )
        ..addText(text);
  final paragraph = builder.build()
    ..layout(ui.ParagraphConstraints(width: maxWidth));
  return paragraph;
}

int _positiveInt(Map<String, dynamic> spec, String name) {
  final value = spec[name];
  if (value is! num || value <= 0) {
    throw FormatException('$name 必须是正数');
  }
  return value.round();
}

double _unitDouble(Map<String, dynamic> spec, String name) {
  final value = spec[name];
  if (value is! num || value < 0 || value > 1) {
    throw FormatException('$name 必须在 0 到 1 之间');
  }
  return value.toDouble();
}
