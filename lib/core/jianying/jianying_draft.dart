import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../subtitle/subtitle_style.dart';
import 'jianying_plan.dart';

/// 把 [JianyingPlan] 翻译成剪映草稿的两份 JSON。纯函数，不碰磁盘。
///
/// 格式实测于 **剪映专业版 VideoFusion-macOS 11.1.0**：草稿以明文 JSON 落盘，
/// 剪映读得进去，它自己保存时才加密（所以我们只管写明文）。
///
/// 两份文件分工（缺一份剪映就当残缺草稿）：
/// - `draft_info.json`  底部时间线（tracks + materials），时间单位**微秒**
/// - `draft_meta_info.json`  左上角素材库（draft_materials）+ 草稿元信息
///
/// 真机踩过的坑：素材库写成空数组时，视频**不会**出现在素材面板里
/// （音频会——剪映自己把音频轨的素材补进去了），用户以为素材没导进来。

/// 毫秒 → 微秒
int _us(int ms) => ms * 1000;

/// 剪映草稿里会落盘的平台字段与平台路径。
///
/// 这不是界面层的系统判断，而是草稿文件格式的一部分；集中在一个值对象里，
/// 防止同一份 JSON 一半是 Windows、一半还残留 macOS。
class JianyingDraftPlatform {
  final String operatingSystem;
  final String osVersion;
  final String appVersion;
  final String windowsDirectory;

  const JianyingDraftPlatform.windows({
    required this.osVersion,
    required this.appVersion,
    this.windowsDirectory = r'C:\Windows',
  }) : operatingSystem = 'windows';

  const JianyingDraftPlatform.macos({
    required this.osVersion,
    required this.appVersion,
  })  : operatingSystem = 'macos',
        windowsDirectory = '';

  factory JianyingDraftPlatform.current({
    String? operatingSystem,
    String? osVersion,
    Map<String, String>? environment,
  }) {
    final os = operatingSystem ?? Platform.operatingSystem;
    final env = environment ?? Platform.environment;
    final version = env['ISHKAFEL_JIANYING_VERSION']?.trim();
    if (os == 'windows') {
      return JianyingDraftPlatform.windows(
        osVersion: osVersion ?? Platform.operatingSystemVersion,
        appVersion: version == null || version.isEmpty ? '11.1.0' : version,
        windowsDirectory: env['WINDIR']?.trim().isNotEmpty == true
            ? env['WINDIR']!.trim()
            : r'C:\Windows',
      );
    }
    return JianyingDraftPlatform.macos(
      osVersion: osVersion ?? Platform.operatingSystemVersion,
      appVersion: version == null || version.isEmpty ? '11.1.0' : version,
    );
  }

  p.Context get _paths => p.Context(
        style: operatingSystem == 'windows' ? p.Style.windows : p.Style.posix,
      );

  String basename(String path) => _paths.basename(path);
  String join(String left, String right) => _paths.join(left, right);

  String get fontPath => operatingSystem == 'windows'
      ? _paths.join(windowsDirectory, 'Fonts', 'msyh.ttc')
      : '/Applications/VideoFusion-macOS.app/Contents/Resources/Font/'
          'SystemFont/zh-hans.ttf';

  Map<String, dynamic> get json => {
        'os': operatingSystem == 'windows' ? 'windows' : 'mac',
        'os_version': osVersion,
        'app_id': 3704,
        'app_version': appVersion,
        'app_source': 'lv',
        'device_id': '',
        'hard_disk_id': '',
        'mac_address': '',
      };
}

/// 生成剪映风格的大写 UUID
class _Ids {
  final Random _r;
  _Ids(int seed) : _r = Random(seed);
  String next() {
    String h(int n) => List.generate(
        n, (_) => '0123456789ABCDEF'[_r.nextInt(16)]).join();
    return '${h(8)}-${h(4)}-${h(4)}-${h(4)}-${h(12)}';
  }
}

/// 素材库里的一条（draft_meta_info 用）
class _LibEntry {
  final String id;
  final String path;
  final String type; // video | music
  final int durationMs;
  final int width;
  final int height;

  /// 排序键：先按组（画面 0 / 口播 1 / 配乐 2），再按首次出现的时刻。
  /// 素材面板是给人翻的，乱序等于没排
  int group;
  int order;

  _LibEntry(this.id, this.path, this.type, this.durationMs, this.width,
      this.height, this.group, this.order);
}

/// 两份 JSON 的构造结果
class JianyingDraftJson {
  final Map<String, dynamic> info;
  final Map<String, dynamic> meta;
  final String draftId;

  /// 说得出口的降级（比如毛玻璃字幕在剪映里没有等价形态）。
  /// 调用方必须把它显示给用户——降级可以有，但不许闷着
  final List<String> notes;

  const JianyingDraftJson(
      {required this.info,
      required this.meta,
      required this.draftId,
      this.notes = const []});
}

/// 构造草稿 JSON。
///
/// [pathOf] 把计划里的素材路径换成**落地后**的路径（素材要复制/硬链接进
/// 草稿目录，剪映是沙盒 app，读不到我们的缓存目录）。
/// 素材总时长由计划自带（`sourceTotalMs`）——方案数据里本来就有，
/// 不必为了填素材库再跑一遍 ffprobe。
JianyingDraftJson buildDraftJson({
  required JianyingPlan plan,
  required SubtitleStyle subtitle,
  required String draftName,
  required String draftFolder,
  required String draftRoot,
  required String Function(String planPath) pathOf,
  int width = 1080,
  int height = 1920,
  int fps = 30,
  int nowSeconds = 0,
  int seed = 20260826,
  JianyingDraftPlatform? targetPlatform,
}) {
  final draftPlatform = targetPlatform ?? JianyingDraftPlatform.current();
  final ids = _Ids(seed);
  final draftId = ids.next();
  final notes = <String>[];

  // ---- materials 容器：每个 segment 都要挂一串近乎空的占位对象，缺了打不开
  final videos = <Map<String, dynamic>>[];
  final audios = <Map<String, dynamic>>[];
  final texts = <Map<String, dynamic>>[];
  final canvases = <Map<String, dynamic>>[];
  final speeds = <Map<String, dynamic>>[];
  final channels = <Map<String, dynamic>>[];
  final vocals = <Map<String, dynamic>>[];
  final animations = <Map<String, dynamic>>[];
  final placeholders = <Map<String, dynamic>>[];
  final beats = <Map<String, dynamic>>[];
  final colors = <Map<String, dynamic>>[];

  final lib = <String, _LibEntry>{};
  String libPut(String path, String type, int durationMs, int group, int order,
      {int w = 0, int h = 0}) {
    final hit = lib[path];
    if (hit != null) {
      // 同一素材被多段引用：排序按它**第一次**出现的位置，不被后面的引用带跑
      if (group < hit.group || (group == hit.group && order < hit.order)) {
        hit.group = group;
        hit.order = order;
      }
      return hit.id;
    }
    final e = _LibEntry(ids.next(), path, type, durationMs, w, h, group, order);
    lib[path] = e;
    return e.id;
  }

  List<String> refsFor({required bool isVideo, double speed = 1.0}) {
    final out = <String>[];
    final sid = ids.next();
    speeds.add({'id': sid, 'type': 'speed', 'speed': speed});
    out.add(sid);
    final pid = ids.next();
    placeholders
        .add({'id': pid, 'type': 'placeholder_info', 'meta_type': 'none'});
    out.add(pid);
    final cid = ids.next();
    channels.add({'id': cid, 'type': ''});
    out.add(cid);
    final vid = ids.next();
    vocals.add({'id': vid, 'type': 'vocal_separation'});
    out.add(vid);
    if (isVideo) {
      final cv = ids.next();
      canvases.add({'id': cv, 'type': 'canvas_color'});
      out.add(cv);
      final mc = ids.next();
      colors.add({'id': mc});
      out.add(mc);
    } else {
      final bt = ids.next();
      beats.add({
        'id': bt,
        'type': 'beats',
        'ai_beats': {'melody_percents': <double>[]}
      });
      out.add(bt);
    }
    return out;
  }

  // ---- 画面轨（可能好几条：同一时间位置上挑了几条候选就有几条轨）
  final videoTrackSegs = <List<Map<String, dynamic>>>[];
  for (var layer = 0; layer < plan.videoTracks.length; layer++) {
  final videoSegs = <Map<String, dynamic>>[];
  for (final s in plan.videoTracks[layer]) {
    final path = pathOf(s.path);
    final total = s.sourceTotalMs;
    final mid = ids.next();
    videos.add({
      'id': mid,
      'type': 'video',
      'path': path,
      'material_name': draftPlatform.basename(path),
      'duration': _us(total),
      'width': width,
      'height': height,
      'category_name': 'local',
      'local_material_id':
          libPut(path, 'video', total, 0, s.atMs, w: width, h: height),
      'crop': <String, dynamic>{},
      'stable': {'time_range': <String, dynamic>{}},
      'matting': {'path': ''},
      'video_algorithm': {
        'path': '',
        'story_video_modify_video_config': <String, dynamic>{}
      },
      'beauty_face_auto_preset': <String, dynamic>{},
      'video_mask_stroke': {'resource_id': '', 'path': '', 'type': ''},
      'video_mask_shadow': {'resource_id': '', 'path': ''},
    });
    videoSegs.add({
      'id': ids.next(),
      'material_id': mid,
      // 剪映靠 source/target 两个时长之比认出倍率，两个都得给对
      'source_timerange': {
        'start': _us(s.sourceStartMs),
        'duration': _us(s.sourceDurationMs)
      },
      'target_timerange': {'start': _us(s.atMs), 'duration': _us(s.durationMs)},
      'render_timerange': <String, dynamic>{},
      'speed': s.speed,
      'volume': s.volume,
      'clip': {
        'scale': {'x': 1, 'y': 1},
        'transform': {'x': 0, 'y': 0},
        'flip': <String, dynamic>{}
      },
      'uniform_scale': {'on': true, 'value': 1},
      'extra_material_refs': refsFor(isVideo: true, speed: s.speed),
      'enable_hsl': false,
      'hdr_settings': {'mode': 1},
      'responsive_layout': <String, dynamic>{},
      'enable_adjust_mask': false,
      'visible': true,
      // 层号越大越靠上。底轨是原片，替换素材摞在它上面——打开草稿看到的
      // 就是替换之后的样子，想看原片把上面那条关掉
      'render_index': layer,
      'source': 'segmentsourcenormal',
    });
  }
  videoTrackSegs.add(videoSegs);
  }

  // ---- 声音轨（口播 / 配乐同构）
  List<Map<String, dynamic>> audioSegs(
      List<JyAudioSegment> list, String name, int group) {
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < list.length; i++) {
      final s = list[i];
      final path = pathOf(s.path);
      final total = s.sourceTotalMs;
      final mid = ids.next();
      audios.add({
        'id': mid,
        'type': 'extract_music',
        'name': '$name ${i + 1}',
        'path': path,
        'duration': _us(total > 0 ? total : s.durationMs),
        'resource_id': '',
        'local_material_id':
            libPut(path, 'music', total > 0 ? total : s.durationMs, group, s.atMs),
        'similiar_music_info': <String, dynamic>{},
        'tts_benefit_info': {'benefit_type': 'none'},
      });
      // 曲子比要铺的区间短就截断（剪映段内不循环）——少铺的那一截必须说出来
      final take = total > 0 && total - s.sourceStartMs < s.durationMs
          ? total - s.sourceStartMs
          : s.durationMs;
      if (take < s.durationMs) {
        notes.add('《${draftPlatform.basename(path)}》只有 ${(take / 1000).toStringAsFixed(1)} 秒，'
            '铺不满 ${(s.durationMs / 1000).toStringAsFixed(1)} 秒的区间，'
            '草稿里这一段末尾会没有声音');
      }
      out.add({
        'id': ids.next(),
        'material_id': mid,
        'source_timerange': {
          'start': _us(s.sourceStartMs),
          'duration': _us(take)
        },
        'target_timerange': {'start': _us(s.atMs), 'duration': _us(take)},
        'render_timerange': <String, dynamic>{},
        'volume': s.volume,
        'speed': 1.0,
        'extra_material_refs': refsFor(isVideo: false),
        'visible': true,
        'source': 'segmentsourcenormal',
      });
    }
    return out;
  }

  final voiceSegs = audioSegs(plan.voice, '配音', 1);
  final bgmSegs = audioSegs(plan.bgm, '配乐', 2);

  // ---- 字幕轨
  final (r, g, b) = _subtitleColor(subtitle);
  if (subtitle.preset == SubtitlePreset.blurBox) {
    notes.add('毛玻璃字幕在剪映里没有对应形态，草稿中改用描边字幕；'
        '底部的模糊需要你在剪映里自行添加');
  } else if (subtitle.preset == SubtitlePreset.whiteBox) {
    notes.add('底条字幕在剪映里改用描边字幕，如需底条请在剪映里加');
  }
  final strokePercent = subtitle.preset == SubtitlePreset.whiteBox ||
          subtitle.preset == SubtitlePreset.blurBox
      ? 3
      : 9;
  final textSegs = <Map<String, dynamic>>[];
  for (final s in plan.text) {
    final content = jsonEncode({
      'styles': [
        {
          'fill': {
            'content': {
              'render_type': 'solid',
              'solid': {
                'alpha': 1,
                'color': [r, g, b]
              }
            }
          },
          'font': {'id': '', 'path': draftPlatform.fontPath},
          'range': [0, s.text.length],
          'shadows': <dynamic>[],
          'size': _fontSize(subtitle.fontRatio),
          'strokes': [
            {
              'content': {
                'render_type': 'solid',
                'solid': {
                  'color': [0, 0, 0]
                }
              },
              'width': strokePercent / 100,
              'mode': 0
            }
          ],
          'useLetterColor': true,
        }
      ],
      'text': s.text,
    });
    final mid = ids.next();
    texts.add({
      'id': mid,
      'type': 'subtitle',
      'content': content,
      'base_content': content,
      'recognize_text': s.text,
      'current_words': <String, dynamic>{},
      'combo_info': <String, dynamic>{},
      'caption_template_info': {'resource_id': '', 'path': ''},
      'layer_weight': 1,
      'line_spacing': 0.02,
      'shadow_alpha': 0.9,
      'border_width': strokePercent / 100,
      'text_color': _hex(r, g, b),
      'font_size': _fontSize(subtitle.fontRatio),
      'font_path': draftPlatform.fontPath,
      'initial_scale': 1,
      'lyrics_template': {'resource_id': '', 'path': ''},
      'recognize_task_id': '',
    });
    final aid = ids.next();
    animations.add({'id': aid, 'type': 'sticker_animation'});
    textSegs.add({
      'id': ids.next(),
      'material_id': mid,
      'target_timerange': {'start': _us(s.atMs), 'duration': _us(s.durationMs)},
      'render_timerange': <String, dynamic>{},
      'clip': {
        'scale': {'x': 1, 'y': 1},
        // 剪映的 y 轴：0 = 画面中心、-1 = 底。我们的 bottomRatio 是「距底比例」
        'transform': {'x': 0, 'y': -(1 - 2 * subtitle.bottomRatio)},
        'flip': <String, dynamic>{}
      },
      'uniform_scale': {'on': true, 'value': 1},
      'extra_material_refs': [aid],
      'render_index': 14000,
      'track_render_index': 1,
      'visible': true,
      'enable_lut': false,
      'enable_adjust': false,
      'enable_hsl': false,
      'responsive_layout': <String, dynamic>{},
      'enable_adjust_mask': false,
      'source': 'segmentsourcenormal',
    });
  }

  Map<String, dynamic> track(String type, List<Map<String, dynamic>> segs,
          {int flag = 0}) =>
      {
        'id': ids.next(),
        'type': type,
        'attribute': 0,
        'flag': flag,
        'is_default_name': true,
        'name': '',
        'segments': segs,
      };

  final tracks = <Map<String, dynamic>>[
    for (final segs in videoTrackSegs)
      if (segs.isNotEmpty) track('video', segs),
    if (textSegs.isNotEmpty) track('text', textSegs, flag: 1),
    if (voiceSegs.isNotEmpty) track('audio', voiceSegs),
    if (bgmSegs.isNotEmpty) track('audio', bgmSegs),
  ];

  final platform = draftPlatform.json;

  final info = <String, dynamic>{
    'id': draftId,
    'name': '',
    'duration': _us(plan.totalMs),
    'fps': fps,
    'canvas_config': {'width': width, 'height': height, 'ratio': 'original'},
    'color_space': -1,
    'cover': null,
    'extra_info': null,
    'group_container': null,
    'create_time': nowSeconds * 1000000,
    'update_time': nowSeconds * 1000000,
    'free_render_index_mode_on': false,
    'render_index_track_mode_on': true,
    'keyframe_graph_list': <dynamic>[],
    'keyframes': {
      for (final k in [
        'adjusts',
        'audios',
        'effects',
        'filters',
        'handwrites',
        'stickers',
        'texts',
        'videos'
      ])
        k: <dynamic>[]
    },
    'materials': {
      'videos': videos,
      'audios': audios,
      'texts': texts,
      'canvases': canvases,
      'speeds': speeds,
      'sound_channel_mappings': channels,
      'vocal_separations': vocals,
      'material_animations': animations,
      'placeholder_infos': placeholders,
      'beats': beats,
      'material_colors': colors,
      'audio_fades': <dynamic>[],
      'effects': <dynamic>[],
      'filters': <dynamic>[],
      'stickers': <dynamic>[],
      'transitions': <dynamic>[],
    },
    'mutable_config': null,
    'relationships': <dynamic>[],
    'retouch_cover': null,
    'source': 'default',
    'static_cover_image_path': '',
    'time_marks': null,
    'tracks': tracks,
    'new_version': '169.0.0',
    'version': 360000,
    'platform': platform,
    'last_modified_platform': platform,
    'config': {
      'adjust_max_index': 1,
      'attachment_info': <dynamic>[],
      'combination_max_index': 1,
      'export_range': null,
      'extract_audio_last_index': 1,
      'lyrics_recognition_id': '',
      'lyrics_sync': true,
      'lyrics_taskinfo': <dynamic>[],
      'maintrack_adsorb': true,
      'material_save_mode': 0,
      'multi_language_current': 'none',
      'multi_language_list': <dynamic>[],
      'multi_language_main': 'none',
      'multi_language_mode': 'none',
      'original_sound_last_index': 1,
      'record_audio_last_index': 1,
      'sticker_max_index': 1,
      'subtitle_keywords_config': null,
      'subtitle_recognition_id': '',
      'subtitle_sync': true,
      'subtitle_taskinfo': <dynamic>[],
      'system_font_list': <dynamic>[],
      'video_mute': false,
      'zoom_info_params': null,
    },
  };

  // 素材库：画面按主轨先后排在一起，其后配音、再配乐
  final sorted = lib.values.toList()
    ..sort((a, b) =>
        a.group != b.group ? a.group - b.group : a.order - b.order);
  final meta = <String, dynamic>{
    'draft_id': draftId,
    'draft_name': draftName,
    'draft_fold_path': draftFolder,
    'draft_root_path': draftRoot,
    'draft_cover': draftPlatform.join(draftFolder, 'draft_cover.jpg'),
    'tm_duration': _us(plan.totalMs),
    'tm_draft_create': nowSeconds * 1000000,
    'tm_draft_modified': nowSeconds * 1000000,
    'tm_draft_removed': 0,
    'draft_timeline_materials_size_': 0,
    'draft_materials': [
      {
        'type': 0,
        'value': [
          for (final e in sorted)
            {
              'ai_group_type': '',
              'create_time': nowSeconds,
              'duration': _us(e.durationMs),
              'enter_from': 0,
              'extra_info': draftPlatform.basename(e.path),
              'file_Path': e.path,
              'height': e.height,
              'width': e.width,
              'id': e.id,
              'import_time': nowSeconds,
              'import_time_ms': nowSeconds * 1000000,
              'item_source': 1,
              'md5': '',
              'metetype': e.type,
              'roughcut_time_range': {'duration': _us(e.durationMs), 'start': 0},
              'sub_time_range': {'duration': -1, 'start': -1},
              'type': 0,
            }
        ]
      },
      for (final t in [1, 2, 3, 6, 7, 8]) {'type': t, 'value': <dynamic>[]},
    ],
    'draft_materials_copied_info': <dynamic>[],
    'draft_segment_extra_info': <dynamic>[],
    'draft_enterprise_info': {
      'draft_enterprise_extra': '',
      'draft_enterprise_id': '',
      'draft_enterprise_name': '',
      'enterprise_material': <dynamic>[],
    },
    'draft_type': '',
    'draft_is_invisible': false,
    'draft_removable_storage_device': '',
    'draft_new_version': '',
    'draft_deeplink_url': '',
    'draft_is_from_deeplink': 'false',
    'draft_cloud_template_id': '',
    'draft_cloud_tutorial_info': '',
    'draft_cloud_purchase_info': '',
    'draft_cloud_last_action_download': false,
    'draft_cloud_capcut_purchase_info': '',
    'draft_cloud_videocut_purchase_info': '',
    'cloud_package_completed_time': '',
    'tm_draft_cloud_completed': '',
    'tm_draft_cloud_modified': 0,
  };

  return JianyingDraftJson(
      info: info, meta: meta, draftId: draftId, notes: notes);
}

/// 字色：自定义色优先，其次预设自己的颜色（与 `subtitle_rasterizer` 同一套）
(double, double, double) _subtitleColor(SubtitleStyle style) {
  final custom = style.colorHex;
  if (custom != null && custom.length >= 6) {
    return (
      int.parse(custom.substring(0, 2), radix: 16) / 255,
      int.parse(custom.substring(2, 4), radix: 16) / 255,
      int.parse(custom.substring(4, 6), radix: 16) / 255,
    );
  }
  return switch (style.preset) {
    SubtitlePreset.yellowOutline => (1.0, 0.85, 0.0),
    _ => (1.0, 1.0, 1.0),
  };
}

String _hex(double r, double g, double b) {
  String c(double v) =>
      (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${c(r)}${c(g)}${c(b)}'.toUpperCase();
}

/// 剪映的字号单位换算：以参考工程标定（fontRatio 0.034 ↔ size 8）。
/// 剪映里字号还能再调，细微出入不影响使用
double _fontSize(double fontRatio) =>
    (fontRatio * 8 / 0.034).clamp(2.0, 30.0);
