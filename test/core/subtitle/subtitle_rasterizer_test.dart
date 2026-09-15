import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/core/subtitle/subtitle_rasterizer.dart';
import 'package:ishkafel/core/subtitle/subtitle_style.dart';

/// 导出时段落是**并行渲的**（窗口 3，见 export_runner），于是同一个工作目录
/// 上会有好几次 rasterize 同时在跑。它们各自算出「还缺哪几张图」，然后把
/// 清单写进**同一个文件名**的 spec 里——后一个把前一个的清单覆盖掉，而前一个
/// 的 osascript 才刚启动、这时候才去读，读到的是别人的清单。
///
/// 真机后果：三条方案全部导出失败，报「某某句没有产出图片」，失败的句子每次
/// 都不一样，但从没飘出过第一个单元（第一个单元一张图都还没渲过，
/// 并发窗口全是「有活要干」的调用，撞得最凶）。
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('subrender'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// 假的 osascript：**进程启动是要时间的**，读 spec 发生在启动之后——
  /// 覆盖窗口就开在这里
  Future<ProcessResult> lateReadingOsascript(
    String bin,
    List<String> args,
  ) async {
    final specPath = args.last;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final spec = jsonDecode(File(specPath).readAsStringSync());
    for (final item in (spec['items'] as List)) {
      File(item['out'] as String).writeAsStringSync('fake png');
    }
    return ProcessResult(1, 0, '', '');
  }

  List<SubtitleLine> lines(List<String> texts) => [
    for (var i = 0; i < texts.length; i++)
      SubtitleLine(text: texts[i], startMs: i * 1000, endMs: i * 1000 + 900),
  ];

  test('同一个目录上并行渲，谁都不许把别人的清单覆盖掉', () async {
    final r = SubtitleRasterizer(run: lateReadingOsascript);
    Future<List<SubtitleOverlayImage>> render(List<String> texts) =>
        r.rasterize(
          lines: lines(texts),
          width: 1080,
          height: 1920,
          style: const SubtitleStyle(),
          outDir: dir,
        );

    // 后发的那个清单更短（前面的段落已经把一部分图渲出来了，这是真实形态）
    final results = await Future.wait([
      render(['早就跟你们说了', '长到身上了', '只会变得更加严重']),
      render(['早就跟你们说了']),
    ]);

    expect(
      results[0],
      hasLength(3),
      reason:
          '三条方案全灭就是从这儿来的：它要的三张图，'
          '被后来者的一张图清单顶掉了两张',
    );
    for (final img in results[0]) {
      expect(
        File(img.pngPath).existsSync(),
        isTrue,
        reason: '${img.pngPath} 没渲出来',
      );
    }
  });

  test('渲过的不重渲——并行也只该起一次进程干活', () async {
    var calls = 0;
    final r = SubtitleRasterizer(
      run: (bin, args) {
        calls++;
        return lateReadingOsascript(bin, args);
      },
    );
    Future<void> render() => r.rasterize(
      lines: lines(['早就跟你们说了']),
      width: 1080,
      height: 1920,
      style: const SubtitleStyle(),
      outDir: dir,
    );

    await Future.wait([render(), render(), render()]);

    expect(
      calls,
      1,
      reason:
          '三次要的是同一张图。串起来之后后两次应该直接命中磁盘上的，'
          '起三个 osascript 是白烧时间',
    );
  });

  test('Windows 只调用同协议 renderer，不调用 osascript', () async {
    String? executable;
    List<String>? arguments;
    final rasterizer = SubtitleRasterizer(
      operatingSystem: 'windows',
      rendererExecutable: r'C:\Ishkafel\ishkafel_renderer.exe',
      run: (bin, args) async {
        executable = bin;
        arguments = args;
        final spec = jsonDecode(File(args.single).readAsStringSync()) as Map;
        expect(spec['protocolVersion'], 1);
        for (final item in spec['items'] as List) {
          File(
            (item as Map)['out'] as String,
          ).writeAsBytesSync(const [1, 2, 3]);
        }
        return ProcessResult(7, 0, '', '');
      },
    );

    final images = await rasterizer.rasterize(
      lines: lines(['Windows 字幕']),
      width: 1080,
      height: 1920,
      style: SubtitleStyle.standard,
      outDir: dir,
    );

    expect(executable, r'C:\Ishkafel\ishkafel_renderer.exe');
    expect(arguments, hasLength(1));
    expect(images.single.pngPath, endsWith('.png'));
  });
}
