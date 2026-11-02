import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/media_source.dart';
import '../services/credential_store.dart';
import '../services/media_library.dart';
import '../services/playback_history.dart';
import '../services/webdav_service.dart';

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
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
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
  double _positionSec = 0;
  double _durationSec = 0;
  double _lastSavedSec = 0;

  /// 当前这集的续播位置：切集后按各集自己的历史进度回跳。
  /// 旧版用 widget.startPosition，切到下一集也会被第一集的进度带偏。
  double? _resumeTarget;

  String? _errorMessage;
  String? _probeResult;

  /// 当前播放的条目（可切集）
  late ScannedVideo _current = widget.video;
  double _speed = 1.0;
  static const _speedOptions = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

  // 音量状态（mpv 音量 0-100）
  double _volume = 100;
  double _volumeBeforeMute = 100;
  bool _muted = false;
  Timer? _volumePersistTimer;

  // OSD 提示（倍速/音量/快进快退/连播）
  String? _osdMessage;
  Timer? _osdTimer;

  /// 自动连播进行中，防止 completed 重复触发。
  bool _advancing = false;

  List<ScannedVideo> get _playlist => widget.episodes ?? const [];

  int get _currentIndex {
    final index = _playlist.indexWhere((v) => v.path == _current.path);
    return index < 0 ? 0 : index;
  }

  bool get _hasNext => _currentIndex < _playlist.length - 1;
  bool get _hasPrev => _currentIndex > 0;

  @override
  void initState() {
    super.initState();
    _positionSub = _player.stream.position.listen((position) {
      _positionSec = position.inMilliseconds / 1000;
      // 每 10 秒自动存档一次进度，应用崩溃/断电也能续播
      if (_durationSec > 0 &&
          _positionSec > 1 &&
          (_positionSec - _lastSavedSec).abs() >= 10) {
        _recordProgress();
      }
      if (mounted) setState(() {});
    });
    _durationSub = _player.stream.duration.listen((duration) {
      final wasZero = _durationSec <= 0;
      _durationSec = duration.inMilliseconds / 1000;
      if (wasZero && _durationSec > 0) {
        _debugLog('视频已就绪，时长 ${_durationSec.toStringAsFixed(1)} 秒');
      }
      if (mounted) setState(() {});
      if (!_seekedToStart && _durationSec > 0) {
        _seekedToStart = true;
        final start = _resumeTarget ?? 0;
        if (start > 1) {
          // 从上次进度继续，稍微回退 3 秒帮助衔接剧情
          final target = (start - 3).clamp(0.0, _durationSec - 5);
          _player.seek(Duration(milliseconds: (target * 1000).round()));
        }
      }
    });
    _errorSub = _player.stream.error.listen((error) {
      _debugLog('mpv error: $error');
      if (mounted && _errorMessage == null) {
        setState(() => _errorMessage = error);
      }
    });
    // 播完自动连播：记录完播进度后切下一集
    _completedSub = _player.stream.completed.listen((completed) async {
      if (!completed || _advancing || _durationSec <= 0) return;
      await _recordProgress(finished: true);
      if (_hasNext) {
        _advancing = true;
        try {
          await _switchTo(_playlist[_currentIndex + 1], osd: '即将播放下一集');
        } finally {
          _advancing = false;
        }
      } else {
        _showOsd('本剧已播完');
        await _player.pause();
      }
    });
    // 暂停时立即存档
    _playingSub = _player.stream.playing.listen((playing) {
      if (!playing && _durationSec > 0 && _positionSec > 1) {
        _recordProgress();
      }
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
    _open(initial: true);
  }

  /// 启动时恢复上次的音量与静音状态。
  Future<void> _restoreVolume() async {
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
    _positionSub?.cancel();
    _durationSub?.cancel();
    _errorSub?.cancel();
    _completedSub?.cancel();
    _playingSub?.cancel();
    _volumeSub?.cancel();
    _tracksSub?.cancel();
    _trackSub?.cancel();
    _volumePersistTimer?.cancel();
    _osdTimer?.cancel();
    _focusNode.dispose();
    _player.dispose();
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

  Future<void> _onEscape() async {
    if (_videoKey.currentState?.isFullscreen() ?? false) {
      await _videoKey.currentState?.exitFullscreen();
    } else {
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

  Future<void> _setSpeed(double rate) async {
    setState(() => _speed = rate);
    await _player.setRate(rate);
    _showOsd(rate == 1.0 ? '正常倍速' : '$rate 倍速');
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
    setState(() {
      _current = video;
      _positionSec = 0;
      _durationSec = 0;
      _lastSavedSec = 0;
      _seekedToStart = false;
      _errorMessage = null;
      _probeResult = null;
    });
    if (osd != null) _showOsd(osd);
    _debugLog('切换剧集: ${video.title}');
    await _open();
  }

  Future<void> _open({bool initial = false}) async {
    _resumeTarget = initial
        ? (widget.startPosition ?? _resumePositionOf(_current))
        : _resumePositionOf(_current);
    final library = MediaLibrary.instance;
    final source = library.sourceById(_current.sourceId);
    final password = library.passwordOf(_current.sourceId);
    if (source == null || password == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('媒体源或密码不存在，请到设置里重新同步')));
        Navigator.of(context).maybePop();
      }
      return;
    }
    final playTarget = await WebDavService.resolvePlayUrl(
      source,
      _current.path,
    );
    final url = playTarget.url;
    _debugLog('播放地址: $url');
    _debugLog('源文件路径: ${_current.path}');
    final auth = WebDavService.authHeader(source.username, password);
    _probe(url, auth);

    // 关键：libmpv 会读取系统环境变量 http_proxy/https_proxy 走代理，
    // 而本机 1501 代理不放行媒体服务器——必须显式禁用。
    final platform = _player.platform;
    if (platform is NativePlayer) {
      try {
        await platform.setProperty('http-proxy', '');
      } catch (error) {
        _debugLog('禁用 mpv 代理失败: $error');
      }
    }

    final headers = <String, String>{'Authorization': auth};
    if (playTarget.hostHeader != null) {
      // 用 IP 连接时保留原始域名，避免服务器按 Host 拒绝。
      headers['Host'] = playTarget.hostHeader!;
    }

    try {
      await _player.open(Media(url.toString(), httpHeaders: headers));
      await _player.setRate(_speed);
      _debugLog('open() 调用完成');
    } catch (error) {
      _debugLog('open() 异常: $error');
      if (mounted) {
        setState(() => _errorMessage = MediaLibrary.describeError(error));
      }
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

  // ---------------------------------------------------------------------------
  // OSD 提示
  // ---------------------------------------------------------------------------

  void _showOsd(String message) {
    _osdTimer?.cancel();
    if (!mounted) return;
    setState(() => _osdMessage = message);
    _osdTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _osdMessage = null);
    });
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

  List<AudioTrack> get _realAudioTracks => _player
      .state
      .tracks
      .audio
      .where((t) => t.id != 'auto' && t.id != 'no')
      .toList();

  List<SubtitleTrack> get _realSubtitleTracks => _player
      .state
      .tracks
      .subtitle
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
    return PopupMenuButton<double>(
      tooltip: '倍速',
      color: _menuColor,
      position: PopupMenuPosition.over,
      initialValue: _speed,
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
              rate == 1.0 ? '正常' : '${rate}x',
              rate == _speed,
            ),
          ),
      ],
      child: _ControlButtonLabel(
        label:
            '${_speed == _speed.truncateToDouble() ? _speed.toInt() : _speed}x',
      ),
    );
  }

  /// 音轨按钮：多音轨时出现在底部控制条，点击向上弹菜单。
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
      ],
      child: const _ControlButtonLabel(
        icon: Icons.audiotrack_rounded,
        label: '音轨',
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
          _showOsd('字幕已关闭');
        } else if (id == 'auto') {
          await _player.setSubtitleTrack(SubtitleTrack.auto());
          _showOsd('字幕：自动');
        } else {
          final track = tracks.firstWhere((t) => t.id == id);
          await _player.setSubtitleTrack(track);
          _showOsd('字幕：${_subtitleLabel(track, tracks.indexOf(track) + 1)}');
        }
      },
      itemBuilder: (_) => [
        _menuItem('no', '关闭字幕', currentId),
        _menuItem('auto', '自动', currentId),
        for (var i = 0; i < tracks.length; i++)
          _menuItem(tracks[i].id, _subtitleLabel(tracks[i], i + 1), currentId),
        if (tracks.isEmpty)
          const PopupMenuItem<String>(
            enabled: false,
            height: 34,
            child: Text(
              '无内嵌字幕轨',
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
                          episode.episodeTitle != null &&
                                  episode.episodeTitle!.isNotEmpty
                              ? '第 ${index + 1} 集 · ${episode.episodeTitle}'
                              : '第 ${index + 1} 集',
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
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): _togglePlay,
        const SingleActivator(LogicalKeyboardKey.keyK): _togglePlay,
        const SingleActivator(LogicalKeyboardKey.mediaPlayPause): _togglePlay,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _seekBy(-5),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _seekBy(5),
        const SingleActivator(LogicalKeyboardKey.keyJ): () => _seekBy(-10),
        const SingleActivator(LogicalKeyboardKey.keyL): () => _seekBy(10),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _changeVolume(5),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _changeVolume(-5),
        const SingleActivator(LogicalKeyboardKey.keyM): _toggleMute,
        const SingleActivator(LogicalKeyboardKey.keyF): _toggleFullscreen,
        const SingleActivator(LogicalKeyboardKey.f11): _toggleFullscreen,
        const SingleActivator(LogicalKeyboardKey.escape): _onEscape,
        const SingleActivator(LogicalKeyboardKey.keyN): _nextEpisode,
        const SingleActivator(LogicalKeyboardKey.keyP): _prevEpisode,
      },
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

  Widget _buildScreen(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: MaterialDesktopVideoControlsTheme(
              normal: _desktopControlsTheme(),
              fullscreen: _desktopControlsTheme(),
              child: Video(
                key: _videoKey,
                controller: _controller,
                // 视频尚未就绪时不渲染控制条，避免其布局在零尺寸下溢出报错。
                controls: (state) => _durationSec > 0
                    ? MaterialDesktopVideoControls(state)
                    : const SizedBox.shrink(),
              ),
            ),
          ),
          if (_durationSec <= 0)
            const Positioned.fill(
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
          if (_errorMessage != null && _durationSec <= 0)
            Positioned.fill(
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
                        const Text(
                          '请检查媒体源密码是否变更，或稍后重试',
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          // OSD 提示：音量/倍速/快进快退/连播
          if (_osdMessage != null)
            Positioned(
              top: 64,
              left: 0,
              right: 0,
              child: IgnorePointer(
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
                      _osdMessage!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
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
                child: Row(
                  children: [
                    _BackButton(
                      onTap: () {
                        _refocus();
                        Navigator.of(context).maybePop();
                      },
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _current.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          shadows: [
                            Shadow(blurRadius: 8, color: Colors.black54),
                          ],
                        ),
                      ),
                    ),
                    if (_playlist.length > 1) ...[
                      const SizedBox(width: 8),
                      _TopChip(
                        label: '选集 ${_currentIndex + 1}/${_playlist.length}',
                        onTap: _showEpisodePicker,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 控制条主题：禁用内建键盘快捷键（由页面层统一接管）；
  /// 底部控制条挂上 上一集/下一集/音轨/字幕/倍速，内建的
  /// SkipPrevious/SkipNext 只会切 Player 内部播放列表（我们不用），换成自己的切集。
  MaterialDesktopVideoControlsThemeData _desktopControlsTheme() {
    final audioTracks = _realAudioTracks;
    final subtitleTracks = _realSubtitleTracks;
    final multi = _playlist.length > 1;
    return MaterialDesktopVideoControlsThemeData(
      keyboardShortcuts: const {},
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
        const Spacer(),
        if (audioTracks.length > 1) _buildAudioButton(audioTracks),
        // 字幕入口常显：没内嵌轨也要能打开菜单确认/关闭
        _buildSubtitleButton(subtitleTracks),
        _buildSpeedButton(),
        const MaterialDesktopFullscreenButton(),
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

/// 播放器顶部小胶囊按钮（选集）。
class _TopChip extends StatelessWidget {
  const _TopChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
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
