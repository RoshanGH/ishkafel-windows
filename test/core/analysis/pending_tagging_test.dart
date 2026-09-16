import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/pending_tagging.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// **打标丢了要认得出来。**
///
/// 打标是切分落库之后转入后台跑的。真机事故：验证别的功能时反复重启 app，
/// 一条刚上传的片子 35 个镜头**一个标签、一句描述都没有**，而任务状态是
/// ready、界面上什么都不说——人看到的是「上传完视频进去发现没标签」，
/// 找不到原因，那一趟的钱也白花了。
void main() {
  Shot shot({String? desc}) =>
      Shot(startMs: 0, endMs: 1000, description: desc);

  SemanticUnit unit(List<Shot> shots, {List<String> tags = const []}) =>
      SemanticUnit(
          index: 0, startMs: 0, endMs: 1000, transcript: '一句话',
          tags: tags, shots: shots);

  RenewTask task(List<SemanticUnit>? units,
          {RenewTaskStatus status = RenewTaskStatus.ready,
          String? source = '/x.mp4',
          String? error}) =>
      RenewTask(
        id: 't', name: '片子', status: status,
        createdAt: DateTime(2026), updatedAt: DateTime(2026),
        sourcePath: source, units: units, analysisError: error,
      );

  test('镜头没有画面描述 = 这一镜没被看过', () {
    expect(shotTagged(shot(desc: '两位主播在货架前')), isTrue);
    expect(shotTagged(shot(desc: '  ')), isFalse);
    expect(shotTagged(shot()), isFalse);
  });

  test('判据是描述不是标签——标签可能本来就一个都不合适', () {
    final t = task([unit([shot(desc: '有描述')], tags: const [])]);
    expect(needsTagging(t), isFalse,
        reason: 'AI 看过了但没挑出合适的标签，那是打过的合法结果');
  });

  test('一镜没看过，整个单元都要重打——打标是按单元发起的', () {
    final t = task([
      unit([shot(desc: '看过了'), shot()]),
    ]);
    expect(unitsPendingTagging(t), {0});
  });

  test('真机那次的样子：全空', () {
    final t = task([
      unit([shot(), shot(), shot()]),
      unit([shot(), shot()]),
    ]);
    expect(unitsPendingTagging(t), {0, 1});
    expect(needsTagging(t), isTrue);
  });

  test('还在分析中的不算欠——那是正常进行中', () {
    final t = task([unit([shot()])], status: RenewTaskStatus.analyzing);
    expect(needsTagging(t), isFalse);
  });

  test('分析失败的不算欠——先解决失败本身', () {
    final t = task([unit([shot()])], error: '源文件不见了');
    expect(needsTagging(t), isFalse);
  });

  test('空白任务不算欠——它的标签本来就是手填的', () {
    final t = task([unit([shot()])], source: null);
    expect(needsTagging(t), isFalse);
  });

  test('还没切分的任务不算欠', () {
    expect(needsTagging(task(null)), isFalse);
    expect(needsTagging(task(const [])), isFalse);
  });

  group('固定过底片的单元，补打标一视同仁', () {
    SemanticUnit pinned({List<String> tags = const []}) => SemanticUnit(
          uid: 'b',
          index: 1,
          startMs: 10000,
          endMs: 16300,
          transcript: '底片转出来的话',
          tags: tags,
          hasSource: false,
          baseCandidateId: 7,
          shots: const [
            Shot(startMs: 10000, endMs: 13000),
            Shot(startMs: 13000, endMs: 16300),
          ],
        );

    test('切了底片、镜头还没打标：要排进去', () {
      expect(unitsPendingTagging(task([unit(const []), pinned()])), contains(1),
          reason: '那条素材转写过、切成了镜头、每一镜都有画面——'
              '模型该看的一样不缺，它就是「参考视频里的一段」');
    });

    test('没固定底片的手加单元照旧跳过——模型没东西可看', () {
      const bare = SemanticUnit(
          uid: 'c',
          index: 1,
          startMs: 10000,
          endMs: 20000,
          transcript: '',
          hasSource: false);

      expect(unitsPendingTagging(task([unit(const [], tags: ['促单']), bare])),
          isEmpty,
          reason: '排进去只会每打开一次任务就白烧一次 AI 调用');
    });

    test('人手填过标签的还是跳过——不能把他的结论盖掉', () {
      final handpicked = pinned(tags: const ['促单'])
          .copyWith(tagsHandpicked: true);

      expect(
          unitsPendingTagging(
              task([unit(const [], tags: ['促单']), handpicked])),
          isEmpty);
    });
  });
}
