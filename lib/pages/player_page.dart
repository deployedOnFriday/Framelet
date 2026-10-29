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
  const PlayerPage({required this.video, this.startPosition, super.key});

  final ScannedVideo video;
  final double? startPosition;

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

  @override
  void initState() {
    super.initState();
    _positionSub = _player.stream.position.listen((position) {
      _positionSec = position.inMilliseconds / 1000;
      if (mounted) setState(() {});
    });
    _durationSub = _player.stream.duration.listen((duration) {
      _durationSec = duration.inMilliseconds / 1000;
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
      if (mounted && _errorMessage == null) {
        setState(() => _errorMessage = error);
      }
    });
    _open();
  }

  Future<void> _open() async {
    final library = MediaLibrary.instance;
    final source = library.sourceById(widget.video.sourceId);
    final password = library.passwordOf(widget.video.sourceId);
    if (source == null || password == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('媒体源或密码不存在，请到设置里重新同步')));
        Navigator.of(context).maybePop();
      }
      return;
    }
    final url = WebDavService.playUrl(source, widget.video.path);
    debugPrint('[Player] 播放地址: $url');
    _probe(url, WebDavService.authHeader(source.username, password));

    // 关键：libmpv 会读取系统环境变量 http_proxy/https_proxy 走代理，
    // 而本机 1501 代理不放行媒体服务器——必须显式禁用。
    final platform = _player.platform;
    if (platform is NativePlayer) {
      try {
        await platform.setProperty('http-proxy', '');
      } catch (error) {
        debugPrint('[Player] 禁用 mpv 代理失败: $error');
      }
    }

    try {
      await _player.open(
        Media(
          url.toString(),
          httpHeaders: {
            'Authorization': WebDavService.authHeader(
              source.username,
              password,
            ),
          },
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _errorMessage = MediaLibrary.describeError(error));
      }
    }
  }

  /// 播放前探测文件地址：把 HTTP 状态码显示在错误卡片上，便于排查。
  Future<void> _probe(Uri url, String auth) async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12);
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.authorizationHeader, auth);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      request.followRedirects = true;
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final length = response.headers.contentLength;
      final detail =
          'HTTP ${response.statusCode}'
          '${length >= 0 ? ' · 大小 ${length ~/ 1024} KB' : ''}'
          '${response.headers.value('content-type') != null ? ' · ${response.headers.value('content-type')}' : ''}';
      debugPrint('[Player] 自检: $detail');
      if (mounted) {
        setState(() => _probeResult = detail);
      }
      // 只关心响应头，绝不把整个视频流读进内存。
      try {
        final socket = await response.detachSocket();
        socket.destroy();
      } catch (_) {}
      client.close(force: true);
    } catch (error) {
      debugPrint('[Player] 自检失败: $error');
      if (mounted) {
        setState(() => _probeResult = '自检请求失败：$error');
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
        sourceId: widget.video.sourceId,
        path: widget.video.path,
        title: widget.video.title,
        kind: widget.video.kind,
        positionSec: _positionSec,
        durationSec: _durationSec,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
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
          if (_errorMessage != null)
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
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  _BackButton(onTap: () => Navigator.of(context).maybePop()),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.video.title,
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
                ],
              ),
            ),
          ),
          // 调试信息（排障用，定位后移除）
          Positioned(
            right: 12,
            bottom: 12,
            child: _DebugPanel(
              probe: _probeResult,
              position: _positionSec,
              duration: _durationSec,
              error: _errorMessage,
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

/// 排障用的实时状态面板：显示地址自检、播放进度与错误。
class _DebugPanel extends StatelessWidget {
  const _DebugPanel({
    required this.probe,
    required this.position,
    required this.duration,
    required this.error,
  });

  final String? probe;
  final double position;
  final double duration;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '自检: ${probe ?? '探测中…'}',
            style: const TextStyle(color: Colors.amberAccent, fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            '播放: ${position.toStringAsFixed(1)}s / ${duration.toStringAsFixed(1)}s',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          if (error != null) ...[
            const SizedBox(height: 4),
            Text(
              '错误: $error',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.redAccent, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}
