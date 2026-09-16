import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/vocal_separator.dart';

/// 取参数后面紧跟的那个值
String? valueAfter(List<String> args, String flag) {
  final i = args.indexOf(flag);
  return i < 0 || i + 1 >= args.length ? null : args[i + 1];
}

({VocalSeparator separator, List<List<String>> calls, Directory out})
    _build({
  int exitCode = 0,
  String stderr = '',
  bool produceFiles = true,
  /// 非空则把子进程卡在这儿，用来造出「上一次还没跑完」的时间窗
  Completer<void>? hold,
}) {
  final calls = <List<String>>[];
  final work = Directory.systemTemp.createTempSync('ishkafel_sep_');
  addTearDown(() => work.deleteSync(recursive: true));
  final out = Directory('${work.path}/stems');

  return (
    separator: VocalSeparator(
      modelDir: Directory('${work.path}/models'),
      run: (bin, args) async {
        calls.add(args);
        if (hold != null) await hold.future;
        if (exitCode == 0 && produceFiles) {
          out.createSync(recursive: true);
          final stem = 'a-${VocalSeparator.modelTag}';
          File('${out.path}/$stem-人声.wav').writeAsStringSync('v');
          File('${out.path}/$stem-背景.wav').writeAsStringSync('b');
        }
        return ProcessResult(1, exitCode, '', stderr);
      },
    ),
    calls: calls,
    out: out,
  );
}

void main() {
  test('Windows 会探测 uv 默认的用户级可执行目录', () {
    expect(
      vocalSeparatorSearchDirsFor(
        operatingSystem: 'windows',
        environment: const {'USERPROFILE': r'C:\Users\Mayn'},
        defaultDirs: const [r'C:\Ishkafel\tools'],
      ),
      const [r'C:\Users\Mayn\.local\bin', r'C:\Ishkafel\tools'],
    );
  });

  test('分离出人声与背景两条轨', () async {
    final b = _build();

    final stems =
        await b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out);

    expect(stems.vocalsPath, endsWith('人声.wav'));
    expect(stems.backgroundPath, endsWith('背景.wav'));
  });

  test('模型是显式指定的，不用工具的默认值', () async {
    final b = _build();

    await b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out);

    expect(valueAfter(b.calls.single, '--model_filename'), VocalSeparator.model,
        reason: '换模型是拿音质换速度的产品决定（15s vs 81s），'
            '不能交给工具的默认值决定');
  });

  test('两套架构的参数都给，换模型时不必跟着改调用点', () async {
    final b = _build();

    await b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out);

    final args = b.calls.single;
    expect(valueAfter(args, '--mdx_batch_size'), '8');
    expect(valueAfter(args, '--mdx_segment_size'), '512');
    expect(valueAfter(args, '--mdxc_batch_size'), '8');
  });

  test('模型目录必须显式指定：工具默认放 /tmp，系统一清就要重下几百兆',
      () async {
    final b = _build();

    await b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out);

    final dir = valueAfter(b.calls.single, '--model_file_dir');
    expect(dir, isNotNull);
    expect(dir, isNot(startsWith('/tmp/audio-separator')));
    expect(Directory(dir!).existsSync(), isTrue, reason: '目录要先建好');
  });

  test('输出文件名固定，不去猜工具按模型名拼出来的那一长串', () async {
    final b = _build();

    await b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out);

    expect(valueAfter(b.calls.single, '--custom_output_names'),
        contains('人声'));
  });

  test('已经分离过就直接复用，不再跑一遍十几秒', () async {
    final b = _build();

    await b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out);
    await b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out);

    expect(b.calls, hasLength(1));
  });

  test('工具没装时给的是「请先安装」，不是一句看不懂的报错', () async {
    final b = _build(exitCode: 127, stderr: 'command not found');

    expect(
      () => b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out),
      throwsA(isA<VocalSeparationException>().having(
          (e) => e.message, 'message', contains('未检测到人声分离工具'))),
    );
  });

  /// 真机事故（2026-09-04）：这句话把用户支使去装一个**已经装好**的工具。
  /// 缺的是分离工具自己要调的 ffmpeg——它抛的也是「No such file」，于是被
  /// 归到了同一句上。说错原因比不说更糟：他会照着做，然后发现还是不行。
  test('缺的是 ffmpeg 时就说 ffmpeg，别赖到人声分离工具头上', () async {
    final b = _build(
      exitCode: 1,
      stderr: "FileNotFoundError: [Errno 2] "
          "No such file or directory: 'ffmpeg'",
    );

    expect(
      () => b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out),
      throwsA(isA<VocalSeparationException>().having(
          (e) => e.message,
          'message',
          allOf(contains('ffmpeg'),
              isNot(contains('未检测到人声分离工具'))))),
    );
  });

  test('跑成功了却没产出文件，同样要报错而不是给一个不存在的路径', () async {
    final b = _build(produceFiles: false);

    expect(
      () => b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out),
      throwsA(isA<VocalSeparationException>()),
    );
  });

  /// 真机事故（2026-09-04）：一条素材被并发起了 **14 个**分离进程，还都往
  /// 同一组文件里写。`separate` 只认**已经跑完**的产物，上一次还在跑的那段
  /// 时间里，每个调用方都会再起一个。
  ///
  /// 以前这事没人发现，因为它们全都因为找不到 ffmpeg 秒退；把 PATH 修好之后
  /// 它们真跑起来了，机器直接被拖垮。
  test('上一次还没跑完时再要一次，就等它——不许再起一个往同一份文件里写', () async {
    final hold = Completer<void>();
    final b = _build(hold: hold);

    final first = b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out);
    final second =
        b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out);
    hold.complete();
    final results = await Future.wait([first, second]);

    expect(b.calls, hasLength(1), reason: '两个调用方共用同一次分离');
    expect(results[0].vocalsPath, results[1].vocalsPath);
  });

  test('跑完之后再要，照旧复用产物、也不受在途登记的影响', () async {
    final b = _build();

    await b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out);
    await b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out);

    expect(b.calls, hasLength(1));
  });

  test('上一次失败了，下一次还能重试——失败不许把登记留在那儿', () async {
    final hold = Completer<void>();
    final b = _build(hold: hold, exitCode: 1, stderr: '模型下载失败');

    final failing =
        b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out);
    hold.complete();
    await expectLater(failing, throwsA(isA<VocalSeparationException>()));

    await expectLater(
        b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out),
        throwsA(isA<VocalSeparationException>()));
    expect(b.calls, hasLength(2), reason: '第二次要真的重试，不是复读上一次的失败');
  });

  test('产物文件名带模型标记：换了模型要重新分离，不能接着用旧产物', () async {
    final b = _build();

    await b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out);

    expect(b.calls.single.join(' '), contains(VocalSeparator.modelTag),
        reason: '这次正是被旧模型的产物坑到——分不干净却当成新结果用');
  });
}
