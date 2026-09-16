import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart' show AsrSentence, AsrWord;
import 'package:ishkafel/core/subtitle/slot_subtitles.dart';
import 'package:ishkafel/core/subtitle/subtitle_track.dart';

/// 底片换成一条素材之后，字幕从**它自己的转写**里取。
///
/// 产品负责人在「按时长摊字数」和「真转写」之间选了后者：
/// 「这条产品线的字幕是要交付的」——摊出来的时间点在成片里一看就飘。
void main() {
  /// 原片那份（时间戳量的是原片轴）
  final origin = [
    const AsrSentence(
        startMs: 11000, endMs: 13500, text: '原片这一段的台词', words: []),
  ];

  /// 底片素材自己的（时间戳是**素材内**毫秒）
  final base = [
    const AsrSentence(startMs: 500, endMs: 2200, text: '素材里说的话', words: [
      AsrWord(startMs: 500, endMs: 1300, text: '素材里'),
      AsrWord(startMs: 1300, endMs: 2200, text: '说的话'),
    ]),
  ];

  test('底片是素材：取它自己的转写，不碰原片那份', () {
    final lines = subtitleLinesForSlot(
      track: const SubtitleTrack.empty(),
      sentences: origin,
      unitUid: 'u2',
      shotIndex: 1,
      slotStartMs: 12000,
      slotEndMs: 14480,
      onMaterialBase: true,
      baseSentences: base,
      baseSlotStartMs: 0,
      baseSlotEndMs: 2480,
    );

    expect(lines, isNotEmpty);
    expect(lines.first.text, contains('素材里'));
  });

  test('坑位按素材内偏移取——用单元坐标会取空', () {
    final lines = subtitleLinesForSlot(
      track: const SubtitleTrack.empty(),
      sentences: origin,
      unitUid: 'u2',
      shotIndex: 1,
      slotStartMs: 12000,
      slotEndMs: 14480,
      onMaterialBase: true,
      baseSentences: base,
      // 这一镜在素材里是 0~2480
      baseSlotStartMs: 0,
      baseSlotEndMs: 2480,
    );

    expect(lines.first.startMs, lessThan(2480),
        reason: '行的时间轴以坑位开头为 0');
  });

  test('还没转写过（null）：不硬凑，一行都不给', () {
    expect(
      subtitleLinesForSlot(
        track: const SubtitleTrack.empty(),
        sentences: origin,
        unitUid: 'u2',
        shotIndex: 1,
        slotStartMs: 12000,
        slotEndMs: 14480,
        onMaterialBase: true,
        baseSlotStartMs: 0,
        baseSlotEndMs: 2480,
      ),
      isEmpty,
    );
  });

  test('转过、这条素材没人说话（空列表）：同样是没有字幕', () {
    expect(
      subtitleLinesForSlot(
        track: const SubtitleTrack.empty(),
        sentences: origin,
        unitUid: 'u2',
        shotIndex: 1,
        slotStartMs: 12000,
        slotEndMs: 14480,
        onMaterialBase: true,
        baseSentences: const [],
        baseSlotStartMs: 0,
        baseSlotEndMs: 2480,
      ),
      isEmpty,
    );
  });

  test('底片是原片时照旧走原片那份', () {
    final lines = subtitleLinesForSlot(
      track: const SubtitleTrack.empty(),
      sentences: origin,
      unitUid: 'u2',
      shotIndex: 1,
      slotStartMs: 10000,
      slotEndMs: 14000,
      baseSentences: base,
    );

    expect(lines.first.text, contains('原片'));
  });
}
