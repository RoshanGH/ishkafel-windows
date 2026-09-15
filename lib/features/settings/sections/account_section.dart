import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/log/app_log.dart';
import '../../../core/miaoa/miaoa_account_service.dart';
import '../../../core/miaoa/miaoa_auth_service.dart';
import '../../../core/miaoa/miaoa_failure.dart';
import '../miaoa_login_sheet.dart';
import '../workspace_picker_sheet.dart';
import '../settings_providers.dart';
import '../settings_widgets.dart';

/// miaoa 账号分区：登录状态、租户、当前项目、登录与退出。
///
/// **凭据始终由 miaoa CLI 保存，app 不留任何一份。** 登录这一步是把手机号和
/// 验证码转发给 CLI 跑一次（见 [MiaoaAuthService]）——自己再存一份 token 就
/// 会有两份登录态，app 显示「已登录」而 CLI 那边早过期，一检索就 401。
///
/// 切换租户/项目仍然只读不写：那会让终端里正在进行的操作莫名其妙地变样。
///
/// 换一台电脑、或者换一个人用这个包，都要在本机登录一次——登录态是跟着
/// miaoa CLI 走的，不在安装包里。
class AccountSection extends ConsumerWidget {
  const AccountSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(miaoaAccountProvider);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      children: [
        account.when(
          loading: () => const SettingsCard(children: [
            SettingsRow(label: '登录状态', value: '读取中…'),
          ]),
          // provider 内部已把异常收敛成 status.failure，这里兜住意外抛出
          error: (e, _) => SettingsCard(children: [
            SettingsErrorBlock(
                message: accountFailureGuidance(MiaoaFailureKind.unknown),
                onRetry: () => ref.invalidate(miaoaAccountProvider)),
          ]),
          data: (status) => _body(ref, status),
        ),
      ],
    );
  }

  Widget _body(WidgetRef ref, MiaoaAccountStatus? status) {
    if (status == null) {
      return const SettingsCard(
          children: [SettingsNote('本次运行未接入 miaoa 账号服务（通常只发生在测试环境）。')]);
    }
    final failure = status.failure;
    if (failure != null) {
      return SettingsCard(children: [
        SettingsErrorBlock(
            message: failure.message,
            onRetry: () => ref.invalidate(miaoaAccountProvider)),
      ]);
    }
    return status.loggedIn ? _LoggedIn(status: status) : const _LoggedOut();
  }
}

class _LoggedIn extends ConsumerWidget {
  final MiaoaAccountStatus status;

  const _LoggedIn({required this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) => SettingsCard(children: [
        // 登录了却没有企业：账号能用，但**什么都干不了**——没有企业就没有项目、
        // 没有标签组、检索不了素材。这个状态必须一眼看见并且当场能解决，
        // 不能只在下面给一个小小的「切换」。真机上同事就卡在这里
        ?_noTenantBanner(context, ref),
        SettingsRow(
          label: '登录状态',
          content: StatusDot(
              ok: true, text: '${status.maskedAccount ?? '已登录账号'} · 已登录'),
          trailing: TextButton(
            onPressed: () => ref.invalidate(miaoaAccountProvider),
            child: const Text('刷新'),
          ),
        ),
        const Divider(height: 1, color: AppColors.border),
        SettingsRow(
          label: '企业',
          value: status.tenantName,
          trailing: _switchButton(
            context,
            ref,
            key: const Key('settings-switch-tenant'),
            title: '切换企业',
            description: '标签组是按企业分的。在错的企业下，新建任务时会选不到'
                '标签组，画面也就打不出标签、挑替换素材时没有标签可用。',
            load: (auth) => auth.listTenants(),
            select: (auth, id) => auth.selectTenant(id),
          ),
        ),
        const Divider(height: 1, color: AppColors.border),
        SettingsRow(
          label: '当前项目',
          value: status.projectCount == null
              ? status.projectName
              : '${status.projectName ?? '未选择'}（${status.projectCount} 个可选）',
          trailing: _switchButton(
            context,
            ref,
            key: const Key('settings-switch-project'),
            title: '切换项目',
            description: '检索候选素材时会限定在当前项目下。',
            load: (auth) => auth.listProjects(),
            select: (auth, id) => auth.switchProject(id),
            // 项目动辄几十上百，本地过滤之外再让服务端按关键词兜一次
            search: (auth, key) => auth.searchProjects(key),
          ),
        ),
        const Divider(height: 1, color: AppColors.border),
        SettingsRow(label: '服务地址', value: status.endpoint),
        if (ref.watch(miaoaAuthServiceProvider) != null) ...[
          const Divider(height: 1, color: AppColors.border),
          SettingsRow(
            label: '退出登录',
            content: const Text('退出后无法检索素材，需要重新用手机号登录',
                style: TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textSecondary)),
            trailing: TextButton(
              key: const Key('settings-logout'),
              onPressed: () => _confirmLogout(context, ref),
              child: const Text('退出', style: TextStyle(color: AppColors.red)),
            ),
          ),
        ],
        // 这句是常驻的，不是出错才显示：企业选错时**一切看起来都正常**，
        // 只有走到新建任务选标签组、或挑替换素材那一步才发现没有标签，
        // 而那时用户根本联想不到企业上
        const SettingsNote('标签组是按企业分的。如果新建任务时选不到标签组、'
            '或挑替换素材时没有标签可用，先确认上面的企业是否正确。'),
      ]);

  /// 「还没选企业」的横幅。企业已选时返回 null
  Widget? _noTenantBanner(BuildContext context, WidgetRef ref) {
    if ((status.tenantName ?? '').trim().isNotEmpty) return null;
    final auth = ref.watch(miaoaAuthServiceProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.orange.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.orange.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 16, color: AppColors.orange),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '还没有选择企业——现在什么都干不了。\n'
                    '项目、标签组、素材检索全都按企业分；没有企业，新建任务时'
                    '选不到标签组，画面也打不出标签。',
                    style: TextStyle(
                        fontSize: AppFontSize.body,
                        height: 1.6,
                        color: AppColors.textPrimary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (auth == null)
              Text('请在终端执行：miaoa tenant list 然后 miaoa tenant select <ID>',
                  style: TextStyle(
                      fontSize: AppFontSize.caption,
                      fontFamily: platformMonospaceFontFamily,
                      color: AppColors.textSecondary))
            else
              FilledButton(
                key: const Key('settings-choose-tenant'),
                onPressed: () async {
                  final picked = await WorkspacePickerSheet.show(
                    context,
                    title: '选择企业',
                    description: '项目、标签组、素材检索都按企业分。选定之后才能开始用。',
                    load: () => auth.listTenants(),
                    select: auth.selectTenant,
                  );
                  if (picked == true) ref.invalidate(miaoaAccountProvider);
                },
                child: const Text('选择企业'),
              ),
          ],
        ),
      ),
    );
  }

  /// 企业/项目的「切换」按钮。没接登录服务时不显示——那时这两项只能去终端改
  Widget? _switchButton(
    BuildContext context,
    WidgetRef ref, {
    required Key key,
    required String title,
    required String description,
    required Future<MiaoaWorkspaceList> Function(MiaoaAuthService) load,
    required Future<MiaoaAuthResult> Function(MiaoaAuthService, int) select,
    Future<MiaoaWorkspaceList> Function(MiaoaAuthService, String)? search,
  }) {
    final auth = ref.watch(miaoaAuthServiceProvider);
    if (auth == null) return null;
    return TextButton(
      key: key,
      onPressed: () async {
        final switched = await WorkspacePickerSheet.show(
          context,
          title: title,
          description: description,
          load: () => load(auth),
          select: (id) => select(auth, id),
          search: search == null ? null : (key) => search(auth, key),
        );
        // 切完整个上下文都变了：企业、项目、能读到的标签组
        if (switched == true) ref.invalidate(miaoaAccountProvider);
      },
      child: const Text('切换'),
    );
  }

  /// 退出是破坏性的（要重新收一次短信才能回来），先确认
  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final service = ref.read(miaoaAuthServiceProvider);
    if (service == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: const Text('退出 miaoa 登录？'),
        content: const Text('退出后这台电脑上无法检索候选素材，也读不到标签组，'
            '需要重新用手机号收一次验证码。已经下载到本地的素材不受影响。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消')),
          TextButton(
            key: const Key('settings-logout-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('退出', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    final result = await service.logout();
    ref.invalidate(miaoaAccountProvider);
    if (!context.mounted) return;
    // 失败不能装作退了：CLI 那边可能还留着凭据
    if (!result.ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(result.message)));
    }
  }
}

class _LoggedOut extends ConsumerWidget {
  const _LoggedOut();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(miaoaAuthServiceProvider);
    return SettingsCard(children: [
      const SettingsRow(
        label: '登录状态',
        content: StatusDot(ok: false, text: '未登录'),
      ),
      const SizedBox(height: AppSpacing.sm),
      Text(
        auth == null
            ? '未登录时无法检索候选素材、也读不到标签组。请在终端运行下面这条命令完成登录'
                '（手机号 + 短信验证码），完成后点「刷新」。'
            : '未登录时无法检索候选素材、也读不到标签组。用注册 miaoa 时的手机号'
                '登录即可——登录状态存在这台电脑上，换一台电脑要再登一次。',
        style: const TextStyle(
            fontSize: AppFontSize.body,
            height: 1.6,
            color: AppColors.textPrimary),
      ),
      const SizedBox(height: AppSpacing.md),
      // 接不到登录服务时（测试环境，或将来 CLI 不支持）退回教用户敲命令，
      // 而不是摆一个点了没反应的按钮
      if (auth == null) ...[
        const _CommandBox(command: miaoaLoginCommand),
        const SizedBox(height: AppSpacing.md),
      ],
      Align(
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (auth != null) ...[
              FilledButton(
                key: const Key('settings-login'),
                onPressed: () => _login(context, ref, auth),
                child: const Text('登录 miaoa'),
              ),
              const SizedBox(width: AppSpacing.sm),
            ],
            OutlinedButton(
              onPressed: () => ref.invalidate(miaoaAccountProvider),
              child: const Text('刷新'),
            ),
          ],
        ),
      ),
    ]);
  }

  Future<void> _login(
      BuildContext context, WidgetRef ref, MiaoaAuthService auth) async {
    final ok = await MiaoaLoginSheet.show(context, auth);
    if (ok != true) return;
    // 登录成功后重新读一次状态：租户、项目、服务地址都要跟着刷新
    ref.invalidate(miaoaAccountProvider);
  }
}

/// 命令行片段 + 一键复制。让用户照着屏幕手打一条命令是最容易出错的一步。
class _CommandBox extends StatefulWidget {
  final String command;

  const _CommandBox({required this.command});

  @override
  State<_CommandBox> createState() => _CommandBoxState();
}

class _CommandBoxState extends State<_CommandBox> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: SelectableText(widget.command,
                  style: TextStyle(
                      fontSize: AppFontSize.body,
                      fontFamily: platformMonospaceFontFamily,
                      color: AppColors.accentBlueLight)),
            ),
            TextButton(
              key: const Key('settings-copy-login-command'),
              onPressed: _copy,
              child: Text(_copied ? '已复制' : '复制'),
            ),
          ],
        ),
      );

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.command));
      if (!mounted) return;
      setState(() => _copied = true);
    } catch (e) {
      // 剪贴板不可用时不能什么都不发生——用户会反复点同一个按钮
      AppLog.warn('复制登录命令失败：$e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('复制失败，请手动选中上面的命令复制。')));
    }
  }
}
