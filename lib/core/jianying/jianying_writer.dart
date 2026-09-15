import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../script/script_doc.dart';
import '../subtitle/subtitle_style.dart';
import '../platform/platform_shell.dart';
import 'jianying_draft.dart';
import 'jianying_materials.dart';
import 'jianying_plan.dart';

/// 生成一份剪映草稿：素材落地 + 两份 JSON + 附属文件，一次写完。
///
/// **草稿只生成，不拉起剪映。** 剪映 11.1.0 没有给外部程序「打开指定草稿」
/// 的通道——URL scheme、命令行参数、文档类型、AppleScript、写状态文件、
/// FSEvents 触发全部实测无效，它对外部草稿只认 copy/delete/rename 三个动作。
/// 它的草稿列表靠自己扫描：**启动时必扫**（实测 8 秒内认领），运行中周期扫、
/// 间隔 3~18 分钟不定。所以正确的话术是「草稿已生成，去剪映里打开」，
/// 而不是假装能替用户点开。详见
/// `docs/superpowers/specs/2026-08-26-剪映草稿导出-design.md`。

/// 生成结果
class JianyingDraftResult {
  /// 草稿名（用户要在剪映草稿列表里找的就是它）
  final String name;

  /// 草稿目录绝对路径
  final String folder;

  final int totalMs;
  final int materialCount;

  /// 说得出口的降级（毛玻璃字幕、配乐铺不满等）。**必须显示给用户**
  final List<String> notes;

  const JianyingDraftResult({
    required this.name,
    required this.folder,
    required this.totalMs,
    required this.materialCount,
    this.notes = const [],
  });
}

/// 剪映的本地草稿根目录。Windows 与 macOS 的尾部结构相同，用户根目录不同。
String defaultJianyingRoot({
  String? operatingSystem,
  Map<String, String>? environment,
}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  final env = environment ?? Platform.environment;
  final rootName = os == 'windows' ? 'LOCALAPPDATA' : 'HOME';
  final root = env[rootName]?.trim();
  if (root == null || root.isEmpty) {
    throw StateError('读不到 $rootName，无法定位剪映草稿目录');
  }
  final context = p.Context(
    style: os == 'windows' ? p.Style.windows : p.Style.posix,
  );
  return context.joinAll([
    root,
    if (os != 'windows') 'Movies',
    'JianyingPro',
    'User Data',
    'Projects',
    'com.lveditor.draft',
  ]);
}

/// 剪映在 macOS 上的 app 名（专业版一直叫这个，跟界面上显示的名字不一样）。
///
/// 只是把它拉起来——剪映**没有**「打开指定草稿」的外部通道，草稿名得交代给人，
/// 让他自己去「本地草稿」里点。
const String jianyingAppName = 'VideoFusion-macOS';

String? resolveJianyingExecutable({
  Map<String, String>? environment,
  bool Function(String path)? exists,
  PlatformShell? shell,
}) {
  final env = environment ?? Platform.environment;
  final has = exists ?? (path) => File(path).existsSync();
  final explicit = env['ISHKAFEL_JIANYING_APP']?.trim();
  if (explicit != null && explicit.isNotEmpty && has(explicit)) {
    return explicit;
  }

  final onPath = shell?.lookupOnPath('JianyingPro.exe');
  if (onPath != null && has(onPath)) return onPath;

  final context = p.Context(style: p.Style.windows);
  final candidates = <String>[];
  void addCandidate(String? root, [String? child]) {
    if (root == null || root.trim().isEmpty) return;
    candidates.add(context.joinAll([
      root,
      'JianyingPro',
      ?child,
      'JianyingPro.exe',
    ]));
  }

  addCandidate(env['LOCALAPPDATA']);
  addCandidate(env['LOCALAPPDATA'], 'Apps');
  addCandidate(env['ProgramFiles']);
  addCandidate(env['ProgramFiles(x86)']);
  return candidates.where(has).firstOrNull;
}

Future<void> launchJianying({
  PlatformShell? shell,
  Map<String, String>? environment,
  bool Function(String path)? exists,
}) async {
  final platform = shell ?? PlatformShell();
  if (platform.operatingSystem != 'windows') {
    return platform.launchApplication(macOSName: jianyingAppName);
  }
  final executable = resolveJianyingExecutable(
    environment: environment,
    exists: exists,
    shell: platform,
  );
  if (executable == null) {
    throw StateError(
      '找不到剪映专业版。请先安装剪映，或设置 '
      r'ISHKAFEL_JIANYING_APP=C:\完整路径\JianyingPro.exe',
    );
  }
  return platform.launchApplication(
    macOSName: jianyingAppName,
    windowsExecutable: executable,
  );
}

class JianyingWriter {
  JianyingWriter({
    required this.sourceOf,
    this.voiceOf,
    this.bgmOf,
    String? root,
  }) : root = root ?? defaultJianyingRoot();

  /// 这一镜的本地素材路径；null = 还没就绪
  final String? Function(LineShot shot) sourceOf;

  final String? Function(ScriptLine line)? voiceOf;

  /// 配乐曲子的本地路径；null = 还没下载好
  final String? Function(int materialId)? bgmOf;

  final String root;

  /// 生成草稿。[taskName] 用来给草稿命名。
  ///
  /// [onProgress] 报进度（done/total/在干什么）——超过一两秒的操作必须有交代。
  Future<JianyingDraftResult> write(
    ScriptDoc doc, {
    required String taskName,
    void Function(int done, int total, String what)? onProgress,
  }) async {
    // 1) 先算计划：数据不对在这里就抛，不留半份草稿在磁盘上
    onProgress?.call(0, 1, '正在核对方案');
    final plan = buildJianyingPlan(doc,
        sourceOf: sourceOf, voiceOf: voiceOf, bgmOf: bgmOf);
    return writePlan(plan,
        taskName: taskName, subtitle: doc.subtitle, onProgress: onProgress);
  }

  /// 把算好的计划写成草稿。
  ///
  /// 与 [write] 分开是因为**两条线各算各的计划**：脚本成片从 ScriptDoc 算，
  /// 替换裂变从单元和替换方案算（见 `renew_jianying_plan.dart`），
  /// 但落盘、素材归集、命名这些完全一样，没有理由写两遍。
  Future<JianyingDraftResult> writePlan(
    JianyingPlan plan, {
    required String taskName,
    required SubtitleStyle subtitle,
    void Function(int done, int total, String what)? onProgress,
  }) async {
    if (plan.isEmpty) {
      throw const JianyingPlanException('这一版方案还没有可用的画面，生成不了剪映草稿');
    }

    // 2) 定名：序号递增，不覆盖。剪映打开过草稿就会把它加密，
    //    覆盖只会毁掉用户已经在剪映里做的精修
    final name = _nextName(taskName);
    final folder = p.join(root, name);
    Directory(folder).createSync(recursive: true);

    // 3) 素材落地
    final stager = MaterialStager(p.join(folder, 'materials'));
    final sources = <String>{
      // 所有轨都要收——底轨之外的候选素材同样得跟着工程走
      for (final s in plan.allVideo) s.path,
      for (final s in plan.voice) s.path,
      for (final s in plan.bgm) s.path,
    };
    final staged = <String, String>{};
    var done = 0;
    for (final src in sources) {
      staged[src] = stager.stage(src);
      done++;
      onProgress?.call(done, sources.length, '正在准备素材');
    }

    // 4) 两份 JSON
    onProgress?.call(sources.length, sources.length, '正在写入草稿');
    final json = buildDraftJson(
      plan: plan,
      subtitle: subtitle,
      draftName: name,
      draftFolder: folder,
      draftRoot: root,
      pathOf: (planPath) => staged[planPath] ?? planPath,
      nowSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    _writeJson(p.join(folder, 'draft_info.json'), json.info);
    _writeJson(p.join(folder, 'draft_meta_info.json'), json.meta);
    _writeSidecars(folder, json.draftId);

    return JianyingDraftResult(
      name: name,
      folder: folder,
      totalMs: plan.totalMs,
      materialCount: stager.count,
      notes: json.notes,
    );
  }

  /// `<任务名>_1` / `_2` / `_3`……取第一个没被占用的
  String _nextName(String taskName) {
    final base = 'ishkafel_${_safe(taskName)}';
    for (var n = 1;; n++) {
      final candidate = '${base}_$n';
      if (!Directory(p.join(root, candidate)).existsSync()) return candidate;
    }
  }

  static String _safe(String name) {
    final cleaned =
        name.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_').trim();
    return cleaned.isEmpty
        ? '草稿'
        : (cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned);
  }

  static void _writeJson(String path, Map<String, dynamic> data) =>
      File(path).writeAsStringSync(jsonEncode(data));

  /// 附属文件：即剪也是全套写出来的。缺了剪映会把草稿当残缺的去补，
  /// 补出来的默认值未必是我们要的
  static void _writeSidecars(String folder, String draftId) {
    _writeJson(p.join(folder, 'draft_agency_config.json'), {
      'is_auto_agency_enabled': false,
      'is_auto_agency_popup': false,
      'is_single_agency_mode': false,
      'marterials': null,
      'use_converter': false,
      'video_resolution': 720,
    });
    File(p.join(folder, 'draft_biz_config.json')).writeAsStringSync('');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    File(p.join(folder, 'draft_settings')).writeAsStringSync(
        '[General]\ndraft_create_time=$now\ndraft_last_edit_time=$now\n'
        'real_edit_keys=1\nreal_edit_seconds=0\n');
    _writeJson(p.join(folder, 'draft_virtual_store.json'), {
      'draft_materials': <dynamic>[],
      'draft_virtual_store': [
        {
          'type': 0,
          'value': [
            {
              'creation_time': 0,
              'display_name': '',
              'filter_type': 0,
              'id': '',
              'import_time': 0,
              'import_time_us': 0,
              'sort_sub_type': 0,
              'sort_type': 0,
              'subdraft_filter_type': 0,
            }
          ]
        },
        {'type': 1, 'value': <dynamic>[]},
        {'type': 2, 'value': <dynamic>[]},
      ],
    });
    _writeJson(p.join(folder, 'key_value.json'), <String, dynamic>{});
    _writeJson(p.join(folder, 'performance_opt_info.json'), {
      'manual_cancle_precombine_segs': null,
      'need_auto_precombine_segs': null,
    });
    _writeJson(p.join(folder, 'timeline_layout.json'), {
      'activeTimeline': draftId,
      'dockItems': [
        {
          'dockIndex': 0,
          'ratio': 1,
          'timelineIds': [draftId],
          'timelineNames': ['时间线01'],
        }
      ],
      'layoutOrientation': 1,
    });
  }
}
