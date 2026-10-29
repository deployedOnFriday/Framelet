import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/media_source.dart';
import '../services/media_library.dart';
import '../services/playback_history.dart';
import '../services/scraper_service.dart';
import '../widgets/match_dialog.dart';
import 'player_page.dart';

/// 影片详情页：海报模糊大背景 + 信息区 + 剧集网格（爆米花风格）。
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

    // 关键：每次构建都从媒体库取最新数据，手动匹配后立即反映
    final current = library.findVideo(video.sourceId, video.path) ?? video;
    final source = library.sourceById(current.sourceId);
    final episodes = library.episodesOf(current);
    final isSeries = episodes.length > 1;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Stack(
            children: [
              _HeroBackdrop(video: current),
              Column(
                children: [
                  const SizedBox(height: 20),
                  _TopBar(video: current),
                  const SizedBox(height: 14),
                  _InfoRow(video: current, source: source, isSeries: isSeries),
                ],
              ),
            ],
          ),
        ),
        if (isSeries)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(32, 10, 32, 36),
            sliver: _EpisodeGrid(episodes: episodes),
          )
        else
          const SliverPadding(padding: EdgeInsets.only(bottom: 36)),
      ],
    );
  }
}

/// 顶部背景：海报放大模糊 + 上下渐变，让内容自然浮在上面。
class _HeroBackdrop extends StatelessWidget {
  const _HeroBackdrop({required this.video});

  final ScannedVideo video;

  @override
  Widget build(BuildContext context) {
    final hasPoster =
        video.posterPath != null && File(video.posterPath!).existsSync();
    final colors = _paletteFor(video.title);
    return SizedBox(
      width: double.infinity,
      height: 470,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasPoster)
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 36, sigmaY: 36),
              child: Transform.scale(
                scale: 1.35,
                child: Image.file(File(video.posterPath!), fit: BoxFit.cover),
              ),
            )
          else
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: colors,
                ),
              ),
            ),
          // 上下渐隐：顶部压暗保证文字可读，底部融入页面底色
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0, 0.35, 1],
                colors: [
                  Colors.black.withValues(alpha: 0.32),
                  Colors.black.withValues(alpha: 0.16),
                  AppColors.background.withValues(alpha: 1),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Color> _paletteFor(String title) {
    const palettes = <List<Color>>[
      [Color(0xFF2E5548), Color(0xFF6FA68B)],
      [Color(0xFF3D5175), Color(0xFF7E97C4)],
      [Color(0xFF6E5544), Color(0xFFBA9373)],
      [Color(0xFF4E3D6E), Color(0xFF9373BA)],
    ];
    var hash = 0;
    for (final code in title.codeUnits) {
      hash = (hash * 31 + code) & 0x7FFFFFFF;
    }
    return palettes[hash % palettes.length];
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.video});

  final ScannedVideo video;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 26),
      child: Row(
        children: [
          Material(
            color: Colors.black38,
            borderRadius: BorderRadius.circular(22),
            child: InkWell(
              onTap: () => Navigator.of(context).maybePop(),
              borderRadius: BorderRadius.circular(22),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.arrow_back_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
                    SizedBox(width: 6),
                    Text(
                      '返回',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Spacer(),
          Text(
            sourceLabel(video.kind),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  static String sourceLabel(MediaKind kind) => switch (kind) {
    MediaKind.movie => '电影',
    MediaKind.series => '电视剧',
    MediaKind.anime => '动漫',
    MediaKind.variety => '综艺',
  };
}

/// 海报 + 标题信息 + 操作按钮。
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.video,
    required this.source,
    required this.isSeries,
  });

  final ScannedVideo video;
  final MediaSource? source;
  final bool isSeries;

  @override
  Widget build(BuildContext context) {
    final episodes = MediaLibrary.instance.episodesOf(video);
    final hasPoster =
        video.posterPath != null && File(video.posterPath!).existsSync();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 海报卡片
          Container(
            width: 200,
            height: 300,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 28,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: hasPoster
                  ? Image.file(
                      File(video.posterPath!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _PosterFallback(video: video),
                    )
                  : _PosterFallback(video: video),
            ),
          ),
          const SizedBox(width: 30),
          // 信息区
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 26),
                Text(
                  video.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (video.rating != null) ...[
                      const Icon(
                        Icons.star_rounded,
                        size: 19,
                        color: Color(0xFFFFC85C),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        video.rating!,
                        style: const TextStyle(
                          color: Color(0xFFFFC85C),
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 16),
                    ],
                    Flexible(
                      child: Text(
                        [
                          if (video.modified != null) '${video.modified!.year}',
                          if (isSeries) '共 ${episodes.length} 集',
                          if (source != null) '来自「${source!.name}」',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        key: const ValueKey('detail-play'),
                        onPressed: episodes.isEmpty
                            ? null
                            : () => _play(context, episodes.first),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black87,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        icon: const Icon(Icons.play_arrow_rounded, size: 26),
                        label: Text(
                          _playLabel(episodes.isEmpty ? null : episodes.first),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        key: const ValueKey('manual-match'),
                        onPressed: () => _matchManually(context, episodes),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.5),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          textStyle: const TextStyle(fontSize: 13.5),
                        ),
                        icon: const Icon(Icons.manage_search_rounded, size: 20),
                        label: const Text('修正匹配'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                if (video.summary != null && video.summary!.isNotEmpty)
                  Text(
                    video.summary!,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.82),
                      fontSize: 13.5,
                      height: 1.75,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _playLabel(ScannedVideo? episode) {
    if (episode == null) return '播放';
    final entry = PlaybackHistory.instance.entryOf(
      episode.sourceId,
      episode.path,
    );
    if (entry == null || entry.positionSec <= 1) return '立即播放';
    if (entry.finished) return '重新播放';
    final left = (entry.durationSec - entry.positionSec) / 60;
    return '继续 · 剩 ${left.ceil()} 分钟';
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

  Future<void> _matchManually(
    BuildContext context,
    List<ScannedVideo> group,
  ) async {
    final parsed = ScraperService.parseTitle(video.title);
    final initialQuery = parsed.queries.isEmpty
        ? video.title
        : parsed.queries.first;
    final candidate = await showDialog<ScrapeCandidate>(
      context: context,
      builder: (_) => MatchSearchDialog(
        initialQuery: initialQuery,
        preferTv: group.length > 1,
      ),
    );
    if (candidate == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final poster = await MediaLibrary.instance.applyCandidate(
      video,
      group,
      candidate,
    );
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            poster != null
                ? '已应用「${candidate.name}」的海报与信息'
                : '已应用「${candidate.name}」的信息（未取到海报）',
          ),
        ),
      );
  }
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback({required this.video});

  final ScannedVideo video;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF3A4A44),
      child: Center(
        child: Icon(
          switch (video.kind) {
            MediaKind.movie => Icons.movie_outlined,
            MediaKind.series => Icons.live_tv_outlined,
            MediaKind.anime => Icons.animation_outlined,
            MediaKind.variety => Icons.emoji_events_outlined,
          },
          size: 52,
          color: Colors.white54,
        ),
      ),
    );
  }
}

/// 剧集网格：每集一张卡片。
class _EpisodeGrid extends StatelessWidget {
  const _EpisodeGrid({required this.episodes});

  final List<ScannedVideo> episodes;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final columns = ((width - 64) / 200).floor().clamp(3, 8);
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
        childAspectRatio: 1.55,
      ),
      delegate: SliverChildBuilderDelegate((context, index) {
        return _EpisodeCard(episode: episodes[index], index: index);
      }, childCount: episodes.length),
    );
  }
}

class _EpisodeCard extends StatefulWidget {
  const _EpisodeCard({required this.episode, required this.index});

  final ScannedVideo episode;
  final int index;

  @override
  State<_EpisodeCard> createState() => _EpisodeCardState();
}

class _EpisodeCardState extends State<_EpisodeCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final episode = widget.episode;
    final entry = PlaybackHistory.instance.entryOf(
      episode.sourceId,
      episode.path,
    );
    final finished = entry?.finished ?? false;
    final progress = entry?.progress ?? 0.0;
    final colors = [const Color(0xFF3D6B5C), const Color(0xFF7FB89F)];

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => _play(context, episode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
            ),
            borderRadius: BorderRadius.circular(14),
            boxShadow: _hovered
                ? [
                    BoxShadow(
                      color: colors.first.withValues(alpha: 0.4),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '第 ${widget.index + 1} 集',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      episode.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.82),
                        fontSize: 11.5,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              if (_hovered)
                Center(
                  child: CircleAvatar(
                    radius: 26,
                    backgroundColor: Colors.black.withValues(alpha: 0.35),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                ),
              if (progress > 0)
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 12,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: finished ? 1 : progress,
                      minHeight: 3.5,
                      color: finished ? Colors.white70 : AppColors.accent,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                ),
              if (finished)
                Positioned(
                  right: 10,
                  top: 10,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black38,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      color: Colors.white,
                      size: 14,
                    ),
                  ),
                ),
            ],
          ),
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
