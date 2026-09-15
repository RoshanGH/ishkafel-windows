import 'dart:io';

import 'package:path/path.dart' as p;

/// GUI 装在哪。
///
/// 验收 Agent 开工前就卡在这儿：手册给的唯一办法是从进程里读路径，
/// 而 app 一关就返回空，接着把出路推给「问用户要」——**那在无人值守的
/// 静默模式里是死路**。
///
/// 真正的解法一直摆在那儿：**CLI 本身就装在 app 包里**
/// （`ishkafel.app/Contents/Resources/cli/ishkafel`），从自己的可执行文件
/// 路径往上数四层就是 app。它一直知道自己在哪，只是没人问过它。
const String defaultAppPath = '/Applications/ishkafel.app';

String? windowsDefaultAppPath([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final programFiles =
      env['ProgramFiles'] ?? Platform.environment['ProgramFiles'];
  if (programFiles == null || programFiles.isEmpty) return null;
  return p.Context(style: p.Style.windows).join(programFiles, 'Ishkafel');
}

/// 从 CLI 自己的路径推出 app 包的位置；不在包里就返回 null（不硬猜）
///
/// **一路往上找 `.app`，不数固定层数**：包里的真实布局是
/// `Contents/Resources/cli/<架构>/bundle/bin/ishkafel`（两个架构并存，
/// 外面那个 `cli/ishkafel` 只是按 uname 选一个的壳），从可执行文件算起是
/// 六层，不是想当然的四层。写死层数的那版在单测里绿着，装进包里就失效——
/// 真机上 doctor 报「缺凭据」而凭据明明就躺在包里。
String? appPathFromExecutable(String executable, {String? operatingSystem}) {
  final windows =
      (operatingSystem ??
          (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(executable) ||
                  executable.contains(r'\')
              ? 'windows'
              : 'macos')) ==
      'windows';
  final context = p.Context(style: windows ? p.Style.windows : p.Style.posix);
  final normalized = context.normalize(executable);
  if (windows) {
    final parts = context.split(normalized);
    for (var i = parts.length - 2; i >= 1; i--) {
      if (parts[i].toLowerCase() == 'cli' &&
          i + 1 < parts.length &&
          parts[i + 1].toLowerCase() == 'bin') {
        return context.joinAll(parts.take(i));
      }
    }
    return null;
  }
  var dir = context.dirname(context.absolute(normalized));
  while (true) {
    if (dir.endsWith('.app')) return dir;
    final parent = context.dirname(dir);
    if (parent == dir) return null;
    dir = parent;
  }
}

/// 按优先级找 app：**环境变量 → 自己所在的包 → 默认位置**。
///
/// 找不到就返回 null——**说找不到，别给一个假路径**：给了假路径，
/// 报错就变成「打不开 /Applications/ishkafel.app」，而人根本没装在那儿。
String? resolveAppPath({
  Map<String, String>? env,
  String? executable,
  bool Function(String path)? exists,
  String? operatingSystem,
}) {
  final e = env ?? Platform.environment;
  final has = exists ?? (path) => Directory(path).existsSync();
  final os = operatingSystem ?? Platform.operatingSystem;

  final fromEnv = (e['ISHKAFEL_APP'] ?? '').trim();
  if (fromEnv.isNotEmpty) return fromEnv;

  final self = appPathFromExecutable(
    executable ?? Platform.resolvedExecutable,
    operatingSystem: os,
  );
  if (self != null && has(self)) return self;

  final fallback = os == 'windows' ? windowsDefaultAppPath(e) : defaultAppPath;
  return fallback != null && has(fallback) ? fallback : null;
}

/// 把 GUI 拉起来。返回 null = 成功；非 null = **可以直接照做的中文原因**。
///
/// 两个真机问题一起收在这里：
///
/// 1. **拉不起来却返回退出码 0**。`open -a` 对不存在的 app 返回非零，
///    但调用方只把 stderr 打出来、没把退出码传下去——照退出码判断的脚本
///    会以为界面已经弹出来了，继续往下跑。
/// 2. **报错是原样的英文栈**（`NSCocoaErrorDomain Code=260`），一个字都
///    没提 `ISHKAFEL_APP` 这条出路——而手册里明明写着。
Future<String?> launchApp({
  required Future<ProcessResult> Function(String, List<String>) run,
  Map<String, String>? env,
  String? executable,
  bool Function(String path)? exists,
  String? operatingSystem,
}) async {
  final os = operatingSystem ?? Platform.operatingSystem;
  final path = resolveAppPath(
    env: env,
    executable: executable,
    exists: exists,
    operatingSystem: os,
  );
  if (path == null) {
    final hint = os == 'windows'
        ? r'  set ISHKAFEL_APP=C:\path\to\Ishkafel'
        : '  export ISHKAFEL_APP=/path/to/ishkafel.app';
    return '找不到 ishkafel 的 app。命令行工具通常装在 app 里面，'
        '所以它一般能自己找到——找不到多半是这个工具被单独拷出来了。'
        '让用户把 app 的路径告诉你，然后：\n'
        '$hint';
  }
  try {
    final r = os == 'windows'
        ? await run(p.join(path, 'ishkafel.exe'), const [])
        : await run('open', ['-a', path]);
    if (r.exitCode != 0) {
      final envHint = os == 'windows'
          ? 'set ISHKAFEL_APP=<真实目录>'
          : 'export ISHKAFEL_APP=<真实路径>';
      return '打不开 app（$path）。\n'
          '· 路径不对的话用 $envHint 指过去\n'
          '· 路径没错就让用户手动双击一次看看，可能是被系统拦了\n'
          '原始报错：${'${r.stderr}'.trim()}';
    }
    return null;
  } catch (e) {
    return '拉起 app 失败（$path）：$e';
  }
}

/// CLI 找凭据要翻的目录，按优先级排。
///
/// 最后那一项是**正式包自带的那份**：`dart build cli` 不支持 `--dart-define`，
/// GUI 那套编译期注入对 CLI 完全无效，于是打包时把凭据拷进
/// `<app>/Contents/Resources/cli/credentials/`，CLI 从自己的路径回推着读。
///
/// 没有这一项的后果不是「少个便利」——是 Agent 拿到正式包后
/// `analyze` 直接失败，而同一台机器上人点界面却好好的。替换裂变第二步就断，
/// 后面挑素材、组方案、导出全部无从谈起（验收 Agent 真机撞上过）。
///
/// 顺序上它排在最后：人手动放进数据目录的那份要能盖掉它，否则换 key 无处可换。
List<Directory> cliSecretsDirs({
  required Directory dataDir,
  String? executable,
  String? currentDir,
  String? operatingSystem,
}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  final bundled = appPathFromExecutable(
    executable ?? Platform.resolvedExecutable,
    operatingSystem: os,
  );
  final context = p.Context(
    style: os == 'windows' ? p.Style.windows : p.Style.posix,
  );
  return [
    Directory(context.join(dataDir.path, 'credentials')),
    Directory(context.join(currentDir ?? Directory.current.path, '.secrets')),
    if (bundled != null)
      Directory(
        os == 'windows'
            ? context.join(bundled, 'cli', 'credentials')
            : context.join(
                bundled,
                'Contents',
                'Resources',
                'cli',
                'credentials',
              ),
      ),
  ];
}
