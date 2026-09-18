import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../log/app_log.dart';
import '../editing/frame_time.dart';
import 'frame_stepper.dart';
import 'playback_controller.dart';
import 'playback_gate.dart';

/// media_kit 实现（薄封装 [Player]）；`Video` 组件由 player_panel 使用。
class MediaKitPlaybackController implements MasterTrack {
  MediaKitPlaybackController({Player? player})
      : player = player ?? Player() {
    _videoController = VideoController(this.player);
    _diagnosticSubscriptions.add(this.player.stream.error.listen((error) {
      AppLog.warn('预览播放器错误：$error；position=${this.player.state.position.inMilliseconds}ms；'
          'playing=${this.player.state.playing}；buffering=${this.player.state.buffering}');
    }));
    _diagnosticSubscriptions.add(this.player.stream.videoParams.listen((params) {
      AppLog.info('预览视频参数：$params');
    }));
  }

  /// media_kit 底层播放器实例。
  final Player player;

  late final VideoController _videoController;
  final List<StreamSubscription<dynamic>> _diagnosticSubscriptions = [];

  /// 逐帧步进的锚点。按住方向键连发时不去读播放器位置（seek 是异步的，
  /// 位置还停在上一次的值，反推出旧帧号就会原地踏步）。
  final FrameStepper _stepper = FrameStepper();

  /// 命令与销毁之间的闸门。见 [PlaybackGate]：视频还没打开完就点返回，
  /// 旧写法会在 mpv 跑 loadlist 的当口把实例销毁，进程直接 abort。
  final PlaybackGate _gate = PlaybackGate();

  @override
  @override
  Future<void> clearSource() => _gate.run(() async {
        await player.stop();
      });

  @override
  Future<void> open(String path) => _gate.run(() async {
        await player.open(Media(path), play: false);
        // 播到文件结尾（或区间终点）时停在最后一帧，而不是卸载文件后黑屏。
        // 只设一次，之后区间播放只管改 `end`。
        await _setMpv('keep-open', 'yes');
      });

  /// 等文件真正加载完（时长已知）再返回。[open] 返回时 mpv 可能还在
  /// loadfile，这个当口发出的 seek 会被加载过程吞掉——参考弹窗
  /// 「每个分镜都从头播」就是这么来的。超时不抛：播放继续尝试，
  /// 大不了退回从头播，不能让弹窗卡死
  @override
  Future<void> waitUntilLoaded(
      {Duration timeout = const Duration(seconds: 5)}) async {
    if (player.state.duration > Duration.zero) return;
    try {
      await player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(timeout);
    } on TimeoutException {
      AppLog.warn('等待视频加载超时（${player.state.playlist.medias}）');
    }
  }

  /// 交给 mpv 自己在终点停：设 `end` 后播放器会正常播到该时间点前的最后
  /// 一帧然后暂停。在 Dart 层盯位置流判断「到点了没」做不到这一点——采样
  /// 粒度决定了它必然过头几十毫秒，再 seek 回去就是一次可见的回跳。
  @override
  Future<bool> playRange(int startMs, int endMs, double fps) async =>
      await _gate.run(() => _playRange(startMs, endMs, fps)) ?? false;

  Future<bool> _playRange(int startMs, int endMs, double fps) async {
    if (endMs <= startMs) return false;
    // 先定位再设终点：反过来的话，当前位置若已在终点之后，mpv 会立刻判 EOF
    final span = FrameSpan.fromMs(startMs, endMs, fps);
    // 上一段可能刚停在 EOF 状态，先解除再定位，否则 seek 会被 end 拦住
    await _setMpv('end', 'none');
    // 定位到这一段的**第一帧**，而不是 startMs 本身（后者未必是帧点）
    await seekMs(span.firstMs);
    final ok = await _setMpv('end', _mpvSeconds(span.withinLastFrameMs));
    if (!ok) return false;
    await player.play(); // 不走 play()：那里的 eof 处理会把刚设好的 end 清掉
    return true;
  }

  /// 解除区间限制。
  ///
  /// **先暂停再清**：mpv 在 `end` 处是以「EOF + keep-open」的形态停住的，
  /// 此时把 `end` 清掉，它会认为没有终点了而**自己恢复播放**（实测：停在
  /// 2615ms 之后二十秒，位置已经跑到 21 秒）。显式 pause 一次把它钉住。
  @override
  Future<void> clearRange() => _gate.run(() async {
        await player.pause();
        await _setMpv('end', 'none');
      });

  Future<String?> _getMpv(String name) async {
    final native = player.platform;
    if (native is! NativePlayer) return null;
    try {
      return await native.getProperty(name);
    } catch (e) {
      return 'ERR';
    }
  }

  /// mpv 的时间值用秒（小数）。毫秒整数除以 1000 保三位小数即可无损。
  static String _mpvSeconds(int ms) => (ms / 1000).toStringAsFixed(3);

  /// 设置 libmpv 属性；非原生实现或调用失败时返回 false 交由调用方降级，
  /// 不让一次属性设置失败把整个播放动作带崩
  Future<bool> _setMpv(String name, String value) async {
    final native = player.platform;
    if (native is! NativePlayer) return false;
    try {
      await native.setProperty(name, value);
      return true;
    } catch (e) {
      AppLog.warn('设置播放器属性失败（$name=$value）：$e');
      return false;
    }
  }


  /// 多轨模式下画面轨要静音——声音全部走口播轨与配乐轨。
  ///
  /// **必须真的把音频轨关掉，光把音量拧到 0 不行。** 音量 0 只是不出声，
  /// mpv 照样解码音频、照样拿它当同步基准；而画面轨的 EDL 里，变速切片是
  /// 无声的（声音归口播轨管），前后两段原片却有声——一条音频流在段之间
  /// 消失又出现，同步基准跟着断一次，播放器随后丢帧追赶。真机探针量到的是
  /// 从切片起点开始 1.67× 连跑 6.5 秒，把后面两三个镜头一起带跑了。
  ///
  /// 关掉之后画面轨只解码视频，段与段之间的轨道布局也就一致了。
  @override
  /// 彻底关掉这一路的音频解码。
  ///
  /// 画面轨拼的是几十条来路不同的素材，有的带音轨有的不带；播到「无音轨 →
  /// 有音轨」的接缝时，播放器要重新初始化整条音频链路，**主时钟会在那里
  /// 停住几秒**（真机：卡在 9955ms 不动，跟随轨被反复拽回同一处，听感就是
  /// 一个词反复念十几遍）。画面轨的声音本来就不该出——口播、配乐、素材原声
  /// 各有各的轨——所以干脆不解码，接缝也就不存在了
  Future<void> disableAudio() =>
      _gate.run(() => player.setAudioTrack(AudioTrack.no()));

  @override
  Future<void> setVolume(double volume) => _gate.run(() async {
        await player.setVolume((volume.clamp(0.0, 1.0)) * 100);
      });

  @override
  Future<void> setMuted(bool muted) => _gate.run(() async {
        await player.setVolume(muted ? 0 : 100);
        await _setMpv('aid', muted ? 'no' : 'auto');
      });

  @override
  Future<void> play() => _gate.run(_play);

  Future<void> _play() async {
    // 播到区间终点（或文件末尾）后 mpv 处于 eof-reached 状态，此时 play()
    // 的语义是**重新播放**——用户按空格想接着看，画面却从头开始（实测）。
    // 先原地 seek 一次把 eof 状态清掉，再播。
    // 播到区间终点（或文件末尾）后 mpv 处于 eof-reached 状态。此时：
    // - 直接 play() 的语义是**重新播放**，画面会从头开始（实测）；
    // - 而残留的 `end` 会让它刚播就又停。
    // 所以先解除区间、再原地 seek 一次把 eof 清掉，然后才真正播。
    if (await _getMpv('eof-reached') == 'yes') {
      final resumeAt = positionMs;
      await _setMpv('end', 'none');
      await player.seek(Duration(milliseconds: resumeAt));
    }
    _stepper.reset();
    await player.play();
  }

  @override
  Future<void> pause() => _gate.run(player.pause);

  @override
  Future<void> seekMs(int ms) => _gate.run(() {
        // 不是逐帧步进的定位：锚点作废，下一次步进重新以实际位置为准
        _stepper.reset();
        return player.seek(Duration(milliseconds: ms));
      });

  @override
  Future<void> stepFrames(int frames, double fps) => _gate.run(() => _step(frames, fps));

  Future<void> _step(int frames, double fps) async {
    await player.pause();
    final targetMs = _stepper.nextMs(
      positionMs: positionMs,
      frames: frames,
      fps: fps,
      durationMs: player.state.duration.inMilliseconds,
    );
    await player.seek(Duration(milliseconds: targetMs));
  }

  @override
  Stream<int> get positionMsStream =>
      player.stream.position.map((d) => d.inMilliseconds);

  @override
  Stream<bool> get playingStream => player.stream.playing;

  @override
  int get positionMs => player.state.position.inMilliseconds;

  @override
  bool get isPlaying => player.state.playing;

  /// 外挂音轨相对视频的偏移：显示视频 t 时播音频 (t - delay)。
  /// 原位预览一个镜头时用它把「整条配音」对齐到该镜的段上，零转码
  Future<void> setAudioDelayMs(int ms) => _gate.run(() async {
        await _setMpv('audio-delay', (ms / 1000).toStringAsFixed(3));
      });

  /// media_kit 原生支持外挂音轨（`AudioTrack.uri`），所以预览不必另起一个
  /// 播放器去追同步——画面与声音由同一个 mpv 对齐。
  @override
  Future<bool> setExternalAudio(String path) async =>
      await _gate.run(() async {
        await player.setAudioTrack(AudioTrack.uri(path));
        return true;
      }) ??
      false;

  @override
  Future<void> clearExternalAudio() =>
      _gate.run(() => player.setAudioTrack(AudioTrack.auto()));

  /// 先等在跑的命令收尾再销毁。直接 dispose 会在 mpv 工作线程跑命令的当口
  /// 抽掉它的配置，触发一次 `assert` 失败——整个进程 SIGABRT。
  @override
  Future<void> dispose() => _gate.close(() async {
    for (final subscription in _diagnosticSubscriptions) { await subscription.cancel(); }
    await player.dispose();
  });

  /// 构建视频画面组件：不带内置控制条，由外层（player_panel）自绘控制层。
  Widget buildVideoWidget() {
    return Video(
      controller: _videoController,
      controls: NoVideoControls,
    );
  }
}
