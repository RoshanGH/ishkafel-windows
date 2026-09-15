import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../agent_skill/agent_skill_doc.dart';
import '../agent_skill/skill_installer.dart';
import '../app_version.dart';
import '../diagnostics/cli_installer.dart';
import '../log/app_log.dart';
import 'app_updater.dart';
import 'release_manifest.dart';
import 'tos_signer.dart';
import 'update_config.dart';

/// 更新走到哪一步了。界面照着它显示——**每一次等待都要有交代**
sealed class UpdateState {
  const UpdateState();
}

class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

class UpdateChecking extends UpdateState {
  const UpdateChecking();
}

/// 有新版本，等人点
class UpdateAvailable extends UpdateState {
  final ReleaseManifest release;
  const UpdateAvailable(this.release);
}

class UpdateDownloading extends UpdateState {
  final ReleaseManifest release;
  final int received;
  final int total;
  const UpdateDownloading(this.release, this.received, this.total);

  double get ratio => total <= 0 ? 0 : (received / total).clamp(0, 1);
}

/// 下好了、验过了，正在换——马上就会重启
class UpdateInstalling extends UpdateState {
  final ReleaseManifest release;
  const UpdateInstalling(this.release);
}

/// 失败要给原因和重试入口，不能只写日志
class UpdateFailed extends UpdateState {
  final String message;
  const UpdateFailed(this.message);
}

/// **一键升级**：查清单 → 下载 → 校验 → 替换 → 重启。
///
/// 重启之后还有两件这个软件独有的收尾（见 [finishAfterRestart]）：
/// 命令行工具和给 Agent 的说明书都要跟着新版走，**版本不一致会直接出事**
/// ——旧 CLI 调新参数、旧手册教不存在的命令，都撞过。
class UpdateService {
  final AppUpdater updater;
  final Directory workDir;

  /// 当前这个 app 在哪儿。默认从运行中的可执行文件往上找
  final Directory currentApp;

  UpdateService({
    AppUpdater? updater,
    Directory? workDir,
    Directory? currentApp,
  }) : updater = updater ?? AppUpdater(),
       workDir =
           workDir ??
           Directory(p.join(Directory.systemTemp.path, 'ishkafel_update')),
       currentApp = currentApp ?? _runningApp();

  /// `<app>/Contents/MacOS/ishkafel` → `<app>`
  static Directory _runningApp() => runningAppFrom(Platform.resolvedExecutable);

  static Directory runningAppFrom(
    String executable, {
    String? operatingSystem,
  }) {
    final os = operatingSystem ?? Platform.operatingSystem;
    final context = p.Context(
      style: os == 'windows' ? p.Style.windows : p.Style.posix,
    );
    final executableDir = context.dirname(executable);
    if (os == 'windows') return Directory(executableDir);
    return Directory(context.dirname(context.dirname(executableDir)));
  }

  TosSigner get _signer => const TosSigner(
    accessKey: UpdateConfig.accessKey,
    secretKey: UpdateConfig.secretKey,
    region: UpdateConfig.region,
    bucket: UpdateConfig.bucket,
    endpoint: UpdateConfig.endpoint,
  );

  /// 查一次。**查不到就当没有新版本**——网络不通不该弹一个错误框吓人
  Future<ReleaseManifest?> check({
    Future<String?> Function(String url)? fetch,
    String current = appVersion,
  }) async {
    if (!UpdateConfig.enabled) return null;
    try {
      // 清单也私有：用同一对只读凭据换一条短效链接。有效期给得很短——
      // 它只是拿来读一次的
      final url = _signer.presignGet(
        UpdateConfig.manifestKey,
        ttl: const Duration(minutes: 5),
      );
      final raw = await (fetch ?? _fetch)(url);
      if (raw == null) return null;
      final m = ReleaseManifest.tryParse(raw);
      if (m == null) {
        AppLog.warn('更新清单读不懂，当作没有新版本');
        return null;
      }
      return isNewerVersion(m.version, current) ? m : null;
    } catch (e) {
      AppLog.info('查更新失败（不打扰用户）：$e');
      return null;
    }
  }

  static Future<String?> _fetch(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final res = await (await client.getUrl(Uri.parse(url))).close();
      if (res.statusCode != HttpStatus.ok) return null;
      return await res.transform(const SystemEncoding().decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  /// 下载并装上。装完这个进程就该退出了（[onExit] 由调用方给）。
  ///
  /// 每一步失败都**说清原因**并停下——绝不带着一个校验没过的包往下走
  Future<void> install(
    ReleaseManifest release, {
    required void Function(UpdateState) onState,
    required Future<void> Function() onExit,
  }) async {
    try {
      if (!updater.canReplace(currentApp)) {
        onState(
          UpdateFailed(
            '没有权限替换「${currentApp.path}」。'
            '把 app 拖到「应用程序」里再试，或者让管理员来装。',
          ),
        );
        return;
      }
      if (workDir.existsSync()) workDir.deleteSync(recursive: true);
      workDir.createSync(recursive: true);

      final url = _signer.presignGet(release.objectKey);
      final zip = File(p.join(workDir.path, p.basename(release.objectKey)));
      onState(UpdateDownloading(release, 0, release.sizeBytes));
      await updater.download(
        url,
        zip,
        onProgress: (got, total) => onState(
          UpdateDownloading(
            release,
            got,
            total > 0 ? total : release.sizeBytes,
          ),
        ),
      );

      onState(UpdateInstalling(release));
      await updater.verifySha256(zip, release.sha256);
      final app = await updater.unpack(
        zip,
        Directory(p.join(workDir.path, 'unpacked')),
      );
      await updater.verifySignature(app);

      await updater.handOff(
        newApp: app,
        currentApp: currentApp,
        workDir: workDir,
      );
      await onExit();
    } on UpdateException catch (e) {
      onState(UpdateFailed(e.message));
    } catch (e) {
      onState(UpdateFailed('更新失败：$e'));
    }
  }

  /// **升级之后的收尾**：让随包走的两样东西跟上新版本。
  ///
  /// - 命令行工具：装的是一个指向 app 内 CLI 的 shim。app 换了路径它就失效，
  ///   路径没变也重写一次（幂等、便宜），省得出现「app 是新的、命令是旧的」
  /// - 给 Agent 的说明书：那是**复制出去的文件**，不重装永远是旧的。
  ///   Agent 照着旧手册调新命令，报错还查不出为什么
  ///
  /// 返回一句要给人看的话；null = 没什么好说的。
  ///
  /// **失败也要说**：说明书没装上却不吭声，人以为已经是新的，
  /// 于是 Agent 照着旧手册调新命令——报错还查不到根因上
  Future<String?> finishAfterRestart() async {
    var skillUpdated = false;
    final problems = <String>[];
    try {
      final cli = CliInstaller.forRunningApp();
      final status = cli.inspect();
      // 装过的才重写。**stale 也要重写**——那正是「app 换了位置、
      // shim 还指着旧路径」的样子，升级路径上最容易出现
      if (status == CliStatus.installed || status == CliStatus.stale) {
        await cli.install();
        AppLog.info('升级收尾：命令行工具已指向新版本');
      }
    } catch (e) {
      AppLog.warn('升级收尾：重装命令行工具失败：$e');
      problems.add('命令行工具没更新成（设置 → 运行环境里可以手动重装）');
    }
    try {
      final skill = SkillInstaller.forCurrentUser(
        markdown: agentSkillMarkdown,
        version: appVersion,
      );
      final status = skill.inspect();
      // **只给已经装过的人更新**：没装过说明他不用 Agent，
      // 升级时替他往家目录里塞文件是多管闲事
      if (status.outdated.isNotEmpty) {
        await skill.install();
        skillUpdated = true;
        AppLog.info('升级收尾：说明书已更新到 $appVersion');
      }
    } catch (e) {
      AppLog.warn('升级收尾：重装说明书失败：$e');
      problems.add('Agent 说明书没更新成（设置 → 运行环境里可以手动重装）');
    }
    if (problems.isNotEmpty) return problems.join('；');
    if (skillUpdated) {
      return '说明书已更新到这一版——让 Codex / Claude Code 重新加载一次技能，'
          '免得它照着旧手册调新命令。';
    }
    return null;
  }
}
