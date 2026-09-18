import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/miaoa/miaoa_tag_service.dart';
import '../../../core/models/project_ref.dart';
import '../../../core/models/tag_group_ref.dart';
import '../../../core/platform/windows_video_picker.dart';
import '../../settings/settings_providers.dart';

/// 新建任务向导的产物：成片来源 + 两层打标各自的标签组。
///
/// 三项都是必填——缺任何一项都会让后续阶段②「按相同标签检索候选素材」拿不
/// 到检索键，所以向导在选齐之前不放行（见 `new_task_wizard.dart` 的禁用理由）。
class NewTaskWizardResult {
  /// 原片路径。**为 null 表示「不用原片，从素材拼」**——分子手动加、
  /// 标签手动填，只靠标签检索素材
  final String? filePath;
  /// 两层各自可以选多个标签组，标签合并成一份受控词表
  final List<TagGroupRef> unitTagGroups;
  final List<TagGroupRef> shotTagGroups;

  /// 两层各自的打标约束（一层一条，不随选了几个组变化）
  final String unitTagPrompt;
  final String shotTagPrompt;

  /// 在哪个项目里找素材；null 表示不限项目
  final ProjectRef? project;

  /// 选了「脚本成片」这一路（filePath 一定为 null）：以脚本行为根，
  /// 建完进编导台
  final bool script;

  NewTaskWizardResult({
    this.filePath,
    this.script = false,
    required List<TagGroupRef> unitTagGroups,
    required List<TagGroupRef> shotTagGroups,
    this.unitTagPrompt = '',
    this.shotTagPrompt = '',
    this.project,
  })  : unitTagGroups = List.unmodifiable(unitTagGroups),
        shotTagGroups = List.unmodifiable(shotTagGroups);
}

/// 选择本地成片文件，返回路径；用户取消时返回 null
typedef VideoFilePicker = Future<String?> Function();

/// 真实实现：系统文件选择框，只接受 mp4 / mov
Future<String?> pickLocalVideoFile({WindowsVideoPicker? windowsPicker}) async {
  if (Platform.isWindows) {
    if (windowsPicker == null) {
      throw const VideoPickerException('应用数据目录尚未就绪，请稍后重试。');
    }
    return windowsPicker.pick();
  }
  const typeGroup = XTypeGroup(label: '视频', extensions: ['mp4', 'mov']);
  final file = await openFile(acceptedTypeGroups: const [typeGroup]);
  return file?.path;
}

/// widget 测试用假实现覆盖，避免弹出真实系统文件框
final windowsVideoPickerProvider = Provider<WindowsVideoPicker?>((ref) {
  if (!Platform.isWindows) return null;
  final data = ref.watch(dataDirProvider);
  if (data == null) return null;
  final picker = WindowsVideoPicker(
    tempRoot: Directory(p.join(data.path, 'tmp', 'video-picker')),
  );
  ref.onDispose(picker.cancel);
  return picker;
});

final videoFilePickerProvider = Provider<VideoFilePicker>((ref) =>
    () => pickLocalVideoFile(windowsPicker: ref.read(windowsVideoPickerProvider)));

/// 其他平台继续使用系统模态选择框；Windows 提供可由主窗口终止的独立进程。
final videoFilePickerCancelProvider = Provider<void Function()?>((ref) =>
    ref.watch(windowsVideoPickerProvider)?.cancel);

/// miaoa 标签体系读取入口。
///
/// 默认构造不会启动任何子进程（只有真正调用 listGroups/listTags 时才 exec），
/// 所以在这里给真实实现是安全的；单测一律 override 成注入假 ProcessRunner 的
/// 实例，绝不碰真实 CLI。
final miaoaTagServiceProvider = Provider<MiaoaTagService>(
    (ref) => MiaoaTagService());
