import 'package:flutter/material.dart';

import '../data/demo_data.dart';
import '../models/media_item.dart';
import '../models/media_source.dart';
import '../pages/home_page.dart';
import '../pages/library_page.dart';
import '../pages/settings_page.dart';
import '../services/media_library.dart';
import 'side_navigation.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;

  void _openLibrary(int index) {
    setState(() => _selectedIndex = index);
  }

  /// 真实扫描数据优先；媒体库为空时回退演示数据。
  List<MediaItem> _itemsFor(MediaKind kind, List<MediaItem> fallback) {
    final library = MediaLibrary.instance;
    final scanned = MediaLibrary.aggregate(library.byKind(kind));
    if (scanned.isEmpty) return fallback;
    return [for (final video in scanned) ?toMediaItem(video)];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: MediaLibrary.instance,
        builder: (context, _) => Row(
          children: [
            SideNavigation(
              selectedIndex: _selectedIndex,
              onSelected: (index) => setState(() => _selectedIndex = index),
            ),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(
              child: IndexedStack(
                index: _selectedIndex,
                children: [
                  HomePage(onOpenLibrary: _openLibrary),
                  LibraryPage(
                    title: '电影',
                    items: _itemsFor(MediaKind.movie, DemoData.movies),
                  ),
                  LibraryPage(
                    title: '电视剧',
                    items: _itemsFor(MediaKind.series, DemoData.series),
                  ),
                  LibraryPage(
                    title: '动漫',
                    items: _itemsFor(MediaKind.anime, DemoData.anime),
                  ),
                  LibraryPage(
                    title: '综艺',
                    items: _itemsFor(MediaKind.variety, DemoData.variety),
                  ),
                  const SettingsPage(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
