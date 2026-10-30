import 'dart:io';

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/media_source.dart';
import '../services/media_library.dart';
import '../services/playback_history.dart';
import '../services/scraper_service.dart';
import '../widgets/match_dialog.dart';
import 'player_page.dart';

/// 影片详情页：爆米花风格——剧照大图背景 + 信息浮层 + 剧集剧照列表。
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
    // 关键：解析到聚合条目（剧名/集数/海报都在聚合层），而非原始单集文件
    final current = library.resolveAggregated(video);
    final source = library.sourceById(current.sourceId);
    final episodes = library.episodesOf(current);
    final isSeries = episodes.length > 1;
    final heroH = (MediaQuery.of(context).size.height * 0.42).clamp(
      320.0,
      500.0,
    );

    return CustomScrollView(
      slivers: [
        // 顶部剧照背景 + 信息浮层
        SliverToBoxAdapter(
          child: _HeroWithInfo(
            video: current,
            source: source,
            episodes: episodes,
            isSeries: isSeries,
            height: heroH,
          ),
        ),
        // 剧集区
        if (isSeries)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 32),
            sliver: _EpisodeList(episodes: episodes),
          )
        else
          const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }
}

/// 顶部剧照背景（占满宽度）+ 所有信息浮在其上。
class _HeroWithInfo extends StatelessWidget {
  const _HeroWithInfo({
    required this.video,
    required this.source,
    required this.episodes,
    required this.isSeries,
    required this.height,
  });

  final ScannedVideo video;
  final MediaSource? source;
  final List<ScannedVideo> episodes;
  final bool isSeries;
  final double height;

  @override
  Widget build(BuildContext context) {
    final hasPoster =
        video.posterPath != null && File(video.posterPath!).existsSync();
    final currentEpisode = _currentEpisode(episodes);

    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 剧照背景：清晰大图，占满整个区域
          if (hasPoster)
            Image.file(
              File(video.posterPath!),
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
            )
          else
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: _paletteFor(video.title),
                ),
              ),
            ),
          // 渐变遮罩：顶部暗 → 中部自然 → 底部融入页面底色
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.0, 0.4, 0.75, 1.0],
                colors: [
                  Colors.black.withValues(alpha: 0.35),
                  Colors.black.withValues(alpha: 0.1),
                  AppColors.background.withValues(alpha: 0.5),
                  AppColors.background,
                ],
              ),
            ),
          ),
          // 信息层
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 16, 28, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部行：返回 + 类型
                Row(
                  children: [
                    _GhostButton(
                      icon: Icons.arrow_back_rounded,
                      label: '返回',
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const Spacer(),
                    Text(
                      _kindLabel(video.kind),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                // 标题
                Text(
                  video.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                // 评分与元信息
                Row(
                  children: [
                    if (video.rating != null) ...[
                      const Icon(
                        Icons.star_rounded,
                        size: 18,
                        color: Color(0xFFFFC85C),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        video.rating!,
                        style: const TextStyle(
                          color: Color(0xFFFFC85C),
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 12),
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
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                // 播放按钮 + 修正匹配
                Row(
                  children: [
                    SizedBox(
                      height: 44,
                      child: ElevatedButton.icon(
                        key: const ValueKey('detail-play'),
                        onPressed: episodes.isEmpty
                            ? null
                            : () => _play(context, currentEpisode),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.black87,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          textStyle: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        icon: const Icon(Icons.play_arrow_rounded, size: 24),
                        label: Text(
                          episodes.isEmpty
                              ? '播放'
                              : '播放 第 ${currentEpisode.index + 1} 集${_formatDuration(currentEpisode.durationSec)}',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      height: 44,
                      child: OutlinedButton.icon(
                        key: const ValueKey('manual-match'),
                        onPressed: () => _matchManually(context, episodes),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.45),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          textStyle: const TextStyle(fontSize: 13),
                        ),
                        icon: const Icon(Icons.manage_search_rounded, size: 18),
                        label: const Text('修正匹配'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                // 简介
                if (video.summary != null && video.summary!.isNotEmpty)
                  Text(
                    video.summary!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75),
                      fontSize: 13,
                      height: 1.65,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 当前应播放的集：优先上次看到的，否则第一集。
  ({ScannedVideo episode, int index, double durationSec}) _currentEpisode(
    List<ScannedVideo> episodes,
  ) {
    if (episodes.isEmpty) return (episode: video, index: 0, durationSec: 0);
    final history = PlaybackHistory.instance;
    for (var i = 0; i < episodes.length; i++) {
      final entry = history.entryOf(episodes[i].sourceId, episodes[i].path);
      if (entry != null && !entry.finished && entry.positionSec > 1) {
        return (episode: episodes[i], index: i, durationSec: entry.durationSec);
      }
    }
    final entry = history.entryOf(episodes.first.sourceId, episodes.first.path);
    return (
      episode: episodes.first,
      index: 0,
      durationSec: entry?.durationSec ?? 0,
    );
  }

  static String _formatDuration(double sec) {
    if (sec <= 0) return '';
    return ' ${(sec / 60).round()} 分钟';
  }

  static void _play(
    BuildContext context,
    ({ScannedVideo episode, int index, double durationSec}) current,
  ) {
    final entry = PlaybackHistory.instance.entryOf(
      current.episode.sourceId,
      current.episode.path,
    );
    final resume = entry != null && !entry.finished && entry.positionSec > 1;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          video: current.episode,
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

  List<Color> _paletteFor(String title) {
    const palettes = <List<Color>>[
      [Color(0xFF1B3A2E), Color(0xFF2D5F47)],
      [Color(0xFF1E2A3F), Color(0xFF3D5A80)],
      [Color(0xFF3A2A1E), Color(0xFF6B4F35)],
      [Color(0xFF2B1B3D), Color(0xFF4A2D6B)],
    ];
    var hash = 0;
    for (final code in title.codeUnits) {
      hash = (hash * 31 + code) & 0x7FFFFFFF;
    }
    return palettes[hash % palettes.length];
  }

  static String _kindLabel(MediaKind kind) => switch (kind) {
    MediaKind.movie => '电影',
    MediaKind.series => '电视剧',
    MediaKind.anime => '动漫',
    MediaKind.variety => '综艺',
  };
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 剧集区：标题 + 剧照缩略图横排。
class _EpisodeList extends StatelessWidget {
  const _EpisodeList({required this.episodes});

  final List<ScannedVideo> episodes;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '第 1 季',
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 130,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: episodes.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              return _EpisodeCard(episode: episodes[index], index: index);
            },
          ),
        ),
      ],
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

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => _play(context, episode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 210,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _hovered
                  ? AppColors.primary.withValues(alpha: 0.5)
                  : AppColors.border,
              width: _hovered ? 1.5 : 1,
            ),
            boxShadow: _hovered
                ? [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.15),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 剧照区域
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF2D5F47), Color(0xFF1B3A2E)],
                    ),
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(10),
                    ),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Center(
                        child: Text(
                          '${widget.index + 1}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.9),
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (_hovered)
                        Center(
                          child: CircleAvatar(
                            radius: 20,
                            backgroundColor: Colors.black.withValues(
                              alpha: 0.5,
                            ),
                            child: const Icon(
                              Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 22,
                            ),
                          ),
                        ),
                      if (progress > 0)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: LinearProgressIndicator(
                            value: finished ? 1 : progress,
                            minHeight: 3,
                            color: finished ? Colors.white70 : AppColors.accent,
                            backgroundColor: Colors.white24,
                          ),
                        ),
                      if (finished)
                        const Positioned(
                          right: 8,
                          top: 8,
                          child: Icon(
                            Icons.check_circle_rounded,
                            color: Colors.white70,
                            size: 16,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // 集数信息
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '第 ${widget.index + 1} 集',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      episode.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
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
