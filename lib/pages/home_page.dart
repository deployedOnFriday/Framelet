import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/app_theme.dart';
import '../data/demo_data.dart';
import '../models/media_item.dart';
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
                _buildPosterSection('电影', DemoData.movies, 1),
                const SizedBox(height: 22),
                _buildPosterSection('电视剧', DemoData.series, 2),
                const SizedBox(height: 22),
                _buildPosterSection('动漫', DemoData.anime, 3),
                const SizedBox(height: 22),
                _buildPosterSection('综艺', DemoData.variety, 4),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearch() {
    return SizedBox(
      height: 46,
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocus,
        textInputAction: TextInputAction.search,
        onSubmitted: (value) =>
            _showMessage(value.trim().isEmpty ? '请输入搜索内容' : '演示搜索：$value'),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = constraints.maxWidth >= 900
            ? 3
            : (constraints.maxWidth >= 560 ? 2 : 1);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: DemoData.recent.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: count,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
            mainAxisExtent: 112,
          ),
          itemBuilder: (context, index) =>
              RecentPlaybackCard(item: DemoData.recent[index]),
        );
      },
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
