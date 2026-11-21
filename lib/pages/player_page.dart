import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/utils/device_profile.dart';
import '../models/media_source.dart';
import '../services/credential_store.dart';
import '../services/danmaku_service.dart';
import '../services/jellyfin_service.dart';
import '../services/media_library.dart';
import '../services/playback_history.dart';
import '../services/playback_preferences.dart';
import '../services/player_host.dart';
import '../services/screen_control_service.dart';
import '../services/skip_marks.dart';
import '../services/skip_marks_service.dart';
import '../services/subtitle_preferences.dart';
import '../services/subtitle_service.dart';
import '../services/thumbnail_service.dart';
import '../services/webdav_service.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/subtitle_picker_dialog.dart';

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

  /// 本集是否已经尝试套用过「上次的字幕选择」。每集只套用一次，
  /// 避免用户手动改选后又被记忆覆盖；切集时重置。
  bool _subtitleRestored = false;

  /// 本集的同名字幕是否已发现完。外挂字幕要等它，否则会在文件列表
  /// 还是空的时候误判成「本集没有对应字幕」。
  bool _subtitleDiscoveryDone = false;

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

  /// 「当前进度暂无弹幕」浮层：只在用户主动开启/换源后显示，
  /// 静默自动加载与换集不显示，避免每集结尾都挂一条提示。
  bool _danmakuEmptyHintVisible = false;
  Timer? _danmakuHintTimer;

  /// 本剧的片头片尾标记（整部剧共用）。
  SeriesSkipMarks _skipMarks = const SeriesSkipMarks();

  /// 当前标记的来源：手动标注 / 在线识别。
  SkipMarkSource _skipSource = SkipMarkSource.none;

  /// 本集是否已跳过片头/片尾，避免重复跳转或重复提示。
  bool _introSkipped = false;
  bool _outroSkipped = false;
  bool _skipSeeking = false;
  final ValueNotifier<SkipPrompt> _skipPrompt = ValueNotifier(SkipPrompt.none);
  Timer? _outroCountdownTimer;
  final ValueNotifier<int> _outroCountdown = ValueNotifier(0);

  static const _outroCountdownSeconds = 5;

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

  // ---------------------------- Android TV ----------------------------
  /// 电视遥控：控制条常驻焦点态，任意按键可唤出，播放中自动收起。
  bool get _isTv => DeviceProfile.instance.isTelevision;
  bool _tvControlsVisible = false;
  Timer? _tvHideTimer;
  final FocusNode _tvPlayFocus = FocusNode(debugLabel: 'tv-play');
  double? _tvScrubSeconds;

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
        _evaluateSkipPrompt();
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
      if (_isTv && mounted) setState(() {});
      if (_isTv) {
        if (playing) {
          if (_tvControlsVisible) _scheduleTvHide();
        } else if (_durationSec > 0 && !_tvControlsVisible) {
          // 暂停常发生在“看完了想停一下”的时刻，直接把控制条亮出来。
          _showTvControls();
        } else {
          _tvHideTimer?.cancel();
        }
      }
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
      if (!mounted) return;
      setState(() {});
      // 内嵌轨是新文件打开后才枚举出来的；还没套用过记忆时补一次。
      if (!_subtitleRestored && _acceptStreamEvents) {
        unawaited(_restoreSubtitleChoice());
      }
    });
    _trackSub = _player.stream.track.listen((_) {
      if (mounted) setState(() {});
    });
    _restoreVolume();
    // 默认倍速来自 设置 → 播放
    _speed.value = PlaybackPreferences.instance.defaultSpeed;
    _title.value = _headerTitle;
    unawaited(_loadSkipMarks());
    _open(initial: true);
    if (_isTv) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showTvControls();
      });
    }
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
    _danmakuHintTimer?.cancel();
    _outroCountdownTimer?.cancel();
    _outroCountdown.dispose();
    _skipPrompt.dispose();
    _osdTimer?.cancel();
    _osdMessage.dispose();
    _tvHideTimer?.cancel();
    _tvPlayFocus.dispose();
    _speed.dispose();
    _title.dispose();
    _focusNode.dispose();
    unawaited(ScreenControlService.instance.resetBrightness());
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

  // ---------------------------------------------------------------------------
  // 跳过片头 / 片尾
  // ---------------------------------------------------------------------------

  /// 读取片头片尾：手动标记按「部」保存，其次是在线识别（按集缓存）。
  Future<void> _loadSkipMarks() async {
    final video = _current;
    final autoKey = SkipMarksService.cacheKeyFor(video);
    var auto = autoKey.isEmpty
        ? null
        : await SkipMarksStore.instance.autoMarksOf(autoKey);
    if (auto == null &&
        autoKey.isNotEmpty &&
        PlaybackPreferences.instance.autoSkipFromDatabase) {
      final fetched = await SkipMarksService.fetch(video);
      if (fetched != null) {
        auto = fetched;
        unawaited(SkipMarksStore.instance.saveAuto(autoKey, fetched));
        _debugLog('片头片尾在线识别: ${fetched.toJson()}');
      } else {
        _debugLog('片头片尾在线识别失败: ${SkipMarksService.lastError}');
      }
    }
    if (!mounted || video.path != _current.path) return;
    final result = await SkipMarksStore.instance.resolve(video, auto: auto);
    if (!mounted || video.path != _current.path) return;
    setState(() {
      _skipMarks = result.marks;
      _skipSource = result.source;
    });
    _evaluateSkipPrompt();
  }

  /// 按当前进度决定是否显示「跳过片头/片尾」。
  void _evaluateSkipPrompt() {
    if (_skipSeeking || _skipMarks.isEmpty) {
      _cancelOutroCountdown();
      if (_skipPrompt.value != SkipPrompt.none) {
        _skipPrompt.value = SkipPrompt.none;
      }
      return;
    }
    final prompt = SkipPromptResolver.resolve(
      marks: _skipMarks,
      positionSec: _positionSec,
      durationSec: _durationSec,
      introSkipped: _introSkipped,
      outroSkipped: _outroSkipped,
    );
    if (_skipPrompt.value == prompt) return;
    _skipPrompt.value = prompt;
    final prefs = PlaybackPreferences.instance;
    // 自动跳过只做一次：跳完把本集标记置位，手动回拖不再反复触发。
    if (prompt == SkipPrompt.intro && prefs.autoSkipIntro) {
      unawaited(_skipIntro(auto: true));
    } else if (prompt == SkipPrompt.outro) {
      // 自动跳过片尾或自动连播任一开启，都在片尾倒计时后进入下一集。
      if (prefs.autoSkipOutro || prefs.autoPlayNext) {
        _startOutroCountdown();
      } else {
        _cancelOutroCountdown();
      }
    } else {
      _cancelOutroCountdown();
    }
  }

  /// Netflix 式片尾倒计时：5 秒后自动进入下一集，点按钮可立即跳过。
  void _startOutroCountdown() {
    if (_outroCountdownTimer != null || _outroSkipped) return;
    _outroCountdown.value = _outroCountdownSeconds;
    _outroCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _skipPrompt.value != SkipPrompt.outro) {
        timer.cancel();
        _outroCountdownTimer = null;
        _outroCountdown.value = 0;
        return;
      }
      final remaining = _outroCountdown.value - 1;
      _outroCountdown.value = remaining < 0 ? 0 : remaining;
      if (remaining > 0) return;
      timer.cancel();
      _outroCountdownTimer = null;
      unawaited(_skipOutro(auto: true));
    });
  }

  void _cancelOutroCountdown() {
    _outroCountdownTimer?.cancel();
    _outroCountdownTimer = null;
    _outroCountdown.value = 0;
  }

  Future<void> _skipIntro({bool auto = false}) async {
    final target = _skipMarks.introEndSec;
    if (target == null || _skipSeeking) return;
    _introSkipped = true;
    _skipPrompt.value = SkipPrompt.none;
    _skipSeeking = true;
    try {
      final seconds = target.clamp(
        0.0,
        _durationSec > 0 ? _durationSec - 1 : target,
      );
      await _seekToSeconds(seconds);
      if (auto) {
        _debugLog('自动跳过片头 → ${_clockText(seconds)}');
      } else {
        _showOsd('已跳过片头');
      }
    } finally {
      _skipSeeking = false;
    }
  }

  Future<void> _skipOutro({bool auto = false}) async {
    if (_outroSkipped || _skipSeeking) return;
    _cancelOutroCountdown();
    _outroSkipped = true;
    _skipPrompt.value = SkipPrompt.none;
    // 片尾就是本集结束：有下一集就进入下一集（自动倒计时也一样），
    // 最后一集才退回「跳到结尾」。
    if (_hasNext) {
      await _nextEpisode();
      return;
    }
    if (_durationSec <= 0) return;
    _skipSeeking = true;
    try {
      await _seekToSeconds((_durationSec - 1).clamp(0.0, _durationSec - 1));
      if (auto) {
        _debugLog('自动跳过片尾 → 结尾');
      } else {
        _showOsd('已跳到结尾');
      }
    } finally {
      _skipSeeking = false;
    }
  }

  Future<void> _seekToSeconds(double seconds) async {
    if (_durationSec <= 0) return;
    final target = seconds.clamp(0.0, _durationSec - 1);
    await _player.seek(Duration(milliseconds: (target * 1000).round()));
  }

  /// 用当前进度「标记片头结束」，并立即应用。
  Future<void> _markIntroEnd() async {
    if (_positionSec <= 1) {
      _showOsd('请先播放到片头结束的位置再标记');
      return;
    }
    final marks = _skipMarks.copyWith(introEndSec: _positionSec);
    setState(() {
      _skipMarks = marks;
      _skipSource = SkipMarkSource.manual;
      _introSkipped = false;
    });
    await SkipMarksStore.instance.save(_current, marks);
    _showOsd('已记住片头（本剧通用）：${_clockText(_positionSec)}');
    _evaluateSkipPrompt();
  }

  /// 用当前进度「标记片尾开始」，并立即应用。
  Future<void> _markOutroStart() async {
    if (_positionSec <= 1 || _durationSec <= 0) {
      _showOsd('请先播放到片尾开始的位置再标记');
      return;
    }
    final marks = _skipMarks.copyWith(outroStartSec: _positionSec);
    setState(() {
      _skipMarks = marks;
      _skipSource = SkipMarkSource.manual;
      _outroSkipped = false;
    });
    await SkipMarksStore.instance.save(_current, marks);
    _showOsd('已记住片尾（本剧通用）：${_clockText(_positionSec)}');
    _evaluateSkipPrompt();
  }

  Future<void> _clearSkipMarks() async {
    final autoKey = SkipMarksService.cacheKeyFor(_current);
    _cancelOutroCountdown();
    setState(() {
      _skipMarks = const SeriesSkipMarks();
      _skipSource = SkipMarkSource.none;
      _introSkipped = false;
      _outroSkipped = false;
      _skipPrompt.value = SkipPrompt.none;
    });
    await SkipMarksStore.instance.save(_current, const SeriesSkipMarks());
    // 自动识别结果也一起清掉，否则下一集会立刻被「识别」回来。
    await SkipMarksStore.instance.clearAuto(autoKey);
    _showOsd('已清除片头片尾标记');
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
    _cancelOutroCountdown();
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
      _danmakuEmptyHintVisible = false;
      _introSkipped = false;
      _outroSkipped = false;
      _skipSeeking = false;
      _skipPrompt.value = SkipPrompt.none;
      // 字幕记忆按「作品」保留，但新的这一集要重新套用一次。
      _subtitleRestored = false;
      _subtitleDiscoveryDone = false;
    });
    _title.value = _headerTitle;
    unawaited(_loadSkipMarks());
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
    if (source == null || (source.requiresPassword && password == null)) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('媒体源或密码不存在，请到设置里重新同步')));
        Navigator.of(context).maybePop();
      }
      return;
    }
    final authPassword = password ?? '';
    var mediaUrl = Uri.file(_current.path).toString();
    final headers = <String, String>{};
    if (source.isJellyfin) {
      final target = await JellyfinService.playUrl(
        source,
        authPassword,
        _current.path,
      );
      if (!mounted || generation != _openGeneration) return;
      mediaUrl = target.url.toString();
    } else if (source.isSmb) {
      // UNC 路径交给系统和 mpv，不需要 HTTP 头。
      mediaUrl = _current.path.replaceAll('/', r'\');
    } else if (!source.isLocal) {
      final playTarget = await WebDavService.resolvePlayUrl(
        source,
        _current.path,
      );
      if (!mounted || generation != _openGeneration) return;
      mediaUrl = playTarget.url.toString();
      final auth = WebDavService.authHeader(source.username, authPassword);
      _probe(playTarget.url, auth);
      headers['Authorization'] = auth;
      if (playTarget.hostHeader != null) {
        headers['Host'] = playTarget.hostHeader!;
      }
    }
    _debugLog('播放地址: $mediaUrl');
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
        Media(mediaUrl, httpHeaders: headers, start: resumeStart),
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
        unawaited(_loadDanmaku(silent: !initial));
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
        _subtitleDiscoveryDone = false;
      });
    }
    final videoPath = _current.path;
    final files = await SubtitleService.discover(source, videoPath, password);
    if (!mounted || videoPath != _current.path) return;
    setState(() {
      _subtitleFiles = files;
      _loadingSubtitles = false;
      _subtitleDiscoveryDone = true;
    });
    // 外挂字幕发现完再套用记忆：内嵌轨可能先到，外挂字幕要等这一步。
    unawaited(_restoreSubtitleChoice());
  }

  /// 套用「这部作品上次选的字幕」到当前集。
  ///
  /// 每集只套用一次（`_subtitleRestored`），用户手动改选后不会被
  /// 随后的轨道事件覆盖。
  Future<void> _restoreSubtitleChoice() async {
    if (!_acceptStreamEvents) return;
    final videoPath = _current.path;
    if (_subtitleRestored) return;

    final choice = await SubtitlePreferences.instance.choiceFor(_current);
    // 读存储是异步的：期间用户可能已经手动选过，不能再用记忆覆盖。
    if (_subtitleRestored || !mounted || videoPath != _current.path) return;
    if (choice == null) {
      _subtitleRestored = true;
      return;
    }

    if (choice.isOff) {
      await _player.setSubtitleTrack(SubtitleTrack.no());
      if (!mounted || videoPath != _current.path) return;
      _subtitleRestored = true;
      setState(() => _activeSubtitlePath = null);
      _debugLog('字幕记忆: 关闭');
      return;
    }

    if (choice.kind == 'track') {
      final tracks = _realSubtitleTracks;
      // 轨道还没枚举出来：留待 tracks 事件再试，不要标记为已处理。
      if (tracks.isEmpty) return;
      final index = SubtitleChoiceResolver.trackIndex(choice, tracks);
      if (index == null) {
        _subtitleRestored = true;
        _debugLog('字幕记忆: 本集没有对应的内嵌字幕轨');
        return;
      }
      final track = tracks[index];
      await _player.setSubtitleTrack(track);
      if (!mounted || videoPath != _current.path) return;
      _subtitleRestored = true;
      setState(() => _activeSubtitlePath = null);
      _debugLog('字幕记忆: ${track.id} ${track.title}');
      // 换集自动沿用不提示：每集弹一次「字幕：xxx」只是噪音。
      return;
    }

    if (choice.kind == 'external') {
      // 同名字幕还在发现中：等 _loadSubtitleFiles 完成后再来一次，
      // 不能把「还没发现完」误判成「本集没有外挂字幕」。
      if (!_subtitleDiscoveryDone) return;
      final subtitle = SubtitleChoiceResolver.externalFile(
        choice,
        _subtitleFiles,
      );
      if (subtitle == null) {
        _subtitleRestored = true;
        _debugLog('字幕记忆: 本集没有对应的外挂字幕');
        return;
      }
      _subtitleRestored = true;
      await _applyExternalSubtitle(subtitle, remember: false);
    }
  }

  Future<void> _applyExternalSubtitle(
    SubtitleFile subtitle, {
    bool remember = true,
  }) async {
    final source = MediaLibrary.instance.sourceById(_current.sourceId);
    if (source == null) return;
    // remember=false 表示「换集自动沿用」：不弹提示，避免每集打扰。
    if (remember) _showOsd('正在加载字幕…');
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
    if (remember) {
      unawaited(
        SubtitlePreferences.instance.save(
          _current,
          SubtitleChoice.external(
            path: subtitle.path,
            language: subtitle.language,
            title: subtitle.title,
          ),
        ),
      );
      _showOsd('字幕：${subtitle.title}');
    }
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
        _danmakuEmptyHintVisible = false;
      });
      _danmakuHintTimer?.cancel();
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
    bool silent = false,
  }) async {
    if (_loadingDanmaku) {
      _debugLog('弹幕加载中，忽略重复请求');
      return;
    }
    setState(() => _loadingDanmaku = true);
    // 切集后自动加载不弹提示；用户点按钮/换源仍要有反馈。
    final quiet = silent;
    void notify(String message, {Duration? duration}) {
      if (quiet) {
        _debugLog('静默提示: $message');
        return;
      }
      _showOsd(
        message,
        duration: duration ?? const Duration(milliseconds: 1800),
      );
    }

    notify('正在匹配弹幕…');
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
          notify(
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
      final lastCommentSec = comments.isEmpty ? 0.0 : comments.last.timeSec;
      setState(() {
        _danmakuComments = comments;
        _danmakuEpisodeKey = selected.key;
        _danmakuEnabled = comments.isNotEmpty;
        _danmakuWanted = comments.isNotEmpty;
        // 只有用户主动开启/换源、且当前进度已越过最后一颗弹幕时，
        // 才解释一次「当前进度暂无弹幕」；切集自动加载保持安静。
        _danmakuEmptyHintVisible =
            !quiet && comments.isNotEmpty && _positionSec > lastCommentSec + 1;
      });
      _scheduleDanmakuHintFade();
      final coverageHint = _danmakuCoverageHint();
      notify(
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
        notify(error.message, duration: const Duration(seconds: 4));
      }
    } catch (error) {
      _debugLog('弹幕加载异常: $error');
      if (mounted) {
        notify('弹幕加载失败：$error', duration: const Duration(seconds: 4));
      }
    } finally {
      if (mounted) setState(() => _loadingDanmaku = false);
    }
  }

  /// 「暂无弹幕」解释只短暂停留，不按进度常驻到片尾。
  void _scheduleDanmakuHintFade() {
    _danmakuHintTimer?.cancel();
    if (!_danmakuEmptyHintVisible) return;
    _danmakuHintTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted || !_danmakuEmptyHintVisible) return;
      setState(() => _danmakuEmptyHintVisible = false);
    });
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

  /// 触摸设备统一使用手机控制层（含 Android / iPad 平板）。
  bool _useTouchControls(BuildContext context) {
    if (_isTv) return false;
    final platform = Theme.of(context).platform;
    return platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  }

  void _refocus() {
    if (mounted) _focusNode.requestFocus();
  }

  // ---------------------------------------------------------------------------
  // 电视遥控：控制条显隐与按键
  // ---------------------------------------------------------------------------

  KeyEventResult _handleTvKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final isBack =
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.browserBack;

    if (_tvControlsVisible) {
      // 控制条展开时把方向键/OK 交给焦点系统，遥控器可逐个按钮移动。
      if (isBack) {
        _hideTvControls();
        return KeyEventResult.handled;
      }
      _scheduleTvHide();
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      unawaited(_togglePlay());
      _showTvControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      unawaited(_seekBy(-10));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      unawaited(_seekBy(10));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      unawaited(_changeVolume(5));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      unawaited(_changeVolume(-5));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _showTvControls() {
    if (!_isTv) return;
    _tvHideTimer?.cancel();
    final wasVisible = _tvControlsVisible;
    if (!wasVisible) {
      setState(() => _tvControlsVisible = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tvControlsVisible) _tvPlayFocus.requestFocus();
      });
    }
    _scheduleTvHide();
  }

  /// 播放中 6 秒无操作自动收起；暂停时保持常驻。
  void _scheduleTvHide() {
    _tvHideTimer?.cancel();
    if (!_player.state.playing) return;
    _tvHideTimer = Timer(const Duration(seconds: 6), () {
      if (mounted && _tvControlsVisible) _hideTvControls();
    });
  }

  void _hideTvControls() {
    _tvHideTimer?.cancel();
    if (!_tvControlsVisible) return;
    setState(() {
      _tvControlsVisible = false;
      _tvScrubSeconds = null;
    });
    _refocus();
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

  /// 片头片尾按钮：一集里只需标记一次，整部剧共用。
  Widget _buildSkipButton() {
    return Tooltip(
      message: '片尾',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('skip-marks-button'),
          onTap: () {
            _refocus();
            unawaited(_showSkipMarkDialog());
          },
          borderRadius: BorderRadius.circular(6),
          child: _ControlButtonLabel(
            icon: _skipMarks.isEmpty
                ? Icons.content_cut_rounded
                : Icons.check_circle_outline_rounded,
            label: '片尾',
          ),
        ),
      ),
    );
  }

  Future<void> _showSkipMarkDialog() async {
    final action = await showDialog<String>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => SimpleDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(switch (_skipSource) {
          SkipMarkSource.manual => '片头片尾（手动标记）',
          SkipMarkSource.auto => '片头片尾（在线识别）',
          SkipMarkSource.none => '片头片尾',
        }, style: const TextStyle(color: Colors.white)),
        children: [
          _skipMarkOption(
            value: 'intro',
            label: _skipMarks.hasIntro
                ? '把片头结束改为 ${_clockText(_positionSec)}'
                : '把当前位置标记为片头结束',
            icon: Icons.skip_next_rounded,
          ),
          _skipMarkOption(
            value: 'outro',
            label: _skipMarks.hasOutro
                ? '把片尾开始改为 ${_clockText(_positionSec)}'
                : '把当前位置标记为片尾开始',
            icon: Icons.fast_forward_rounded,
          ),
          if (!_skipMarks.isEmpty)
            _skipMarkOption(
              value: 'clear',
              label: '清除本剧的片头片尾',
              icon: Icons.delete_outline_rounded,
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 4, 24, 12),
            child: Text(
              '时间来自在线片头片尾库（按 TMDB 集号匹配），'
              '手动标记会覆盖自动结果并整部剧沿用。',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
        ],
      ),
    );
    switch (action) {
      case 'intro':
        await _markIntroEnd();
      case 'outro':
        await _markOutroStart();
      case 'clear':
        await _clearSkipMarks();
    }
    _refocus();
  }

  Widget _skipMarkOption({
    required String value,
    required String label,
    required IconData icon,
  }) {
    return SimpleDialogOption(
      onPressed: () => Navigator.of(context).pop(value),
      child: Row(
        children: [
          Icon(icon, color: Colors.white70, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }

  /// 字幕按钮：常驻底部控制条（没内嵌字幕轨也保留入口），
  /// 点开一个独立的字幕选择弹窗，支持关闭/自动/指定轨/外挂字幕。
  ///
  /// 不用 PopupMenuButton：它挂在播放器 controls 里时，
  /// 弹出层在部分窗口尺寸/缩放下点不中选项（菜单会关闭但不触发选择）。
  /// 独立 Dialog 走正常路由，鼠标和遥控器都稳定。
  Widget _buildSubtitleButton(List<SubtitleTrack> tracks) {
    return Tooltip(
      message: '字幕',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => unawaited(_showSubtitlePicker(tracks)),
          borderRadius: BorderRadius.circular(6),
          child: const _ControlButtonLabel(
            icon: Icons.subtitles_rounded,
            label: '字幕',
          ),
        ),
      ),
    );
  }

  Future<void> _showSubtitlePicker(List<SubtitleTrack> tracks) async {
    final currentId = _player.state.track.subtitle.id;
    final entries = <SubtitlePickerEntry>[
      SubtitlePickerEntry(
        value: 'no',
        label: '关闭字幕',
        selected: currentId == 'no',
      ),
      SubtitlePickerEntry(
        value: 'auto',
        label: '自动',
        selected: currentId == 'auto',
      ),
      for (var i = 0; i < tracks.length; i++)
        SubtitlePickerEntry(
          value: 'track:${tracks[i].id}',
          label: _subtitleLabel(tracks[i], i + 1),
          selected: currentId == tracks[i].id,
        ),
      if (_subtitleFiles.isNotEmpty) const SubtitlePickerEntry.divider(),
      for (final subtitle in _subtitleFiles)
        SubtitlePickerEntry(
          value: 'external:${subtitle.path}',
          label: subtitle.title,
          selected: _activeSubtitlePath == subtitle.path,
        ),
      const SubtitlePickerEntry.divider(),
      const SubtitlePickerEntry(value: 'pick', label: '加载外挂字幕…'),
      if (_loadingSubtitles)
        const SubtitlePickerEntry.hint('正在查找同名字幕…')
      else if (tracks.isEmpty && _subtitleFiles.isEmpty)
        const SubtitlePickerEntry.hint('未发现内嵌或同名字幕'),
    ];
    final value = await showDialog<String>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => SubtitlePickerDialog(entries: entries),
    );
    if (!mounted || value == null) return;
    _refocus();
    await _applySubtitleChoice(value, tracks);
  }

  Future<void> _applySubtitleChoice(
    String value,
    List<SubtitleTrack> tracks,
  ) async {
    // 用户在本集做了显式选择：后续轨道事件不应再用「记忆」回写。
    _subtitleRestored = true;
    if (value == 'no') {
      await _player.setSubtitleTrack(SubtitleTrack.no());
      if (mounted) setState(() => _activeSubtitlePath = null);
      unawaited(
        SubtitlePreferences.instance.save(_current, const SubtitleChoice.off()),
      );
      _debugLog('字幕切换: 关闭');
      _showOsd('字幕已关闭');
      return;
    }
    if (value == 'auto') {
      await _player.setSubtitleTrack(SubtitleTrack.auto());
      if (mounted) setState(() => _activeSubtitlePath = null);
      // 「自动」= 恢复默认，清掉这部作品的记忆，免得下次又被拽回来。
      unawaited(SubtitlePreferences.instance.clear(_current));
      _debugLog('字幕切换: 自动');
      _showOsd('字幕：自动');
      return;
    }
    if (value == 'pick') {
      await _pickExternalSubtitle();
      return;
    }
    if (value.startsWith('external:')) {
      final path = value.substring('external:'.length);
      final subtitle = _subtitleFiles.where((item) => item.path == path);
      if (subtitle.isNotEmpty) await _applyExternalSubtitle(subtitle.first);
      return;
    }
    if (value.startsWith('track:')) {
      final id = value.substring('track:'.length);
      final track = tracks.firstWhere((t) => t.id == id);
      await _player.setSubtitleTrack(track);
      if (mounted) setState(() => _activeSubtitlePath = null);
      unawaited(
        SubtitlePreferences.instance.save(
          _current,
          SubtitleChoice.track(
            id: track.id,
            language: track.language,
            title: track.title,
          ),
        ),
      );
      _debugLog('字幕切换: ${track.id} ${track.title}');
      _showOsd('字幕：${_subtitleLabel(track, tracks.indexOf(track) + 1)}');
    }
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
    final player = CallbackShortcuts(
      bindings: _shortcutBindings,
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _isTv ? _handleTvKey : null,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onSecondaryTapDown: (_) => _showMediaInfo(),
          child: _buildScreen(context),
        ),
      ),
    );
    if (!_isTv) return player;
    // 电视遥控的返回键走系统 pop：控制条展开时先收起，而不是直接退出播放页。
    return PopScope(
      canPop: !_tvControlsVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _tvControlsVisible) _hideTvControls();
      },
      child: player,
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
        // 弹幕放完后的「暂无弹幕」解释只在用户刚开启/换源后短暂给一次，
        // 不再按进度常驻——每集结尾都挂一条浮层属于噪音。
        ValueListenableBuilder<double>(
          valueListenable: _danmakuClock,
          builder: (context, position, _) {
            if (!_danmakuEmptyHintVisible) return const SizedBox.shrink();
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

  /// 「跳过片头/片尾」浮层。放在 controls 子树里，全屏同样可见。
  Widget _buildSkipPrompt(BuildContext context) {
    return ValueListenableBuilder<SkipPrompt>(
      valueListenable: _skipPrompt,
      builder: (context, prompt, _) {
        if (prompt == SkipPrompt.none) return const SizedBox.shrink();
        final isIntro = prompt == SkipPrompt.intro;
        final label = isIntro ? '跳过片头' : (_hasNext ? '下一集' : '跳到结尾');
        // Netflix 式白底黑字按钮：贴在进度条正上方，右侧对齐。
        return Positioned(
          right: _useTouchControls(context) ? 16 : 28,
          bottom: _useTouchControls(context) ? 196 : (_isTv ? 154 : 100),
          child: FilledButton(
            key: ValueKey(isIntro ? 'skip-intro' : 'skip-outro'),
            onPressed: () => unawaited(isIntro ? _skipIntro() : _skipOutro()),
            style:
                FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 13,
                  ),
                  minimumSize: const Size(0, 44),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  elevation: 8,
                  shadowColor: Colors.black.withValues(alpha: 0.55),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ).copyWith(
                  overlayColor: WidgetStatePropertyAll(
                    Colors.black.withValues(alpha: 0.06),
                  ),
                ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isIntro && _hasNext)
                  ValueListenableBuilder<int>(
                    valueListenable: _outroCountdown,
                    builder: (context, remaining, _) {
                      if (remaining <= 0) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(right: 9),
                        child: SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(
                            value: remaining / _outroCountdownSeconds,
                            strokeWidth: 2.2,
                            color: Colors.black87,
                            backgroundColor: Colors.black12,
                          ),
                        ),
                      );
                    },
                  ),
                Text(label),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildScreen(BuildContext context) {
    final touch = _useTouchControls(context);
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
                // 非 libass 平台（Android/iOS）由 Flutter 画字幕：
                // 默认 32px 在播放器里偏大、且贴着窗口底边容易被裁掉。
                subtitleViewConfiguration: const SubtitleViewConfiguration(
                  style: TextStyle(
                    height: 1.35,
                    fontSize: 22,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                    backgroundColor: Color(0x99000000),
                  ),
                  textAlign: TextAlign.center,
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 56),
                ),
                // 视频尚未就绪时不渲染控制条，避免其布局在零尺寸下溢出报错。
                //
                // 弹幕层必须放在 controls 里：media_kit 进入全屏时会新建
                // 一个只包含 Video 的路由，挂在播放页 Stack 上的覆盖层
                // 不会跟过去。controls 闭包会被复制到全屏 Video，因此
                // 普通模式和全屏模式都能看到同一层弹幕。
                controls: (state) => _durationSec <= 0
                    ? const SizedBox.shrink()
                    : GestureDetector(
                        // 全屏是 media_kit 另起的一个路由，只带 Video 和这份
                        // controls；页面层的右键监听不在那棵子树里。把右键
                        // 监听挂进 controls，普通/全屏就都能用了。
                        behavior: HitTestBehavior.translucent,
                        onSecondaryTapDown: (_) => _showMediaInfo(),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Positioned.fill(
                              child: AnimatedBuilder(
                                animation: PlaybackPreferences.instance,
                                builder: (_, _) => _buildDanmakuOverlay(),
                              ),
                            ),
                            Positioned.fill(
                              child: _isTv
                                  ? const SizedBox.shrink()
                                  : touch
                                  ? _MobilePlayerControls(page: this)
                                  : MaterialDesktopVideoControls(state),
                            ),
                            if (_isTv)
                              Positioned.fill(child: _buildTvControls()),
                            _buildOsdOverlay(),
                            _buildSkipPrompt(context),
                          ],
                        ),
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
          // 顶部标题栏：触摸设备收进控制层，随控制条一起显隐。
          if (!touch)
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

  // ---------------------------------------------------------------------------
  // 电视控制层
  // ---------------------------------------------------------------------------

  Widget _buildTvControls() {
    final duration = _durationSec <= 0 ? 1.0 : _durationSec;
    final position = (_tvScrubSeconds ?? _positionSec).clamp(0.0, duration);
    final playing = _player.state.playing;
    final multi = _playlist.length > 1;

    return IgnorePointer(
      ignoring: !_tvControlsVisible,
      child: AnimatedOpacity(
        opacity: _tvControlsVisible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.78),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 22, 28, 56),
                    child: Row(
                      children: [
                        _TvRoundButton(
                          icon: Icons.arrow_back_rounded,
                          tooltip: '返回',
                          onTap: _exitPlayer,
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: ValueListenableBuilder<String>(
                            valueListenable: _title,
                            builder: (context, title, _) => Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 26,
                                fontWeight: FontWeight.w600,
                                shadows: [
                                  Shadow(blurRadius: 10, color: Colors.black54),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.88),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 60, 28, 22),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              _clockText(position),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                            const SizedBox(width: 18),
                            Expanded(
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 5,
                                  activeTrackColor: Colors.white,
                                  inactiveTrackColor: Colors.white24,
                                  thumbColor: Colors.white,
                                  overlayColor: Colors.white24,
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 9,
                                  ),
                                ),
                                child: Slider(
                                  value: position,
                                  max: duration,
                                  onChanged: (value) =>
                                      setState(() => _tvScrubSeconds = value),
                                  onChangeEnd: (value) async {
                                    setState(() => _tvScrubSeconds = null);
                                    await _player.seek(
                                      Duration(
                                        milliseconds: (value * 1000).round(),
                                      ),
                                    );
                                    _showTvControls();
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(width: 18),
                            Text(
                              _clockText(_durationSec),
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 17,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              _TvPlayerButton(
                                icon: Icons.replay_10_rounded,
                                label: '快退 10 秒',
                                onTap: () => unawaited(_seekBy(-10)),
                              ),
                              _TvPlayerButton(
                                icon: playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                label: playing ? '暂停' : '播放',
                                focusNode: _tvPlayFocus,
                                onTap: () => unawaited(_togglePlay()),
                              ),
                              _TvPlayerButton(
                                icon: Icons.forward_10_rounded,
                                label: '快进 10 秒',
                                onTap: () => unawaited(_seekBy(10)),
                              ),
                              if (multi) ...[
                                _TvPlayerButton(
                                  icon: Icons.skip_previous_rounded,
                                  label: '上一集',
                                  onTap: () => unawaited(_prevEpisode()),
                                ),
                                _TvPlayerButton(
                                  icon: Icons.skip_next_rounded,
                                  label: '下一集',
                                  onTap: () => unawaited(_nextEpisode()),
                                ),
                              ],
                              _TvPlayerButton(
                                icon: Icons.video_library_rounded,
                                label:
                                    '选集 ${_currentIndex + 1}/${_playlist.length}',
                                onTap: () => unawaited(_showTvEpisodePicker()),
                              ),
                              ValueListenableBuilder<double>(
                                valueListenable: _speed,
                                builder: (context, speed, _) => _TvPlayerButton(
                                  icon: Icons.speed_rounded,
                                  label: _speedLabel(speed),
                                  onTap: () => unawaited(_showTvSpeedPicker()),
                                ),
                              ),
                              _TvPlayerButton(
                                icon: Icons.audiotrack_rounded,
                                label: '音轨',
                                onTap: () => unawaited(_showTvAudioPicker()),
                              ),
                              _TvPlayerButton(
                                icon: Icons.subtitles_rounded,
                                label: '字幕',
                                onTap: () => unawaited(_showTvSubtitlePicker()),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showTvChoiceDialog({
    required String title,
    required List<({String label, bool selected, VoidCallback onPick})> choices,
  }) async {
    _tvHideTimer?.cancel();
    await showDialog<void>(
      context: context,
      builder: (_) => _TvChoiceDialog(title: title, choices: choices),
    );
    if (!mounted) return;
    _showTvControls();
  }

  Future<void> _showTvSpeedPicker() {
    final current = _speed.value;
    return _showTvChoiceDialog(
      title: '播放速度',
      choices: [
        for (final rate in _speedOptions)
          (
            label: rate == 1.0 ? '正常' : _speedLabel(rate),
            selected: rate == current,
            onPick: () => unawaited(_setSpeed(rate)),
          ),
      ],
    );
  }

  Future<void> _showTvAudioPicker() {
    final tracks = _realAudioTracks;
    final currentId = _player.state.track.audio.id;
    return _showTvChoiceDialog(
      title: '音轨',
      choices: [
        (
          label: '自动',
          selected: currentId == 'auto',
          onPick: () {
            unawaited(_player.setAudioTrack(AudioTrack.auto()));
            _showOsd('音轨：自动');
          },
        ),
        for (var i = 0; i < tracks.length; i++)
          (
            label: _audioLabel(tracks[i], i + 1),
            selected: currentId == tracks[i].id,
            onPick: () {
              unawaited(_player.setAudioTrack(tracks[i]));
              _showOsd('音轨：${_audioLabel(tracks[i], i + 1)}');
            },
          ),
      ],
    );
  }

  Future<void> _showTvSubtitlePicker() {
    final tracks = _realSubtitleTracks;
    final currentId = _player.state.track.subtitle.id;
    return _showTvChoiceDialog(
      title: '字幕',
      choices: [
        (
          label: '关闭字幕',
          selected: currentId == 'no',
          onPick: () {
            unawaited(_player.setSubtitleTrack(SubtitleTrack.no()));
            unawaited(
              SubtitlePreferences.instance.save(
                _current,
                const SubtitleChoice.off(),
              ),
            );
            _showOsd('字幕已关闭');
          },
        ),
        (
          label: '自动',
          selected: currentId == 'auto',
          onPick: () {
            unawaited(_player.setSubtitleTrack(SubtitleTrack.auto()));
            unawaited(SubtitlePreferences.instance.clear(_current));
            _showOsd('字幕：自动');
          },
        ),
        for (var i = 0; i < tracks.length; i++)
          (
            label: _subtitleLabel(tracks[i], i + 1),
            selected: currentId == tracks[i].id,
            onPick: () {
              unawaited(_player.setSubtitleTrack(tracks[i]));
              unawaited(
                SubtitlePreferences.instance.save(
                  _current,
                  SubtitleChoice.track(
                    id: tracks[i].id,
                    language: tracks[i].language,
                    title: tracks[i].title,
                  ),
                ),
              );
              _showOsd('字幕：${_subtitleLabel(tracks[i], i + 1)}');
            },
          ),
      ],
    );
  }

  Future<void> _showTvEpisodePicker() async {
    _tvHideTimer?.cancel();
    final picked = await showDialog<int>(
      context: context,
      builder: (_) =>
          _TvEpisodeDialog(episodes: _playlist, currentIndex: _currentIndex),
    );
    if (!mounted) return;
    _showTvControls();
    if (picked != null) await _switchTo(_playlist[picked]);
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
                _buildSkipButton(),
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

enum _MobileHud { none, brightness, volume, seek }

/// 手机端触摸控制层。
///
/// 桌面控制条依赖鼠标移入才显示，触摸设备上会完全看不到；这里单独
/// 实现常驻控制条、点击显隐、左侧亮度、右侧音量与横向拖动进度。
class _MobilePlayerControls extends StatefulWidget {
  const _MobilePlayerControls({required this.page});

  final _PlayerPageState page;

  @override
  State<_MobilePlayerControls> createState() => _MobilePlayerControlsState();
}

class _MobilePlayerControlsState extends State<_MobilePlayerControls> {
  Player get _player => widget.page._player;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _playingSub;

  bool _visible = true;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  int _lastPositionSecond = -1;
  double? _scrubSeconds;
  Timer? _hideTimer;

  _MobileHud _hud = _MobileHud.none;
  Timer? _hudTimer;
  double _hudValue = 0;
  double _hudSeekTarget = 0;

  double _brightness = 0.8;
  double _volume = 0.5;
  bool? _nativeBrightness;
  bool? _nativeVolume;
  Timer? _brightnessPushTimer;
  Timer? _volumePushTimer;
  double? _pendingBrightness;
  double? _pendingVolume;

  double _dragStartX = 0;
  double _dragStartY = 0;
  double _dragBaseBrightness = 0.8;
  double _dragBaseVolume = 0.5;
  double _dragBasePosition = 0;
  double _dragSeekTarget = 0;
  bool _verticalBrightness = false;

  @override
  void initState() {
    super.initState();
    _playing = _player.state.playing;
    _position = _player.state.position;
    _duration = _player.state.duration;
    _positionSub = _player.stream.position.listen((position) {
      _position = position;
      final second = position.inSeconds;
      if (!_visible || _scrubSeconds != null || second == _lastPositionSecond) {
        return;
      }
      _lastPositionSecond = second;
      if (mounted) setState(() {});
    });
    _durationSub = _player.stream.duration.listen((duration) {
      _duration = duration;
      if (mounted && _visible) setState(() {});
    });
    _playingSub = _player.stream.playing.listen((playing) {
      _playing = playing;
      if (!mounted) return;
      if (playing) {
        if (_visible) _scheduleHide();
        return;
      }
      // 暂停 / 播完后把控制条亮出来，方便继续操作。
      _hideTimer?.cancel();
      if (!_visible) {
        setState(() => _visible = true);
      } else {
        setState(() {});
      }
    });
    unawaited(_readHardwareLevels());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleHide();
    });
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _hideTimer?.cancel();
    _hudTimer?.cancel();
    _brightnessPushTimer?.cancel();
    _volumePushTimer?.cancel();
    super.dispose();
  }

  Future<void> _readHardwareLevels() async {
    final brightness = await ScreenControlService.instance.readBrightness();
    final volume = await ScreenControlService.instance.readVolume();
    if (!mounted) return;
    setState(() {
      _nativeBrightness = brightness != null;
      _nativeVolume = volume != null;
      _brightness = brightness ?? 0.8;
      _volume = volume ?? (_player.state.volume / 100).clamp(0.0, 1.0);
    });
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_playing || !_visible) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || !_visible || !_player.state.playing) return;
      setState(() {
        _visible = false;
        _hud = _MobileHud.none;
      });
    });
  }

  void _keepVisible() {
    if (!_visible) {
      setState(() => _visible = true);
    }
    _scheduleHide();
  }

  void _toggleVisible() {
    _hideTimer?.cancel();
    setState(() {
      _visible = !_visible;
      if (!_visible) _hud = _MobileHud.none;
    });
    if (_visible) _scheduleHide();
  }

  void _showHud(_MobileHud hud, {double value = 0, double seekTarget = 0}) {
    _hudTimer?.cancel();
    setState(() {
      _hud = hud;
      _hudValue = value;
      _hudSeekTarget = seekTarget;
    });
  }

  void _hideHudSoon() {
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 550), () {
      if (mounted) setState(() => _hud = _MobileHud.none);
    });
  }

  void _pushBrightness(double value) {
    if (_nativeBrightness == false) return;
    _pendingBrightness = value;
    _brightnessPushTimer ??= Timer(const Duration(milliseconds: 50), () {
      _brightnessPushTimer = null;
      final pending = _pendingBrightness;
      _pendingBrightness = null;
      if (pending != null) {
        unawaited(ScreenControlService.instance.setBrightness(pending));
      }
    });
  }

  void _pushVolume(double value) {
    if (_nativeVolume == false) {
      unawaited(_player.setVolume((value * 100).clamp(0.0, 100.0)));
      return;
    }
    _pendingVolume = value;
    _volumePushTimer ??= Timer(const Duration(milliseconds: 50), () {
      _volumePushTimer = null;
      final pending = _pendingVolume;
      _pendingVolume = null;
      if (pending != null) {
        unawaited(ScreenControlService.instance.setVolume(pending));
      }
    });
  }

  void _onVerticalDragStart(DragStartDetails details) {
    _hideTimer?.cancel();
    final width = MediaQuery.sizeOf(context).width;
    _dragStartY = details.localPosition.dy;
    _verticalBrightness = details.localPosition.dx < width / 2;
    _dragBaseBrightness = _brightness;
    _dragBaseVolume = _volume;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    final height = MediaQuery.sizeOf(context).height;
    final delta = (_dragStartY - details.localPosition.dy) / (height * 0.6);
    if (_verticalBrightness) {
      final value = (_dragBaseBrightness + delta).clamp(0.05, 1.0);
      _brightness = value;
      _pushBrightness(value);
      _showHud(_MobileHud.brightness, value: value);
    } else {
      final value = (_dragBaseVolume + delta).clamp(0.0, 1.0);
      _volume = value;
      _pushVolume(value);
      _showHud(_MobileHud.volume, value: value);
    }
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    _hideHudSoon();
    _scheduleHide();
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    _hideTimer?.cancel();
    _dragStartX = details.localPosition.dx;
    _dragBasePosition = _position.inMilliseconds / 1000;
    _dragSeekTarget = _dragBasePosition;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_duration <= Duration.zero) return;
    final width = MediaQuery.sizeOf(context).width;
    final deltaSeconds = (details.localPosition.dx - _dragStartX) / width * 120;
    final maxSeconds = _duration.inMilliseconds / 1000 - 1;
    _dragSeekTarget = (_dragBasePosition + deltaSeconds).clamp(
      0.0,
      maxSeconds < 0 ? 0.0 : maxSeconds,
    );
    _showHud(_MobileHud.seek, seekTarget: _dragSeekTarget);
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_duration > Duration.zero) {
      unawaited(
        _player.seek(Duration(milliseconds: (_dragSeekTarget * 1000).round())),
      );
    }
    _hideHudSoon();
    _scheduleHide();
  }

  void _handleDoubleTap() {
    final width = MediaQuery.sizeOf(context).width;
    final step = _dragStartX < width / 2 ? -10 : 10;
    _keepVisible();
    unawaited(widget.page._seekBy(step));
  }

  Widget _buildHud() {
    if (_hud == _MobileHud.none) return const SizedBox.shrink();
    final isSeek = _hud == _MobileHud.seek;
    final icon = switch (_hud) {
      _MobileHud.brightness =>
        _hudValue < 0.3
            ? Icons.brightness_low_rounded
            : _hudValue < 0.7
            ? Icons.brightness_medium_rounded
            : Icons.brightness_high_rounded,
      _MobileHud.volume =>
        _hudValue <= 0
            ? Icons.volume_off_rounded
            : _hudValue < 0.5
            ? Icons.volume_down_rounded
            : Icons.volume_up_rounded,
      _MobileHud.seek => Icons.fast_forward_rounded,
      _MobileHud.none => Icons.circle,
    };
    final text = isSeek
        ? _PlayerPageState._clockText(_hudSeekTarget)
        : '${(_hudValue * 100).round()}%';
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 24),
              const SizedBox(width: 10),
              Text(
                text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconButton(
    IconData icon,
    VoidCallback onTap, {
    double size = 24,
    String? tooltip,
  }) {
    final button = InkResponse(
      onTap: () {
        _keepVisible();
        onTap();
      },
      radius: 24,
      child: Padding(
        padding: const EdgeInsets.all(9),
        child: Icon(icon, color: Colors.white, size: size),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip, child: button);
  }

  Widget _playButton() {
    return InkResponse(
      onTap: () {
        _keepVisible();
        unawaited(widget.page._togglePlay());
      },
      radius: 32,
      child: Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          shape: BoxShape.circle,
        ),
        child: Icon(
          _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          color: Colors.white,
          size: 34,
        ),
      ),
    );
  }

  Widget _actionChip(Widget child) {
    return Container(
      height: 42,
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(21),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(21),
        child: Center(child: child),
      ),
    );
  }

  Widget _buildTopBar() {
    return Row(
      children: [
        _iconButton(Icons.arrow_back_rounded, () {
          unawaited(widget.page._exitPlayer());
        }, tooltip: '返回'),
        const SizedBox(width: 2),
        Expanded(
          child: ValueListenableBuilder<String>(
            valueListenable: widget.page._title,
            builder: (context, title, _) => Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBottomBar() {
    final duration = _duration.inMilliseconds / 1000;
    final max = duration <= 0 ? 1.0 : duration;
    final position = (_scrubSeconds ?? _position.inMilliseconds / 1000).clamp(
      0.0,
      max,
    );
    final multi = widget.page._playlist.length > 1;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              _PlayerPageState._clockText(position),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                  overlayColor: Colors.white24,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 16,
                  ),
                ),
                child: Slider(
                  value: position,
                  max: max,
                  onChangeStart: (_) => _hideTimer?.cancel(),
                  onChanged: (value) => setState(() => _scrubSeconds = value),
                  onChangeEnd: (value) {
                    setState(() => _scrubSeconds = null);
                    unawaited(
                      _player.seek(
                        Duration(milliseconds: (value * 1000).round()),
                      ),
                    );
                    _scheduleHide();
                  },
                ),
              ),
            ),
            Text(
              _PlayerPageState._clockText(duration),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        Row(
          children: [
            if (multi)
              _iconButton(
                Icons.skip_previous_rounded,
                () => unawaited(widget.page._prevEpisode()),
                tooltip: '上一集',
              ),
            _iconButton(
              Icons.replay_10_rounded,
              () => unawaited(widget.page._seekBy(-10)),
              tooltip: '快退 10 秒',
            ),
            _playButton(),
            _iconButton(
              Icons.forward_10_rounded,
              () => unawaited(widget.page._seekBy(10)),
              tooltip: '快进 10 秒',
            ),
            if (multi)
              _iconButton(
                Icons.skip_next_rounded,
                () => unawaited(widget.page._nextEpisode()),
                tooltip: '下一集',
              ),
            const Spacer(),
          ],
        ),
        const SizedBox(height: 2),
        SizedBox(
          height: 44,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                if (multi) _actionChip(widget.page._buildEpisodeButton()),
                _actionChip(widget.page._buildSpeedButton()),
                _actionChip(
                  widget.page._buildAudioButton(widget.page._realAudioTracks),
                ),
                _actionChip(
                  widget.page._buildSubtitleButton(
                    widget.page._realSubtitleTracks,
                  ),
                ),
                _actionChip(widget.page._buildDanmakuSwitch()),
                _actionChip(widget.page._buildDanmakuSettingsButton()),
                _actionChip(widget.page._buildSkipButton()),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final dim = _nativeBrightness == false
        ? (1 - _brightness).clamp(0.0, 1.0) * 0.8
        : 0.0;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (dim > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(color: Colors.black.withValues(alpha: dim)),
            ),
          ),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleVisible,
            onDoubleTapDown: (details) {
              _dragStartX = details.localPosition.dx;
            },
            onDoubleTap: _handleDoubleTap,
            onVerticalDragStart: _onVerticalDragStart,
            onVerticalDragUpdate: _onVerticalDragUpdate,
            onVerticalDragEnd: _onVerticalDragEnd,
            onHorizontalDragStart: _onHorizontalDragStart,
            onHorizontalDragUpdate: _onHorizontalDragUpdate,
            onHorizontalDragEnd: _onHorizontalDragEnd,
          ),
        ),
        IgnorePointer(
          ignoring: !_visible,
          child: AnimatedOpacity(
            opacity: _visible ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: Stack(
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.72),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(6, 4, 12, 28),
                        child: _buildTopBar(),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.86),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 40, 12, 6),
                        child: _buildBottomBar(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        _buildHud(),
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

// -----------------------------------------------------------------------------
// 电视端控制层组件
// -----------------------------------------------------------------------------

class _TvRoundButton extends StatefulWidget {
  const _TvRoundButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  static const double size = 56;

  @override
  State<_TvRoundButton> createState() => _TvRoundButtonState();
}

class _TvRoundButtonState extends State<_TvRoundButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      width: _TvRoundButton.size,
      height: _TvRoundButton.size,
      decoration: BoxDecoration(
        color: _focused ? Colors.white : Colors.white.withValues(alpha: 0.14),
        shape: BoxShape.circle,
        border: Border.all(
          color: _focused ? Colors.white : Colors.white24,
          width: 2,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          focusColor: Colors.transparent,
          onFocusChange: (value) {
            if (_focused != value) setState(() => _focused = value);
          },
          onTap: widget.onTap,
          child: Tooltip(
            message: widget.tooltip,
            child: Icon(
              widget.icon,
              size: _TvRoundButton.size * 0.46,
              color: _focused ? Colors.black : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _TvPlayerButton extends StatefulWidget {
  const _TvPlayerButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.focusNode,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  State<_TvPlayerButton> createState() => _TvPlayerButtonState();
}

class _TvPlayerButtonState extends State<_TvPlayerButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final foreground = _focused ? Colors.black : Colors.white;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 64,
        decoration: BoxDecoration(
          color: _focused ? Colors.white : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _focused ? Colors.white : Colors.white24,
            width: 2,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            focusNode: widget.focusNode,
            borderRadius: BorderRadius.circular(12),
            focusColor: Colors.transparent,
            onFocusChange: (value) {
              if (_focused != value) setState(() => _focused = value);
            },
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.icon, size: 26, color: foreground),
                  const SizedBox(width: 10),
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 16.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TvChoiceDialog extends StatelessWidget {
  const _TvChoiceDialog({required this.title, required this.choices});

  final String title;
  final List<({String label, bool selected, VoidCallback onPick})> choices;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1B2230),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(30, 26, 30, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 18),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: choices.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final choice = choices[index];
                    final hasSelected = choices.any((item) => item.selected);
                    return _TvChoiceTile(
                      label: choice.label,
                      selected: choice.selected,
                      autofocus:
                          choice.selected || (!hasSelected && index == 0),
                      onTap: () {
                        Navigator.of(context).pop();
                        choice.onPick();
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TvChoiceTile extends StatefulWidget {
  const _TvChoiceTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.autofocus = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  State<_TvChoiceTile> createState() => _TvChoiceTileState();
}

class _TvChoiceTileState extends State<_TvChoiceTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 130),
      decoration: BoxDecoration(
        color: _focused
            ? Colors.white
            : (widget.selected
                  ? Colors.white.withValues(alpha: 0.14)
                  : Colors.white.withValues(alpha: 0.05)),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _focused ? Colors.white : Colors.white12,
          width: 2,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          autofocus: widget.autofocus,
          borderRadius: BorderRadius.circular(12),
          focusColor: Colors.transparent,
          onFocusChange: (value) {
            if (_focused != value) setState(() => _focused = value);
          },
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 17),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _focused ? Colors.black : Colors.white,
                      fontSize: 19,
                      fontWeight: widget.selected || _focused
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
                if (widget.selected)
                  Icon(
                    Icons.check_rounded,
                    size: 22,
                    color: _focused ? Colors.black : const Color(0xFF60A5FA),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TvEpisodeDialog extends StatelessWidget {
  const _TvEpisodeDialog({required this.episodes, required this.currentIndex});

  final List<ScannedVideo> episodes;
  final int currentIndex;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1B2230),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(30, 26, 30, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '选集（共 ${episodes.length} 集）',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 20),
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  itemCount: episodes.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 2.6,
                  ),
                  itemBuilder: (context, index) => _TvEpisodeTile(
                    number: index + 1,
                    title: MediaLibrary.episodeDisplayTitle(
                      episodes[index],
                      fallbackNumber: index + 1,
                    ),
                    selected: index == currentIndex,
                    autofocus: index == currentIndex,
                    onTap: () => Navigator.of(context).pop(index),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TvEpisodeTile extends StatefulWidget {
  const _TvEpisodeTile({
    required this.number,
    required this.title,
    required this.selected,
    required this.onTap,
    this.autofocus = false,
  });

  final int number;
  final String title;
  final bool selected;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  State<_TvEpisodeTile> createState() => _TvEpisodeTileState();
}

class _TvEpisodeTileState extends State<_TvEpisodeTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 130),
      decoration: BoxDecoration(
        color: _focused
            ? Colors.white
            : (widget.selected
                  ? Colors.white.withValues(alpha: 0.16)
                  : Colors.white.withValues(alpha: 0.05)),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _focused ? Colors.white : Colors.white12,
          width: 2,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          autofocus: widget.autofocus,
          borderRadius: BorderRadius.circular(10),
          focusColor: Colors.transparent,
          onFocusChange: (value) {
            if (_focused != value) setState(() => _focused = value);
          },
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text(
                  '${widget.number}',
                  style: TextStyle(
                    color: _focused ? Colors.black : Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _focused
                          ? Colors.black.withValues(alpha: 0.72)
                          : Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
