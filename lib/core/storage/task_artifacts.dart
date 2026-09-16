import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';

/// 中间产物归属判定：文件名等于 id，或以 `id.` / `id_` 开头。
///
/// 不能用裸前缀匹配——id 为 `ab` 时 `abc.pcm` 也会被判成它的产物，清理时
/// 就会误删另一条任务的文件。分隔符是这条判定的全部意义所在。
bool artifactBelongsTo(String name, String taskId) =>
    name == taskId ||
    name.startsWith('$taskId.') ||
    name.startsWith('${taskId}_');

/// 一个**单元**在磁盘上会留下什么（按它的身份命名的那些）。
///
/// 固定底片的单元会各自抽一份缩略图、算一份波形、留下切点检测的中转文件，
/// 全都以 `<taskId>_u<uid>` 开头。删任务时它们跟着走（前缀仍是 taskId），
/// 但**换底片、删这个单元**时任务还在——不单独清一道，那几份就永远躺在
/// 盘上没人读。反复试几次底片就是几十兆（2026-09-15 清点时发现）。
bool unitArtifactBelongsTo(String name, String taskId, String unitUid) =>
    unitUid.isNotEmpty && name.startsWith('${taskId}_u$unitUid');

/// **一条任务在磁盘上会留下什么——唯一的一份清单。**
///
/// 为什么要有这个类：产物散在七八个目录里，删任务的清理器、设置页的「可回收
/// 空间」、启动时的孤儿清扫各自维护一份路径清单，只要有一处漏掉，那类产物就
/// 永远留在盘上没人管。真机上就是这个下场——1.4G 数据里活着的任务只有一条，
/// 六条已删任务的封面、人声分离结果（32M/条）、预览切片全都还躺着，
/// 因为清理器写的是 `if (entity is! File) continue`，把目录整个跳过了。
///
/// 新增一种产物**只改这里**，删任务与孤儿清扫会自动覆盖到它。
class TaskArtifacts {
  final Directory dataDir;

  const TaskArtifacts(this.dataDir);

  /// 一个任务一个子目录的那些：`<这个目录>/<taskId>/…`
  static const perTaskDirNames = [
    'export_work', // 导出的中间产物（增量重导要复用，按任务归属清理）
    'voices', // 生成的配音
    'picked_thumbs', // 已选素材的首帧图
    'review_thumbs', // 审核页原片段落的首帧图
    'speed_fit', // 预览的变速切片（曾经不在清单里：任务删了目录还躺着）
    'gap_clip', // 还没挑素材那几段垫的黑场（EDL 不能留洞）
    'silent_clip', // 「原片这一镜不出声」那几镜垫的静音（EDL 同样不能留洞）
    'materials', // 这个任务用到的素材原始下载（**导出读这里**）
    'bgm', // 这个任务用到的配乐
    'proxy', // 预览代理（派生产物，删了会重转）
    'vocals', // 素材人声分离结果（派生产物，但重算很贵）
    // ↓ 脚本成片那条线的产物。曾经全都不在清单里——删任务时留下近 900M
    // 没人认领的文件（自查时在真机上量到的）
    'script_export', // 编导台导出的中间产物
    'speed_fit_script', // 编导台预览的变速切片
    'shot_frames', // 镜头首帧图
    'script_refs', // 参考片切片
    'preview_voice', // 预览用的配音归一化产物
  ];

  /// **复制任务时要跟着走**的那几类产物（见 [TaskCopier]）。
  ///
  /// 判据只有一条：**丢了副本会瞎，或者重算要花钱/花很久**。
  /// - 任务里存着绝对路径的（配音、首帧图）——不带走，删了原任务副本就瞎；
  /// - 重算要花钱的（TTS 配音）或很久的（人声分离、素材下载）。
  ///
  /// 不在这个名单里的都是**派生产物**，用到自然会重建：导出中间产物
  /// （真机上一条任务 373M，副本本来就该从零导）、预览代理、变速切片、
  /// 黑场与静音垫片、审核页缩略图。
  ///
  /// 人声/背景轨（`analysis_work/stems/<id>/`）和封面（`covers/<id>.jpg`）
  /// 不在「一个任务一个子目录」这一套里，由 [TaskCopier] 单独搬。
  static const copyOnDuplicateDirNames = [
    'voices', // 生成的配音——重做是花钱的 TTS
    'materials', // 已下载的素材——重下要等、要流量
    'picked_thumbs', // 已选素材的首帧图（任务里存着它的路径）
    'bgm', // 配乐缓存
    'vocals', // 素材人声分离结果——派生的，但重算很贵
    'shot_frames', // 镜头首帧图（编导台）
    'script_refs', // 参考片切片（编导台）
  ];

  /// **跨任务共享**的缓存目录：里面按内容指纹命名，同一份内容只存一次，
  /// 换任务、换候选都能命中。归不到某个任务名下，所以不进 [perTaskDirNames]，
  /// 但占的是同一块盘，必须计入占用
  /// 现在只剩**工具**，不再有任务数据。
  ///
  /// 素材、配乐、预览代理、人声分离结果全部改成按任务存
  /// （见 [TaskMedia]），删任务时跟着一起走。共享缓存省了重复下载与
  /// 重复计算，代价是**任务删了没人收**——盘上永远躺着一批不知道归谁的
  /// 文件，谁都不敢删。用户明确选了「按项目存、不留孤儿」这一边。
  ///
  /// 这一改顺带让清理逻辑简单了一大截：按素材反查孤儿（vocalOrphans）
  /// 和按配额清扫（sweepByQuota）都不再需要——删任务直接带走
  static const sharedCacheDirNames = [
    'separator_models', // 人声分离**模型**：与任务无关，是工具不是数据
    // 分析产物按**源文件内容指纹**存，所以必须跨任务活着——同一条片子
    // 重新导入时靠它复用切分（不然 LLM 每次切出来的单元数都不一样，
    // 方案文件就跨不了任务）。一条片子几十 KB，攒不出量
    'prepared',
  ];

  /// 已经废弃、但可能还躺在老用户盘上的目录。开机扫一遍清掉——
  /// 磁盘上躺着的每一份数据都要有人读、有人删，没人读的就该走
  static const retiredDirNames = [
    // 预合成的预览音视频：多轨预览取代后已无写入方，老用户盘上清掉
    'preview_audio',
    'preview_video',
    // 审核回执（短命的中间设计）：审核完一切回到主流程，任务里的方案就是
    // 最终结果，回执没有第二个读者
    'reviews',
    // 「把素材转成原片规格」那套（MaterialNormalizer）已随代理方案退休，
    // 产物改放 preview_proxy。真机上这里躺着 77MB
    'material_normalized',
  ];

  /// 已经不会再有人读的那些目录（存在才返回）
  List<FileSystemEntity> retired() => [
        for (final name in retiredDirNames)
          if (Directory(p.join(dataDir.path, name)).existsSync())
            Directory(p.join(dataDir.path, name)),
      ];

  /// 分析工作目录：任务产物**平铺**在这里（`<id>_thumbs.raw`、`<id>.pcm`…），
  /// 外加两个按任务分的子目录（`<id>_frames/`、`stems/<id>/`）
  Directory get workDir => Directory(p.join(dataDir.path, 'analysis_work'));

  Directory get coversDir => Directory(p.join(dataDir.path, 'covers'));

  Directory get stemsDir => Directory(p.join(workDir.path, 'stems'));

  /// 属于 [taskId] 的全部产物（文件与目录都算）
  List<FileSystemEntity> of(String taskId) => [
        File(p.join(coversDir.path, '$taskId.jpg')),
        ..._workEntities().where(
            (e) => artifactBelongsTo(p.basename(e.path), taskId)),
        Directory(p.join(stemsDir.path, taskId)),
        for (final name in perTaskDirNames)
          Directory(p.join(dataDir.path, name, taskId)),
      ].where((e) => e.existsSync()).toList();

  /// 这个单元名下的产物（缩略图、波形、切点检测的中转）。
  ///
  /// 换底片、删单元时清它：那几份是按这张底片抽的，换一张就全不作数了
  List<FileSystemEntity> ofUnit(String taskId, String unitUid) =>
      _workEntities()
          .where((e) =>
              unitArtifactBelongsTo(p.basename(e.path), taskId, unitUid))
          .toList();

  /// 「用完即弃」的中转文件——**不管属于哪条任务，一律该删**。
  ///
  /// 它们只在产生它们的那一步里被读一次：
  /// - `<id>.pcm`：ASR 的输入，转完就没人看了（一条 96 秒的片子 18MB）；
  /// - `<id>_thumbs.raw`：切点检测的缩略图流，算完信号就没人看了（8.5MB）；
  /// - `<id>_scene.txt`：ffmpeg 场景分数的中转文件，同上；
  /// - `<id>_rev<ms>.jpg`：切点复核图，模型判完就没人看了（一条片子上百张）。
  ///
  /// 新代码已经在用完那一刻删掉它们，这里管的是**老存档留下的那批**——
  /// 它们归属得到现存任务，[orphans] 永远不会碰。
  List<FileSystemEntity> transients() => _workEntities()
      .whereType<File>()
      .where((e) => isTransient(p.basename(e.path)))
      .toList();

  static final _transientPatterns = [
    RegExp(r'\.pcm$'),
    RegExp(r'_thumbs\.raw$'),
    RegExp(r'_scene\.txt$'),
    RegExp(r'_rev\d+\.jpg$'),
  ];

  static bool isTransient(String name) =>
      _transientPatterns.any((re) => re.hasMatch(name));

  /// 归属不到 [liveTaskIds] 里任何一条的产物。
  ///
  /// 崩溃、手动删存档、开发期换机器——总会留下没主的东西，删任务时清干净
  /// 只解决一半问题，启动时再扫一遍才是根治。
  List<FileSystemEntity> orphans(Set<String> liveTaskIds) {
    bool orphan(String name) =>
        !liveTaskIds.any((id) => artifactBelongsTo(name, id));

    return [
      ..._children(coversDir).where((e) => orphan(_stem(e))),
      ..._workEntities().where((e) => orphan(p.basename(e.path))),
      ..._children(stemsDir).where((e) => orphan(p.basename(e.path))),
      for (final name in perTaskDirNames)
        ..._children(Directory(p.join(dataDir.path, name)))
            .where((e) => orphan(p.basename(e.path))),
    ];
  }

  /// 删掉给定的这些，返回**实际**释放的字节数（删失败的不计入，不虚报）
  int delete(Iterable<FileSystemEntity> entities) {
    var freed = 0;
    for (final entity in entities) {
      if (!entity.existsSync()) continue;
      final size = sizeOf(entity);
      try {
        entity.deleteSync(recursive: true);
        freed += size;
      } catch (e) {
        // 单个被占用/无权限不该中断整轮清理
        AppLog.warn('清理产物失败 ${entity.path}：$e');
      }
    }
    return freed;
  }

  static int sizeOf(FileSystemEntity entity) {
    try {
      if (entity is File) return entity.lengthSync();
      if (entity is Directory) {
        var total = 0;
        for (final child
            in entity.listSync(recursive: true, followLinks: false)) {
          if (child is File) total += child.lengthSync();
        }
        return total;
      }
    } catch (e) {
      // 扫描期间被删掉是正常竞态
      AppLog.warn('读取产物大小失败 ${entity.path}：$e');
    }
    return 0;
  }

  /// analysis_work 第一层里属于任务的东西。`stems` 是按任务分的子目录，
  /// 不在这一层算——它由 [stemsDir] 单独管
  List<FileSystemEntity> _workEntities() => _children(workDir)
      .where((e) => p.basename(e.path) != 'stems')
      .toList();

  static List<FileSystemEntity> _children(Directory dir) {
    if (!dir.existsSync()) return const [];
    try {
      return dir.listSync(followLinks: false);
    } catch (e) {
      AppLog.warn('读取目录失败 ${dir.path}：$e');
      return const [];
    }
  }

  /// 封面是 `<id>.jpg`，归属判定要拿掉扩展名再比——否则 `ab.jpg` 会被
  /// 当成 id 为 `ab.jpg` 的任务的产物
  static String _stem(FileSystemEntity entity) =>
      p.basenameWithoutExtension(entity.path);
}
