import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/playback/follower_track.dart';

/// **跟随轨用「悄悄调速」追主时钟，不再硬 seek。**
///
/// 产品负责人 2026-09-16 的症状：「有一句话是谁说的怎么怎么样，然后它会是
/// 谁说的、哎、是谁说的，说两遍，然后接着正常播放。」
///
/// 那正是硬 seek 往回跳的声音——主时钟在接缝处停一拍，跟随轨相对超前，
/// 下一次对表就把它拽回去，那一小段于是重播一遍。
///
/// 改成调速之后：接缝顿挫还在（换文件必然有开销），但它不再变成**可闻的**
/// 毛病——速率偏个 2%，人听不出来（mpv 默认音调校正，变速不变调）。
void main() {
  group('追赶速率', () {
    test('已经很近了就收手——别一直微调', () {
      expect(chaseRate(0), 1.0);
      expect(chaseRate(20), 1.0);
      expect(chaseRate(-20), 1.0);
    });

    test('落后就加速，超前就减速', () {
      // 落后 100ms（drift 为负）
      expect(chaseRate(-100), greaterThan(1.0));
      // 超前 100ms
      expect(chaseRate(100), lessThan(1.0));
    });

    test('偏离幅度小到听不出来——100ms 的偏差只要 2.5%', () {
      expect(chaseRate(-100), closeTo(1.025, 0.001));
      expect(chaseRate(100), closeTo(0.975, 0.001));
    });

    test('再大的偏差也不许把速率拉到能听出来', () {
      expect(chaseRate(-100000), closeTo(1 + maxChaseRate, 0.0001));
      expect(chaseRate(100000), closeTo(1 - maxChaseRate, 0.0001));
    });

    test('收手的死区要比硬阈值小得多——否则会留下一个永远不纠的偏差', () {
      // 2026-09-16 真机：口播轨全程落后 26~139ms，够不着 150ms 的硬阈值，
      // 所以**永远不纠**，整条预览一直带着这个音画偏差。
      // 死区必须小到能把它吃掉
      expect(chaseDeadZoneMs, lessThan(syncToleranceMs ~/ 4));
      expect(chaseRate(-65), isNot(1.0), reason: '这个偏差以前是无人过问的');
    });

    test('差到换了个地方的程度就跳，不追', () {
      // 人拖了播放头、换了源：慢慢追要追几十秒
      expect(seekInsteadOfChaseMs, greaterThan(syncToleranceMs));
      expect(seekInsteadOfChaseMs, lessThan(5000));
    });
  });
}
