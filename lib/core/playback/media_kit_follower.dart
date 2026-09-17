import 'package:media_kit/media_kit.dart';

import '../log/app_log.dart';
import 'follower_track.dart';
import 'playback_gate.dart';

/// 用 media_kit 实现一条只出声的跟随轨。
///
/// 一个实例就是一个独立的 mpv 核心——真机实测同时跑三个（画面/口播/配乐）
/// 偏差在 ±70ms 以内且不累积。
class MediaKitFollower implements FollowerTrack {
  final Player player;

  /// 曲子比铺的那一段短时要循环（产品定的配乐原则：不够长就循环）。
  /// 口播轨不循环——它的长度本来就等于成片长度
  final bool loop;

  /// 命令与销毁之间的闸门。见 [PlaybackGate]：换源还没跑完就销毁，
  /// 会在 mpv 工作线程里触发 assert，整个进程 abort
  final PlaybackGate _gate = PlaybackGate();

  String? _loaded;

  MediaKitFollower({Player? player, this.loop = false})
      : player = player ?? Player();

  @override
  Future<bool> load(String? edl) async =>
      await _gate.run(() => _load(edl)) ?? false;

  Future<bool> _load(String? edl) async {
    if (edl == _loaded) return false;
    _loaded = edl;
    if (edl == null) {
      await player.stop();
      return true;
    }
    await player.open(Media(edl), play: false);
    // 播到结尾停住而不是卸载，否则位置会归零、纠偏逻辑会把主时钟拉回去
    await _setMpv('keep-open', 'yes');
    await _setMpv('loop-file', loop ? 'inf' : 'no');
    // 这一轨只要声音。不关视频解码的话，同一份画面会被解两遍白烧 CPU
    await _setMpv('vid', 'no');
    return true;
  }

  @override
  Future<void> play() => _gate.run(player.play);

  @override
  Future<void> pause() => _gate.run(player.pause);

  @override
  Future<void> seekMs(int ms) => _gate.run(
      () => player.seek(Duration(milliseconds: ms < 0 ? 0 : ms)));

  @override
  Future<void> setVolume(double volume) =>
      _gate.run(() => player.setVolume((volume.clamp(0.0, 1.0)) * 100));

  /// 上一次设的速率。同一个值不重复下发——每次都下发会让 mpv 反复重建
  /// 音频滤镜链，那本身就是一次可闻的顿挫
  double _rate = 1.0;

  @override
  Future<void> setRate(double rate) async {
    if ((rate - _rate).abs() < 0.001) return;
    _rate = rate;
    await _gate.run(() => player.setRate(rate));
  }

  @override
  int get positionMs => _loaded == null ? 0 : player.state.position.inMilliseconds;

  @override
  Future<void> dispose() => _gate.close(player.dispose);

  Future<void> _setMpv(String name, String value) async {
    final native = player.platform;
    if (native is! NativePlayer) return;
    try {
      await native.setProperty(name, value);
    } catch (e) {
      AppLog.warn('设置跟随轨属性失败（$name=$value）：$e');
    }
  }
}
