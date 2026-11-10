import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/media_item.dart';
import '../models/media_source.dart';
import '../pages/detail_page.dart';
import '../pages/player_page.dart';
import '../services/media_library.dart';
import '../services/playback_history.dart';
import '../widgets/banner_carousel.dart';
import '../widgets/tv_poster_card.dart';
import '../widgets/tv_poster_grid.dart';

/// 电视端首页：大横幅 + 继续观看 + 分类海报墙。
class TvHomePage extends StatefulWidget {
  const TvHomePage({this.onOpenLibrary, this.onOpenSettings, super.key});

  final ValueChanged<int>? onOpenLibrary;
  final VoidCallback? onOpenSettings;

  @override
  State<TvHomePage> createState() => _TvHomePageState();
}

class _TvHomePageState extends State<TvHomePage>
    with AutomaticKeepAliveClientMixin {
  static const _sectionRowColumns = 5;
  static const _sectionRows = 2;

  final _bannerController = PageController();
  final _scrollController = ScrollController();
  Timer? _carouselTimer;
  int _bannerIndex = 0;

  List<MediaItem>? _bannerCache;
  String _bannerSignature = '';

  @override
  void initState() {
    super.initState();
    _carouselTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted || !_bannerController.hasClients) return;
      final items = _bannerItems();
      if (items.isEmpty) return;
      _bannerController.animateToPage(
        (_bannerIndex + 1) % items.length,
        duration: const Duration(milliseconds: 480),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _carouselTimer?.cancel();
    _bannerController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AnimatedBuilder(
      animation: Listenable.merge([
        MediaLibrary.instance,
        PlaybackHistory.instance,
      ]),
      builder: (context, _) {
        final banners = _bannerItems();
        final recent = _recentEntries();
        final sections =
            [
                  (kind: MediaKind.movie, title: '电影', page: 1),
                  (kind: MediaKind.series, title: '电视剧', page: 2),
                  (kind: MediaKind.anime, title: '动漫', page: 3),
                  (kind: MediaKind.variety, title: '综艺', page: 4),
                ]
                .map(
                  (section) => (
                    title: section.title,
                    page: section.page,
                    items: _sectionItems(section.kind),
                  ),
                )
                .where((section) => section.items.isNotEmpty)
                .toList();
        final empty = banners.isEmpty && recent.isEmpty && sections.isEmpty;

        if (empty) return _buildEmptyLibrary();

        return CustomScrollView(
          key: const PageStorageKey('tv-home-scroll'),
          controller: _scrollController,
          slivers: [
            if (banners.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(40, 28, 40, 0),
                  child: BannerCarousel(
                    items: banners,
                    controller: _bannerController,
                    index: _bannerIndex,
                    large: true,
                    onPageChanged: (index) =>
                        setState(() => _bannerIndex = index),
                    onPlay: _playBanner,
                    onShowDetails: _showBannerDetails,
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 34)),
            ],
            if (recent.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: _SectionTitle(
                    title: '继续观看',
                    onViewAll: () => widget.onOpenLibrary?.call(0),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 510,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(40, 16, 40, 12),
                    itemCount: recent.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 26),
                    itemBuilder: (context, index) {
                      final entry = recent[index];
                      return SizedBox(
                        width: 250,
                        child: TvPosterCard(
                          item: _historyItem(entry),
                          width: 250,
                          onTap: () => _resume(entry),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 26)),
            ],
            for (var i = 0; i < sections.length; i++)
              ..._sectionSlivers(sections[i], isLast: i == sections.length - 1),
            const SliverToBoxAdapter(child: SizedBox(height: 60)),
          ],
        );
      },
    );
  }

  List<Widget> _sectionSlivers(
    ({String title, int page, List<MediaItem> items}) section, {
    required bool isLast,
  }) {
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        sliver: SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: _SectionTitle(
                title: section.title,
                onViewAll: () => widget.onOpenLibrary?.call(section.page),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 16)),
            SliverLayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.crossAxisExtent;
                const spacing = 28.0;
                final columns = TvPosterGrid.columnsFor(
                  width,
                  spacing: spacing,
                  max: _sectionRowColumns,
                );
                final cardWidth = (width - spacing * (columns - 1)) / columns;
                final textScaler = MediaQuery.textScalerOf(context);
                return SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: spacing,
                    mainAxisSpacing: 34,
                    mainAxisExtent: TvPosterCard.extentForWidth(
                      cardWidth,
                      textScaler,
                    ),
                  ),
                  delegate: SliverChildBuilderDelegate(
                    childCount: section.items.length,
                    (context, index) => TvPosterCard(
                      item: section.items[index],
                      width: cardWidth,
                    ),
                  ),
                );
              },
            ),
            if (!isLast) const SliverToBoxAdapter(child: SizedBox(height: 34)),
          ],
        ),
      ),
    ];
  }

  Widget _buildEmptyLibrary() {
    final colors = context.colors;
    final hasSources = MediaLibrary.instance.sources.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 120),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.video_library_outlined, size: 72, color: colors.primary),
            const SizedBox(height: 24),
            Text(
              hasSources ? '还没有已匹配的影片' : '媒体库还是空的',
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w700,
                color: colors.text,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              hasSources
                  ? '扫描到的条目需要匹配到海报后才会显示。可到「设置 → 刮削」处理未匹配内容。'
                  : '添加本地目录或 WebDAV 后，扫描到的影片会出现在这里。',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.muted, fontSize: 18, height: 1.6),
            ),
            const SizedBox(height: 26),
            FilledButton.icon(
              onPressed: widget.onOpenSettings,
              icon: const Icon(Icons.add_rounded, size: 22),
              label: Text(
                hasSources ? '去处理未匹配内容' : '去添加媒体源',
                style: const TextStyle(fontSize: 18),
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size(220, 58),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<MediaItem> _bannerItems() {
    final library = MediaLibrary.instance;
    final all = <ScannedVideo>[];
    for (final kind in MediaKind.values) {
      all.addAll(library.byKind(kind));
    }
    if (all.isEmpty) {
      _bannerCache = null;
      _bannerSignature = '';
      return const [];
    }
    final signature = all
        .map((video) => '${video.sourceId}|${video.path}|${video.posterPath}')
        .join('\u0000');
    final cached = _bannerCache;
    if (cached != null && signature == _bannerSignature) return cached;
    final shuffled = [for (final video in all) ?toMediaItem(video)]
      ..shuffle(Random(signature.hashCode));
    _bannerCache = shuffled.take(6).toList();
    _bannerSignature = signature;
    return _bannerCache!;
  }

  List<MediaItem> _sectionItems(MediaKind kind) {
    final library = MediaLibrary.instance;
    return [for (final video in library.byKind(kind)) ?toMediaItem(video)]
        .take(_sectionRowColumns * _sectionRows)
        .toList();
  }

  /// 继续观看：同一部作品只留最近一条，最多 8 条。
  List<HistoryEntry> _recentEntries() {
    final library = MediaLibrary.instance;
    final result = <HistoryEntry>[];
    final seen = <String>{};
    for (final entry in PlaybackHistory.instance.entries) {
      final video = library.findVideo(entry.sourceId, entry.path);
      if (entry.finished) continue;
      if (video != null && library.isHiddenVideo(video)) continue;
      final key = video == null
          ? '${entry.sourceId}|${entry.path}'
          : _groupKey(entry, video);
      if (!seen.add(key)) continue;
      result.add(entry);
      if (result.length >= 8) break;
    }
    return result;
  }

  String _groupKey(HistoryEntry entry, ScannedVideo video) {
    final library = MediaLibrary.instance;
    final aggregate = library.resolveAggregated(video);
    if (video.kind == MediaKind.movie) {
      final tmdbId = video.tmdbId ?? aggregate.tmdbId;
      if (tmdbId != null) return 'movie|${video.sourceId}|tmdb|$tmdbId';
      final title =
          (MediaLibrary.officialTitleOf(video) ??
                  MediaLibrary.officialTitleOf(aggregate) ??
                  '')
              .trim();
      if (title.isNotEmpty) {
        return 'movie|${video.sourceId}|title|${title.toLowerCase()}';
      }
      return '${video.sourceId}|${video.path}';
    }
    final rawTitle =
        (MediaLibrary.officialTitleOf(aggregate) ?? aggregate.title).trim();
    final title = MediaLibrary.normalizeSeriesTitle(
      MediaLibrary.seriesTitleForDisplay(rawTitle),
    );
    return 'series|${aggregate.sourceId}|${(title.isEmpty ? rawTitle : title).toLowerCase()}';
  }

  MediaItem _historyItem(HistoryEntry entry) {
    final video = MediaLibrary.instance.findVideo(entry.sourceId, entry.path);
    var title = entry.title;
    String? episodeLabel;
    if (video != null) {
      final aggregate = MediaLibrary.instance.aggregateOf(video);
      final official = MediaLibrary.officialTitleOf(aggregate) ?? '';
      final display = official.isNotEmpty ? official : aggregate.title.trim();
      if (display.isNotEmpty) title = display;
      if (video.kind != MediaKind.movie) {
        final normalized = MediaLibrary.normalizeSeriesTitle(
          MediaLibrary.seriesTitleForDisplay(title),
        );
        if (normalized.isNotEmpty) title = normalized;
        episodeLabel = MediaLibrary.episodeLabelOf(video);
      }
    }
    return MediaItem(
      title: title,
      subtitle: entry.finished
          ? '已看完'
          : '看到 ${(entry.progress * 100).toStringAsFixed(0)}%',
      year: '',
      colors: const [Color(0xFF1E293B), Color(0xFF0F172A)],
      icon: switch (entry.kind) {
        MediaKind.movie => Icons.movie_outlined,
        MediaKind.series => Icons.live_tv_outlined,
        MediaKind.anime => Icons.animation_outlined,
        MediaKind.variety => Icons.emoji_events_outlined,
      },
      episodeLabel: episodeLabel,
      progress: entry.progress,
      posterPath: entry.thumbnailPath,
      payload: entry,
    );
  }

  void _playBanner(MediaItem item) {
    final video = item.payload;
    if (video is! ScannedVideo) return;
    final library = MediaLibrary.instance;
    final episodes = library.episodesOf(library.resolveAggregated(video));
    final episode = episodes.first;
    final entry = PlaybackHistory.instance.entryOf(
      episode.sourceId,
      episode.path,
    );
    final resume = entry != null && !entry.finished && entry.positionSec > 1;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          video: episode,
          episodes: episodes,
          startPosition: resume ? entry.positionSec : null,
        ),
      ),
    );
  }

  void _showBannerDetails(MediaItem item) {
    final video = item.payload;
    if (video is! ScannedVideo) return;
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => DetailPage(video: video)));
  }

  void _resume(HistoryEntry entry) {
    final library = MediaLibrary.instance;
    final video = library.findVideo(entry.sourceId, entry.path);
    if (video == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('该内容所属媒体源未同步或已删除，去设置里重新同步后再试')),
        );
      return;
    }
    final episodes = library.episodesOf(library.resolveAggregated(video));
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          video: video,
          episodes: episodes,
          startPosition: entry.positionSec,
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.onViewAll});

  final String title;
  final VoidCallback? onViewAll;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      children: [
        Container(
          width: 5,
          height: 30,
          decoration: BoxDecoration(
            color: colors.primary,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 14),
        Text(
          title,
          style: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w700,
            color: colors.text,
            letterSpacing: -0.4,
          ),
        ),
        const Spacer(),
        if (onViewAll != null)
          TextButton(
            onPressed: onViewAll,
            style: TextButton.styleFrom(
              foregroundColor: colors.muted,
              minimumSize: const Size(110, 48),
            ),
            child: const Text('查看全部', style: TextStyle(fontSize: 17)),
          ),
      ],
    );
  }
}
