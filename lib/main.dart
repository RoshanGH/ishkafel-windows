import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'core/audio/material_vocal_cache.dart';
import 'features/workbench/preview_tracks.dart';
import 'core/audio/vocal_separator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'app/app.dart';
import 'core/ai/ai_credentials.dart';
import 'core/ai/volcano_asr_provider.dart';
import 'core/audio/bgm_cache_factory.dart';
import 'core/storage/media_migration.dart';
import 'core/storage/task_media.dart';
import 'core/ffmpeg/ffprobe_service.dart';
import 'core/ffmpeg/process_runner.dart';
import 'core/ffmpeg/thumbnail_service.dart';
import 'app/flutter_error_bridge.dart';
import 'app/service_wiring.dart';
import 'core/script/script_service_wiring.dart';
import 'features/director/director_providers.dart';
import 'cli/commands/open_command.dart';
import 'core/log/app_log.dart';
import 'core/miaoa/miaoa_account_service.dart';
import 'core/diagnostics/tool_installer.dart';
import 'core/miaoa/miaoa_auth_service.dart';
import 'core/diagnostics/environment_report.dart';
import 'core/storage/cache_usage.dart';
import 'core/storage/task_artifacts.dart';
import 'core/storage/file_task_repository.dart';
import 'features/import_flow/import_service.dart';
import 'features/settings/settings_providers.dart';
import 'features/tasks/environment_banner.dart';
import 'features/tasks/task_artifact_cleaner.dart';
import 'features/tasks/task_list_controller.dart';
import 'features/workbench/voice_swap_runner.dart';
import 'features/export/export_dialog.dart';
import 'core/ai/frame_check_wiring.dart';
import 'features/picking/picking_providers.dart';
import 'features/workbench/bgm_picker_sheet.dart';
import 'core/miaoa/material_downloader.dart';
import 'core/export/export_runner.dart';
import 'core/miaoa/miaoa_content_service.dart';
import 'core/subtitle/subtitle_renderer_entry.dart';

@pragma('vm:entry-point')
Future<void> subtitleRendererMain(List<String> args) =>
    runSubtitleRenderer(args);

/// 素材人声分离器。预览与导出共用一份缓存目录，同一条素材只分离一次
/// 人声分离结果落在**这个任务名下**（`vocals/<taskId>/`）：
/// 派生产物也按项目存，删任务时一起走
MaterialVocalCache materialVocals(Directory dataDir, String taskId) =>
    MaterialVocalCache(
      separator: VocalSeparator(
        extractAudio: extractAudioForSeparation,
        binary: resolveVocalSeparatorBinary(),
        modelDir: Directory(p.join(dataDir.path, 'separator_models')),
      ),
      cacheDir: TaskMedia(dataDir: dataDir, taskId: taskId).vocalsDir,
    );

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // 尽早接管：框架异常默认经 debugPrint 输出，真机直接跑二进制时不可见
  installFlutterErrorForwarding();
  MediaKit.ensureInitialized();
  final supportDir = await getApplicationSupportDirectory();
  AppLog.startFileLogging(Directory(p.join(supportDir.path, 'logs')));
  AppLog.info('应用启动；日志目录：${p.join(supportDir.path, 'logs')}');
  final dataDir = Directory(p.join(supportDir.path, 'ishkafel_data'));
  final repository = FileTaskRepository(dataDir);
  final coversDir = Directory(p.join(dataDir.path, 'covers'));
  final artifactCleaner = FileTaskArtifactCleaner(dataDir: dataDir);
  final importService = ImportService(
    repository: repository,
    ffprobe: FfprobeService(),
    thumbnails: ThumbnailService(),
    coversDir: coversDir,
  );

  // 两个位置都找：开发期从项目目录跑 `flutter run` 用前者；双击启动的
  // app 工作目录是 `/`，只能靠后者（打包版更常见的是 --dart-define 注入，
  // 见 scripts/build_macos.sh，那条路径优先级最高）
  final credentials = CredentialsLoader.load(
    secretsDirs: [
      Directory('${Directory.current.path}/.secrets'),
      Directory('${dataDir.path}/credentials'),
    ],
  );
  final analysisPipeline = buildAnalysisPipeline(credentials, dataDir);

  // 启动期预检 ffmpeg/ffprobe：GUI 进程 PATH 不含 Homebrew 目录，
  // 缺失时列表页常驻横幅引导安装，而不是等用户导入时撞见子进程异常
  // 结果不接住：真正读它的是 mediaToolsStatusProvider（每次重算，见下面的
  // override）。这里跑一遍是为了**开机就在日志里留下缺哪个工具**，
  // 排查问题时不用等用户点进设置页
  sharedMediaToolsLocator.preflight();

  // 开机扫一遍孤儿产物。删任务时清干净只解决一半问题——崩溃、手动删存档、
  // 开发期换机器总会留下没主的东西，它们只会一直躺在盘上占地方
  // 先迁移再清扫：物料从共享缓存搬到各任务名下。
  // 顺序不能反——清扫认的是新布局，先扫会把还在共享目录里的素材当孤儿删掉
  try {
    final migrated = await migrateSharedMediaToTasks(dataDir);
    if (migrated.didSomething) {
      AppLog.info(
        '物料已按任务归位：搬 ${migrated.moved} 个、'
        '清掉 ${migrated.orphansRemoved} 个没人引用的',
      );
    }
  } catch (e) {
    // 迁移失败不能挡启动：下次再迁，共享目录还在，数据不会丢
    AppLog.warn('物料迁移失败（下次启动再试）：$e');
  }
  // **清孤儿不挡首屏**：它要把全部任务读一遍、再扫一遍产物目录，
  // 盘上东西多的时候是好几百毫秒的纯 IO——挡在 runApp 前面，人点了图标
  // 只能对着 Dock 上跳动的图标等（2026-09-09 性能走查）。
  // 这活儿纯粹是维护性的：删的都是没人引用的东西，晚几秒开始不影响任何
  // 正在用的数据。**注意跟上面的迁移不同**，迁移会改素材的落地位置，
  // 那个必须在 UI 读到路径之前做完，不能挪。
  unawaited(_sweepOrphans(repository, dataDir));

  // `ishkafel open <task>` 会带 --task=<id> 把 app 拉起来。CLI 写、GUI 读，
  // 两边对同一个约定（见 open_command.dart）
  final initialTaskId = initialTaskIdFrom(args);

  runApp(
    ProviderScope(
      overrides: [
        initialTaskIdProvider.overrideWithValue(initialTaskId),
        taskRepositoryProvider.overrideWithValue(repository),
        importServiceProvider.overrideWithValue(importService),
        analysisPipelineProvider.overrideWithValue(analysisPipeline),
        // 编导台「从视频提取脚本」：凭据齐了才给实例，否则入口禁用并说明
        scriptTranscriberProvider.overrideWithValue(
          buildScriptTranscriber(credentials, dataDir),
        ),
        // 编导台「生成配音」：同上，语音凭据齐了才有
        lineVoiceFactoryProvider.overrideWithValue(
          defaultLineVoiceFactory(credentials, dataDir),
        ),
        // 配音要带上「参考片这一句是怎么念的」：不接这一步，预置音色只会用
        // 默认语气平铺直叙（用户反馈：原片在激动地争吵，复刻出来情绪扁平）
        lineDeliveryFactoryProvider.overrideWithValue(
          defaultLineDeliveryFactory(credentials, dataDir),
        ),
        // 编导台「自动打标」：方舟凭据齐了才有
        lineTaggerProvider.overrideWithValue(buildLineTagger(credentials)),
        // 参考视觉镜头打标（多帧 vision：标签 + 画面描述）
        refShotTaggerProvider.overrideWithValue(
          buildRefShotTagger(credentials),
        ),
        // 挑中素材时顺手看一眼首帧图：烧没烧字、露的是谁家产品
        // ——一次调用问两件事，只对挑中的那几条跑
        frameCheckerProvider.overrideWithValue(buildFrameChecker(credentials)),
        // 编导台：素材落地后看一眼画面（烧字 + 产品露出品牌）。
        // 装配在 core，命令行那头共用同一份
        shotFrameCheckFactoryProvider.overrideWithValue(
          (dir, taskId) => buildShotFrameCheck(
            arkApiKey: credentials.arkApiKey,
            dataDir: dir,
            taskId: taskId,
          ),
        ),
        // **用 overrideWith 而不是 overrideWithValue**：横幅和「能否开工」都读它，
        // 存成一个启动时算好的值的话，用户装好 ffmpeg 后横幅不消失、功能也不
        // 恢复，只能重启 app。这样写才能在清掉未命中缓存后 invalidate 重算
        mediaToolsStatusProvider.overrideWith(
          (ref) => sharedMediaToolsLocator.preflight(),
        ),
        taskArtifactCleanerProvider.overrideWithValue(artifactCleaner),
        // 设置页：扫描/体检都用真实目录与真实进程，注入点集中在这里
        cacheScannerProvider.overrideWithValue(CacheScanner(dataDir: dataDir)),
        environmentProbeProvider.overrideWithValue(
          defaultEnvironmentProbe(
            resolveMediaTools: sharedMediaToolsLocator.preflight,
            credentials: credentials,
          ),
        ),
        miaoaAccountServiceProvider.overrideWithValue(MiaoaAccountService()),
        miaoaAuthServiceProvider.overrideWithValue(MiaoaAuthService()),
        toolInstallerProvider.overrideWithValue(ToolInstaller()),
        dataDirProvider.overrideWithValue(dataDir),
        // 「生成配音」：凭据齐了才给工厂，否则工作台把按钮禁用并说明原因，
        // 而不是让用户点了之后撞一个网络错误
        // 听一段上传的配音说了什么：和命令行那条路同一份实现
        voiceWordsProvider.overrideWithValue(
          credentials.speechAppId.isEmpty
              ? null
              : (audio) => transcribeVoiceWords(
                  VolcanoAsrProvider(
                    appId: credentials.speechAppId,
                    accessToken: credentials.speechAccessToken,
                  ),
                  audio,
                ),
        ),
        voiceSwapFactoryProvider.overrideWithValue(
          defaultVoiceSwapFactory(credentials: credentials, dataDir: dataDir),
        ),
        // 矩阵导出：真实 ffmpeg + 真实下载。素材缓存按任务分目录，
        // 清理缓存时能整目录带走
        // 预览音轨：与导出共用同一个混音器，听到的就是要交付的
        // 选中配乐就把它下到本地：和预览/导出读同一份缓存
        bgmFetcherProvider.overrideWithValue(
          (taskId, m) => bgmCache(dataDir, taskId).fetch(m),
        ),
        // 挑素材时就把本体下到本地：和导出读同一个缓存目录，导出时不必再下
        materialFetcherProvider.overrideWithValue(
          (taskId, id) => MaterialDownloader(
            content: MiaoaContentService(),
            cacheDir: TaskMedia(dataDir: dataDir, taskId: taskId).materialsDir,
          ).fetch(id),
        ),
        // 预览与导出共用同一份素材人声：听到的就是要交付的
        // （工具没装时 vocalsOf 一律返回 null，界面据此如实说明）
        materialSeparatorProvider.overrideWithValue(
          (taskId, path) => materialVocals(dataDir, taskId).vocalsOf(path),
        ),
        exportRunnerFactoryProvider.overrideWithValue(
          (taskId, subtitle) => ExportRunner(
            run: const ResolvingProcessRunner().call,
            subtitleStyle: subtitle,
            workDir: Directory(p.join(dataDir.path, 'export_work', taskId)),
            resolveBgm: bgmCache(dataDir, taskId).fetch,
            // 整体替换的段落铺了配乐时，用素材的纯人声——否则素材自带的
            // 背景音和新配乐两首曲子一起响
            separateMaterial: materialVocals(dataDir, taskId).vocalsOf,
            // 镜头替换要按候选的真实时长算变速倍率
            probeDurationMs: (path) async => (await FfprobeService(
              run: const ResolvingProcessRunner().call,
            ).probe(path)).duration.inMilliseconds,
            fetchMaterial: MaterialDownloader(
              content: MiaoaContentService(),
              cacheDir: TaskMedia(
                dataDir: dataDir,
                taskId: taskId,
              ).materialsDir,
            ).fetch,
          ),
        ),
      ],
      child: const IshkafelApp(),
    ),
  );
}

/// 清掉归属不到任何现存任务的产物。
///
/// 失败不阻断启动：读不出任务清单时**一个都不删**——宁可留着占地方，
/// 也不能因为清单是空的就把用户所有素材当孤儿清了。
Future<void> _sweepOrphans(
  FileTaskRepository repository,
  Directory dataDir,
) async {
  try {
    final tasks = await repository.findAll();
    final artifacts = TaskArtifacts(dataDir);
    // 无主的 + 用完即弃的。后者归属得到现存任务，只靠孤儿判定永远清不掉
    final junk = [
      ...artifacts.orphans({for (final t in tasks) t.id}),
      ...artifacts.transients(),
    ];
    if (junk.isEmpty) return;
    final freed = artifacts.delete(junk);
    AppLog.info('启动清理：${junk.length} 项无用产物，释放 ${formatBytes(freed)}');
  } catch (e) {
    AppLog.warn('启动清理孤儿产物失败，跳过：$e');
  }
}

/// 凭据完整时组装真实分析管线；不完整时返回 null（导入后跳过自动分析）。
///
/// 两层打标在这里接通：taggers 走同一个 Ark 客户端（无状态，可共享），
/// 受控词表走 [MiaoaTagVocabularySource]——按**任务自己选的**标签组现取，
