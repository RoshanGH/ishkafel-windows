import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart' show AsrSentence, AsrWord;
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/subtitle/preview_subtitle_at.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/core/subtitle/subtitle_track.dart';

/// U1 两镜：0~2000、2000~4000；U2 一镜：4000~8000
List<SemanticUnit> _units() => [
      SemanticUnit(
        index: 0,
        uid: 'aaaaaaaaaaaa',
        startMs: 0,
        endMs: 4000,
        transcript: 'U1',
        shots: [Shot(startMs: 0, endMs: 2000), Shot(startMs: 2000, endMs: 4000)],
      ),
      SemanticUnit(
        index: 1,
        uid: 'bbbbbbbbbbbb',
        startMs: 4000,
        endMs: 8000,
        transcript: 'U2',
        shots: [Shot(startMs: 4000, endMs: 8000)],
      ),
    ];

/// 「感染的白色念珠菌」落在 0~1500，「记得每周消毒」落在 5000~6500
List<AsrSentence> _sentences() => [
      AsrSentence(
          startMs: 0,
          endMs: 1500,
          text: '感染的白色念珠菌',
          words: const <AsrWord>[]),
      AsrSentence(
          startMs: 5000,
          endMs: 6500,
          text: '记得每周消毒',
          words: const <AsrWord>[]),
    ];

ComposedTimeline _timeline() =>
    ComposedTimeline.of(units: _units(), wholeDurations: const {});

void main() {
  group('预览画面上此刻该显示哪一行字', () {
    test('替换过的镜头上，显示我们要烧的那一句', () {
      final text = previewSubtitleAt(
        composedMs: 800,
        timeline: _timeline(),
        replacements: [
          UnitReplacement.perShot({0: [116719]}, previewIds: {0: 116719}),
          UnitReplacement.keepOriginal(),
        ],
        track: const SubtitleTrack.empty(),
        sentences: _sentences(),
      );

      expect(text, '感染的白色念珠菌');
    });

    test('没替换的镜头一个字都不叠——那儿的字是原素材自己带的，叠上去就成两层', () {
      final text = previewSubtitleAt(
        // 2000~4000 是 U1 的第二镜，没挑素材
        composedMs: 2500,
        timeline: _timeline(),
        replacements: [
          UnitReplacement.perShot({0: [116719]}, previewIds: {0: 116719}),
          UnitReplacement.keepOriginal(),
        ],
        track: const SubtitleTrack.empty(),
        sentences: [
          AsrSentence(
              startMs: 2000,
              endMs: 3500,
              text: '这句归第二镜',
              words: const <AsrWord>[]),
        ],
      );

      expect(text, isNull);
    });

    test('这一刻没人说话就不出字', () {
      final text = previewSubtitleAt(
        composedMs: 1800, // 句子 0~1500 已经说完
        timeline: _timeline(),
        replacements: [
          UnitReplacement.perShot({0: [116719]}, previewIds: {0: 116719}),
          UnitReplacement.keepOriginal(),
        ],
        track: const SubtitleTrack.empty(),
        sentences: _sentences(),
      );

      expect(text, isNull);
    });

    test('手改过的字幕优先——和导出、属性面板同一个出口', () {
      final track = const SubtitleTrack.empty().withLines(
        const SubtitleSlot(unitUid: 'bbbbbbbbbbbb', shotIndex: 0),
        const [SubtitleLine(startMs: 0, endMs: 4000, text: '我手改的这句')],
      );

      final text = previewSubtitleAt(
        composedMs: 5200,
        timeline: _timeline(),
        replacements: [
          UnitReplacement.keepOriginal(),
          UnitReplacement.perShot({0: [200]}, previewIds: {0: 200}),
        ],
        track: track,
        sentences: _sentences(),
      );

      expect(text, '我手改的这句');
    });

    test('单元调换位置之后，字幕还认得回自己那一句（按 uid 不按位置）', () {
      final track = const SubtitleTrack.empty().withLines(
        const SubtitleSlot(unitUid: 'bbbbbbbbbbbb', shotIndex: 0),
        const [SubtitleLine(startMs: 0, endMs: 4000, text: '跟着 uid 走')],
      );
      // U2 挪到了前面：位置变了，uid 没变
      final swapped = [
        _units()[1].copyWith(index: 0, startMs: 0, endMs: 4000, shots: [
          Shot(startMs: 0, endMs: 4000),
        ]),
        _units()[0].copyWith(index: 1, startMs: 4000, endMs: 8000, shots: [
          Shot(startMs: 4000, endMs: 6000),
          Shot(startMs: 6000, endMs: 8000),
        ]),
      ];

      final text = previewSubtitleAt(
        composedMs: 1000,
        timeline:
            ComposedTimeline.of(units: swapped, wholeDurations: const {}),
        replacements: [
          UnitReplacement.perShot({0: [200]}, previewIds: {0: 200}),
          UnitReplacement.keepOriginal(),
        ],
        track: track,
        sentences: _sentences(),
      );

      expect(text, '跟着 uid 走');
    });

    test('整体替换的那一段不出字——那段整个换成了另一条素材', () {
      final text = previewSubtitleAt(
        composedMs: 800,
        timeline: ComposedTimeline.of(
            units: _units(), wholeDurations: const {0: 4000}),
        replacements: [
          UnitReplacement.whole([116719], previewId: 116719),
          UnitReplacement.keepOriginal(),
        ],
        track: const SubtitleTrack.empty(),
        sentences: _sentences(),
      );

      expect(text, isNull);
    });
  });

  group('固定过底片的单元：画面不是原片了，但它有自己的镜头', () {
    /// 手加的单元，选了一条素材当底片，切成两镜；第一镜换了素材。
    /// 转写记在 baseSentences 上，时间戳是**素材内**毫秒
    List<SemanticUnit> baseUnits() => [
          const SemanticUnit(
            index: 0,
            uid: 'cccccccccccc',
            startMs: 0,
            endMs: 4000,
            transcript: '如果你以为它只能灭火',
            hasSource: false,
            baseCandidateId: 105678,
            baseSentences: [
              AsrSentence(
                  startMs: 40,
                  endMs: 1500,
                  text: '如果你以为它只能灭火',
                  words: <AsrWord>[]),
            ],
            shots: [
              Shot(startMs: 0, endMs: 2000),
              Shot(startMs: 2000, endMs: 4000),
            ],
          ),
        ];

    String? at(int composedMs) => previewSubtitleAt(
          composedMs: composedMs,
          timeline:
              ComposedTimeline.of(units: baseUnits(), wholeDurations: const {}),
          replacements: [
            UnitReplacement.perShot({
              0: [116719]
            }, previewIds: {
              0: 116719
            }),
          ],
          track: const SubtitleTrack.empty(),
          sentences: const [],
        );

    test('换过素材的那一镜照样出字——底片不等于「整段替换」', () {
      // isReplaced 对它也为真（画面确实不是原片了），拿它当判据的话
      // 整个单元在这儿被跳过：时间线的字幕轨照画，预览画面上一个字都没有
      expect(at(800), '如果你以为它只能灭火',
          reason: '它有自己的镜头切分，每一镜都能单独换素材、都该出字幕');
    });

    test('字从底片自己的转写里取，原片那份一个字都不用', () {
      // sentences 传的是空的：真出了字，就只能来自 baseSentences
      expect(at(1600), isNull, reason: '1.6s 已经过了那一句（40~1500）');
    });

    test('没换素材的那一镜不叠——字幕烧在原素材的像素里', () {
      expect(at(2500), isNull);
    });
  });
}
