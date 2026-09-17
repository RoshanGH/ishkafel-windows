import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/process_runner.dart';
import 'package:ishkafel/core/ffmpeg/rendered_cache.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('ishkafel_rc_'));
  tearDown(() => temp.deleteSync(recursive: true));

  ({RenderedCache cache, List<List<String>> calls}) make({bool fail = false}) {
    final calls = <List<String>>[];
    return (
      cache: RenderedCache(
        dir: temp,
        run: (binary, args) async {
          calls.add(args);
          if (fail) return ProcessResult(1, 1, '', '炸了');
          await File(args.last).writeAsString('out');
          return ProcessResult(1, 0, '', '');
        },
      ),
      calls: calls,
    );
  }

  Future<String> render(RenderedCache cache, String key) => cache.render(
        key: key,
        prefix: 'clip',
        extension: 'mp4',
        args: (out) => ['-i', 'x', out],
        what: '切一段',
      );

  group('按内容指纹复用', () {
    test('同一个键只跑一次 ffmpeg', () async {
      final env = make();

      final a = await render(env.cache, 'trim|/v/a.mp4|0|1000');
      final b = await render(env.cache, 'trim|/v/a.mp4|0|1000');

      expect(a, b);
      expect(env.calls, hasLength(1));
    });

    test('换了新实例照样命中——认的是磁盘上的文件，不是内存里那张表', () async {
      final first = make();
      await render(first.cache, 'trim|/v/a.mp4|0|1000');

      final second = make();
      await render(second.cache, 'trim|/v/a.mp4|0|1000');

      expect(second.calls, isEmpty,
          reason: '每进一次工作台就新建一个合成器，只认内存表等于永远不命中');
    });

    test('内容变了就是另一个文件——不能按名字复用出上一个方案的内容', () async {
      final env = make();

      final a = await render(env.cache, 'trim|/v/a.mp4|0|1000');
      final b = await render(env.cache, 'trim|/v/a.mp4|0|2000');

      expect(a, isNot(b));
      expect(env.calls, hasLength(2));
    });

    test('不同种类的产物不会撞名', () async {
      final env = make();

      final clip = await env.cache.render(
          key: 'same',
          prefix: 'clip',
          extension: 'mp4',
          args: (out) => [out],
          what: 'a');
      final audio = await env.cache.render(
          key: 'same',
          prefix: 'audio',
          extension: 'wav',
          args: (out) => [out],
          what: 'b');

      expect(clip, isNot(audio));
    });
  });

  group('半截文件不会被当成好的用', () {
    test('先写 .part 再改名，失败时把半截删掉', () async {
      final env = make(fail: true);

      await expectLater(render(env.cache, 'k'), throwsA(isA<FfmpegException>()));

      final left = temp.listSync().map((e) => e.path).toList();
      expect(left, isEmpty, reason: '留下 .part 或 0 字节的成品都会毒害下一次');
    });

    test('临时名把扩展名留在最后——ffmpeg 靠它推断输出格式', () async {
      final env = make();

      await render(env.cache, 'k');

      expect(env.calls.single.last, endsWith('.mp4'),
          reason: '写成 xxx.mp4.part 会让 ffmpeg 报「Unable to choose an '
              'output format」——真机上就这么炸的');
      // `.part` 后面跟一个序号：同一个 key 可能被两处同时渲（工作台和
      // 编导台各持一个缓存实例），临时名一样的话两边写同一个文件，
      // 先 rename 的把文件搬走，后一个当场炸（2026-09-17 真机日志）
      expect(env.calls.single.last, contains('.part'));
      expect(env.calls.single.last, isNot(contains('.part.')),
          reason: '固定的临时名会让并发的两次渲染互相踩');
    });

    test('上次留下的 .part 不算命中', () async {
      final env = make();
      // 上一轮崩在半路留下的临时文件
      final stale = env.cache
          .tempPathFor(key: 'k', prefix: 'clip', extension: 'mp4');
      File(stale).writeAsStringSync('半截');

      final path = await render(env.cache, 'k');

      expect(env.calls, hasLength(1), reason: '半截文件不能当成已经有了');
      expect(File(path).existsSync(), isTrue);
      expect(path, isNot(stale), reason: '成品名和临时名本来就不是一个');
      // 陈旧的 .part 由 keepOnly 收走——它不在这一轮 _touched 里
      env.cache.keepOnly();
      expect(File(stale).existsSync(), isFalse);
    });

    test('0 字节的成品也不算命中', () async {
      final env = make();
      final path = env.cache
          .pathFor(key: 'k', prefix: 'clip', extension: 'mp4');
      File(path).writeAsStringSync('');

      await render(env.cache, 'k');

      expect(env.calls, hasLength(1));
    });
  });

  group('清理陈旧版本', () {
    test('只留这一轮用到的，其余删掉', () async {
      final env = make();
      final old = await render(env.cache, '上一个方案');
      env.cache.resetTouched();
      final current = await render(env.cache, '这一个方案');

      env.cache.keepOnly();

      expect(File(current).existsSync(), isTrue);
      expect(File(old).existsSync(), isFalse,
          reason: '指纹命名意味着换一次方案就多一套，不清就只增不减');
    });

    test('protect 里的文件一律不动', () async {
      final env = make();
      final state = File('${temp.path}/state.json')..writeAsStringSync('{}');
      await render(env.cache, 'k');

      env.cache.keepOnly(protect: {state.path});

      expect(state.existsSync(), isTrue);
    });

    test('目录不存在时不炸', () {
      final cache = RenderedCache(
          dir: Directory('${temp.path}/nope'),
          run: (_, _) async => ProcessResult(1, 0, '', ''));

      expect(cache.keepOnly, returnsNormally);
    });
  });

  test('同内容同名、异内容不同名', () {
    expect(RenderedCache.digest('a'), RenderedCache.digest('a'));
    expect(RenderedCache.digest('a'), isNot(RenderedCache.digest('b')));
    expect(RenderedCache.digest('a'), hasLength(16));
  });

  group('并发渲同一份', () {
    /// 2026-09-17 真机日志：
    /// 「生成预览代理失败，先按原样用（接缝处可能有一下顿挫）：
    ///   Cannot rename file to '.../proxy_ed5b44a484e75b8d.mp4',
    ///   path = '.../proxy_ed5b44a484e75b8d.part.mp4'」
    ///
    /// 两处同时要同一份代理（预览重推 + 素材固定），临时名一样，先 rename
    /// 的那个把文件搬走，后一个当场炸——那一段于是退回原规格，
    /// **接缝处照旧闪**。规格化那道闸装了，却被这个竞态放空。
    test('同一个 key 并发要两次：只跑一次 ffmpeg，两边都拿到成品', () async {
      final env = make();

      final both = await Future.wait([
        render(env.cache, 'same'),
        render(env.cache, 'same'),
      ]);

      expect(both.first, both.last);
      expect(env.calls, hasLength(1), reason: '并发转两遍是白烧一倍 CPU');
      expect(File(both.first).existsSync(), isTrue);
    });

    test('两个实例各渲各的：临时名不许撞，两边都要成功', () async {
      // 工作台和编导台各持一个 RenderedCache，内存里的去重表管不着对方
      final a = make();
      final b = make();

      final both = await Future.wait([
        render(a.cache, 'same'),
        render(b.cache, 'same'),
      ]);

      expect(both.first, both.last, reason: '同一个 key 就是同一份成品');
      expect(File(both.first).existsSync(), isTrue);
      expect(a.calls.single.last, isNot(b.calls.single.last),
          reason: '临时名一样的话，两边会写同一个文件、互相踩');
    });
  });
}
