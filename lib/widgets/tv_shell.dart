import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../models/media_source.dart';
import '../pages/settings_page.dart';
import '../pages/tv_home_page.dart';
import '../pages/tv_library_page.dart';
import '../pages/tv_search_page.dart';
import '../services/media_library.dart';
import 'tv_navigation_rail.dart';

/// Android TV 专用外壳：左侧常驻导航 + 10 尺内容区。
class TvShell extends StatefulWidget {
  const TvShell({super.key});

  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> {
  int _selectedIndex = 0;
  final _pageController = PageController();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _select(int index) {
    if (index == _selectedIndex) return;
    setState(() => _selectedIndex = index);
    if (_pageController.hasClients) _pageController.jumpToPage(index);
  }

  void _openSearch() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const TvSearchPage()));
  }

  List<MediaItem> _itemsFor(MediaKind kind) {
    final scanned = MediaLibrary.instance.byKind(kind);
    return [for (final video in scanned) ?toMediaItem(video)];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          TvNavigationRail(
            selectedIndex: _selectedIndex,
            onSelected: _select,
            onSearch: _openSearch,
          ),
          Expanded(
            child: AnimatedBuilder(
              animation: MediaLibrary.instance,
              builder: (context, _) => PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  TvHomePage(
                    onOpenLibrary: _select,
                    onOpenSettings: () => _select(5),
                  ),
                  TvLibraryPage(
                    title: '电影',
                    items: _itemsFor(MediaKind.movie),
                    onSearch: _openSearch,
                  ),
                  TvLibraryPage(
                    title: '电视剧',
                    items: _itemsFor(MediaKind.series),
                    onSearch: _openSearch,
                  ),
                  TvLibraryPage(
                    title: '动漫',
                    items: _itemsFor(MediaKind.anime),
                    onSearch: _openSearch,
                  ),
                  TvLibraryPage(
                    title: '综艺',
                    items: _itemsFor(MediaKind.variety),
                    onSearch: _openSearch,
                  ),
                  const SettingsPage(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
