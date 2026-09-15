import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/diagnostics/cli_installer.dart';
import 'package:ishkafel/features/settings/cli_install_card.dart';
import 'package:path/path.dart' as p;

/// 命令行工具那张卡片。
///
/// 盯的是**每种状态下用户看到什么、能点什么**——状态区分得再细，界面上说不
/// 清楚也是白搭。
void main() {
  late Directory temp;
  late Directory bin;
  late File bundled;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('cli_card');
    bin = Directory(p.join(temp.path, 'bin'))..createSync();
    bundled = File(p.join(temp.path, 'app', 'cli', 'bin', 'ishkafel'));
    bundled.parent.createSync(recursive: true);
    bundled.writeAsStringSync('#!/bin/sh\n');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  File shim() =>
      File(p.join(bin.path, Platform.isWindows ? 'ishkafel.cmd' : 'ishkafel'));

  Future<void> pump(WidgetTester tester, CliInstaller installer) =>
      tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: CliInstallCard(installer: installer),
              ),
            ),
          ),
        ),
      );

  testWidgets('没装：给安装按钮，并说清楚装了能干嘛', (tester) async {
    await pump(tester, CliInstaller(binDir: bin, bundledCli: bundled));
    expect(find.text('未安装'), findsOneWidget);
    expect(find.text('安装'), findsOneWidget);
    expect(find.textContaining('任意终端敲 ishkafel'), findsOneWidget);
  });

  testWidgets('点安装 → 真的装上，并告诉用户下一步敲什么', (tester) async {
    await pump(tester, CliInstaller(binDir: bin, bundledCli: bundled));
    // 安装要落盘、要 chmod，都是真 I/O；testWidgets 默认的假时钟里等不到。
    // 等的条件是「装完了」而不是「文件出现了」——文件写下去的那一刻 chmod
    // 还没跑，这时候退出 runAsync，剩下的 await 就永远停在假时钟里了
    final probe = CliInstaller(binDir: bin, bundledCli: bundled);
    await tester.runAsync(() async {
      await tester.tap(find.text('安装'));
      while (probe.inspect() != CliStatus.installed) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(shim().existsSync(), isTrue);
    expect(find.text('已安装'), findsOneWidget);
    expect(find.textContaining('ishkafel --help'), findsWidgets);
    expect(find.text('移除'), findsOneWidget);
  });

  testWidgets('这版没带 CLI：不给能点的按钮，免得点了没反应', (tester) async {
    await pump(
      tester,
      CliInstaller(binDir: bin, bundledCli: File(p.join(temp.path, '没有这个'))),
    );
    expect(find.text('此版本未包含'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '安装'), findsNothing);
  });

  testWidgets('别人家的同名命令：说明为什么不动它，也不给按钮', (tester) async {
    shim().writeAsStringSync('别人家的');
    await pump(tester, CliInstaller(binDir: bin, bundledCli: bundled));
    expect(find.text('被占用'), findsOneWidget);
    expect(find.textContaining('不是本应用装的'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '安装'), findsNothing);
  });

  testWidgets('app 挪过位置：说清是怎么回事，按钮变成重新安装', (tester) async {
    final oldSpot = File(p.join(temp.path, '旧', 'ishkafel'));
    oldSpot.parent.createSync(recursive: true);
    oldSpot.writeAsStringSync('#!/bin/sh\n');
    await tester.runAsync(
      () => CliInstaller(binDir: bin, bundledCli: oldSpot).install(),
    );
    oldSpot.parent.deleteSync(recursive: true);

    await pump(tester, CliInstaller(binDir: bin, bundledCli: bundled));
    expect(find.text('需要重新安装'), findsOneWidget);
    expect(find.text('重新安装'), findsOneWidget);
    expect(find.textContaining('换过位置'), findsOneWidget);
  });
}
