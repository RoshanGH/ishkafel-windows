import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../ffmpeg/process_runner.dart';
import 'subtitle_overlay.dart';
import 'subtitle_renderer_protocol.dart';
import 'subtitle_style.dart';

/// 把字幕行渲成透明 PNG——文字交给 macOS 自带的系统渲染（AppKit，经
/// osascript 的 JXA 调用），不依赖 ffmpeg 编没编 libass/freetype。
///
/// 产物按内容指纹命名（文本 + 样式 + 分辨率），已存在就不重渲；一次
/// osascript 进程渲完这一批缺的，不是一句一个进程。
class SubtitleRasterizer {
  final ProcessRunner run;
  final String operatingSystem;
  final String? rendererExecutable;

  SubtitleRasterizer({
    this.run = systemProcessRunner,
    String? operatingSystem,
    this.rendererExecutable,
  }) : operatingSystem = operatingSystem ?? Platform.operatingSystem;

  /// 同一个工作目录上的渲染要**排队**。
  ///
  /// 导出时段落是并行渲的（窗口 3），于是好几次 rasterize 会同时盯着同一个
  /// 目录：各自算出「还缺哪几张」，再各自把清单写进 spec——后一个覆盖前一个，
  /// 而前一个的 osascript 才刚启动、这时候才去读，读到的是别人的清单，
  /// 于是它要的图没人渲。真机上三条方案全部导出失败就是这么来的，
  /// 报「某某句没有产出图片」，句子每次都不一样。
  ///
  /// 排队不亏：这一层本来就靠内容指纹复用，排在后面的多半直接命中磁盘，
  /// 连进程都不用起。
  static final Map<String, Future<void>> _queues = {};

  /// 一次调用一份 spec：跨进程（比如界面和命令行同时导）排不到同一个队里，
  /// 文件名撞了照样互相覆盖
  static int _seq = 0;

  /// 把 [lines] 渲成 PNG，返回与 overlay 滤镜对接的图。
  /// 渲染失败直接抛——字幕是成片内容，悄悄少一句正是不允许的那类错。
  Future<List<SubtitleOverlayImage>> rasterize({
    required List<SubtitleLine> lines,
    required int width,
    required int height,
    required SubtitleStyle style,
    required Directory outDir,
  }) async {
    if (lines.isEmpty) return const [];
    outDir.createSync(recursive: true);

    final key = outDir.absolute.path;
    final ahead = _queues[key] ?? Future<void>.value();
    final mine = ahead.then(
      (_) => _rasterize(
        lines: lines,
        width: width,
        height: height,
        style: style,
        outDir: outDir,
      ),
    );
    // 队列只记「轮到下一个没有」，失败不能把后面的人一起带走
    _queues[key] = mine.then((_) {}, onError: (_) {});
    try {
      return await mine;
    } finally {
      if (identical(_queues[key], mine)) _queues.remove(key);
    }
  }

  Future<List<SubtitleOverlayImage>> _rasterize({
    required List<SubtitleLine> lines,
    required int width,
    required int height,
    required SubtitleStyle style,
    required Directory outDir,
  }) async {
    final blur = style.preset == SubtitlePreset.blurBox;
    final entries = <({String out, SubtitleLine line})>[];
    final missing = <SubtitleRendererItem>[];
    for (final line in lines) {
      final key = _fingerprint(line.text, width, height, style);
      final out = p.join(outDir.path, 'subimg_$key.png');
      entries.add((out: out, line: line));
      // 毛玻璃要 sidecar 文本框；两样缺一样都算没渲过
      if (!File(out).existsSync() || (blur && !File('$out.box').existsSync())) {
        missing.add(SubtitleRendererItem(text: line.text, out: out));
      }
    }
    if (missing.isEmpty) return _collect(entries, blur);

    final stamp = '${pid}_${_seq++}';
    final spec = File(p.join(outDir.path, 'subrender_spec_$stamp.json'))
      ..writeAsStringSync(
        jsonEncode(
          buildSubtitleRendererSpec(
            width: width,
            height: height,
            style: style,
            items: missing,
          ),
        ),
      );

    File? script;
    late final String executable;
    late final List<String> arguments;
    if (operatingSystem == 'macos') {
      script = File(p.join(outDir.path, 'subrender_$stamp.js'))
        ..writeAsStringSync(_jxaScript);
      executable = 'osascript';
      arguments = ['-l', 'JavaScript', script.path, spec.path];
    } else {
      executable =
          rendererExecutable ??
          resolveSubtitleRendererExecutable(operatingSystem: operatingSystem);
      arguments = [spec.path];
    }
    final result = await run(executable, arguments);
    // 中间产物用完即弃——留在工作目录里只会越堆越多，且谁也不读
    for (final f in [?script, spec]) {
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (_) {
        // 删不掉不影响成片，不值得让导出失败
      }
    }
    if (result.exitCode != 0) {
      throw StateError(
        '字幕渲染失败（$executable exit=${result.exitCode}）：'
                '${result.stderr}'
            .trim(),
      );
    }
    final bad = [
      for (final m in missing)
        if (!File(m.out).existsSync()) m.text,
    ];
    if (bad.isNotEmpty) {
      // 说清是谁没干活、人能做什么。以前这里只有一句「没有产出图片」，
      // 拿到的人不知道图该由谁产出、也不知道该去修什么
      final recovery = operatingSystem == 'macos'
          ? '请人试一次：终端里跑 `osascript -l JavaScript -e "1+1"`，'
                '若被拦，去「系统设置 → 隐私与安全性 → 自动化」里给终端放行。'
          : 'Windows 字幕辅助进程没有产出完整结果，请检查安装目录中的 '
                '`ishkafel_renderer.exe` 与应用日志。';
      throw StateError(
        '字幕图没渲出来（${bad.length} 句，第一句是「${bad.first}」）。'
        '$recovery',
      );
    }
    return _collect(entries, blur);
  }

  /// 组装结果；毛玻璃预设从 sidecar 读回文本框。sidecar 读不出时该句
  /// 退化为无遮罩（字仍带细描边，可读）——不因一块框丢一句字幕
  static List<SubtitleOverlayImage> _collect(
    List<({String out, SubtitleLine line})> entries,
    bool blur,
  ) {
    return List.unmodifiable([
      for (final e in entries)
        SubtitleOverlayImage(
          pngPath: e.out,
          startMs: e.line.startMs,
          endMs: e.line.endMs,
          blurBox: blur ? _readBox('${e.out}.box') : null,
        ),
    ]);
  }

  static SubtitleBlurBox? _readBox(String path) {
    try {
      final parts = File(path).readAsStringSync().trim().split(',');
      if (parts.length != 4) return null;
      final v = parts.map(int.parse).toList();
      return SubtitleBlurBox(x: v[0], y: v[1], w: v[2], h: v[3]);
    } catch (_) {
      return null;
    }
  }

  static String _fingerprint(
    String text,
    int width,
    int height,
    SubtitleStyle style,
  ) =>
      '${text.hashCode.toRadixString(16)}_${width}x$height'
      '_${style.fingerprint.hashCode.toRadixString(16)}';
}

/// AppKit 渲字（JXA）。白字黑描边（NSStrokeWidth 负值 = 描边 + 填充），
/// 底部居中、按宽度折行；box 预设先铺半透明圆角底再画字。
/// 真机验证过：中文（PingFang SC）、折行、透明通道都正常。
const String _jxaScript = r'''
function run(argv) {
  ObjC.import('Cocoa');
  const data = $.NSData.dataWithContentsOfFile(argv[0]);
  const spec = JSON.parse($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js);
  const w = spec.width, h = spec.height;
  for (const it of spec.items) {
    const rep = $.NSBitmapImageRep.alloc
      .initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(
        null, w, h, 8, 4, true, false, $.NSDeviceRGBColorSpace, 0, 0);
    $.NSGraphicsContext.saveGraphicsState;
    $.NSGraphicsContext.setCurrentContext($.NSGraphicsContext.graphicsContextWithBitmapImageRep(rep));
    let font = $.NSFont.fontWithNameSize('PingFangSC-Semibold', spec.fontSize);
    if (font.isNil()) font = $.NSFont.boldSystemFontOfSize(spec.fontSize);
    const para = $.NSMutableParagraphStyle.alloc.init;
    // NSTextAlignmentCenter：新 SDK 里是 1（老 AppKit 的 2 现在是右对齐，
    // 真机上就是被它坑出了「从右往左排」）
    para.setAlignment(1);
    // 两遍绘制：先用「仅描边」（正值）画粗黑边打底，再画实心字芯——
    // 描边和填充一遍画（负值）时，描边一粗就会吃进字的内部
    const strokeAttrs = $.NSMutableDictionary.alloc.init;
    strokeAttrs.setObjectForKey(font, $.NSFontAttributeName);
    strokeAttrs.setObjectForKey($.NSColor.blackColor, $.NSStrokeColorAttributeName);
    strokeAttrs.setObjectForKey($.NSNumber.numberWithDouble(spec.strokePercent * 2), $.NSStrokeWidthAttributeName);
    strokeAttrs.setObjectForKey(para, $.NSParagraphStyleAttributeName);
    const attrs = $.NSMutableDictionary.alloc.init;
    attrs.setObjectForKey(font, $.NSFontAttributeName);
    attrs.setObjectForKey($.NSColor.colorWithSRGBRedGreenBlueAlpha(spec.r, spec.g, spec.b, 1), $.NSForegroundColorAttributeName);
    // 字芯自身再带一圈同色细描边，撑出样张里那种饱满的字重
    attrs.setObjectForKey($.NSColor.colorWithSRGBRedGreenBlueAlpha(spec.r, spec.g, spec.b, 1), $.NSStrokeColorAttributeName);
    attrs.setObjectForKey($.NSNumber.numberWithDouble(-2.5), $.NSStrokeWidthAttributeName);
    attrs.setObjectForKey(para, $.NSParagraphStyleAttributeName);
    const ns = $(it.text);
    const margin = Math.round(w * 0.055);
    const box = $.NSMakeSize(w - margin * 2, h);
    const bounds = ns.boundingRectWithSizeOptionsAttributesContext(box, 1, attrs, $());
    const rect = $.NSMakeRect(margin, spec.marginV, w - margin * 2, Math.ceil(bounds.size.height));
    if (spec.box) {
      $.NSColor.colorWithSRGBRedGreenBlueAlpha(0, 0, 0, 0.45).setFill;
      const pad = Math.round(spec.fontSize * 0.3);
      const bw = Math.ceil(bounds.size.width) + pad * 2;
      $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius(
        $.NSMakeRect((w - bw) / 2, rect.origin.y - pad, bw, Math.ceil(bounds.size.height) + pad * 2),
        pad * 0.6, pad * 0.6).fill;
    }
    ns.drawWithRectOptionsAttributesContext(rect, 1, strokeAttrs, $());
    ns.drawWithRectOptionsAttributesContext(rect, 1, attrs, $());
    $.NSGraphicsContext.restoreGraphicsState;
    rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $())
       .writeToFileAtomically($(it.out), true);
    if (spec.emitBox) {
      // 毛玻璃遮罩的文本框：AppKit 原点在左下，转成 ffmpeg 的左上原点。
      // 框比文字四周各放一点 padding，磨砂边缘不贴字
      const padB = Math.round(spec.fontSize * 0.35);
      const bw = Math.min(w, Math.ceil(bounds.size.width) + padB * 2);
      const bh = Math.ceil(bounds.size.height) + padB * 2;
      const bx = Math.max(0, Math.round((w - bw) / 2));
      const byTop = Math.max(0, h - (spec.marginV + Math.ceil(bounds.size.height)) - padB);
      $(bx + ',' + byTop + ',' + bw + ',' + bh)
        .writeToFileAtomicallyEncodingError($(it.out + '.box'), true, $.NSUTF8StringEncoding, $());
    }
  }
  return 'ok:' + spec.items.length;
}
''';
