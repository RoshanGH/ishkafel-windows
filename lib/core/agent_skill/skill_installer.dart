import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/platform_paths.dart';

/// 一个 Agent 的用户级技能目录。
///
/// **用户级，不是工作目录级**：`AGENTS.md` 那类文件跟着「文件夹」走，说的是
/// 「你现在干活的这个目录是怎么回事」；而「这个工具怎么用」跟目录无关——
/// 使用者在哪个文件夹干活都该生效。所以装到 `~/.claude/skills/` 这种地方。
class SkillTarget {
  /// 界面上怎么称呼它
  final String agent;

  /// 技能目录，例如 `~/.claude/skills`
  final Directory dir;

  const SkillTarget({required this.agent, required this.dir});

  File get file => File(p.join(dir.path, SkillInstaller.skillName, 'SKILL.md'));
}

class SkillStatus {
  /// 装了且是当前版本
  final List<SkillTarget> installed;

  /// 装了但是旧版本
  final List<SkillTarget> outdated;

  /// 没装
  final List<SkillTarget> missing;

  const SkillStatus({
    required this.installed,
    required this.outdated,
    required this.missing,
  });

  bool get allCurrent => missing.isEmpty && outdated.isEmpty;
  bool get anyPresent => installed.isNotEmpty || outdated.isNotEmpty;
}

class SkillInstallResult {
  final bool ok;
  final String message;

  const SkillInstallResult({required this.ok, required this.message});
}

/// 把给 Agent 的操作手册装进各家 Agent 的用户级技能目录。
///
/// 这一步补的是最后一个缺口：使用者装了 app、装了命令行工具，Agent 有了
/// 「能调什么」，还缺「怎么用才做得出能用的片子」。
class SkillInstaller {
  static const skillName = 'ishkafel';

  final List<SkillTarget> targets;

  /// 手册正文（编在二进制里，见 tool/gen_agent_skill.dart）
  final String markdown;

  /// 当前 app 版本。写进文件里，将来能判断手上那份是不是旧的
  final String version;

  const SkillInstaller({
    required this.targets,
    required this.markdown,
    required this.version,
  });

  /// 按当前用户的家目录组装默认目标
  factory SkillInstaller.forCurrentUser({
    required String markdown,
    required String version,
    String? home,
    PlatformPaths? paths,
  }) {
    final base = home ?? paths?.userHome ?? PlatformPaths().userHome;
    return SkillInstaller(
      markdown: markdown,
      version: version,
      targets: [
        SkillTarget(
          agent: 'Claude Code',
          dir: Directory(p.join(base, '.claude', 'skills')),
        ),
        SkillTarget(
          agent: 'Codex',
          dir: Directory(p.join(base, '.codex', 'skills')),
        ),
      ],
    );
  }

  SkillStatus inspect() {
    final installed = <SkillTarget>[];
    final outdated = <SkillTarget>[];
    final missing = <SkillTarget>[];
    for (final target in targets) {
      if (!target.file.existsSync()) {
        missing.add(target);
        continue;
      }
      String body;
      try {
        body = target.file.readAsStringSync();
      } catch (_) {
        missing.add(target);
        continue;
      }
      // 说明书跟着工具版本走：旧副本会让 Agent 照着旧文档调新命令，
      // 报错还不知道为什么
      (body.contains(_versionLine) ? installed : outdated).add(target);
    }
    return SkillStatus(
      installed: installed,
      outdated: outdated,
      missing: missing,
    );
  }

  Future<SkillInstallResult> install() async {
    final done = <String>[];
    final failed = <String>[];
    for (final target in targets) {
      try {
        target.file.parent.createSync(recursive: true);
        target.file.writeAsStringSync(_skillFile());
        // 带上具体路径：Agent 装完要把路径回报给用户，这是验收信号
        done.add('${target.agent} → ${target.file.path}');
      } catch (e) {
        failed.add('${target.agent}（$e）');
      }
    }
    if (done.isEmpty) {
      return SkillInstallResult(
        ok: false,
        message: '一个都没装上：${failed.join('、')}',
      );
    }
    final note = failed.isEmpty ? '' : '；没装上：${failed.join('、')}';
    return SkillInstallResult(
      ok: failed.isEmpty,
      message: '技能已装到：\n${done.join('\n')}$note',
    );
  }

  /// 删掉装过的那些，返回删了几份
  Future<int> uninstall() async {
    var removed = 0;
    for (final target in targets) {
      if (!target.file.existsSync()) continue;
      try {
        target.file.deleteSync();
        final dir = target.file.parent;
        if (dir.listSync().isEmpty) dir.deleteSync();
        removed++;
      } catch (_) {}
    }
    return removed;
  }

  String get _versionLine => '<!-- ishkafel-skill $version -->';

  /// 说明书的完整文本（带 frontmatter）。
  ///
  /// **这是最通用的分发方式**：装进技能目录只对认那个目录的 Agent 有用
  /// （Claude Code、Codex 各有各的位置），而 Warp、Cursor、各家桌面版、
  /// 明天冒出来的新工具都不一样，穷举不完。底下那层是通的——把文本给它。
  String get markdownForSharing => _skillFile();

  /// frontmatter 里的 `description` 决定 Agent **什么时候会想起用它**。
  ///
  /// 只写「替换裂变」是**写窄了**：这个工具还能从台词直接造一条新片
  /// （编导台那条线，不需要原片）。描述里不写，用户说「帮我做条口播
  /// 视频」时 Agent 根本不会联想过来——能力再全也白搭。
  static String describeForFrontmatter() =>
      '用 ishkafel 做**竖屏口播短视频**：台词决定时间、画面填进去。'
      '两条线——**替换裂变**（拿一条现成的片子，保持台词与结构不变、'
      '把画面全换成新素材，产出若干条结构相同但画面全新的视频）；'
      '**脚本成片**（从台词开始造一条新片：写台词或从参考片提取、'
      '生成配音、给每句配画面、铺配乐、导出，不需要原片）。'
      '当用户提到替换裂变、换画面、换分镜、替换素材、批量出片，'
      '或者写口播稿、做口播视频、按脚本出片、仿一条片子重做，'
      '或直接点名 ishkafel 时使用。'
      '也覆盖导入、语义切分与打标、挑素材、配音、断句上字幕、'
      '导出成片、写成剪映草稿这些具体做法。';

  String _skillFile() =>
      '''---
name: $skillName
description: >-
  ${describeForFrontmatter()}
---

$_versionLine

$markdown''';
}
