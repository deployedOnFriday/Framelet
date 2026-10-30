import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/app_theme.dart';
import '../data/demo_data.dart';
import '../models/media_item.dart';
import '../models/media_source.dart';
import '../pages/player_page.dart';
import '../pages/search_results_page.dart';
import '../services/media_library.dart';
import '../services/playback_history.dart';
import '../widgets/banner_carousel.dart';
import '../widgets/poster_card.dart';
import '../widgets/recent_playback_card.dart';
import '../widgets/section_header.dart';

class HomePage extends StatefulWidget {
  const HomePage({this.onOpenLibrary, super.key});

  final ValueChanged<int>? onOpenLibrary;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _bannerController = PageController();
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _carouselTimer;
  int _bannerIndex = 0;

  @override
  void initState() {
    super.initState();
    _carouselTimer = Timer.periodic(const Duration(seconds: 7), (_) {
      if (!mounted || !_bannerController.hasClients) return;
      final next = (_bannerIndex + 1) % DemoData.featured.length;
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
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _searchFocus.requestFocus,
      },
      child: CustomScrollView(
        key: const PageStorageKey('home-scroll'),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _buildSearch(),
                const SizedBox(height: 22),
                BannerCarousel(
                  items: DemoData.featured,
                  controller: _bannerController,
                  index: _bannerIndex,
                  onPageChanged: (index) =>
                      setState(() => _bannerIndex = index),
                ),
                const SizedBox(height: 24),
                SectionHeader(
                  title: '最近播放',
                  onViewAll: () => _showMessage('最近播放完整记录将在媒体库接入后开放'),
                ),
                const SizedBox(height: 12),
                _buildRecentGrid(),
                const SizedBox(height: 24),
                ?_buildSyncNotice(),
                _buildPosterSection(
                  '电影',
                  _sectionItems(MediaKind.movie, DemoData.movies),
                  1,
                ),
                const SizedBox(height: 22),
                _buildPosterSection(
                  '电视剧',
                  _sectionItems(MediaKind.series, DemoData.series),
                  2,
                ),
                const SizedBox(height: 22),
                _buildPosterSection(
                  '动漫',
                  _sectionItems(MediaKind.anime, DemoData.anime),
                  3,
                ),
                const SizedBox(height: 22),
                _buildPosterSection(
                  '综艺',
                  _sectionItems(MediaKind.variety, DemoData.variety),
                  4,
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  /// 真实扫描数据优先；为空时回退演示内容。
  List<MediaItem> _sectionItems(MediaKind kind, List<MediaItem> fallback) {
    final library = MediaLibrary.instance;
    final scanned = library.byKind(kind);
    if (scanned.isEmpty) return fallback;
    return [for (final video in scanned) ?toMediaItem(video)];
  }

  /// 媒体库有同步内容时，显示一条同步状态提示。
  Widget? _buildSyncNotice() {
    final library = MediaLibrary.instance;
    if (!library.hasAnyContent) return null;
    var total = 0;
    for (final videos in library.byKind(MediaKind.values.first)) {
      total += videos.episodeCount;
    }
    for (final kind in [MediaKind.series, MediaKind.anime, MediaKind.variety]) {
      for (final video in library.byKind(kind)) {
        total += video.episodeCount;
      }
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.cloud_done_outlined,
            size: 18,
            color: AppColors.primary,
          ),
          const SizedBox(width: 10),
          Text(
            '媒体库已同步 · 共 ${library.sources.length} 个媒体源、$total 个视频文件',
            style: const TextStyle(color: AppColors.primary, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildSearch() {
    return SizedBox(
      height: 46,
      child: TextField(
        spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
        controller: _searchController,
        focusNode: _searchFocus,
        textInputAction: TextInputAction.search,
        onSubmitted: (value) {
          final query = value.trim();
          if (query.isEmpty) {
            _showMessage('请输入搜索内容');
            return;
          }
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SearchResultsPage(query: query),
            ),
          );
        },
        decoration: InputDecoration(
          hintText: '搜索影片、剧集或演员',
          hintStyle: const TextStyle(color: AppColors.muted, fontSize: 14),
          prefixIcon: const Icon(Icons.search_rounded, color: AppColors.muted),
          suffixIcon: const Padding(
            padding: EdgeInsets.only(right: 14, top: 13),
            child: Text(
              'Ctrl  K',
              style: TextStyle(color: AppColors.muted, fontSize: 12),
            ),
          ),
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(13),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(13),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(13),
            borderSide: const BorderSide(color: AppColors.primary, width: 1.4),
          ),
        ),
      ),
    );
  }

  Widget _buildRecentGrid() {
    return AnimatedBuilder(
      animation: PlaybackHistory.instance,
      builder: (context, _) {
        final history = PlaybackHistory.instance.entries
            .where((entry) => !entry.finished)
            .take(4)
            .toList();
        final hasReal = history.isNotEmpty;
        final count = hasReal ? history.length : DemoData.recent.length;
        return LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 1000
                ? 3
                : (constraints.maxWidth >= 560 ? 2 : 1);
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: count,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                mainAxisExtent: 112,
              ),
              itemBuilder: (context, index) => hasReal
                  ? RecentPlaybackCard(
                      item: _historyItem(history[index]),
                      onTap: () => _resume(history[index]),
                    )
                  : RecentPlaybackCard(item: DemoData.recent[index]),
            );
          },
        );
      },
    );
  }

  MediaItem _historyItem(HistoryEntry entry) {
    return MediaItem(
      title: entry.title,
      subtitle: entry.finished
          ? '已看完'
          : '看到 ${(entry.progress * 100).toStringAsFixed(0)}% · '
                '剩余 ${((entry.durationSec - entry.positionSec) / 60).ceil()} 分钟',
      year: '',
      colors: _paletteFor(entry.title),
      icon: switch (entry.kind) {
        MediaKind.movie => Icons.movie_outlined,
        MediaKind.series => Icons.live_tv_outlined,
        MediaKind.anime => Icons.animation_outlined,
        MediaKind.variety => Icons.emoji_events_outlined,
      },
      progress: entry.progress,
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
    final video = MediaLibrary.instance.findVideo(entry.sourceId, entry.path);
    if (video == null) {
      _showMessage('该内容所属媒体源未同步或已删除，去设置里重新同步后再试');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            PlayerPage(video: video, startPosition: entry.positionSec),
      ),
    );
  }

  Widget _buildPosterSection(
    String title,
    List<MediaItem> items,
    int pageIndex,
  ) {
    return Column(
      children: [
        SectionHeader(
          title: title,
          onViewAll: () => widget.onOpenLibrary?.call(pageIndex),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 254,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, index) =>
                PosterCard(item: items[index], width: 142),
          ),
        ),
      ],
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
