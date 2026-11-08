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
import '../widgets/poster_card.dart';
import '../widgets/recent_playback_card.dart';
import '../widgets/section_header.dart';

class HomePage extends StatefulWidget {
  const HomePage({this.onOpenLibrary, this.onOpenSettings, super.key});

  final ValueChanged<int>? onOpenLibrary;
  final VoidCallback? onOpenSettings;

  /// 测试注入用：固定随机源使轮播内容可复现（golden 截图与文本断言）。
  /// 产品环境为 null，使用系统随机。
  @visibleForTesting
  static Random? bannerShuffleRandom;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with AutomaticKeepAliveClientMixin {
  final _bannerController = PageController();

  Timer? _carouselTimer;
  int _bannerIndex = 0;

  @override
  void initState() {
    super.initState();
    _carouselTimer = Timer.periodic(const Duration(seconds: 7), (_) {
      if (!mounted || !_bannerController.hasClients) return;
      final items = _bannerItems();
      if (items.isEmpty) return;
      final next = (_bannerIndex + 1) % items.length;
      _bannerController.animateToPage(
        next,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _carouselTimer?.cancel();
    _bannerController.dispose();
    super.dispose();
  }

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
        final history = _recentEntries();
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
        final empty = banners.isEmpty && history.isEmpty && sections.isEmpty;

        // 分区用原生 SliverGrid 逐卡懒构建，而不是每个分区一个
        // shrinkWrap GridView——后者在分区进入视口的那一帧要一次性
        // 构建 14 张卡片，是首页滚动顿挫的根源。
        return LayoutBuilder(
          builder: (context, constraints) {
            final rawWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;
            final contentWidth = rawWidth - 56; // 左右各 28 内边距
            return CustomScrollView(
              key: const PageStorageKey('home-scroll'),
              slivers: [
                if (empty)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(28, 20, 28, 40),
                    sliver: SliverToBoxAdapter(child: _buildEmptyLibrary()),
                  )
                else ...[
                  if (banners.isNotEmpty) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(28, 20, 28, 0),
                        child: BannerCarousel(
                          items: banners,
                          controller: _bannerController,
                          index: _bannerIndex,
                          onPageChanged: (index) =>
                              setState(() => _bannerIndex = index),
                          onPlay: _playBanner,
                          onShowDetails: _showBannerDetails,
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                  if (history.isNotEmpty) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SectionHeader(
                              title: '最近播放',
                              onViewAll: () =>
                                  _showMessage('最近播放完整记录将在媒体库接入后开放'),
                            ),
                            const SizedBox(height: 12),
                            _buildRecentGrid(history),
                          ],
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                  for (var i = 0; i < sections.length; i++)
                    ..._sectionSlivers(
                      sections[i],
                      contentWidth,
                      isLast: i == sections.length - 1,
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 40)),
                ],
              ],
            );
          },
        );
      },
    );
  }

  /// 单个分区：标题 + 海报网格，网格用 SliverGrid 按卡懒构建。
  List<Widget> _sectionSlivers(
    ({String title, int page, List<MediaItem> items}) section,
    double contentWidth, {
    required bool isLast,
  }) {
    final columns = ((contentWidth + 16) / (168 + 16)).floor().clamp(
      1,
      _wallColumns,
    );
    final cardWidth = (contentWidth - 16 * (columns - 1)) / columns;
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        sliver: SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: SectionHeader(
                title: section.title,
                onViewAll: () => widget.onOpenLibrary?.call(section.page),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
            SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 16,
                mainAxisSpacing: 22,
                mainAxisExtent: PosterCard.extentForWidth(cardWidth),
              ),
              delegate: SliverChildBuilderDelegate(
                childCount: section.items.length,
                (context, index) =>
                    PosterCard(item: section.items[index], width: cardWidth),
              ),
            ),
            if (!isLast) const SliverToBoxAdapter(child: SizedBox(height: 28)),
          ],
        ),
      ),
    ];
  }

  Widget _buildEmptyLibrary() {
    final hasSources = MediaLibrary.instance.sources.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: context.colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.video_library_outlined,
            size: 42,
            color: context.colors.primary,
          ),
          const SizedBox(height: 14),
          Text(
            hasSources ? '还没有已匹配的影片' : '媒体库还是空的',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            hasSources
                ? '扫描到的条目需要匹配到海报后才会显示。可到「设置 → 刮削」处理未匹配内容。'
                : '添加本地目录或 WebDAV 后，扫描到的影片会出现在这里。',
            style: TextStyle(
              color: context.colors.muted,
              fontSize: 13,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            key: const ValueKey('empty-library-settings'),
            onPressed: widget.onOpenSettings,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: Text(hasSources ? '去处理未匹配内容' : '去添加媒体源'),
          ),
        ],
      ),
    );
  }

  void _playBanner(MediaItem item) {
    final video = item.payload;
    if (video is! ScannedVideo) return;
    final library = MediaLibrary.instance;
    final aggregated = library.resolveAggregated(video);
    final episodes = library.episodesOf(aggregated);
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

  /// 首页轮播：启动/内容变化后随机挑选一次，避免每次重建都变。
  List<MediaItem>? _bannerCache;
  String _bannerSignature = '';

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
      ..shuffle(HomePage.bannerShuffleRandom);
    _bannerCache = shuffled.take(6).toList();
    _bannerSignature = signature;
    return _bannerCache!;
  }

  /// 首页每个分区铺两行海报墙，其余进「查看全部」。
  static const _wallColumns = 7;
  static const _wallRows = 2;

  List<MediaItem> _sectionItems(MediaKind kind) {
    final library = MediaLibrary.instance;
    return [for (final video in library.byKind(kind)) ?toMediaItem(video)]
        .take(_wallColumns * _wallRows)
        .toList();
  }

  List<HistoryEntry> _recentEntries() {
    final library = MediaLibrary.instance;
    return PlaybackHistory.instance.entries
        .where((entry) => !entry.finished)
        // 已隐藏的影片不再出现在首页「最近播放」里，否则同步后又像
        // 没隐藏成功一样被刷回首页。
        .where((entry) {
          final video = library.findVideo(entry.sourceId, entry.path);
          return video == null || !library.isHiddenVideo(video);
        })
        .take(3)
        .toList();
  }

  @override
  bool get wantKeepAlive => true;

  Widget _buildRecentGrid(List<HistoryEntry> history) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 760
            ? 3
            : (constraints.maxWidth >= 520 ? 2 : 1);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: history.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
            mainAxisExtent: 92,
          ),
          itemBuilder: (context, index) => RecentPlaybackCard(
            key: ValueKey(
              'recent-${history[index].sourceId}-${history[index].path}',
            ),
            item: _historyItem(history[index]),
            onTap: () => _resume(history[index]),
            onDelete: () => _removeRecent(history[index]),
          ),
        );
      },
    );
  }

  MediaItem _historyItem(HistoryEntry entry) {
    final library = MediaLibrary.instance;
    final video = library.findVideo(entry.sourceId, entry.path);
    var title = entry.title;
    String? episodeLabel;
    if (video != null) {
      final aggregate = library.aggregateOf(video);
      final officialTitle = aggregate.tmdbTitle?.trim() ?? '';
      final displayTitle = officialTitle.isNotEmpty
          ? officialTitle
          : aggregate.title.trim();
      if (displayTitle.isNotEmpty) title = displayTitle;
      if (video.kind != MediaKind.movie) {
        final normalized = MediaLibrary.normalizeSeriesTitle(
          MediaLibrary.seriesTitleForDisplay(title),
        );
        if (normalized.isNotEmpty) title = normalized;
      }
      episodeLabel = MediaLibrary.episodeLabelOf(video);
    }
    return MediaItem(
      title: title,
      subtitle: entry.finished
          ? '已看完'
          : '看到 ${(entry.progress * 100).toStringAsFixed(0)}% · '
                '剩余 ${((entry.durationSec - entry.positionSec) / 60).ceil()} 分钟',
      year: '',
      colors: _paletteFor(title),
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

  List<Color> _paletteFor(String title) {
    const palettes = [
      [Color(0xFF3D6B5C), Color(0xFF7FB89F)],
      [Color(0xFF4A5E85), Color(0xFF8FA8D0)],
      [Color(0xFF7A5C4A), Color(0xFFC89F7F)],
      [Color(0xFF5C4A7A), Color(0xFFA88FC8)],
    ];
    var hash = 0;
    for (final code in title.codeUnits) {
      hash = (hash * 31 + code) & 0x7FFFFFFF;
    }
    return palettes[hash % palettes.length];
  }

  void _resume(HistoryEntry entry) {
    final library = MediaLibrary.instance;
    final video = library.findVideo(entry.sourceId, entry.path);
    if (video == null) {
      _showMessage('该内容所属媒体源未同步或已删除，去设置里重新同步后再试');
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

  Future<void> _removeRecent(HistoryEntry entry) async {
    final title = _historyItem(entry).title;
    final removal = PlaybackHistory.instance.remove(entry.sourceId, entry.path);
    if (mounted) setState(() {});
    await removal;
    if (!mounted) return;
    _showMessage('已从最近播放移除「$title」');
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
