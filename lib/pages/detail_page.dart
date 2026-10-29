import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/media_item.dart';
import '../models/media_source.dart';
import '../services/media_library.dart';
import '../services/playback_history.dart';
import '../widgets/media_artwork.dart';
import 'player_page.dart';

/// 影片详情页：顶部氛围横幅 + 信息区 + 剧集列表。
class DetailPage extends StatelessWidget {
  const DetailPage({required this.video, super.key});

  final ScannedVideo video;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        PlaybackHistory.instance,
        MediaLibrary.instance,
      ]),
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final library = MediaLibrary.instance;
    final source = library.sourceById(video.sourceId);
    final episodes = library.episodesOf(video);
    final isSeries = video.episodeCount > 1;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildHero(context)),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 36),
          sliver: SliverToBoxAdapter(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildPosterColumn(context, episodes),
                const SizedBox(width: 34),
                Expanded(
                  child: _buildInfoPanel(context, source, episodes, isSeries),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 顶部氛围横幅：双色渐变底 + 氛围纹理 + 分类与大标题。
  Widget _buildHero(BuildContext context) {
    return Container(
      height: 300,
      margin: const EdgeInsets.fromLTRB(24, 20, 24, 22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _heroColors,
        ),
        boxShadow: [
          BoxShadow(
            color: _heroColors.first.withValues(alpha: 0.35),
            blurRadius: 30,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Stack(
                children: [
                  const Positioned.fill(child: _AmbientPattern()),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.05),
                          Colors.black.withValues(alpha: 0.45),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _BackPill(onTap: () => Navigator.of(context).maybePop()),
                const Spacer(),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _KindBadge(kind: video.kind),
                          const SizedBox(height: 12),
                          Text(
                            video.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 34,
                              fontWeight: FontWeight.w700,
                              height: 1.2,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 24),
                    _YearHint(year: video.modified?.year.toString()),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Color> get _heroColors {
    const palettes = <List<Color>>[
      [Color(0xFF2E5548), Color(0xFF6FA68B)],
      [Color(0xFF3D5175), Color(0xFF7E97C4)],
      [Color(0xFF6E5544), Color(0xFFBA9373)],
      [Color(0xFF4E3D6E), Color(0xFF9373BA)],
      [Color(0xFF3D6E64), Color(0xFF73BAA4)],
      [Color(0xFF6E6444), Color(0xFFBAA473)],
    ];
    var hash = 0;
    for (final code in video.title.codeUnits) {
      hash = (hash * 31 + code) & 0x7FFFFFFF;
    }
    return palettes[hash % palettes.length];
  }

  Widget _buildPosterColumn(BuildContext context, List<ScannedVideo> episodes) {
    final entry = PlaybackHistory.instance.entryOf(video.sourceId, video.path);
    return SizedBox(
      width: 230,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: MediaArtwork(
              item: _posterItem(entry?.progress ?? 0),
              showQuality: true,
              borderRadius: 16,
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 50,
            child: FilledButton.icon(
              onPressed: () => _play(context, episodes.first),
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13),
                ),
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              icon: const Icon(Icons.play_arrow_rounded, size: 24),
              label: Text(_playLabel(episodes.first)),
            ),
          ),
        ],
      ),
    );
  }

  MediaItem _posterItem(double progress) {
    return MediaItem(
      title: video.title,
      subtitle: '',
      year: video.modified?.year.toString() ?? '',
      colors: _heroColors,
      icon: switch (video.kind) {
        MediaKind.movie => Icons.movie_outlined,
        MediaKind.series => Icons.live_tv_outlined,
        MediaKind.anime => Icons.animation_outlined,
        MediaKind.variety => Icons.emoji_events_outlined,
      },
      quality: video.episodeCount > 1 ? '${video.episodeCount} 集' : null,
      progress: progress,
    );
  }

  String _playLabel(ScannedVideo episode) {
    final entry = PlaybackHistory.instance.entryOf(
      episode.sourceId,
      episode.path,
    );
    if (entry == null || entry.positionSec <= 1) return '立即播放';
    if (entry.finished) return '重新播放';
    final left = (entry.durationSec - entry.positionSec) / 60;
    return '继续播放 · 剩余 ${left.ceil()} 分钟';
  }

  Widget _buildInfoPanel(
    BuildContext context,
    MediaSource? source,
    List<ScannedVideo> episodes,
    bool isSeries,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            if (video.modified != null) _chip('年份 ${video.modified!.year}'),
            if (isSeries) _chip('共 ${video.episodeCount} 集'),
            _chip(_sizeLabel()),
            if (source != null) _chip('来自「${source.name}」'),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          video.path,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        if (isSeries) ...[
          Row(
            children: [
              Text('剧集', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(width: 10),
              Text(
                '${episodes.length} 集',
                style: const TextStyle(color: AppColors.muted, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _EpisodeList(episodes: episodes, onTap: (e) => _play(context, e)),
        ] else
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.high_quality_outlined,
                  color: AppColors.primary,
                  size: 26,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    '单文件影片，点击左侧「立即播放」开始观看。',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _sizeLabel() {
    final gb = video.sizeBytes / (1024 * 1024 * 1024);
    if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
    return '${(video.sizeBytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }

  Widget _chip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12.5,
          color: AppColors.primary,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  void _play(BuildContext context, ScannedVideo episode) {
    final entry = PlaybackHistory.instance.entryOf(
      episode.sourceId,
      episode.path,
    );
    final resume = entry != null && !entry.finished && entry.positionSec > 1;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          video: episode,
          startPosition: resume ? entry.positionSec : null,
        ),
      ),
    );
  }
}

/// 横幅里的氛围纹理：半透明圆环与细线堆叠，克制不抢戏。
class _AmbientPattern extends StatelessWidget {
  const _AmbientPattern();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _AmbientPainter(),
      child: const SizedBox.expand(),
    );
  }
}

class _AmbientPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final ringPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final cx = size.width * 0.82;
    final cy = size.height * 0.35;
    for (var radius = 30.0; radius < 220; radius += 34) {
      canvas.drawCircle(Offset(cx, cy), radius, ringPaint);
    }
    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..strokeWidth = 1;
    for (var i = 0; i < 6; i++) {
      final y = size.height * 0.15 + i * 44.0;
      canvas.drawLine(
        Offset(size.width * 0.55, y),
        Offset(size.width, y),
        linePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _BackPill extends StatelessWidget {
  const _BackPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black26,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_back_rounded, color: Colors.white, size: 18),
              SizedBox(width: 6),
              Text('返回', style: TextStyle(color: Colors.white, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.kind});

  final MediaKind kind;

  @override
  Widget build(BuildContext context) {
    final label = switch (kind) {
      MediaKind.movie => '电影',
      MediaKind.series => '电视剧',
      MediaKind.anime => '动漫',
      MediaKind.variety => '综艺',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _YearHint extends StatelessWidget {
  const _YearHint({this.year});

  final String? year;

  @override
  Widget build(BuildContext context) {
    if (year == null || year!.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          year!,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w300,
          ),
        ),
        const Text(
          '入库年份',
          style: TextStyle(color: Colors.white70, fontSize: 11),
        ),
      ],
    );
  }
}

class _EpisodeList extends StatelessWidget {
  const _EpisodeList({required this.episodes, required this.onTap});

  final List<ScannedVideo> episodes;
  final ValueChanged<ScannedVideo> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 420),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        padding: const EdgeInsets.all(10),
        itemCount: episodes.length,
        separatorBuilder: (_, _) => const SizedBox(height: 6),
        itemBuilder: (context, index) {
          final episode = episodes[index];
          final entry = PlaybackHistory.instance.entryOf(
            episode.sourceId,
            episode.path,
          );
          final finished = entry?.finished ?? false;
          return Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            child: InkWell(
              onTap: () => onTap(episode),
              borderRadius: BorderRadius.circular(11),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: finished
                            ? AppColors.primarySoft
                            : AppColors.primary,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: finished
                            ? const Icon(
                                Icons.check_rounded,
                                color: AppColors.primary,
                                size: 18,
                              )
                            : const Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 18,
                              ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _episodeTitle(episode, index),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          if (entry != null && entry.positionSec > 1) ...[
                            const SizedBox(height: 5),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: LinearProgressIndicator(
                                value: entry.progress,
                                minHeight: 3,
                                color: AppColors.accent,
                                backgroundColor: AppColors.border,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    if (finished)
                      const Text(
                        '已看完',
                        style: TextStyle(color: AppColors.muted, fontSize: 12),
                      )
                    else
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: AppColors.muted,
                        size: 20,
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  String _episodeTitle(ScannedVideo episode, int index) {
    final base = episode.title;
    final hasMarker = RegExp(
      r'[Ss]\d{1,2}[Ee]|第\s*\d+\s*[集期]|\bEP?\d+',
      caseSensitive: false,
    ).hasMatch(base);
    return hasMarker ? base : '第 ${index + 1} 集 · $base';
  }
}
