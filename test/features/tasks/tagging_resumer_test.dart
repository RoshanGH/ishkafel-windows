import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/tagging_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/tasks/tagging_resumer.dart';

/// 打标丢了要能补回来。真机上丢过一次：一条刚上传的片子 35 个镜头一个标签、
/// 一句描述都没有，任务状态却是 ready、界面上什么都不说。
class _FakeRepo implements TaskRepository {
  final Map<String, RenewTask> store;
  int saves = 0;
  _FakeRepo(List<RenewTask> tasks)
      : store = {for (final t in tasks) t.id: t};

  @override
  Future<List<RenewTask>> findAll() async => store.values.toList();
  @override
  Future<RenewTask?> findById(String id) async => store[id];
  @override
  Future<void> save(RenewTask task) async {
    saves++;
    store[task.id] = task;
  }
  @override
  Future<void> delete(String id) async => store.remove(id);
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeTagging implements TaggingService {
  int calls = 0;
  Set<int>? lastOnly;
  final bool fail;

  /// 打标**进行中**人在工作台里做的事（加单元、拖顺序、删单元）。
  /// 补标签跑完会重读一次任务，读到的就是这里改完的样子
  void Function()? duringTag;

  _FakeTagging({this.fail = false});

  @override
  Future<List<SemanticUnit>> tag(RenewTask task, List<SemanticUnit> units,
      {Set<int>? only,
      dynamic onProgress,
      Map<int, String> baseVideoPaths = const {}}) async {
    calls++;
    lastOnly = only;
    duringTag?.call();
    if (fail) throw StateError('云端挂了');
    return [
      for (var i = 0; i < units.length; i++)
        if (only == null || only.contains(i))
          units[i].copyWith(
            tags: const ['促单'],
            shots: [
              for (final s in units[i].shots) s.copyWith(description: '看过了'),
            ],
          )
        else
          units[i],
    ];
  }

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  Shot shot({String? desc}) => Shot(startMs: 0, endMs: 1000, description: desc);
  var uidSeq = 0;
  // **身份是必需的**：读档时 RenewTask.fromJson 一定跑过 ensureUnitUids，
  // 所以真实数据上每个单元都有 uid，标签写回就按它配对
  SemanticUnit unit(List<Shot> shots, {String? uid, int index = 0}) =>
      SemanticUnit(
          uid: uid ?? 'u${uidSeq++}',
          index: index,
          startMs: 0,
          endMs: 1000,
          transcript: '一句',
          shots: shots);
  RenewTask task(String id, List<SemanticUnit> units) => RenewTask(
        id: id, name: '片子 $id', status: RenewTaskStatus.ready,
        createdAt: DateTime(2026), updatedAt: DateTime(2026),
        sourcePath: '/x.mp4', units: units,
      );

  test('欠打标的补上，打过的不重打——重打就是白花一次钱', () async {
    final repo = _FakeRepo([
      task('a', [unit([shot()])]),                 // 欠
      task('b', [unit([shot(desc: '看过了')])]),    // 不欠
    ]);
    final tagging = _FakeTagging();
    final fixed = await TaggingResumer(repository: repo, tagging: tagging)
        .resumeAll();

    expect(fixed, 1);
    expect(tagging.calls, 1, reason: '只该为欠的那条发起一次');
    expect(repo.store['a']!.units!.first.tags, ['促单']);
    expect(repo.store['b']!.units!.first.tags, isEmpty);
  });

  test('只补欠的那几个单元，已经打过的不动', () async {
    final repo = _FakeRepo([
      task('a', [
        unit([shot(desc: '打过了')]),
        unit([shot()]),
      ]),
    ]);
    final tagging = _FakeTagging();
    await TaggingResumer(repository: repo, tagging: tagging).resumeAll();
    expect(tagging.lastOnly, {1}, reason: '第 0 个打过了，重打是白花钱');
  });

  test('补的时候人正在改这条任务：不能拿旧的整个盖回去', () async {
    final repo = _FakeRepo([task('a', [unit([shot()])])]);
    final tagging = _FakeTagging();
    final resumer = TaggingResumer(repository: repo, tagging: tagging);
    // 模拟：打标进行中，人在工作台里把任务改了名
    final before = repo.store['a']!;
    repo.store['a'] = before.copyWith(name: '人刚改的名字');
    await resumer.resumeAll();
    expect(repo.store['a']!.name, '人刚改的名字',
        reason: '拿手上那份旧的整个覆盖回去，会把他刚做的编辑抹掉');
    expect(repo.store['a']!.units!.first.tags, ['促单']);
  });

  test('补失败不该拦住人用软件', () async {
    final repo = _FakeRepo([task('a', [unit([shot()])])]);
    final fixed = await TaggingResumer(
            repository: repo, tagging: _FakeTagging(fail: true))
        .resumeAll();
    expect(fixed, 0);
    expect(repo.store['a'], isNotNull, reason: '任务本身不能因此坏掉');
  });

  test('叫停就停——人要关软件时别继续烧钱', () async {
    final repo = _FakeRepo([
      task('a', [unit([shot()])]),
      task('b', [unit([shot()])]),
    ]);
    final tagging = _FakeTagging();
    var n = 0;
    await TaggingResumer(repository: repo, tagging: tagging)
        .resumeAll(shouldStop: () => n++ > 0);
    expect(tagging.calls, lessThanOrEqualTo(1));
  });

  /// **标签按身份走，不是按位置走。**
  ///
  /// 产品负责人 2026-09-16（真机）：「我新添加的一个测试单元，拉到第一位，
  /// 我还没有做任何操作，它为什么就有标签了？而且是跟 U2 的标签一样。
  /// 这些信息不是应该跟台词语义单元走吗？」
  ///
  /// 补标签是后台跑的，跑完会**重读**一次任务再写回——而这段时间里人正在
  /// 工作台里加单元、拖顺序。重读回来的那份下标早就不是发起打标时那一套了，
  /// 按下标写回，标签就结结实实糊到了别人身上，而且哪儿都不报错。
  group('补标签期间人改了顺序', () {
    test('新加的单元拖到第一位，不该凭空拿到别人的标签', () async {
      // 发起打标时：只有 A 一个单元，欠标签
      final a = unit([shot()], uid: 'aaa', index: 0);
      final repo = _FakeRepo([task('t', [a])]);
      final tagging = _FakeTagging();
      // 打标进行中，人加了一个空单元 B（原片上没有它）并拖到第一位
      final b = SemanticUnit(
          uid: 'bbb',
          index: 0,
          startMs: 1000,
          endMs: 11000,
          transcript: '',
          hasSource: false);
      tagging.duringTag = () {
        repo.store['t'] = repo.store['t']!
            .copyWith(units: [b, a.copyWith(index: 1)]);
      };

      await TaggingResumer(repository: repo, tagging: tagging).resumeAll();

      final units = repo.store['t']!.units!;
      expect(units[0].uid, 'bbb');
      expect(units[0].tags, isEmpty,
          reason: '它是刚加进来的空单元，一个标签都不该有');
      expect(units[1].uid, 'aaa');
      expect(units[1].tags, ['促单'], reason: '标签该落在它自己身上');
    });

    test('单元被删掉，补回来的标签不许顺移到后面那个身上', () async {
      final a = unit([shot()], uid: 'aaa', index: 0);
      final b = unit([shot()], uid: 'bbb', index: 1);
      final repo = _FakeRepo([task('t', [a, b])]);
      final tagging = _FakeTagging();
      // 打标进行中，人把 A 删了
      tagging.duringTag = () {
        repo.store['t'] =
            repo.store['t']!.copyWith(units: [b.copyWith(index: 0)]);
      };

      await TaggingResumer(repository: repo, tagging: tagging).resumeAll();

      final units = repo.store['t']!.units!;
      expect(units, hasLength(1));
      expect(units.single.uid, 'bbb');
      expect(units.single.tags, ['促单'], reason: 'B 自己那份照常落上');
    });
  });
}
