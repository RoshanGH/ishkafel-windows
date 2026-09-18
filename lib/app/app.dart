import 'package:flutter/material.dart';
import '../features/agent/agent_stage_overlay.dart';
import '../features/tasks/task_list_page.dart';
import 'theme/app_theme.dart';
import '../features/settings/diagnostic_report_button.dart';

class IshkafelApp extends StatelessWidget {
  const IshkafelApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'ishkafel',
        navigatorKey: diagnosticNavigatorKey,
        theme: buildAppTheme(),
        debugShowCheckedModeBanner: false,
        // Agent 的播报层套在**所有页面外面**：它会跨模块走
        // （新建任务 → 编导台 → 找镜头 → 导出），播报得一路跟下去。
        // 各页面各画各的话，切页面时播报就断了——而那恰恰是人最需要
        // 看的时候。这一层同时也是节奏控制点：每条至少停 0.5 秒才回执，
        // Agent 收到才走下一步
        builder: (context, child) =>
            Column(children: [
              Expanded(child: AgentStageOverlay(child: child ?? const SizedBox.shrink())),
              const Material(child: Align(alignment: Alignment.centerRight,
                child: DiagnosticReportButton())),
            ]),
        home: const TaskListPage(),
      );
}
