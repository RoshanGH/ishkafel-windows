import 'dart:async';
import 'dart:math' as math;

/// 播放控制抽象：UI 只依赖它，测试注入 [FakePlaybackController]，
/// 生产环境注入 `MediaKitPlaybackController`。
abstract class PlaybackController {
  /// 打开并暂停在首帧。
  Future<void> open(String path);

  /// 等文件真正加载完再返回。
  ///
  /// **换源之后的 seek 必须等它**：`open` 返回时播放器可能还在 loadfile，
  /// 这个当口发出的 seek 会被加载过程整个吞掉，位置就停在片头。
  /// 2026-09-09 真机：调字幕样式时切片重烧一次就换一次源，人正对着第 45 秒
  /// 那一镜调位置，一拖就被扔回 00:00 —— 还原的那一下发出去了，只是没人接。
  ///
  /// 默认什么都不做：不是所有实现都需要等（测试假件、空实现）。
  Future<void> waitUntilLoaded() async {}

  /// 开始播放。
  Future<void> play();

  /// 暂停播放。
  Future<void> pause();

  /// 跳转到指定毫秒位置。
  Future<void> seekMs(int ms);

  /// 播放 [startMs, endMs) 并**由播放器自己**在终点停住。
  ///
  /// 为什么必须交给播放器：在外面盯位置流判「到点了没」，采样粒度决定了它
  /// 必然过头几十毫秒，再 seek 回去就是一次肉眼可见的回跳。用户要的是一帧
  /// 一帧正常播到最后一帧然后停，不是播过了再倒带。
  ///
  /// 返回 false 表示当前实现没有这个能力，调用方据此降级（不要假装停得住）。
  Future<bool> playRange(int startMs, int endMs, double fps);

  /// 解除区间限制，恢复成一直往下播
  Future<void> clearRange();

  /// 卸掉当前播放源，画面回到空。
  ///
  /// 存在的理由：**「没有东西可播」和「什么都不做」是两回事**。后者会让
  /// 播放器一直挂着上一次打开的内容——真机上撞到过：新建的空白任务里播着
  /// 上一条成片的一帧，用户完全没法理解那画面从哪来的。
  Future<void> clearSource();

  /// 按帧步进（暂停态逐帧）：`frames` 为正前进、为负后退，`fps` 为素材帧率。
  Future<void> stepFrames(int frames, double fps);

  /// 播放位置流（毫秒）。
  Stream<int> get positionMsStream;

  /// 播放/暂停状态流：随 [play]/[pause] 或任何外部原因（如播放到片尾自动
  /// 暂停）变化而推送最新值，供 UI 保持图标与真实状态同步，而不是靠本地
  /// 变量盲目翻转。
  Stream<bool> get playingStream;

  /// 当前播放位置（毫秒）。
  int get positionMs;

  /// 是否正在播放。
  bool get isPlaying;

  /// 挂一条**外挂音轨**：画面照播原片，声音改用这个文件。
  ///
  /// 预览要听到的是「配音替换 + 配乐叠加」之后的成品声音，而它与原片自带的
  /// 那条音轨不是一回事。外挂音轨由播放器自己与画面对齐，比另起一个播放器
  /// 去追同步可靠得多。
  ///
  /// 返回 false 表示这个实现做不到，调用方据此降级（照常播原声，不假装换了）。
  Future<bool> setExternalAudio(String path);

  /// 换回原片自带的音轨
  Future<void> clearExternalAudio();

  /// 释放底层资源。
  Future<void> dispose();
}

/// 多轨里的**画面轨**：比普通播放器多一个静音开关。
///
/// 画面轨播的可能是候选素材，那条素材自带的声音该不该出由口播轨按替换规格
/// 决定（整体替换要、镜头替换不要）——画面轨出声只会变成两份声音重叠。
///
/// 抽成接口不只是为了整齐：换方案时「画面没变就一帧不动、正在播就接着播、
/// 按逻辑位置恢复」这三条规矩全在 [MultitrackPlayback.setPlan] 里，
/// 不能注入替身就只能靠反复戳界面去验，那不是验证。
/// 原生播放器可能在打开命令返回之后才报告解码/读取错误。
abstract class PlaybackErrorSource {
  Stream<String> get playbackErrors;
}

abstract class MasterTrack implements PlaybackController {
  Future<void> setMuted(bool muted);

  /// 关掉这一路的音频解码（画面轨用；见 MediaKitPlaybackController.disableAudio）
  Future<void> disableAudio();

  /// 画面轨自己的音量（0~1）：素材原声要不要出、出多大。
  /// 分镜自带的声音里常有音效，全丢掉片子会发干；但它又不能盖过口播
  Future<void> setVolume(double volume);
}

/// 测试替身：内存位置模拟，记录调用，零 libmpv 依赖。
class FakePlaybackController implements MasterTrack {
  final List<String> calls = [];

  /// 假件里文件是「立刻就绪」的，等于不用等
  @override
  Future<void> waitUntilLoaded() async => calls.add('waitUntilLoaded');

  @override
  Future<void> clearSource() async => calls.add('clearSource');

  final StreamController<int> _positionController =
      StreamController<int>.broadcast();
  final StreamController<bool> _playingController =
      StreamController<bool>.broadcast();

  int _positionMs = 0;
  bool _isPlaying = false;

  /// 静音状态（测试断言用）
  bool muted = false;

  /// 画面轨音量（测试断言用）
  double volume = 1.0;

  @override
  Future<void> setMuted(bool value) async {
    muted = value;
    calls.add('setMuted:$value');
  }

  @override
  Future<void> setVolume(double value) async {
    volume = value;
    calls.add('setVolume:$value');
  }

  /// 音频解码是否已关（测试断言用）
  bool audioDisabled = false;

  @override
  Future<void> disableAudio() async {
    audioDisabled = true;
    calls.add('disableAudio');
  }

  /// 测试里模拟主时钟走到某一刻
  void emitPosition(int ms) {
    _positionMs = ms;
    _positionController.add(ms);
  }

  @override
  Future<bool> setExternalAudio(String path) async {
    calls.add('setExternalAudio:$path');
    externalAudio = path;
    return true;
  }

  @override
  Future<void> clearExternalAudio() async {
    calls.add('clearExternalAudio');
    externalAudio = null;
  }

  /// 当前挂着的外挂音轨（测试断言用）
  String? externalAudio;

  @override
  Future<void> open(String path) async {
    calls.add('open($path)');
    _positionMs = 0;
    _isPlaying = false;
    _positionController.add(_positionMs);
    _playingController.add(_isPlaying);
  }

  @override
  Future<void> play() async {
    calls.add('play()');
    _isPlaying = true;
    _playingController.add(_isPlaying);
  }

  @override
  Future<void> pause() async {
    calls.add('pause()');
    _isPlaying = false;
    _playingController.add(_isPlaying);
  }

  @override
  Future<void> seekMs(int ms) async {
    calls.add('seekMs($ms)');
    _positionMs = math.max(0, ms);
    _positionController.add(_positionMs);
  }

  /// 是否具备区间播放能力（测试可置 false 来验证降级路径）
  bool supportsRange = true;

  @override
  Future<bool> playRange(int startMs, int endMs, double fps) async {
    calls.add('playRange($startMs, $endMs)');
    if (!supportsRange) return false;
    await seekMs(startMs);
    await play();
    return true;
  }

  @override
  Future<void> clearRange() async => calls.add('clearRange()');

  @override
  Future<void> stepFrames(int frames, double fps) async {
    calls.add('stepFrames($frames, $fps)');
    final deltaMs = (1000 / fps).round() * frames;
    _positionMs = math.max(0, _positionMs + deltaMs);
    _positionController.add(_positionMs);
  }

  @override
  Stream<int> get positionMsStream => _positionController.stream;

  @override
  Stream<bool> get playingStream => _playingController.stream;

  @override
  int get positionMs => _positionMs;

  @override
  bool get isPlaying => _isPlaying;

  @override
  Future<void> dispose() async {
    calls.add('dispose()');
    await _positionController.close();
    await _playingController.close();
  }
}
