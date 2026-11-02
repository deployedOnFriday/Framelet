import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/media_source.dart';
import '../services/media_library.dart';
import '../services/playback_history.dart';
import '../services/webdav_service.dart';

/// 沉浸式播放页：media_kit 硬件解码 + WebDAV Basic 认证流。
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
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<String>? _errorSub;
  bool _seekedToStart = false;
  bool _saved = false;
  double _positionSec = 0;
  double _durationSec = 0;
  String? _errorMessage;
  String? _probeResult;

  /// 当前播放的条目（可切集）
  late ScannedVideo _current = widget.video;
  double _speed = 1.0;
  static const _speedOptions = [0.75, 1.0, 1.25, 1.5, 2.0];

  List<ScannedVideo> get _playlist => widget.episodes ?? const [];

  int get _currentIndex {
    final index = _playlist.indexWhere((v) => v.path == _current.path);
    return index < 0 ? 0 : index;
  }

  @override
  void initState() {
    super.initState();
    _positionSub = _player.stream.position.listen((position) {
      _positionSec = position.inMilliseconds / 1000;
      if (mounted) setState(() {});
    });
    _durationSub = _player.stream.duration.listen((duration) {
      final wasZero = _durationSec <= 0;
      _durationSec = duration.inMilliseconds / 1000;
      if (wasZero && _durationSec > 0) {
        _debugLog('视频已就绪，时长 ${_durationSec.toStringAsFixed(1)} 秒');
      }
      if (mounted) setState(() {});
      final start = widget.startPosition ?? 0;
      if (!_seekedToStart && _durationSec > 0 && start > 1) {
        _seekedToStart = true;
        // 从上次进度继续，稍微回退 3 秒帮助衔接剧情
        final target = (start - 3).clamp(0.0, _durationSec - 5);
        _player.seek(Duration(milliseconds: (target * 1000).round()));
      }
    });
    _errorSub = _player.stream.error.listen((error) {
      _debugLog('mpv error: $error');
      if (mounted && _errorMessage == null) {
        setState(() => _errorMessage = error);
      }
    });
    _open();
  }

  /// 切换到另一集：重置状态并重新打开。
  Future<void> _switchTo(ScannedVideo video) async {
    if (video.path == _current.path) return;
    await _saveProgress();
    _saved = false;
    _seekedToStart = false;
    setState(() {
      _current = video;
      _positionSec = 0;
      _durationSec = 0;
      _errorMessage = null;
      _probeResult = null;
    });
    _debugLog('切换剧集: ${video.title}');
    await _open();
    await _player.setRate(_speed);
  }

  /// 循环切换倍速。
  Future<void> _cycleSpeed() async {
    final index = _speedOptions.indexOf(_speed);
    final next = _speedOptions[(index + 1) % _speedOptions.length];
    setState(() => _speed = next);
    await _player.setRate(next);
  }

  /// 右键弹出影片技术信息（分辨率/码率/编码/帧率等）。
  Future<void> _showMediaInfo() async {
    final info = await _collectMediaInfo();
    if (!mounted) return;
    final rows = <MapEntry<String, String>>[
      MapEntry('文件名', _current.title),
      ...info.entries,
      MapEntry('文件路径', _current.path),
    ];
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
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
      ),
    );
  }

  /// 从 mpv 读取技术参数并格式化。
  Future<Map<String, String>> _collectMediaInfo() async {
    final result = <String, String>{};
    final platform = _player.platform;
    if (platform is! NativePlayer) return result;
    Future<String?> read(String property) async {
      try {
        final value = await platform.getProperty(property);
        if (value.isEmpty || value == 'no') return null;
        return value;
      } catch (_) {
        return null;
      }
    }

    String? formatBitrate(String? value) {
      final bps = int.tryParse(value ?? '');
      if (bps == null || bps <= 0) return null;
      final mbps = bps / 1000000;
      return mbps >= 1
          ? '${mbps.toStringAsFixed(1)} Mbps'
          : '${(bps / 1000).toStringAsFixed(0)} Kbps';
    }

    final width = await read('video-params/w');
    final height = await read('video-params/h');
    if (width != null && height != null) {
      result['分辨率'] = '$width × $height';
    }
    final fps = await read('container-fps') ?? await read('video-params/fps');
    if (fps != null) {
      final parsed = double.tryParse(fps);
      if (parsed != null) result['帧率'] = '${parsed.toStringAsFixed(2)} fps';
    }
    final videoCodec = await read('video-codec-name');
    if (videoCodec != null) result['视频编码'] = videoCodec.toUpperCase();
    final videoRate = formatBitrate(await read('video-bitrate'));
    if (videoRate != null) result['视频码率'] = videoRate;
    final audioCodec = await read('audio-codec-name');
    if (audioCodec != null) result['音频编码'] = audioCodec.toUpperCase();
    final audioRate = formatBitrate(await read('audio-bitrate'));
    if (audioRate != null) result['音频码率'] = audioRate;
    final channels = await read('audio-params/channel-count');
    if (channels != null) result['声道'] = '$channels 声道';
    final sampleRate = await read('audio-params/samplerate');
    if (sampleRate != null) {
      final khz = double.tryParse(sampleRate);
      if (khz != null) result['采样率'] = '${(khz / 1000).toStringAsFixed(1)} kHz';
    }
    final size = int.tryParse(await read('file-size') ?? '');
    if (size != null && size > 0) {
      final gb = size / (1024 * 1024 * 1024);
      result['文件大小'] = gb >= 1
          ? '${gb.toStringAsFixed(2)} GB'
          : '${(size / 1024 / 1024).toStringAsFixed(0)} MB';
    }
    if (_durationSec > 0) {
      final minutes = _durationSec ~/ 60;
      final seconds = (_durationSec % 60).toInt();
      result['时长'] = '$minutes 分 ${seconds.toString().padLeft(2, '0')} 秒';
    }
    return result;
  }

  /// 选集面板：列出本剧所有集，点击切换。
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
    if (picked != null) await _switchTo(picked);
  }

  Future<void> _open() async {
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

  @override
  void dispose() {
    _saveProgress();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _errorSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _saveProgress() async {
    if (_saved) return;
    _saved = true;
    if (_positionSec <= 1 || _durationSec <= 0) return;
    await PlaybackHistory.instance.record(
      HistoryEntry(
        sourceId: _current.sourceId,
        path: _current.path,
        title: _current.title,
        kind: widget.video.kind,
        positionSec: _positionSec,
        durationSec: _durationSec,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (_) => _showMediaInfo(),
      child: _buildScreen(context),
    );
  }

  Widget _buildScreen(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: Video(
              controller: _controller,
              // 视频尚未就绪时不渲染控制条，避免其布局在零尺寸下溢出报错。
              controls: (state) => _durationSec > 0
                  ? MaterialDesktopVideoControls(state)
                  : const SizedBox.shrink(),
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
                    _BackButton(onTap: () => Navigator.of(context).maybePop()),
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
                    _TopChip(
                      label:
                          '${_speed == _speed.truncateToDouble() ? _speed.toInt() : _speed}x',
                      onTap: _cycleSpeed,
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

/// 排障日志：写入 exe 同目录 player_debug.log，便于直接读取真实状态。
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

/// 播放器顶部小胶囊按钮（倍速/选集）。
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
