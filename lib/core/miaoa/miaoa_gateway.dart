import 'dart:convert';
import 'dart:io';

import '../ffmpeg/process_runner.dart';
import '../log/app_log.dart';
import 'miaoa_errors.dart';
import 'miaoa_exception.dart';
import 'miaoa_failure.dart';
import 'miaoa_locator.dart';

/// 全 app **唯一**的 miaoa 子进程出入口。
///
/// 为什么必须唯一：可执行文件怎么找（GUI 进程的 PATH 不含 ~/.local/bin）、
/// 失败怎么分类（401 是「去重新登录」、断网是「重试」）——这两件事只要存在
/// 第二份实现，就会有一份漏掉修复。「素材面板误报未找到 miaoa 而设置页正常」
/// 那个 bug 的根因就是每个服务各自拿路径、各自起子进程。
///
/// 边界由架构测试看守（test/architecture/miaoa_boundary_test.dart）：
/// 除本文件外，lib/ 里不允许再出现 miaoa 子进程的直接调用。
class MiaoaGateway {
  final ProcessRunner _run;

  /// 已解析的可执行文件路径（测试注入裸名即可）
  final String binary;

  MiaoaGateway({ProcessRunner? run, String? binary})
      : _run = run ?? systemProcessRunner,
        binary = binary ?? resolveMiaoaBinary();

  /// 执行一条 miaoa 命令，成功返回 stdout 文本。
  ///
  /// 任何失败都抛 [MiaoaException]：kind 已分类、message 是可照做的中文。
  /// [what] 用于日志与兜底文案，如「读取标签组」。
  Future<String> text(List<String> args, {required String what}) async {
    final result = await raw(args);
    if (result.exitCode != 0) {
      throw miaoaExitException(
          result.exitCode, _text(result.stdout), _text(result.stderr), what);
    }
    return _text(result.stdout);
  }

  /// 低层入口：只保证「子进程一定起得来或抛已分类异常」，退出码交给调用方。
  ///
  /// 给登录/账号这类要自行解读退出码与报文的流程用（CLI 可能退出码 0
  /// 却在 JSON 里说没成）。其余场景一律用 [text]。
  Future<ProcessResult> raw(List<String> args) async {
    try {
      return await _run(binary, args);
    } on ProcessException catch (_) {
      throw MiaoaException(missingToolMessage('miaoa'),
          kind: MiaoaFailureKind.cliMissing);
    } on MediaToolMissingException catch (_) {
      throw MiaoaException(missingToolMessage('miaoa'),
          kind: MiaoaFailureKind.cliMissing);
    }
  }

  /// 诊断用：解析到的 miaoa 安装路径；没装（回退裸名）时为 null。
  /// 环境报告页显示它，让「装在哪」有一个和实际调用一致的答案
  static String? installedPath() {
    final resolved = resolveMiaoaBinary();
    return resolved == 'miaoa' ? null : resolved;
  }

  /// 子进程输出既可能是 String，也可能是 `List<int>`（取决于 stdoutEncoding）
  static String _text(Object? out) {
    if (out is String) return out;
    if (out is List<int>) return utf8.decode(out, allowMalformed: true);
    return '';
  }
}

/// 非零退出码 → 已分类异常。这是**唯一一份**「miaoa 报错 → 用户动作」的翻译。
MiaoaException miaoaExitException(
    int exitCode, String stdout, String stderr, String what) {
  final errText = miaoaErrorText(stdout, stderr);
  // 项目越权：CLI 校验 --projects 不在「我的项目」内时以退出码 2 拒绝。
  // 单独说——用户能做的是换个项目，而不是重试或重新登录
  if (errText.contains('我的项目')) {
    return const MiaoaException('所选项目不在你可用的项目范围内，请在标签组设置里换一个项目',
        kind: MiaoaFailureKind.forbidden);
  }
  final kind = classifyMiaoaFailure(errText);
  // 原始报文可能包含访问密钥、JWT、签名 URL 或本地路径。它只参与内存中的
  // 错误分类，不进入 UI，也不写进 Windows 的持久日志。
  AppLog.warn('miaoa $what 失败（exit=$exitCode，$kind）');
  return MiaoaException(_guidance(kind, what), kind: kind);
}

/// 通用语境的中文引导。统一用「素材库」指代 miaoa，除非要用户敲命令
String _guidance(MiaoaFailureKind kind, String what) => switch (kind) {
      MiaoaFailureKind.cliMissing => missingToolMessage('miaoa'),
      MiaoaFailureKind.unauthorized =>
        '素材库登录已失效。请到「设置 → miaoa 账号」重新登录'
            '（或在终端执行 miaoa auth login），然后重试。',
      MiaoaFailureKind.forbidden => '没有访问该素材库资源的权限，请联系素材库管理员。',
      MiaoaFailureKind.notFound => '素材库里找不到请求的内容，它可能已被删除。',
      MiaoaFailureKind.network => '连接素材库失败，请检查网络后重试。',
      MiaoaFailureKind.unknown => '$what失败，请稍后重试。',
    };
