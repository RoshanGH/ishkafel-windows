import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// miaoa 边界的看门测试：**全 app 只允许一个 miaoa 子进程出入口**。
///
/// 「素材面板误报未找到 miaoa 而设置页正常」那个 bug 的根因，是每个服务
/// 各自拿可执行文件路径、各自起子进程——入口一多，修复就总有一份漏掉。
/// 这两条规则把「新代码绕过网关」变成测试红灯，而不是等真机上再炸：
///
/// 1. `resolveMiaoaBinary` 只许 miaoa_locator.dart（定义）与
///    miaoa_gateway.dart（唯一消费者）出现；
/// 2. lib/core/miaoa/ 下除网关外不许拿子进程执行器（systemProcessRunner）
///    （candidate_probe 例外——它跑的是 ffprobe，不是 miaoa）。
void main() {
  Iterable<File> dartFilesUnder(String root) => Directory(root)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));

  test('resolveMiaoaBinary 只允许网关消费——路径解析不许有第二份', () {
    const allowed = {
      'lib/core/miaoa/miaoa_locator.dart',
      'lib/core/miaoa/miaoa_gateway.dart',
    };
    final offenders = [
      for (final f in dartFilesUnder('lib'))
        if (!allowed.contains(f.path.replaceAll(r'\', '/')) &&
            f.readAsStringSync().contains('resolveMiaoaBinary'))
          f.path,
    ];
    expect(
      offenders,
      isEmpty,
      reason:
          '这些文件绕过了 MiaoaGateway 自己解析 miaoa 路径。'
          '把调用改走网关，否则 GUI 空 PATH 的坑会再踩一遍',
    );
  });

  test('miaoa 各服务不许自己起子进程——失败分类不许有第二份', () {
    const allowed = {
      // 唯一出入口
      'lib/core/miaoa/miaoa_gateway.dart',
      // ffprobe 探测器，跑的不是 miaoa
      'lib/core/miaoa/candidate_probe.dart',
    };
    final offenders = [
      for (final f in dartFilesUnder('lib/core/miaoa'))
        if (!allowed.contains(f.path.replaceAll(r'\', '/')) &&
            f.readAsStringSync().contains('systemProcessRunner'))
          f.path,
    ];
    expect(
      offenders,
      isEmpty,
      reason:
          '这些 miaoa 服务绕过了 MiaoaGateway 直接拿子进程执行器。'
          '改成注入 MiaoaGateway，让路径解析与错误分类只存在一份',
    );
  });
}
