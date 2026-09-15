import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';
import '../platform/platform_shell.dart';

/// 心跳停多久算失效。
///
/// **锁必须能自愈**：持有者可能崩溃、被 kill、断电。没有这条，任务会被一把
/// 永远不会释放的锁封死，而用户完全无从下手——那比「两边同时写」还糟。
const Duration defaultStaleAfter = Duration(seconds: 60);

/// 占着锁的是**界面**（人在场），还是另一个 Agent？
///
/// 这两种「写不进去」要区别对待：另一个 Agent 占着是真冲突，只能等；
/// 界面占着说明人正开着它看——Agent 该把活儿**委派给界面**去做
/// （见 [AgentRequest]），而不是报一句「写不进去」就完事。
///
/// 判据是持有者标识的约定：界面用 `gui:<pid>` 或 `人（…）`，
/// Agent 用 `Agent` / `agent:<pid>`
bool isGuiHolder(String? holder) =>
    holder != null && (holder.startsWith('gui:') || holder.startsWith('人'));

/// 一把任务锁的内容
class TaskLock {
  /// 谁持有（`agent:<pid>` / `gui:<pid>`）——出问题时界面上要能说出是谁占着
  final String holder;
  final DateTime acquiredAt;
  final DateTime heartbeatAt;
  final Duration staleAfter;

  const TaskLock({
    required this.holder,
    required this.acquiredAt,
    required this.heartbeatAt,
    this.staleAfter = defaultStaleAfter,
  });

  /// 持有者标识里的进程号（`gui:82809` → 82809）。没有就返回 null
  int? get holderPid {
    final i = holder.indexOf(':');
    return i < 0 ? null : int.tryParse(holder.substring(i + 1).trim());
  }

  /// 这把锁还作不作数。
  ///
  /// 除了心跳超时，还多问一句「写锁的那个进程还在吗」：真机上每次重启 app
  /// 打开任务都会撞到一条黄横幅说任务被占着、当前只读，而那个 pid 的进程
  /// 早就退了——进程都不在了还让人干等一分钟，是白等。
  ///
  /// pid 会被系统复用，所以「问到还活着」不代表真是它——那个方向是保守的
  /// （不接管），安全。
  bool isStale(DateTime now, {bool Function(int pid)? processAlive}) {
    if (now.difference(heartbeatAt) > staleAfter) return true;
    final pid = holderPid;
    if (pid == null || processAlive == null) return false;
    return !processAlive(pid);
  }

  Map<String, dynamic> toJson() => {
    'holder': holder,
    'acquiredAt': acquiredAt.toIso8601String(),
    'heartbeatAt': heartbeatAt.toIso8601String(),
  };

  /// 宽松解析：**任何一处不对就返回 null**，由调用方当作「没有锁」。
  /// 一个读不懂的锁文件不该把任务永久封死
  static TaskLock? tryFromJson(Object? raw, Duration staleAfter) {
    if (raw is! Map) return null;
    final holder = raw['holder'];
    final acquired = DateTime.tryParse('${raw['acquiredAt']}');
    final heartbeat = DateTime.tryParse('${raw['heartbeatAt']}');
    if (holder is! String || holder.isEmpty) return null;
    if (acquired == null || heartbeat == null) return null;
    return TaskLock(
      holder: holder,
      acquiredAt: acquired,
      heartbeatAt: heartbeat,
      staleAfter: staleAfter,
    );
  }
}

/// 落在盘上的任务锁：`<dataDir>/locks/<taskId>.json`。
///
/// **用文件而不是内存**：Agent 与 GUI 是两个进程，只有磁盘是它们的公共地面。
/// 这也是整套 CLI 方案不需要进程间通信的同一个理由。
class TaskLockFile {
  final Directory dataDir;
  final String taskId;
  final Duration staleAfter;

  TaskLockFile({
    required this.dataDir,
    required this.taskId,
    this.staleAfter = defaultStaleAfter,
    bool Function(int pid)? processAlive,
  }) : processAlive = processAlive ?? isProcessAlive;

  /// 写锁的那个进程还在不在。默认问系统，单测里注入
  final bool Function(int pid) processAlive;

  File get _file => File(p.join(dataDir.path, 'locks', '$taskId.json'));

  /// 当前的锁。没有、或文件坏了都返回 null。
  ///
  /// **注意**：这里不判失效——失效与否取决于「什么时候看」，交给调用方用
  /// [TaskLock.isStale] 判断。
  TaskLock? read() {
    final file = _file;
    if (!file.existsSync()) return null;
    try {
      return TaskLock.tryFromJson(
        jsonDecode(file.readAsStringSync()),
        staleAfter,
      );
    } catch (e) {
      AppLog.warn('任务锁读不懂，当作没有锁（$taskId）：$e');
      return null;
    }
  }

  /// 拿锁。被别人持有且尚未失效时返回 false。
  bool acquire(String holder, {DateTime? now}) {
    final at = now ?? DateTime.now().toUtc();
    final current = read();
    if (current != null &&
        current.holder != holder &&
        !current.isStale(at, processAlive: processAlive)) {
      return false;
    }
    _write(TaskLock(holder: holder, acquiredAt: at, heartbeatAt: at));
    return true;
  }

  /// 续命。**不是持有者时什么都不做**——不能替别人续
  bool heartbeat(String holder, {DateTime? now}) {
    final at = now ?? DateTime.now().toUtc();
    final current = read();
    if (current == null || current.holder != holder) return false;
    _write(
      TaskLock(holder: holder, acquiredAt: current.acquiredAt, heartbeatAt: at),
    );
    return true;
  }

  /// 放锁。**不是持有者时什么都不做**——不能替别人放
  void release(String holder) {
    final current = read();
    if (current == null || current.holder != holder) return;
    try {
      _file.deleteSync();
    } catch (e) {
      AppLog.warn('释放任务锁失败（$taskId）：$e');
    }
  }

  /// 强制接管：人要抢就能抢。
  ///
  /// 这是产品定的出路——被一个还没超时的锁挡住时，用户总得有办法继续。
  /// 抢完之后原持有者的写入会被拒绝。
  void forceTakeover(String newHolder, {DateTime? now}) {
    final at = now ?? DateTime.now().toUtc();
    _write(TaskLock(holder: newHolder, acquiredAt: at, heartbeatAt: at));
  }

  void _write(TaskLock lock) {
    final file = _file;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(lock.toJson()));
  }
}

/// 这个进程号还在不在。
///
/// 用 `kill(pid, 0)` 的等价物：`ps -p` 查一次。只在开任务、拿锁这类稀疏
/// 时刻调用，不在热路径上。查不动就当它活着——保守方向是「不接管」，
/// 宁可让人多等一分钟，也不能把另一个真开着的窗口挤掉。
bool isProcessAlive(int pid) {
  return PlatformShell().isProcessAlive(pid);
}
