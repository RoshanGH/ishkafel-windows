import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/agent_skill/skill_installer.dart';
import 'package:ishkafel/core/platform/platform_paths.dart';
import 'package:path/path.dart' as p;

/// 把说明书装进 Agent 的用户级技能目录。
///
/// **为什么是用户级而不是工作目录**：`AGENTS.md` 跟着「文件夹」走，描述的是
/// 「你现在干活的这个目录是怎么回事」。工具怎么用跟目录无关——使用者在哪个
/// 文件夹干活都该生效，所以装到 `~/.claude/skills/` 这类地方。
/// miaoa 就是这么做的。
void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('skill_installer'));
  tearDown(() => home.deleteSync(recursive: true));

  SkillInstaller make({String version = '9.9.9'}) => SkillInstaller(
    targets: [
      SkillTarget(
        agent: 'Claude Code',
        dir: Directory(p.join(home.path, '.claude', 'skills')),
      ),
      SkillTarget(
        agent: 'Codex',
        dir: Directory(p.join(home.path, '.codex', 'skills')),
      ),
    ],
    markdown: '# 用法\n\n跑 ishkafel --help。\n',
    version: version,
  );

  test('Windows 默认安装到 USERPROFILE，而不是当前工作目录', () {
    final installer = SkillInstaller.forCurrentUser(
      markdown: '# 用法',
      version: '1.0.0',
      paths: PlatformPaths(
        operatingSystem: 'windows',
        environment: const {
          'USERPROFILE': r'D:\用户\阿明',
          'APPDATA': r'D:\应用数据',
          'LOCALAPPDATA': r'D:\本地应用数据',
          'TEMP': r'D:\临时',
        },
        windowsKnownFolder: (_) => null,
      ),
    );

    expect(
      installer.targets.first.dir.path,
      p.join(r'D:\用户\阿明', '.claude', 'skills'),
    );
    expect(
      installer.targets.last.dir.path,
      p.join(r'D:\用户\阿明', '.codex', 'skills'),
    );
  });

  File written(String agentDir) =>
      File(p.join(home.path, agentDir, 'skills', 'ishkafel', 'SKILL.md'));

  group('装', () {
    test('两个 Agent 各写一份，目录不存在就建出来', () async {
      final result = await make().install();
      expect(result.ok, isTrue);
      expect(written('.claude').existsSync(), isTrue);
      expect(written('.codex').existsSync(), isTrue);
      expect(result.message, contains('Claude Code'));
      expect(result.message, contains('Codex'));
    });

    test('带 frontmatter，且 description 要能让 Agent 判断什么时候该用', () async {
      await make().install();
      final body = written('.claude').readAsStringSync();

      expect(body, startsWith('---\n'));
      expect(body, contains('name: ishkafel'));
      // 只写「ishkafel 的使用说明」的话，Agent 不知道什么场景该想起它
      expect(body, contains('description:'));
      expect(body, contains('替换裂变'));
      expect(body, contains('# 用法'), reason: '正文要原样带上');
    });

    test('写进版本号——将来要靠它判断手上这份是不是旧的', () async {
      await make(version: '1.2.3').install();
      expect(written('.claude').readAsStringSync(), contains('1.2.3'));
    });

    test('重复装是覆盖，不是追加', () async {
      await make().install();
      await make().install();
      final body = written('.claude').readAsStringSync();
      expect('name: ishkafel'.allMatches(body), hasLength(1));
    });
  });

  group('看状态', () {
    test('没装过', () {
      expect(make().inspect().installed, isEmpty);
      expect(make().inspect().outdated, isEmpty);
    });

    test('装的就是当前版本', () async {
      await make(version: '1.0.0').install();
      final status = make(version: '1.0.0').inspect();
      expect(status.installed.map((t) => t.agent), ['Claude Code', 'Codex']);
      expect(status.outdated, isEmpty);
      expect(status.allCurrent, isTrue);
    });

    test('app 升级过，手上那份是旧的——要说出来并让他重装', () async {
      // 说明书跟着工具版本走。旧副本会让 Agent 照着旧文档调新命令
      await make(version: '1.0.0').install();
      final status = make(version: '2.0.0').inspect();
      expect(status.outdated.map((t) => t.agent), ['Claude Code', 'Codex']);
      expect(status.allCurrent, isFalse);
    });

    test('只装了一个 Agent 时如实分开报', () async {
      await make().install();
      written('.codex').deleteSync();
      final status = make().inspect();
      expect(status.installed.map((t) => t.agent), ['Claude Code']);
      expect(status.missing.map((t) => t.agent), ['Codex']);
    });
  });

  group('卸', () {
    test('两份都删掉', () async {
      await make().install();
      expect(await make().uninstall(), 2);
      expect(written('.claude').existsSync(), isFalse);
      expect(written('.codex').existsSync(), isFalse);
    });
  });
}
