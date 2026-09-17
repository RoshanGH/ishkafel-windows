import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';
import 'process_runner.dart';

/// 按**内容指纹**缓存 ffmpeg 产物。
///
/// 为什么必须按指纹而不是按「文件名存在」：预览的中间产物此前叫
/// `mix_u4_1.wav`——名字里只有单元下标，不含内容。换一次配乐、改一次替换，
/// 这个名字对应的内容就变了。要是按「文件在就当已经有了」去复用，放出来的
/// 是上一个方案的声音，**用户听不出来，导出才发现**。静默出错比多等十几秒
/// 糟得多，所以键必须唯一决定内容。
///
/// 渲染先写 `.part` 再改名：ffmpeg 跑到一半被杀掉留下的是半截文件，
/// 下次启动照单全收的话，拼出来的东西会缺一段。
class RenderedCache {
  final Directory dir;
  final ProcessRunner run;

  /// 这一轮用到的产物路径。[keepOnly] 据此把陈旧版本清掉
  final Set<String> _touched = {};

  RenderedCache({required this.dir, required this.run});

  /// 这一轮用到了哪些文件（含命中缓存的）
  Set<String> get touched => Set.unmodifiable(_touched);

  void resetTouched() => _touched.clear();

  /// 渲染一件产物；[key] 相同就直接复用，一次 ffmpeg 都不跑。
  ///
  /// [prefix] 只影响文件名可读性，不参与内容判定——但要参与命名，
  /// 否则不同种类的产物撞在同一个名字上。
  /// 正在渲的那几个：同一个 key 只跑一次，后来的等它。
  ///
  /// 不去重的话同一条素材会被并发转两遍——白烧一倍 CPU，
  /// 而两个 ffmpeg 抢同一台机器只会都变慢
  final Map<String, Future<String>> _inFlight = {};

  Future<String> render({
    required String key,
    required String prefix,
    required String extension,
    required List<String> Function(String out) args,
    required String what,
  }) async {
    final path = pathFor(key: key, prefix: prefix, extension: extension);
    final file = File(path);
    if (file.existsSync() && file.lengthSync() > 0) {
      _touched.add(path);
      return path;
    }
    // 已经有人在渲同一份了：等它，别再起一个 ffmpeg
    if (_inFlight[path] case final running?) return running;
    final future = _render(
      path: path,
      key: key,
      prefix: prefix,
      extension: extension,
      args: args,
      what: what,
    );
    _inFlight[path] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(path);
    }
  }

  Future<String> _render({
    required String path,
    required String key,
    required String prefix,
    required String extension,
    required List<String> Function(String out) args,
    required String what,
  }) async {
    dir.createSync(recursive: true);
    // 扩展名必须留在最后：ffmpeg 靠它推断输出格式，写成 `xxx.wav.part`
    // 会直接报「Unable to choose an output format」（真机上就这么炸的）
    final temp = tempPathFor(key: key, prefix: prefix, extension: extension);
    try {
      final result = await run('ffmpeg', args(temp));
      if (result.exitCode != 0) {
        final tail = '${result.stderr}'.trim().split('\n').take(3).join(' / ');
        throw FfmpegException('$what 失败：$tail');
      }
      // 另一个实例可能已经渲好并搬到位了——那就用它的，把自己这份删掉。
      // 内容由 key 决定，两份是一样的
      if (File(path).existsSync() && File(path).lengthSync() > 0) {
        File(temp).deleteSync();
      } else {
        File(temp).renameSync(path);
      }
    } catch (e) {
      if (File(temp).existsSync()) File(temp).deleteSync();
      rethrow;
    }
    _touched.add(path);
    return path;
  }

  /// 写一个由 [key] 决定内容的小文件（concat 清单这类），同样只写一次
  String writeText({
    required String key,
    required String prefix,
    required String extension,
    required String content,
  }) {
    final path = pathFor(key: key, prefix: prefix, extension: extension);
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() == 0) {
      dir.createSync(recursive: true);
      file.writeAsStringSync(content);
    }
    _touched.add(path);
    return path;
  }

  String pathFor({
    required String key,
    required String prefix,
    required String extension,
  }) => p.join(dir.path, '${prefix}_${digest(key)}.$extension');

  /// 渲染中的临时名。`.part` 放在扩展名**之前**——见 [render] 里的说明。
  ///
  /// **每次调用都不一样**（带一个序号）：同一个 key 可能被两处同时渲
  /// （工作台和编导台各持一个缓存实例、预览重推和素材固定并发），
  /// 临时名一样的话两边写同一个文件，先 rename 的那个把文件搬走，
  /// 后一个当场 `PathNotFoundException`——真机日志：
  /// 「生成预览代理失败……Cannot rename file to proxy_xxx.mp4」，
  /// 那一段于是退回原规格，接缝处照旧闪（2026-09-17）
  String tempPathFor({
    required String key,
    required String prefix,
    required String extension,
  }) =>
      p.join(dir.path, '${prefix}_${digest(key)}.part${_tempSeq++}.$extension');

  /// 临时名的序号。只要在同一个进程里互不相同就够——跨进程靠 pid 那一段
  static int _tempSeq = DateTime.now().microsecondsSinceEpoch & 0xffff;

  /// 把这一轮没用到的产物删掉。
  ///
  /// 指纹命名意味着换一次方案就多一套文件，不清理的话目录只增不减——
  /// 而旧的那套除了占地方没有任何用处（撤销回去重合一遍就是了）。
  /// [protect] 里的文件一律不动（比如记着「这份预览是按什么方案合的」那份存档）。
  void keepOnly({Set<String> protect = const {}}) {
    if (!dir.existsSync()) return;
    final keep = {
      for (final path in {..._touched, ...protect}) p.canonicalize(path),
    };
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! File) continue;
      if (keep.contains(p.canonicalize(entity.path))) continue;
      try {
        entity.deleteSync();
      } catch (e) {
        // 删不掉最多占点地方，不该因此中断
        AppLog.warn('清理陈旧渲染产物失败 ${entity.path}：$e');
      }
    }
  }

  /// 短指纹。不需要密码学强度，只要**同内容同名、异内容极难撞**：
  /// 64 位 FNV-1a，十六进制 16 位。自己实现是为了不为这件事多拉一个依赖。
  static String digest(String key) {
    var hash = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    const mask = 0xFFFFFFFFFFFFFFFF;
    for (final unit in key.codeUnits) {
      hash = (hash ^ unit) & mask;
      hash = (hash * prime) & mask;
    }
    // Dart 的 int 是 64 位**有符号**的，直接 toRadixString 会给出带负号的
    // 字符串（'-509c23b3…'），拿去当文件名既难看又长短不一。拆成两个
    // 无符号 32 位分别输出
    final high = (hash >> 32).toUnsigned(32).toRadixString(16).padLeft(8, '0');
    final low = hash.toUnsigned(32).toRadixString(16).padLeft(8, '0');
    return '$high$low';
  }
}
