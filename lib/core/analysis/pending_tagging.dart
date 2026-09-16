/// **这个任务还欠打标吗。**
///
/// 打标是切分落库之后转入后台跑的（让人 26 秒就能进去看切分，不用等占七成
/// 时长的打标）。这个优化本身是对的，错在它只做了乐观路径：**app 一关，
/// 打标就永久丢了**——任务状态已经是 ready，看起来一切正常，没有任何地方
/// 记得它还欠着，界面也不提示。人看到的是「上传完视频，进去发现没标签」，
/// 而且找不到原因（真机上就这么丢过一次：35 个镜头一个标签都没有）。
///
/// 判据用**画面描述**而不是标签：AI 打过标一定会写一句描述，而标签可能
/// 本来就一个都不合适（那是打过的合法结果）。描述空 = 这一镜没被看过。
library;

import '../models/renew_task.dart';
import '../models/semantic_unit.dart';
import '../replacement/unit_base.dart';
import '../models/shot.dart';

/// 这一镜被看过了吗
bool shotTagged(Shot shot) => (shot.description ?? '').trim().isNotEmpty;

/// 这个单元里还有几镜没被看过
List<int> untaggedShotIndexes(SemanticUnit unit) => [
      for (var i = 0; i < unit.shots.length; i++)
        // 人手改过的不算欠着——哪怕他改成了空（那是「我就是不要标签」）
        if (!unit.shots[i].tagsHandpicked && !shotTagged(unit.shots[i])) i,
    ];

/// 哪些单元还欠打标（下标，升序）。
///
/// 只要单元里有一镜没被看过，整个单元就要重打——打标是按单元发起的，
/// 单元标签和镜头标签一起出
Set<int> unitsPendingTagging(RenewTask task) {
  final units = task.units;
  if (units == null || units.isEmpty) return const {};
  // 空白任务没有原片，镜头是从素材拼出来的，标签本来就是手填的
  if (task.isBlank) return const {};
  return {
    for (var i = 0; i < units.length; i++)
      // **人手改过的一律跳过**：他把标签改成空，意思是「我就是不要标签」，
      // 而不是「还没打」。分不清的话后台会默默补一份回去，把他刚做的判断
      // 盖掉——他看不见这一步，只会觉得改了没生效
      //
      // **手加的单元一律跳过**：原片里没有它，它没有台词、没有镜头、
      // 也没有画面，模型没有任何东西可以据以打标——排进去只会每打开一次
      // 任务就白烧一次 AI 调用，返回的还永远是空（2026-09-08 真机上，
      // 一条任务的 U1 就这么被反复打了好几轮）。它的标签本来就是人手填的，
      // 见 withHandpickedTags
      //
      // **固定过底片的除外**：那条素材转写过、切成了镜头、每一镜都有画面
      // ——模型该看的东西一样不缺。它就是「参考视频里的一段」，
      // 补打标这条路也得一视同仁（产品负责人：「该走的流程全部走完」）
      if ((units[i].hasSource || hasOwnBaseShots(units[i])) &&
          !units[i].tagsHandpicked &&
          (units[i].shots.isEmpty
              ? units[i].tags.isEmpty
              : untaggedShotIndexes(units[i]).isNotEmpty))
        i,
  };
}

/// 这个任务欠不欠打标。**只看已经切分完的任务**——还在分析中的不算，
/// 那是正常进行中
bool needsTagging(RenewTask task) =>
    task.status == RenewTaskStatus.ready &&
    task.analysisError == null &&
    unitsPendingTagging(task).isNotEmpty;
