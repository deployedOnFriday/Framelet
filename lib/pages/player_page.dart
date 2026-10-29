import 'dart:async';

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

  @override
  void initState() {
    super.initState();
    _positionSub = _player.stream.position.listen((position) {
      _positionSec = position.inMilliseconds / 1000;
    });
    _durationSub = _player.stream.duration.listen((duration) {
      _durationSec = duration.inMilliseconds / 1000;
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
              controls: MaterialDesktopVideoControls,
            ),
          ),
          if (_errorMessage != null)
            Positioned.fill(
              child: Center(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 560),
                  margin: const EdgeInsets.symmetric(horizontal: 40),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white24),
                  ),
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
