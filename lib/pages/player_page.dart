import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/media_source.dart';
import '../services/credential_store.dart';
import '../services/danmaku_service.dart';
import '../services/media_library.dart';
import '../services/playback_history.dart';
import '../services/playback_preferences.dart';
import '../services/player_host.dart';
import '../services/subtitle_service.dart';
import '../services/thumbnail_service.dart';
import '../services/webdav_service.dart';
import '../widgets/danmaku_overlay.dart';

/// 沉浸式播放页：media_kit 硬件解码 + WebDAV Basic 认证流。
///
/// 播放控制全部在页面层接管：
/// - 键盘快捷键（内建 MaterialDesktopVideoControls 的快捷键已置空，
///   避免空格/方向键被双重触发）
/// - 播完自动连播下一集
/// - 音轨/字幕/倍速面板
/// - 音量记忆（安全存储持久化）
/// - 进度每 10 秒自动保存，崩溃也不丢
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    required this.video,
    this.startPosition,
    this.episodes,
    super.key,
  });

  final ScannedVideo video;
  final double? startPosition;

  /// 同一部剧的集列表（含当前集），为空时只播当前这一个。
  final List<ScannedVideo>? episodes;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  // 播放器常驻复用（见 PlayerHost）：退出只 stop 不 dispose。
  late final Player _player = PlayerHost.player;
  late final VideoController _controller = PlayerHost.controller;
  final GlobalKey<VideoState> _videoKey = GlobalKey<VideoState>();
  final FocusNode _focusNode = FocusNode();
  final CredentialStore _store = CredentialStore();

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<double>? _volumeSub;
  StreamSubscription<Tracks>? _tracksSub;
  StreamSubscription<Track>? _trackSub;

  bool _seekedToStart = false;

  /// 续播跳转目标。跳转真正落地前保持加载遮罩，避免闪出片头画面。
  double? _resumeSeekTarget;
  Timer? _resumeSeekTimer;
  static const _resumeSeekTolerance = 3.0;
  double _positionSec = 0;
  double _durationSec = 0;
  double _lastSavedSec = 0;
  bool _mediaReady = false;

  /// 上次触发界面重建的秒数（进度 UI 按秒节流）。
  int _lastUiSecond = -1;
  double _lastThumbnailSec = -100;
  bool _capturingThumbnail = false;

  /// 常驻播放器会保留上一段视频的状态。新文件真正 open 完成前，
  /// 忽略 position/duration/completed 等旧事件，避免把上一集当成当前集。
  bool _acceptStreamEvents = false;
  int _openGeneration = 0;

  /// 当前这集的续播位置：切集后按各集自己的历史进度回跳。
  /// 旧版用 widget.startPosition，切到下一集也会被第一集的进度带偏。
  double? _resumeTarget;

  String? _errorMessage;
  String? _probeResult;

  /// 自检拿到网页而不是媒体流时，通常意味着地址缺少 WebDAV 路径前缀。
  bool get _probeLooksLikeWebPage =>
      _probeResult?.toLowerCase().contains('text/html') == true;
  List<SubtitleFile> _subtitleFiles = const [];
  String? _activeSubtitlePath;
  bool _loadingSubtitles = false;
  List<DanmakuComment> _danmakuComments = const [];
  bool _danmakuEnabled = false;
  bool _loadingDanmaku = false;
  List<DanmakuEpisode> _danmakuCandidates = const [];
  String? _danmakuEpisodeKey;

  /// 用户本次是否想要弹幕；切集后据此继续自动加载。
  bool _danmakuWanted = false;

  /// 弹幕时钟：position 流实时更新，弹幕层用它驱动逐帧重绘，
  /// 不经 setState（整页 setState 每帧重建是卡顿根源之一）。
  final ValueNotifier<double> _danmakuClock = ValueNotifier(0);

  /// 当前播放的条目（可切集）
  late ScannedVideo _current = widget.video;

  /// 倍速用 ValueNotifier 共享：media_kit 全屏会复制 controls 子树，
  /// 页面级 setState 不会重建全屏里的倍速按钮。
  final ValueNotifier<double> _speed = ValueNotifier<double>(1.0);
  static const _speedOptions = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

  /// 顶栏标题同样用共享通知：全屏控制层里的标题要能随切集更新。
  final ValueNotifier<String> _title = ValueNotifier<String>('');

  // 音量状态（mpv 音量 0-100）
  double _volume = 100;
  double _volumeBeforeMute = 100;
  bool _muted = false;
  Timer? _volumePersistTimer;

  // OSD 提示（倍速/音量/快进快退/连播/弹幕匹配结果）。
  // 必须用 ValueNotifier：media_kit 全屏会把 controls 复制到一个新路由，
  // 页面级 setState 不会重建那棵子树，只有共享的 Listenable 能同步过去。
  final ValueNotifier<String?> _osdMessage = ValueNotifier<String?>(null);
  Timer? _osdTimer;

  /// 自动连播进行中，防止 completed 重复触发。
  bool _advancing = false;

  /// 播放列表。调用方没传或只传了单集时，从媒体库按当前文件反查整组，
  /// 避免从「最近播放」打开第 N 集时上一集/下一集/选集全部消失。
  late final List<ScannedVideo> _playlist;

  int get _currentIndex {
    final index = _playlist.indexWhere((v) => v.path == _current.path);
    return index < 0 ? 0 : index;
  }

  bool get _hasNext => _currentIndex < _playlist.length - 1;
  bool get _hasPrev => _currentIndex > 0;

  /// 左上角标题：电影用片名，剧集用「剧名 · 第 N 集 · 单集标题」。
  String get _headerTitle {
    if (_current.kind == MediaKind.movie) return _current.title;
    final aggregated = MediaLibrary.instance.resolveAggregated(_current);
    final showTitle = MediaLibrary.normalizeSeriesTitle(
      (MediaLibrary.officialTitleOf(aggregated) ?? aggregated.title).trim(),
    );
    final episodeTitle = MediaLibrary.episodeDisplayTitle(
      _current,
      fallbackNumber: _currentIndex + 1,
    );
    return showTitle.isEmpty ? episodeTitle : '$showTitle · $episodeTitle';
  }

  @override
  void initState() {
    super.initState();
    final provided = widget.episodes;
    if (provided != null && provided.length > 1) {
      _playlist = provided;
    } else {
      final library = MediaLibrary.instance;
      final resolved = library.episodesOf(
        library.resolveAggregated(widget.video),
      );
      _playlist = resolved.length > 1 ? resolved : (provided ?? [widget.video]);
    }
    _positionSub = _player.stream.position.listen((position) {
      if (!_acceptStreamEvents) return;
      _positionSec = position.inMilliseconds / 1000;
      // 弹幕层逐帧时钟（ValueNotifier，不触发整页重建）
      _danmakuClock.value = _positionSec;
      final resumeTarget = _resumeSeekTarget;
      final resumeThreshold = resumeTarget == null
          ? null
          : (resumeTarget <= 5.0
                ? resumeTarget
                : resumeTarget - _resumeSeekTolerance);
      if (resumeThreshold != null && _positionSec >= resumeThreshold) {
        _resumeSeekTarget = null;
        _resumeSeekTimer?.cancel();
        if (mounted && !_mediaReady) {
          setState(() => _mediaReady = true);
        }
      }
      // 每 10 秒自动存档一次进度，应用崩溃/断电也能续播
      if (_durationSec > 0 &&
          _positionSec > 1 &&
          (_positionSec - _lastSavedSec).abs() >= 10) {
        _recordProgress();
      }
      // 进度条与时间标签只按秒展示，按秒节流重建；
      // 否则每个 position tick 都整页 setState，播放全程高负载。
      final second = position.inSeconds;
      if (mounted && second != _lastUiSecond) {
        _lastUiSecond = second;
        setState(() {
          if (_resumeSeekTarget == null &&
              _durationSec > 0 &&
              _positionSec > 1) {
            _mediaReady = true;
          }
        });
      }
    });
    _durationSub = _player.stream.duration.listen((duration) {
      if (!_acceptStreamEvents) return;
      _handleDuration(duration);
    });
    _errorSub = _player.stream.error.listen((error) {
      _debugLog('mpv error: $error');
      if (mounted && _errorMessage == null) {
        setState(() => _errorMessage = error);
      }
    });
    // 播完自动连播：记录完播进度后切下一集
    _completedSub = _player.stream.completed.listen((completed) async {
      if (!_acceptStreamEvents ||
          !completed ||
          _advancing ||
          _durationSec <= 0) {
        return;
      }
      await _recordProgress(finished: true);
      if (_hasNext && PlaybackPreferences.instance.autoPlayNext) {
        _advancing = true;
        try {
          await _switchTo(_playlist[_currentIndex + 1], osd: '即将播放下一集');
        } finally {
          _advancing = false;
        }
      } else if (_hasNext) {
        _showOsd('本集播完（自动连播已关闭）');
        await _player.pause();
      } else {
        _showOsd('本剧已播完');
        await _player.pause();
      }
    });
    // 暂停时立即存档
    _playingSub = _player.stream.playing.listen((playing) async {
      if (!_acceptStreamEvents ||
          playing ||
          _durationSec <= 0 ||
          _positionSec <= 1) {
        return;
      }
      await _recordProgress();
      await _captureThumbnail();
    });
    // 音量变化（含底部控制条滑条）同步到页面状态并持久化
    _volumeSub = _player.stream.volume.listen((value) {
      if (!mounted) return;
      setState(() {
        _volume = value;
        if (value > 0) _muted = false;
      });
      _scheduleVolumePersist();
    });
    // 轨道变化驱动顶栏「音轨/字幕」按钮的显隐
    _tracksSub = _player.stream.tracks.listen((_) {
      if (mounted) setState(() {});
    });
    _trackSub = _player.stream.track.listen((_) {
      if (mounted) setState(() {});
    });
    _restoreVolume();
    // 默认倍速来自 设置 → 播放
    _speed.value = PlaybackPreferences.instance.defaultSpeed;
    _title.value = _headerTitle;
    _open(initial: true);
  }

  void _handleDuration(Duration duration) {
    final wasZero = _durationSec <= 0;
    _durationSec = duration.inMilliseconds / 1000;
    if (wasZero && _durationSec > 0) {
      _debugLog('视频已就绪，时长 ${_durationSec.toStringAsFixed(1)} 秒');
      // 默认倍速在 open 后立即设置时，mpv 可能尚未接收媒体；时长就绪
      // 后再补一次，确保每次开播都按用户设置的速度播放。
      unawaited(_applySpeed(_speed.value, showOsd: false));
    }
    if (!_seekedToStart && _durationSec > 0) {
      _seekedToStart = true;
      final start = _resumeTarget ?? 0;
      if (start > 1) {
        // 从上次进度继续，按设置回退若干秒帮助衔接剧情
        final target = (start - PlaybackPreferences.instance.rewindSeconds)
            .clamp(0.0, _durationSec - 5);
        _resumeSeekTarget = target;
        _resumeSeekTimer?.cancel();
        // seek 指令不保证立刻出帧；给一个兜底，避免遮罩无限停留。
        _resumeSeekTimer = Timer(const Duration(milliseconds: 2500), () {
          if (!mounted || _resumeSeekTarget == null) return;
          setState(() {
            _resumeSeekTarget = null;
            _mediaReady = true;
          });
        });
        unawaited(
          _player.seek(Duration(milliseconds: (target * 1000).round())),
        );
      }
    }
    if (mounted) {
      setState(() {
        if (_resumeSeekTarget == null && _durationSec > 0 && _positionSec > 1) {
          _mediaReady = true;
        }
      });
    }
  }

  /// 启动时恢复上次的音量与静音状态（「记住音量」开启时）。
  Future<void> _restoreVolume() async {
    if (!PlaybackPreferences.instance.rememberVolume) return;
    try {
      final stored = await _store.read('framelet.player.volume');
      final value = double.tryParse(stored ?? '');
      if (value != null && value > 0 && value <= 100) {
        _volume = _volumeBeforeMute = value;
        await _player.setVolume(value);
      }
      if (await _store.read('framelet.player.mute') == '1') {
        _muted = true;
        await _player.setVolume(0);
      }
    } catch (_) {
      // 读取失败用默认音量
    }
  }

  void _scheduleVolumePersist() {
    if (!PlaybackPreferences.instance.rememberVolume) return;
    _volumePersistTimer?.cancel();
    _volumePersistTimer = Timer(const Duration(milliseconds: 800), () {
      _store
        ..write('framelet.player.volume', _volume.toStringAsFixed(0))
        ..write('framelet.player.mute', _muted ? '1' : '0');
    });
  }

  @override
  void dispose() {
    _recordProgress();
    _danmakuClock.dispose();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _errorSub?.cancel();
    _completedSub?.cancel();
    _playingSub?.cancel();
    _volumeSub?.cancel();
    _tracksSub?.cancel();
    _trackSub?.cancel();
    _volumePersistTimer?.cancel();
    _resumeSeekTimer?.cancel();
    _osdTimer?.cancel();
    _osdMessage.dispose();
    _speed.dispose();
    _title.dispose();
    _focusNode.dispose();
    // 常驻播放器：只停播、不销毁（见 PlayerHost）。mpv 的 render
    // context 释放与 terminate 都是同步 FFI，逐次销毁正是退出卡顿
    // 的根源。订阅已全部取消，stop 后不会再有回调进入本页。
    unawaited(_player.stop());
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 播放控制动作（键盘快捷键与按钮共用）
  // ---------------------------------------------------------------------------

  Future<void> _togglePlay() async {
    await _player.playOrPause();
  }

  Future<void> _seekBy(int seconds) async {
    if (_durationSec <= 0) return;
    final target = (_positionSec + seconds).clamp(0.0, _durationSec - 1);
    await _player.seek(Duration(milliseconds: (target * 1000).round()));
    _showOsd(seconds > 0 ? '快进 $seconds 秒' : '快退 ${-seconds} 秒');
  }

  Future<void> _changeVolume(double delta) async {
    final target = (_volume + delta).clamp(0.0, 100.0);
    await _player.setVolume(target);
    _showOsd(target <= 0 ? '静音' : '音量 ${target.round()}%');
  }

  Future<void> _toggleMute() async {
    if (_muted) {
      _muted = false;
      await _player.setVolume(_volumeBeforeMute <= 0 ? 100 : _volumeBeforeMute);
      _showOsd('取消静音');
    } else {
      if (_volume > 0) _volumeBeforeMute = _volume;
      _muted = true;
      await _player.setVolume(0);
      _showOsd('静音');
    }
    if (mounted) setState(() {});
    _scheduleVolumePersist();
  }

  Future<void> _toggleFullscreen() async {
    await _videoKey.currentState?.toggleFullscreen();
  }

  Future<void> _exitPlayer() async {
    await _captureThumbnail();
    if (!mounted) return;
    _refocus();
    Navigator.of(context).maybePop();
  }

  Future<void> _onEscape() async {
    if (_videoKey.currentState?.isFullscreen() ?? false) {
      await _videoKey.currentState?.exitFullscreen();
    } else {
      await _captureThumbnail();
      if (!mounted) return;
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _nextEpisode() async {
    if (_playlist.length < 2) {
      _showOsd('没有下一集');
      return;
    }
    if (!_hasNext) {
      _showOsd('已经是最后一集');
      return;
    }
    await _switchTo(_playlist[_currentIndex + 1]);
  }

  Future<void> _prevEpisode() async {
    if (_playlist.length < 2 || !_hasPrev) {
      _showOsd('没有上一集');
      return;
    }
    await _switchTo(_playlist[_currentIndex - 1]);
  }

  Future<void> _setSpeed(double rate) => _applySpeed(rate, showOsd: true);

  String _speedLabel(double rate) =>
      rate == rate.truncateToDouble() ? '${rate.toInt()}x' : '${rate}x';

  /// 设置播放速度。
  ///
  /// 常驻 Player 与全屏时附加的第二个 Video 会让 media_kit 的 setRate
  /// 偶发只更新 Dart 侧 state、mpv 的 speed 属性没有真正落地。这里在
  /// setRate 之后再直接写一次 native speed，并读回校验，保证画面真的变速。
  Future<void> _applySpeed(double rate, {required bool showOsd}) async {
    if (!mounted) return;
    final previous = _speed.value;
    _speed.value = rate;
    final platform = _player.platform;
    var applied = false;
    Object? failure;

    try {
      await _player.setRate(rate);
      applied = platform is! NativePlayer;
    } catch (error) {
      failure = error;
    }

    if (platform is NativePlayer) {
      try {
        await platform.setProperty('speed', rate.toStringAsFixed(3));
        await platform.setProperty('audio-pitch-correction', 'yes');
        final actual = double.tryParse(await platform.getProperty('speed'));
        if (actual == null || (actual - rate).abs() > 0.02) {
          await platform.command(['set', 'speed', rate.toStringAsFixed(3)]);
        }
        final verified = double.tryParse(await platform.getProperty('speed'));
        applied = verified == null || (verified - rate).abs() <= 0.02;
      } catch (error) {
        failure ??= error;
      }
    }

    if (!applied) {
      if (!mounted) return;
      _speed.value = previous;
      _debugLog('设置倍速失败: $failure');
      if (showOsd) _showOsd('倍速切换失败，请重试');
      return;
    }

    if (!mounted) return;
    _debugLog('倍速已切换: ${_speedLabel(rate)}');
    if (showOsd) {
      _showOsd(rate == 1.0 ? '正常倍速' : '${_speedLabel(rate)} 倍速');
    }
  }

  // ---------------------------------------------------------------------------
  // 打开与切集
  // ---------------------------------------------------------------------------

  /// 某一集自己的续播位置（看完的从头播）。
  double? _resumePositionOf(ScannedVideo video) {
    final entry = PlaybackHistory.instance.entryOf(video.sourceId, video.path);
    if (entry != null && !entry.finished && entry.positionSec > 1) {
      return entry.positionSec;
    }
    return null;
  }

  /// 切换到另一集：存档当前进度，重置状态并重新打开。
  Future<void> _switchTo(ScannedVideo video, {String? osd}) async {
    if (video.path == _current.path) return;
    await _recordProgress();
    _acceptStreamEvents = false;
    _resumeSeekTimer?.cancel();
    _resumeSeekTarget = null;
    setState(() {
      _current = video;
      _positionSec = 0;
      _durationSec = 0;
      _lastSavedSec = 0;
      _lastThumbnailSec = -100;
      _lastUiSecond = -1;
      _seekedToStart = false;
      _mediaReady = false;
      _errorMessage = null;
      _probeResult = null;
      _danmakuComments = const [];
      _danmakuCandidates = const [];
      _danmakuEpisodeKey = null;
      _danmakuEnabled = false;
    });
    _title.value = _headerTitle;
    if (osd != null) _showOsd(osd);
    _debugLog('切换剧集: ${video.title}');
    await _open();
  }

  Future<void> _open({bool initial = false}) async {
    final generation = ++_openGeneration;
    _acceptStreamEvents = false;
    _resumeSeekTimer?.cancel();
    _resumeSeekTarget = null;
    if (_mediaReady && mounted) {
      setState(() => _mediaReady = false);
    }
    _resumeTarget = initial
        ? (widget.startPosition ?? _resumePositionOf(_current))
        : _resumePositionOf(_current);
    // 让 mpv 在加载时就落在续播点，而不是先解码片头再 seek。
    // 只靠打开后的 seek 会闪出一帧片头；先设置 start 后，解码出的
    // 第一帧就是续播位置。
    final resumeStart = _resumeStartOf(_resumeTarget);
    if (resumeStart != null) {
      _resumeSeekTarget = resumeStart.inMilliseconds / 1000;
    }
    final library = MediaLibrary.instance;
    final source = library.sourceById(_current.sourceId);
    final password = library.passwordOf(_current.sourceId);
    if (source == null || (!source.isLocal && password == null)) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('媒体源或密码不存在，请到设置里重新同步')));
        Navigator.of(context).maybePop();
      }
      return;
    }
    final authPassword = password ?? '';
    var url = Uri.file(_current.path);
    final headers = <String, String>{};
    if (!source.isLocal) {
      final playTarget = await WebDavService.resolvePlayUrl(
        source,
        _current.path,
      );
      if (!mounted || generation != _openGeneration) return;
      url = playTarget.url;
      final auth = WebDavService.authHeader(source.username, authPassword);
      _probe(url, auth);
      headers['Authorization'] = auth;
      if (playTarget.hostHeader != null) {
        headers['Host'] = playTarget.hostHeader!;
      }
    }
    _debugLog('播放地址: $url');
    _debugLog('源文件路径: ${_current.path}');

    // 关键：libmpv 会读取系统环境变量 http_proxy/https_proxy 走代理，
    // 而本机 1501 代理不放行媒体服务器——必须显式禁用。
    final platform = _player.platform;
    if (platform is NativePlayer) {
      try {
        await platform.setProperty('http-proxy', '');
      } catch (error) {
        _debugLog('禁用 mpv 代理失败: $error');
      }
      // 硬件解码开关：关闭时走软解（设置 → 播放）
      try {
        await platform.setProperty(
          'hwdec',
          PlaybackPreferences.instance.hardwareDecode ? 'auto-safe' : 'no',
        );
      } catch (error) {
        _debugLog('设置硬件解码失败: $error');
      }
      // 网络流内存预读：标准给足日常缓冲，弱网再放大前向/后向缓存，
      // 用更多内存换更长的抗卡顿时长。改动下次打开生效。
      final prefs = PlaybackPreferences.instance;
      final (
        cacheMb,
        backCacheMb,
        readaheadSecs,
      ) = switch (prefs.networkCacheMode) {
        NetworkCacheMode.standard => (512, 128, 180),
        NetworkCacheMode.weak => (1024, 256, 600),
        NetworkCacheMode.custom => (
          prefs.customCacheMb,
          prefs.customBackCacheMb,
          prefs.customReadaheadSecs,
        ),
      };
      final cacheProperties = <String, String>{
        'demuxer-max-bytes': '${cacheMb * 1024 * 1024}',
        'demuxer-max-back-bytes': '${backCacheMb * 1024 * 1024}',
        'demuxer-readahead-secs': '$readaheadSecs',
      };
      for (final property in cacheProperties.entries) {
        try {
          await platform.setProperty(property.key, property.value);
        } catch (error) {
          _debugLog('设置 ${property.key} 失败: $error');
        }
      }
    }

    try {
      await _player.open(
        Media(url.toString(), httpHeaders: headers, start: resumeStart),
      );
      if (!mounted || generation != _openGeneration) return;
      _acceptStreamEvents = true;
      final duration = _player.state.duration;
      if (duration > Duration.zero) _handleDuration(duration);
      await _applySpeed(_speed.value, showOsd: false);
      _debugLog('open() 调用完成');
      unawaited(_loadSubtitleFiles(source, authPassword));
      // 自动加载弹幕（设置 → 播放），需先配置弹幕服务
      if ((PlaybackPreferences.instance.autoLoadDanmaku || _danmakuWanted) &&
          DanmakuService.configured) {
        unawaited(_loadDanmaku());
      }
    } catch (error) {
      if (generation == _openGeneration) _acceptStreamEvents = false;
      _debugLog('open() 异常: $error');
      if (mounted && generation == _openGeneration) {
        setState(() {
          _mediaReady = false;
          _errorMessage = MediaLibrary.describeError(error);
        });
      }
    }
  }

  /// 续播起点（已按设置回退），无有效进度时返回 null。
  Duration? _resumeStartOf(double? resumeTarget) {
    if (resumeTarget == null || resumeTarget <= 1) return null;
    final start = (resumeTarget - PlaybackPreferences.instance.rewindSeconds)
        .clamp(0.0, double.infinity);
    if (start <= 1) return null;
    return Duration(milliseconds: (start * 1000).round());
  }

  Future<void> _loadSubtitleFiles(MediaSource source, String password) async {
    if (mounted) {
      setState(() {
        _subtitleFiles = const [];
        _activeSubtitlePath = null;
        _loadingSubtitles = true;
      });
    }
    final videoPath = _current.path;
    final files = await SubtitleService.discover(source, videoPath, password);
    if (!mounted || videoPath != _current.path) return;
    setState(() {
      _subtitleFiles = files;
      _loadingSubtitles = false;
    });
  }

  Future<void> _applyExternalSubtitle(SubtitleFile subtitle) async {
    final source = MediaLibrary.instance.sourceById(_current.sourceId);
    if (source == null) return;
    _showOsd('正在加载字幕…');
    final path = await SubtitleService.materialize(
      subtitle: subtitle,
      source: source,
      password: MediaLibrary.instance.passwordOf(_current.sourceId) ?? '',
    );
    if (!mounted) return;
    if (path == null) {
      _showOsd('字幕加载失败');
      return;
    }
    await _player.setSubtitleTrack(
      SubtitleTrack.uri(
        Uri.file(path).toString(),
        title: subtitle.title,
        language: subtitle.language,
      ),
    );
    if (!mounted) return;
    setState(() => _activeSubtitlePath = subtitle.path);
    _showOsd('字幕：${subtitle.title}');
  }

  Future<void> _pickExternalSubtitle() async {
    const type = XTypeGroup(
      label: '字幕文件',
      extensions: ['srt', 'ass', 'ssa', 'vtt', 'sub'],
    );
    final selected = await openFile(acceptedTypeGroups: const [type]);
    if (selected == null || !mounted) return;
    final subtitle = SubtitleService.fromLocalFile(selected.path);
    setState(() {
      if (!_subtitleFiles.any((item) => item.path == subtitle.path)) {
        _subtitleFiles = [..._subtitleFiles, subtitle];
      }
    });
    await _applyExternalSubtitle(subtitle);
    _refocus();
  }

  Future<void> _toggleDanmaku() async {
    _debugLog(
      '弹幕开关点击: enabled=$_danmakuEnabled comments=${_danmakuComments.length} '
      'loading=$_loadingDanmaku host=${DanmakuService.displayHost}',
    );
    if (_danmakuEnabled) {
      setState(() {
        _danmakuEnabled = false;
        _danmakuWanted = false;
      });
      _showOsd('弹幕已关闭');
      return;
    }
    _danmakuWanted = true;
    // 已加载过就直接显示，不必重新请求（切集时会清空）
    if (_danmakuComments.isNotEmpty) {
      setState(() => _danmakuEnabled = true);
      _showOsd(_danmakuCoverageHint() ?? '弹幕已开启');
      return;
    }
    if (!DanmakuService.configured) {
      _debugLog('弹幕服务未配置');
      _showOsd('请先在 设置 → 弹幕 配置服务');
      return;
    }
    await _loadDanmaku();
  }

  /// 加载弹幕。[episodeId] 用于在已匹配的候选里切换弹幕源，
  /// [searchAgain] 会重新按当前集搜索一遍。
  Future<void> _loadDanmaku({
    String? candidateKey,
    bool searchAgain = false,
  }) async {
    if (_loadingDanmaku) {
      _debugLog('弹幕加载中，忽略重复请求');
      return;
    }
    setState(() => _loadingDanmaku = true);
    _showOsd('正在匹配弹幕…');
    try {
      var candidates = _danmakuCandidates;
      var query = '';
      var episodeNumber = 1;
      if (searchAgain || candidates.isEmpty || candidateKey == null) {
        final aggregated = MediaLibrary.instance.resolveAggregated(_current);
        query = MediaLibrary.normalizeSeriesTitle(
          MediaLibrary.officialTitleOf(aggregated) ?? aggregated.title,
        );
        episodeNumber = MediaLibrary.episodeNumberOfVideo(_current) ?? 1;
        _debugLog(
          '弹幕搜索: query="$query" episode=$episodeNumber '
          'sources=${DanmakuService.enabledBackends.map((item) => item.name).join('+')}',
        );
        candidates = await DanmakuService.searchEpisodes(
          anime: query,
          episode: episodeNumber,
        );
        _debugLog('弹幕搜索完成: ${candidates.length} 个源');
        if (!mounted) return;
        if (candidates.isEmpty) {
          _showOsd(
            '没有找到「$query」第 $episodeNumber 集的弹幕',
            duration: const Duration(seconds: 4),
          );
          return;
        }
        setState(() => _danmakuCandidates = candidates);
      }
      final selected = candidateKey == null
          ? candidates.first
          : candidates.firstWhere(
              (episode) => episode.key == candidateKey,
              orElse: () => candidates.first,
            );
      _debugLog(
        '拉取弹幕: ${selected.animeTitle} · ${selected.episodeTitle} '
        '(${selected.episodeId})',
      );
      final comments = await DanmakuService.comments(selected);
      _debugLog('弹幕拉取完成: ${comments.length} 条');
      if (!mounted) return;
      comments.sort((a, b) => a.timeSec.compareTo(b.timeSec));
      if (comments.isNotEmpty) {
        _debugLog(
          '弹幕时间范围: ${_clockText(comments.first.timeSec)} - '
          '${_clockText(comments.last.timeSec)}，当前 '
          '${_clockText(_positionSec)}',
        );
      }
      setState(() {
        _danmakuComments = comments;
        _danmakuEpisodeKey = selected.key;
        _danmakuEnabled = comments.isNotEmpty;
        _danmakuWanted = comments.isNotEmpty;
      });
      final coverageHint = _danmakuCoverageHint();
      _showOsd(
        comments.isEmpty
            ? '该节目暂无弹幕'
            : coverageHint ??
                  '弹幕已匹配「${selected.animeTitle} · ${selected.episodeTitle}」'
                      ' · ${comments.length} 条',
        duration: comments.isEmpty
            ? const Duration(seconds: 4)
            : const Duration(milliseconds: 1800),
      );
    } on DanmakuException catch (error) {
      _debugLog('弹幕加载失败: ${error.message}');
      if (mounted) {
        _showOsd(error.message, duration: const Duration(seconds: 4));
      }
    } catch (error) {
      _debugLog('弹幕加载异常: $error');
      if (mounted) {
        _showOsd('弹幕加载失败：$error', duration: const Duration(seconds: 4));
      }
    } finally {
      if (mounted) setState(() => _loadingDanmaku = false);
    }
  }

  /// 播放前探测文件地址：把 HTTP 状态码显示在错误卡片上，便于排查。
  Future<void> _probe(Uri url, String auth) async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 6);
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.authorizationHeader, auth);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      request.followRedirects = true;
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      final length = response.headers.contentLength;
      final detail =
          'HTTP ${response.statusCode}'
          '${length >= 0 ? ' · 大小 ${length ~/ 1024} KB' : ''}'
          '${response.headers.value('content-type') != null ? ' · ${response.headers.value('content-type')}' : ''}';
      _debugLog('自检: $detail');
      if (mounted) {
        setState(() => _probeResult = detail);
      }
      // 只关心响应头，绝不把整个视频流读进内存。
      try {
        final socket = await response.detachSocket();
        socket.destroy();
      } catch (_) {}
      client.close(force: true);
    } on TimeoutException {
      _debugLog('自检超时: $url');
      if (mounted) {
        setState(() => _probeResult = '超时（服务器无响应）· $url');
      }
    } catch (error) {
      _debugLog('自检失败: $error');
      if (mounted) {
        setState(() => _probeResult = '${error.runtimeType}: $error');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 进度记录
  // ---------------------------------------------------------------------------

  Future<void> _recordProgress({bool finished = false}) async {
    if (_durationSec <= 0) return;
    final position = finished ? _durationSec : _positionSec;
    if (!finished && position <= 1) return;
    _lastSavedSec = position;
    await PlaybackHistory.instance.record(
      HistoryEntry(
        sourceId: _current.sourceId,
        path: _current.path,
        title: _current.title,
        kind: _current.kind,
        positionSec: position,
        durationSec: _durationSec,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// 截取当前暂停帧并写入播放历史，供最近播放卡片展示。
  Future<void> _captureThumbnail() async {
    if (!mounted || !_mediaReady || _durationSec <= 0 || _positionSec <= 1) {
      return;
    }
    if (_capturingThumbnail) return;
    final position = _positionSec;
    if ((position - _lastThumbnailSec).abs() < 3) return;
    _capturingThumbnail = true;
    final sourceId = _current.sourceId;
    final videoPath = _current.path;
    try {
      final bytes = await _player.screenshot(format: 'image/jpeg');
      if (bytes == null || bytes.isEmpty) return;
      if (!mounted || videoPath != _current.path) return;
      final path = await ThumbnailService.save(bytes, sourceId, videoPath);
      if (path == null) return;
      _lastThumbnailSec = position;
      await PlaybackHistory.instance.setThumbnail(sourceId, videoPath, path);
    } catch (_) {
      // 截图失败不影响播放与续播。
    } finally {
      _capturingThumbnail = false;
    }
  }

  // ---------------------------------------------------------------------------
  // OSD 提示
  // ---------------------------------------------------------------------------

  void _showOsd(
    String message, {
    Duration duration = const Duration(milliseconds: 1800),
  }) {
    _osdTimer?.cancel();
    if (!mounted) return;
    _osdMessage.value = message;
    _osdTimer = Timer(duration, () {
      if (mounted) _osdMessage.value = null;
    });
  }

  /// 当前进度超过最后一颗弹幕时给出解释，避免误以为弹幕没加载。
  String? _danmakuCoverageHint() {
    if (_danmakuComments.isEmpty) return null;
    final last = _danmakuComments.last.timeSec;
    if (_positionSec <= last + 1) return null;
    return '当前进度暂无弹幕（该集弹幕止于 ${_clockText(last)}）';
  }

  static String _clockText(double seconds) {
    final total = seconds.round().clamp(0, 359999);
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  void _refocus() {
    if (mounted) _focusNode.requestFocus();
  }

  // ---------------------------------------------------------------------------
  // 面板：倍速 / 音轨 / 字幕 / 选集 / 影片信息
  // ---------------------------------------------------------------------------

  static const _languageNames = {
    'chi': '中文',
    'zho': '中文',
    'zh': '中文',
    'yue': '粤语',
    'eng': '英语',
    'en': '英语',
    'jpn': '日语',
    'ja': '日语',
    'kor': '韩语',
    'ko': '韩语',
    'fra': '法语',
    'fre': '法语',
    'deu': '德语',
    'ger': '德语',
    'rus': '俄语',
    'spa': '西班牙语',
    'tha': '泰语',
    'vie': '越南语',
    'ita': '意大利语',
    'por': '葡萄牙语',
  };

  static String? _languageName(String? code) {
    if (code == null) return null;
    final lower = code.toLowerCase().trim();
    if (lower.isEmpty || lower == 'und') return null;
    return _languageNames[lower] ?? code.toUpperCase();
  }

  String _audioLabel(AudioTrack track, int index) {
    final title = track.title?.trim();
    final lang = _languageName(track.language);
    if (title != null && title.isNotEmpty) {
      return lang == null ? title : '$title（$lang）';
    }
    return lang ?? '音轨 $index';
  }

  String _subtitleLabel(SubtitleTrack track, int index) {
    final title = track.title?.trim();
    final lang = _languageName(track.language);
    if (title != null && title.isNotEmpty) {
      return lang == null ? title : '$title（$lang）';
    }
    return lang ?? '字幕 $index';
  }

  List<AudioTrack> get _realAudioTracks => _player.state.tracks.audio
      .where((t) => t.id != 'auto' && t.id != 'no')
      .toList();

  List<SubtitleTrack> get _realSubtitleTracks => _player.state.tracks.subtitle
      .where((t) => t.id != 'auto' && t.id != 'no')
      .toList();

  // ---------------------------------------------------------------------------
  // 底部控制条：倍速 / 音轨 / 字幕 / 上一集 / 下一集
  // ---------------------------------------------------------------------------

  /// 弹出菜单的统一深色背景。
  static const _menuColor = Color(0xF21A1A1A);

  /// 菜单项统一外观：选中项左侧打勾并高亮。
  Widget _menuRow(String label, bool selected) {
    return Row(
      children: [
        SizedBox(
          width: 22,
          child: selected
              ? const Icon(
                  Icons.check_rounded,
                  size: 16,
                  color: Color(0xFF5B8CFF),
                )
              : null,
        ),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? Colors.white : Colors.white70,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }

  /// 统一样式的菜单项（当前选中项打勾）。
  PopupMenuItem<String> _menuItem(
    String value,
    String label,
    String currentId,
  ) => PopupMenuItem(
    value: value,
    height: 40,
    child: _menuRow(label, value == currentId),
  );

  /// 倍速按钮：显示当前倍速，点击向上弹菜单。
  Widget _buildSpeedButton() {
    return ValueListenableBuilder<double>(
      valueListenable: _speed,
      builder: (context, speed, _) => PopupMenuButton<double>(
        tooltip: '倍速',
        color: _menuColor,
        position: PopupMenuPosition.over,
        initialValue: speed,
        padding: EdgeInsets.zero,
        onSelected: (rate) {
          _refocus();
          _setSpeed(rate);
        },
        itemBuilder: (_) => [
          for (final rate in _speedOptions)
            PopupMenuItem(
              value: rate,
              height: 40,
              child: _menuRow(
                rate == 1.0 ? '正常' : _speedLabel(rate),
                rate == speed,
              ),
            ),
        ],
        child: _ControlButtonLabel(label: _speedLabel(speed)),
      ),
    );
  }

  /// 音轨按钮：常驻底部控制条（单音轨也保留入口，菜单里给提示），
  /// 点击向上弹菜单。
  Widget _buildAudioButton(List<AudioTrack> tracks) {
    final currentId = _player.state.track.audio.id;
    return PopupMenuButton<String>(
      tooltip: '音轨',
      color: _menuColor,
      position: PopupMenuPosition.over,
      padding: EdgeInsets.zero,
      onSelected: (id) async {
        _refocus();
        if (id == 'auto') {
          await _player.setAudioTrack(AudioTrack.auto());
          _showOsd('音轨：自动');
        } else {
          final track = tracks.firstWhere((t) => t.id == id);
          await _player.setAudioTrack(track);
          _showOsd('音轨：${_audioLabel(track, tracks.indexOf(track) + 1)}');
        }
      },
      itemBuilder: (_) => [
        _menuItem('auto', '自动', currentId),
        for (var i = 0; i < tracks.length; i++)
          _menuItem(tracks[i].id, _audioLabel(tracks[i], i + 1), currentId),
        if (tracks.length <= 1)
          const PopupMenuItem<String>(
            enabled: false,
            height: 34,
            child: Text(
              '该视频只有一条音轨',
              style: TextStyle(color: Colors.white30, fontSize: 12),
            ),
          ),
      ],
      child: const _ControlButtonLabel(
        icon: Icons.audiotrack_rounded,
        label: '音轨',
      ),
    );
  }

  /// 选集按钮：显示当前集数，点击弹出底部选集面板。
  Widget _buildEpisodeButton() {
    return Tooltip(
      message: '选集',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            _refocus();
            _showEpisodePicker();
          },
          child: _ControlButtonLabel(
            icon: Icons.video_library_rounded,
            label: '选集 ${_currentIndex + 1}/${_playlist.length}',
          ),
        ),
      ),
    );
  }

  /// 字幕按钮：常驻底部控制条（没内嵌字幕轨也保留入口，
  /// 菜单里给「无内嵌字幕轨」提示），支持关闭/自动/指定轨。
  Widget _buildSubtitleButton(List<SubtitleTrack> tracks) {
    final currentId = _player.state.track.subtitle.id;
    return PopupMenuButton<String>(
      tooltip: '字幕',
      color: _menuColor,
      position: PopupMenuPosition.over,
      padding: EdgeInsets.zero,
      onSelected: (id) async {
        _refocus();
        if (id == 'no') {
          await _player.setSubtitleTrack(SubtitleTrack.no());
          if (mounted) setState(() => _activeSubtitlePath = null);
          _showOsd('字幕已关闭');
        } else if (id == 'auto') {
          await _player.setSubtitleTrack(SubtitleTrack.auto());
          if (mounted) setState(() => _activeSubtitlePath = null);
          _showOsd('字幕：自动');
        } else if (id == 'pick') {
          await _pickExternalSubtitle();
        } else if (id.startsWith('external:')) {
          final path = id.substring('external:'.length);
          final subtitle = _subtitleFiles.where((item) => item.path == path);
          if (subtitle.isNotEmpty) {
            await _applyExternalSubtitle(subtitle.first);
          }
        } else {
          final track = tracks.firstWhere((t) => t.id == id);
          await _player.setSubtitleTrack(track);
          if (mounted) setState(() => _activeSubtitlePath = null);
          _showOsd('字幕：${_subtitleLabel(track, tracks.indexOf(track) + 1)}');
        }
      },
      itemBuilder: (_) => [
        _menuItem('no', '关闭字幕', currentId),
        _menuItem('auto', '自动', currentId),
        for (var i = 0; i < tracks.length; i++)
          _menuItem(tracks[i].id, _subtitleLabel(tracks[i], i + 1), currentId),
        if (_subtitleFiles.isNotEmpty) const PopupMenuDivider(),
        for (final subtitle in _subtitleFiles)
          PopupMenuItem<String>(
            value: 'external:${subtitle.path}',
            height: 40,
            child: _menuRow(
              subtitle.title,
              _activeSubtitlePath == subtitle.path,
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'pick',
          height: 40,
          child: Row(
            children: [
              const Icon(
                Icons.file_open_outlined,
                size: 16,
                color: Colors.white70,
              ),
              const SizedBox(width: 7),
              const Text(
                '加载外挂字幕…',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ),
        if (_loadingSubtitles)
          const PopupMenuItem<String>(
            enabled: false,
            height: 34,
            child: Text(
              '正在查找同名字幕…',
              style: TextStyle(color: Colors.white30, fontSize: 12),
            ),
          )
        else if (tracks.isEmpty && _subtitleFiles.isEmpty)
          const PopupMenuItem<String>(
            enabled: false,
            height: 34,
            child: Text(
              '未发现内嵌或同名字幕',
              style: TextStyle(color: Colors.white30, fontSize: 12),
            ),
          ),
      ],
      child: const _ControlButtonLabel(
        icon: Icons.subtitles_rounded,
        label: '字幕',
      ),
    );
  }

  /// 弹幕开关：点击直接弹出菜单。第一次点击会先匹配一次，
  /// 菜单里同时提供「开启/关闭」和已匹配的弹幕源。
  ///
  /// 按钮固定放在控制条右侧常显区域，避免被滚动手势吞掉点击。
  Widget _buildDanmakuSwitch() {
    return Builder(
      builder: (buttonContext) => Tooltip(
        message: '弹幕开关（点击选择弹幕源）',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => unawaited(_openDanmakuMenu(buttonContext)),
            borderRadius: BorderRadius.circular(6),
            child: _ControlButtonLabel(
              icon: _danmakuEnabled
                  ? Icons.chat_bubble_rounded
                  : Icons.chat_bubble_outline_rounded,
              label: _loadingDanmaku
                  ? '弹幕…'
                  : (_danmakuEnabled ? '弹幕开' : '弹幕关'),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openDanmakuMenu(BuildContext buttonContext) async {
    _debugLog(
      '弹幕菜单打开: enabled=$_danmakuEnabled '
      'candidates=${_danmakuCandidates.length} loading=$_loadingDanmaku',
    );
    _refocus();
    // 第一次点击先匹配一次，让菜单里直接出现可选的弹幕源。
    if (_danmakuCandidates.isEmpty && !_loadingDanmaku) {
      await _loadDanmaku();
    }
    if (!mounted || !buttonContext.mounted) return;
    final overlay =
        Overlay.of(buttonContext).context.findRenderObject() as RenderBox?;
    final box = buttonContext.findRenderObject() as RenderBox?;
    if (overlay == null || box == null || !box.hasSize) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final anchor = topLeft & box.size;
    final value = await showMenu<String>(
      context: buttonContext,
      color: _menuColor,
      position: RelativeRect.fromRect(anchor, Offset.zero & overlay.size),
      items: _danmakuMenuItems(),
    );
    if (!mounted || value == null) return;
    _debugLog('弹幕菜单选择: $value');
    if (value == 'toggle') {
      await _toggleDanmaku();
    } else if (value == 'seek-first') {
      if (_danmakuComments.isNotEmpty) {
        await _player.seek(
          Duration(
            milliseconds: (_danmakuComments.first.timeSec * 1000).round(),
          ),
        );
        _showOsd('已跳到有弹幕的位置');
      }
    } else if (value == 'reload') {
      await _loadDanmaku(searchAgain: true);
    } else if (value.startsWith('episode:')) {
      await _loadDanmaku(candidateKey: value.substring('episode:'.length));
    }
  }

  List<PopupMenuEntry<String>> _danmakuMenuItems() {
    return [
      if (_loadingDanmaku)
        const PopupMenuItem<String>(
          enabled: false,
          height: 44,
          child: Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: Colors.white54,
                ),
              ),
              SizedBox(width: 9),
              Text(
                '正在匹配弹幕…',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        )
      else
        PopupMenuItem<String>(
          value: 'toggle',
          height: 44,
          child: Row(
            children: [
              Icon(
                _danmakuEnabled
                    ? Icons.toggle_on_rounded
                    : Icons.toggle_off_rounded,
                size: 26,
                color: _danmakuEnabled
                    ? const Color(0xFF5B8CFF)
                    : Colors.white38,
              ),
              const SizedBox(width: 8),
              Text(
                _danmakuEnabled ? '关闭弹幕' : '开启弹幕',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ],
          ),
        ),
      if (_danmakuComments.isNotEmpty &&
          _positionSec > _danmakuComments.last.timeSec + 1)
        PopupMenuItem<String>(
          value: 'seek-first',
          height: 40,
          child: Row(
            children: [
              const Icon(
                Icons.fast_rewind_rounded,
                size: 18,
                color: Colors.white70,
              ),
              const SizedBox(width: 7),
              Text(
                '跳到有弹幕的位置（${_clockText(_danmakuComments.first.timeSec)}）',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ),
      if (_danmakuCandidates.isNotEmpty) ...[
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          enabled: false,
          height: 28,
          child: Text(
            '弹幕源（点击切换）',
            style: TextStyle(color: Colors.white38, fontSize: 11.5),
          ),
        ),
        for (final candidate in _danmakuCandidates.take(8))
          PopupMenuItem<String>(
            value: 'episode:${candidate.key}',
            height: 40,
            child: _menuRow(
              '[${candidate.backendLabel}] ${candidate.animeTitle} · '
              '${candidate.episodeTitle}',
              candidate.key == _danmakuEpisodeKey,
            ),
          ),
      ],
      const PopupMenuDivider(),
      const PopupMenuItem<String>(
        value: 'reload',
        height: 40,
        child: Row(
          children: [
            Icon(Icons.refresh_rounded, size: 17, color: Colors.white70),
            SizedBox(width: 7),
            Text(
              '重新匹配弹幕',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _buildDanmakuSettingsButton() {
    return _ControlIconButton(
      icon: Icons.tune_rounded,
      tooltip: '弹幕设置',
      onTap: _showDanmakuSettings,
    );
  }

  /// 弹幕显示设置：字号 / 不透明度 / 滚动时长 / 行数，改动即时生效。
  Future<void> _showDanmakuSettings() async {
    _refocus();
    final prefs = PlaybackPreferences.instance;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Widget sliderRow({
              required String label,
              required String valueLabel,
              required double min,
              required double max,
              required int divisions,
              required double value,
              required ValueChanged<double> onChanged,
            }) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        valueLabel,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      activeTrackColor: const Color(0xFF5B8CFF),
                      inactiveTrackColor: Colors.white24,
                      thumbColor: const Color(0xFF5B8CFF),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 12,
                      ),
                    ),
                    child: Slider(
                      value: value,
                      min: min,
                      max: max,
                      divisions: divisions,
                      label: valueLabel,
                      onChanged: (next) {
                        onChanged(next);
                        setSheetState(() {});
                      },
                    ),
                  ),
                ],
              );
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          '弹幕设置',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () {
                            unawaited(prefs.setDanmakuFontSize(22));
                            unawaited(prefs.setDanmakuOpacity(0.65));
                            unawaited(prefs.setDanmakuLifetime(14));
                            unawaited(prefs.setDanmakuLanes(6));
                            setSheetState(() {});
                          },
                          child: const Text(
                            '恢复默认',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    sliderRow(
                      label: '字号',
                      valueLabel: '${prefs.danmakuFontSize.round()}',
                      min: 12,
                      max: 30,
                      divisions: 18,
                      value: prefs.danmakuFontSize,
                      onChanged: (value) =>
                          unawaited(prefs.setDanmakuFontSize(value)),
                    ),
                    sliderRow(
                      label: '不透明度',
                      valueLabel: '${(prefs.danmakuOpacity * 100).round()}%',
                      min: 0.3,
                      max: 1,
                      divisions: 14,
                      value: prefs.danmakuOpacity,
                      onChanged: (value) =>
                          unawaited(prefs.setDanmakuOpacity(value)),
                    ),
                    sliderRow(
                      label: '滚动时长（越大越慢）',
                      valueLabel:
                          '${prefs.danmakuLifetime.toStringAsFixed(0)} 秒/屏',
                      min: 4,
                      max: 24,
                      divisions: 20,
                      value: prefs.danmakuLifetime,
                      onChanged: (value) =>
                          unawaited(prefs.setDanmakuLifetime(value)),
                    ),
                    sliderRow(
                      label: '显示行数',
                      valueLabel: '${prefs.danmakuLanes} 行',
                      min: 3,
                      max: 10,
                      divisions: 7,
                      value: prefs.danmakuLanes.toDouble(),
                      onChanged: (value) =>
                          unawaited(prefs.setDanmakuLanes(value.round())),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      '改动即时生效，下次播放沿用。',
                      style: TextStyle(color: Colors.white38, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    _refocus();
  }

  /// 右键弹出影片技术信息（分辨率/码率/编码/帧率等）。
  /// 对话框打开期间每秒刷新实时码率。
  Future<void> _showMediaInfo() async {
    final platform = _player.platform;
    await showDialog<void>(
      context: context,
      builder: (context) => _MediaInfoDialog(
        title: _current.title,
        durationSec: _durationSec,
        platform: platform is NativePlayer ? platform : null,
      ),
    );
    _refocus();
  }

  /// 选集面板：列出本剧所有集（含进度），点击切换。
  Future<void> _showEpisodePicker() async {
    final picked = await showModalBottomSheet<ScannedVideo>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.55,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
                  child: Text(
                    '选集（共 ${_playlist.length} 集）',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _playlist.length,
                    itemBuilder: (context, index) {
                      final episode = _playlist[index];
                      final selected = episode.path == _current.path;
                      final entry = PlaybackHistory.instance.entryOf(
                        episode.sourceId,
                        episode.path,
                      );
                      return ListTile(
                        dense: true,
                        onTap: () => Navigator.of(context).pop(episode),
                        leading: Icon(
                          selected
                              ? Icons.play_circle_fill_rounded
                              : Icons.play_circle_outline_rounded,
                          size: 20,
                          color: selected
                              ? const Color(0xFF2B65FF)
                              : Colors.white38,
                        ),
                        title: Text(
                          MediaLibrary.episodeDisplayTitle(
                            episode,
                            fallbackNumber: index + 1,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: selected ? Colors.white : Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                        trailing: entry != null && entry.progress > 0
                            ? Text(
                                entry.finished
                                    ? '已看完'
                                    : '已看 ${(entry.progress * 100).round()}%',
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 11.5,
                                ),
                              )
                            : null,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    _refocus();
    if (picked != null) await _switchTo(picked);
  }

  // ---------------------------------------------------------------------------
  // 界面
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: _shortcutBindings,
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onSecondaryTapDown: (_) => _showMediaInfo(),
          child: _buildScreen(context),
        ),
      ),
    );
  }

  /// 播放快捷键。页面层与 controls 层共用同一份：
  /// media_kit 全屏会新建只包含 Video 的路由，页面上的
  /// CallbackShortcuts 不在那棵子树里，只有 controls 的
  /// keyboardShortcuts 能跟过去。
  Map<ShortcutActivator, VoidCallback> get _shortcutBindings => {
    const SingleActivator(LogicalKeyboardKey.space): _togglePlay,
    const SingleActivator(LogicalKeyboardKey.keyK): _togglePlay,
    const SingleActivator(LogicalKeyboardKey.mediaPlayPause): _togglePlay,
    SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
        _seekBy(-PlaybackPreferences.instance.seekStep),
    SingleActivator(LogicalKeyboardKey.arrowRight): () =>
        _seekBy(PlaybackPreferences.instance.seekStep),
    const SingleActivator(LogicalKeyboardKey.keyJ): () => _seekBy(-10),
    const SingleActivator(LogicalKeyboardKey.keyL): () => _seekBy(10),
    const SingleActivator(LogicalKeyboardKey.arrowUp): () => _changeVolume(5),
    const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
        _changeVolume(-5),
    const SingleActivator(LogicalKeyboardKey.keyM): _toggleMute,
    const SingleActivator(LogicalKeyboardKey.keyF): _toggleFullscreen,
    const SingleActivator(LogicalKeyboardKey.f11): _toggleFullscreen,
    const SingleActivator(LogicalKeyboardKey.escape): _onEscape,
    const SingleActivator(LogicalKeyboardKey.keyN): _nextEpisode,
    const SingleActivator(LogicalKeyboardKey.keyP): _prevEpisode,
  };

  Widget _buildDanmakuOverlay() {
    if (!_danmakuEnabled || _danmakuComments.isEmpty) {
      return const SizedBox.shrink();
    }
    final prefs = PlaybackPreferences.instance;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Canvas 绘制：TextPainter 缓存 + ticker 驱动，不随播放页整页重建
        DanmakuOverlay(
          comments: _danmakuComments,
          clock: _danmakuClock,
          fontSize: prefs.danmakuFontSize,
          opacity: prefs.danmakuOpacity,
          lifetimeSeconds: prefs.danmakuLifetime,
          laneCount: prefs.danmakuLanes,
        ),
        // 进度越过最后一颗弹幕时的解释：用共享时钟驱动，全屏路由里
        // 也能随播放进度出现，而不是停在进入全屏那一刻的状态。
        ValueListenableBuilder<double>(
          valueListenable: _danmakuClock,
          builder: (context, position, _) {
            final last = _danmakuComments.last.timeSec;
            if (position <= last + 1) return const SizedBox.shrink();
            return IgnorePointer(
              child: Align(
                alignment: Alignment.topCenter,
                child: Container(
                  margin: const EdgeInsets.only(top: 84),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '当前进度暂无弹幕 · 该集弹幕止于 ${_clockText(last)}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  /// OSD 放进 Video 的 controls 子树：media_kit 全屏时只复制 controls，
  /// 页面级 Stack 上的提示在全屏里看不到。
  Widget _buildOsdOverlay() {
    return Positioned(
      top: 72,
      left: 0,
      right: 0,
      child: ValueListenableBuilder<String?>(
        valueListenable: _osdMessage,
        builder: (context, message, _) {
          if (message == null) return const SizedBox.shrink();
          return IgnorePointer(
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildScreen(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: MaterialDesktopVideoControlsTheme(
              normal: _desktopControlsTheme(showTopBar: false),
              fullscreen: _desktopControlsTheme(showTopBar: true),
              child: Video(
                key: _videoKey,
                controller: _controller,
                // 视频尚未就绪时不渲染控制条，避免其布局在零尺寸下溢出报错。
                //
                // 弹幕层必须放在 controls 里：media_kit 进入全屏时会新建
                // 一个只包含 Video 的路由，挂在播放页 Stack 上的覆盖层
                // 不会跟过去。controls 闭包会被复制到全屏 Video，因此
                // 普通模式和全屏模式都能看到同一层弹幕。
                controls: (state) => _durationSec <= 0
                    ? const SizedBox.shrink()
                    : Stack(
                        fit: StackFit.expand,
                        children: [
                          Positioned.fill(
                            child: AnimatedBuilder(
                              animation: PlaybackPreferences.instance,
                              builder: (_, _) => _buildDanmakuOverlay(),
                            ),
                          ),
                          Positioned.fill(
                            child: MaterialDesktopVideoControls(state),
                          ),
                          _buildOsdOverlay(),
                        ],
                      ),
              ),
            ),
          ),
          if (!_mediaReady && _errorMessage == null)
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.black,
                child: IgnorePointer(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 34,
                          height: 34,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.6,
                            color: Colors.white54,
                          ),
                        ),
                        SizedBox(height: 16),
                        Text(
                          '正在打开视频…',
                          style: TextStyle(color: Colors.white54, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (_errorMessage != null && !_mediaReady)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black,
                child: Center(
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: 560,
                      maxHeight: MediaQuery.of(context).size.height * 0.75,
                    ),
                    margin: const EdgeInsets.symmetric(horizontal: 40),
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            color: Colors.redAccent,
                            size: 40,
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            '播放失败',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _errorMessage!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              height: 1.6,
                            ),
                          ),
                          if (_probeResult != null) ...[
                            const SizedBox(height: 14),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.white10,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '地址自检：$_probeResult',
                                style: const TextStyle(
                                  color: Colors.amberAccent,
                                  fontSize: 12,
                                  height: 1.5,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          Text(
                            _probeLooksLikeWebPage
                                ? '服务器返回的是网页而不是视频文件：请检查媒体源地址'
                                      '是否为 WebDAV 地址（AList 通常以 /dav 结尾）。'
                                : '请检查媒体源密码是否变更，或稍后重试',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // 顶部标题栏：固定在顶部，避免被 StackFit.expand 拉到全屏居中
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: _buildTopBar(onBack: _exitPlayer),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 控制条主题：禁用内建键盘快捷键（由页面层统一接管）；
  /// 底部控制条挂上 上一集/下一集/选集/弹幕/音轨/字幕/倍速，内建的
  /// SkipPrevious/SkipNext 只会切 Player 内部播放列表（我们不用），换成自己的切集。
  ///
  /// 注意：media_kit 的底栏是一个不换行的 Row，电视剧多出「上一集/下一集」后
  /// 右侧按钮会被挤出可视区域（看起来像音轨/字幕按钮消失）。这里把右半部分
  /// 包进 Expanded + 横向滚动，窄窗口下也不会被裁掉。
  Widget _buildTopBar({required VoidCallback onBack}) {
    return Row(
      children: [
        _BackButton(onTap: onBack),
        const SizedBox(width: 10),
        Expanded(
          child: ValueListenableBuilder<String>(
            valueListenable: _title,
            builder: (context, title, _) => Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
              ),
            ),
          ),
        ),
      ],
    );
  }

  MaterialDesktopVideoControlsThemeData _desktopControlsTheme({
    required bool showTopBar,
  }) {
    final audioTracks = _realAudioTracks;
    final subtitleTracks = _realSubtitleTracks;
    final multi = _playlist.length > 1;
    return MaterialDesktopVideoControlsThemeData(
      keyboardShortcuts: _shortcutBindings,
      // 控制条收起后隐藏鼠标；全屏时不再一直显示箭头。
      hideMouseOnControlsRemoval: true,
      // 内建点击播放/暂停默认关闭；这里开启后，点击画面中间（避开底部
      // 进度条区域）即可暂停/继续，普通与全屏共用同一套主题。
      playAndPauseOnTap: true,
      // 全屏会新建只包含 Video + controls 的路由，页面级顶栏不在其中。
      // 把同一份标题栏挂到 controls 的 topButtonBar，鼠标移入时随控制条出现。
      topButtonBar: showTopBar
          ? [
              Expanded(
                child: Builder(
                  builder: (context) => _buildTopBar(
                    onBack: () => unawaited(exitFullscreen(context)),
                  ),
                ),
              ),
            ]
          : const [],
      topButtonBarMargin: const EdgeInsets.symmetric(horizontal: 14),
      bottomButtonBar: [
        if (multi)
          _ControlIconButton(
            icon: Icons.skip_previous_rounded,
            tooltip: '上一集（P）',
            onTap: _prevEpisode,
          ),
        const MaterialDesktopPlayOrPauseButton(),
        if (multi)
          _ControlIconButton(
            icon: Icons.skip_next_rounded,
            tooltip: '下一集（N）',
            onTap: _nextEpisode,
          ),
        const MaterialDesktopVolumeButton(),
        const MaterialDesktopPositionIndicator(),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (multi) _buildEpisodeButton(),
                // 紧贴音轨左侧，中间不留弹性空隙。
                _buildDanmakuSwitch(),
                _buildDanmakuSettingsButton(),
                // 音轨/字幕入口常显：电视剧单音轨、无内嵌字幕轨也要能点开确认
                _buildAudioButton(audioTracks),
                _buildSubtitleButton(subtitleTracks),
                _buildSpeedButton(),
                const SizedBox(width: 2),
                const MaterialDesktopFullscreenButton(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black38,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: Icon(Icons.arrow_back_rounded, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}

/// 排障日志：写入临时目录 framelet_player.log，便于直接读取真实状态。
void _debugLog(String message) {
  debugPrint('[Player] $message');
  try {
    final file = File('${Directory.systemTemp.path}/framelet_player.log');
    file.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $message\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {
    // 日志失败不影响播放
  }
}

/// 底部控制条的图标按钮（上一集/下一集）——内建 Skip 按钮走 Player 内部
/// 播放列表（我们不用），所以自己接切集逻辑。
class _ControlIconButton extends StatelessWidget {
  const _ControlIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onTap,
        iconSize: 24,
        color: Colors.white,
        padding: const EdgeInsets.all(8),
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        splashRadius: 20,
        icon: Icon(icon),
      ),
    );
  }
}

/// 底部控制条的胶囊按钮外观：可同时显示图标与文字（音轨/字幕），
/// 或只显示文字（倍速）。
class _ControlButtonLabel extends StatelessWidget {
  const _ControlButtonLabel({this.label, this.icon});

  final String? label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) Icon(icon, color: Colors.white, size: 19),
          if (icon != null && label != null) const SizedBox(width: 4),
          if (label != null)
            Text(
              label!,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}

/// 影片技术信息对话框：静态参数读一次，码率每秒轮询 mpv 实时刷新。
///
/// mpv 的 video-bitrate/audio-bitrate 是即时码率（流媒体/可变码率会跳动），
/// 只读一次就没意义了；这里用 1 秒定时器刷新，并显示「实时」标记。
class _MediaInfoDialog extends StatefulWidget {
  const _MediaInfoDialog({
    required this.title,
    required this.durationSec,
    required this.platform,
  });

  final String title;
  final double durationSec;
  final NativePlayer? platform;

  @override
  State<_MediaInfoDialog> createState() => _MediaInfoDialogState();
}

class _MediaInfoDialogState extends State<_MediaInfoDialog> {
  final Map<String, String> _static = {};
  String? _videoBitrate;
  String? _audioBitrate;
  Timer? _rateTimer;

  /// 行的展示顺序（文件名单独放首）。
  static const _order = [
    '分辨率',
    '帧率',
    '视频编码',
    '视频码率',
    '音频编码',
    '音频码率',
    '声道',
    '采样率',
    '文件大小',
    '时长',
    '平均码率',
  ];

  @override
  void initState() {
    super.initState();
    _loadStatic();
    _rateTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _refreshRates(),
    );
    _refreshRates();
  }

  @override
  void dispose() {
    _rateTimer?.cancel();
    super.dispose();
  }

  Future<String?> _read(String property) async {
    final platform = widget.platform;
    if (platform == null) return null;
    try {
      final value = await platform.getProperty(property);
      if (value.isEmpty || value == 'no') return null;
      return value;
    } catch (_) {
      return null;
    }
  }

  /// mpv 即时码率是 "2498312.000000" 这类浮点字符串，必须 double 解析。
  /// 不可用时 mpv 会返回 "nan"，必须过滤掉，否则会显示成 "NaN Mbps"。
  String? _formatBitrate(String? raw) {
    final bps = double.tryParse((raw ?? '').trim());
    if (bps == null || !bps.isFinite || bps <= 0) return null;
    return _prettyBitrate(bps);
  }

  static String _prettyBitrate(double bps) {
    final mbps = bps / 1000000;
    return mbps >= 1
        ? '${mbps.toStringAsFixed(1)} Mbps'
        : '${(bps / 1000).toStringAsFixed(0)} Kbps';
  }

  Future<void> _refreshRates() async {
    if (widget.platform == null) return;
    final video = _formatBitrate(await _read('video-bitrate'));
    final audio = _formatBitrate(await _read('audio-bitrate'));
    if (!mounted) return;
    if (video == _videoBitrate && audio == _audioBitrate) return;
    setState(() {
      _videoBitrate = video;
      _audioBitrate = audio;
    });
  }

  Future<void> _loadStatic() async {
    final result = <String, String>{};
    final width = await _read('video-params/w');
    final height = await _read('video-params/h');
    if (width != null && height != null) {
      result['分辨率'] = '$width × $height';
    }
    final fps = await _read('container-fps') ?? await _read('video-params/fps');
    if (fps != null) {
      final parsed = double.tryParse(fps);
      if (parsed != null) result['帧率'] = '${parsed.toStringAsFixed(2)} fps';
    }
    final videoCodec = await _read('video-codec-name');
    if (videoCodec != null) result['视频编码'] = videoCodec.toUpperCase();
    final audioCodec = await _read('audio-codec-name');
    if (audioCodec != null) result['音频编码'] = audioCodec.toUpperCase();
    final channels = await _read('audio-params/channel-count');
    if (channels != null) result['声道'] = '$channels 声道';
    final sampleRate = await _read('audio-params/samplerate');
    if (sampleRate != null) {
      final khz = double.tryParse(sampleRate);
      if (khz != null) result['采样率'] = '${(khz / 1000).toStringAsFixed(1)} kHz';
    }
    final size = int.tryParse(await _read('file-size') ?? '');
    if (size != null && size > 0) {
      final gb = size / (1024 * 1024 * 1024);
      result['文件大小'] = gb >= 1
          ? '${gb.toStringAsFixed(2)} GB'
          : '${(size / 1024 / 1024).toStringAsFixed(0)} MB';
    }
    if (widget.durationSec > 0) {
      final minutes = widget.durationSec ~/ 60;
      final seconds = (widget.durationSec % 60).toInt();
      result['时长'] = '$minutes 分 ${seconds.toString().padLeft(2, '0')} 秒';
      // 文件平均码率（总码率，含音视频），即时码率取不到时的兜底。
      // file-size 单位是字节，码率是比特/秒，必须 ×8，否则只有真实值的 1/8。
      if (size != null && size > 0) {
        result['平均码率'] = _prettyBitrate(size * 8 / widget.durationSec);
      }
    }
    if (!mounted) return;
    setState(() {
      _static
        ..clear()
        ..addAll(result);
    });
  }

  List<MapEntry<String, String>> _rows() {
    final values = <String, String>{
      ..._static,
      '视频码率': ?_videoBitrate,
      '音频码率': ?_audioBitrate,
    };
    return [
      MapEntry('文件名', widget.title),
      for (final key in _order)
        if (values[key] != null) MapEntry(key, values[key]!),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows();
    return Dialog(
      backgroundColor: const Color(0xF21A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Container(
        width: 560,
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '影片信息',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final row in rows)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 9),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 92,
                              child: Text(
                                row.key,
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                            Expanded(
                              child: SelectableText(
                                row.value,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12.5,
                                  height: 1.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
