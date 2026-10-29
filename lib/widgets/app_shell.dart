import 'package:flutter/material.dart';

import '../data/demo_data.dart';
import '../pages/home_page.dart';
import '../pages/library_page.dart';
import '../pages/settings_page.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
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
                const LibraryPage(title: '电影', items: DemoData.movies),
                const LibraryPage(title: '电视剧', items: DemoData.series),
                const LibraryPage(title: '动漫', items: DemoData.anime),
                const LibraryPage(title: '综艺', items: DemoData.variety),
                const SettingsPage(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
