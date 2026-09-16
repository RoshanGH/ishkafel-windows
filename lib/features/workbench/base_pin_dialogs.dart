import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_typography.dart';
import '../../core/editing/base_pin_ops.dart';

/// 切分之前问一句：**这一段从此只能用这一条素材**，其余候选会掉。
///
/// 不是破坏性操作，但会让已经选好的东西作废——不说清楚，人点完才发现
/// 勾少了、镜头选择没了，只会以为软件吃掉了他的活儿。
/// 返回 true 表示确认切分
Future<bool> confirmPinBase(
  BuildContext context, {
  required String unitLabel,
  required PinBaseCost cost,
  bool repin = false,
}) async {
  final lines = [
    if (repin)
      '$unitLabel 已经切过一次。重新切会按这条素材重新划镜头，'
          '现在这些镜头和挂在上面的选择全部作废。'
    else
      '切分之后，$unitLabel 的画面就按这条素材一刀一刀地换——每一镜都能'
          '单独挑素材。',
    if (cost.droppedCandidates > 0)
      '这一段现在选了好几条素材。底片只能有一张，'
          '另外 ${cost.droppedCandidates} 条会取消选中（这一段也就不再产出多条变体）。',
    if (cost.droppedShotPicks > 0)
      '已经挑过的 ${cost.droppedShotPicks} 处镜头替换会被清掉——'
          '镜头是重新划的，旧的选择没有地方安放。',
    '这一下做三件事：读一遍这条素材判断切点，把它转写一遍'
        '（字幕要的词级时间戳只能从这儿来，原片那份跟这段画面对不上），'
        '再逐镜看图打标（标签和画面描述是按画面搜素材的检索键）。'
        '三步都要等，转写和打标还要花钱。',
  ];
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.surfaceRaised,
      title: Text(repin ? '重新切分这一段' : '切分这一段',
          style: const TextStyle(fontSize: AppFontSize.title)),
      content: Text(
        lines.join('\n\n'),
        style: const TextStyle(fontSize: AppFontSize.emphasis, height: 1.6),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('confirm-pin-base'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(repin ? '重新切分并打标' : '切分并打标'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// 换底片之前问一句：旧底片切出来的镜头和选择全要清掉。
/// 返回 true 表示确认换
Future<bool> confirmUnpinBase(
  BuildContext context, {
  required String unitLabel,
  required int shotCount,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.surfaceRaised,
      title: const Text('换一张底片',
          style: TextStyle(fontSize: AppFontSize.title)),
      content: Text(
        '$unitLabel 现在按这条素材切成了 $shotCount 个镜头。换底片会把这些镜头'
        '和挑在上面的素材全部清掉，这一段回到「还没挑素材」的状态。\n\n'
        '换完重新挑一条，再切一次就行。',
        style: const TextStyle(fontSize: AppFontSize.emphasis, height: 1.6),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        TextButton(
          key: const Key('confirm-unpin-base'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: TextButton.styleFrom(foregroundColor: AppColors.red),
          child: const Text('清掉，重新挑'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
