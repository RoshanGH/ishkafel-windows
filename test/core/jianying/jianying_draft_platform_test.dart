import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/jianying/jianying_draft.dart';
import 'package:ishkafel/core/jianying/jianying_plan.dart';
import 'package:ishkafel/core/subtitle/subtitle_style.dart';

void main() {
  final plan = JianyingPlan.single(
    video: const [
      JyVideoSegment(
        path: 'source',
        atMs: 0,
        durationMs: 2000,
        sourceStartMs: 0,
        sourceDurationMs: 2000,
        speed: 1,
        volume: 1,
        sourceTotalMs: 5000,
      ),
    ],
    text: const [JyTextSegment(text: 'Windows 字幕', atMs: 0, durationMs: 2000)],
  );

  test('Windows 草稿不再携带任何 macOS 平台与路径字段', () {
    final draft = buildDraftJson(
      plan: plan,
      subtitle: const SubtitleStyle(),
      draftName: '测试',
      draftFolder: r'D:\剪映草稿\测试',
      draftRoot: r'D:\剪映草稿',
      pathOf: (_) => r'D:\剪映草稿\测试\materials\片段.mp4',
      targetPlatform: const JianyingDraftPlatform.windows(
        osVersion: '10.0.26100',
        appVersion: '11.1.0',
        windowsDirectory: r'C:\Windows',
      ),
    );

    expect(draft.info['platform']['os'], 'windows');
    expect(draft.info['platform']['os_version'], '10.0.26100');
    expect(draft.info['last_modified_platform'], draft.info['platform']);
    expect(draft.meta['draft_cover'], r'D:\剪映草稿\测试\draft_cover.jpg');

    final video = (draft.info['materials']['videos'] as List).single;
    expect(video['material_name'], '片段.mp4');
    final library =
        (draft.meta['draft_materials'] as List).first['value'] as List;
    expect(library.single['extra_info'], '片段.mp4');

    final text = (draft.info['materials']['texts'] as List).single;
    expect(text['font_path'], r'C:\Windows\Fonts\msyh.ttc');
    expect(
      jsonDecode(text['content'])['styles'][0]['font']['path'],
      r'C:\Windows\Fonts\msyh.ttc',
    );
    expect(jsonEncode(draft.info), isNot(contains('/Applications/')));
  });

  test('macOS 草稿保持既有平台值与字体路径', () {
    final draft = buildDraftJson(
      plan: plan,
      subtitle: const SubtitleStyle(),
      draftName: '测试',
      draftFolder: '/Users/a/Movies/JianyingPro/测试',
      draftRoot: '/Users/a/Movies/JianyingPro',
      pathOf: (_) => '/Users/a/Movies/JianyingPro/测试/materials/a.mp4',
      targetPlatform: const JianyingDraftPlatform.macos(
        osVersion: '15.3',
        appVersion: '11.1.0',
      ),
    );

    expect(draft.info['platform']['os'], 'mac');
    expect(
      (draft.info['materials']['texts'] as List).single['font_path'],
      startsWith('/Applications/VideoFusion-macOS.app/'),
    );
    expect(
      draft.meta['draft_cover'],
      '/Users/a/Movies/JianyingPro/测试/draft_cover.jpg',
    );
  });
}
