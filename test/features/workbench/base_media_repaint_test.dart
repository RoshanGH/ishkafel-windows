import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/text_layout_cache.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_painter.dart';

/// 底片那几段的画面/波形是**后到的**（要先抽帧、先算包络）。
/// `shouldRepaint` 不算上它们，图解好了躺在那儿、画布不重画——时间线上那一格
/// 照旧是空的。2026-09-15 真机上为此改了三轮才发现卡在这一行，
/// 和当初「拖字幕拖不动」是同一类漏。
void main() {
  const units = [
    SemanticUnit(
      uid: 'u0',
      index: 0,
      startMs: 0,
      endMs: 16300,
      transcript: '',
      hasSource: false,
      baseCandidateId: 7,
    ),
  ];

  TimelinePainter painter({
    Map<String, List<double>> waves = const {},
  }) =>
      TimelinePainter(
        units: units,
        geometry: const TimelineGeometry(durationMs: 16300, msPerPx: 20),
        selection: null,
        textCache: TextLayoutCache(),
        playheadMs: 0,
        baseWaveEnvelopes: waves,
      );

  test('底片波形到了要重画', () {
    final before = painter();
    final after = painter(waves: const {
      'u0': [0.1, 0.5]
    });

    expect(after.shouldRepaint(before), isTrue,
        reason: '不重画的话，波形算好了那一格还是空的');
  });

  test('没变就不重画——每帧重画整条时间线是纯浪费', () {
    const same = {
      'u0': [0.1, 0.5]
    };
    expect(painter(waves: same).shouldRepaint(painter(waves: same)), isFalse);
  });
}
