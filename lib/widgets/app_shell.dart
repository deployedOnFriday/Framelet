import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/app_theme.dart';
import '../core/utils/phone_layout.dart';
import '../models/media_item.dart';
import '../models/media_source.dart';
import '../pages/home_page.dart';
import '../pages/library_page.dart';
import '../pages/mobile_library_page.dart';
import '../pages/mobile_search_page.dart';
import '../pages/search_results_page.dart';
import '../pages/settings_page.dart';
import '../services/media_library.dart';
import '../services/perf_diagnostics.dart';
import 'mobile_bottom_navigation.dart';
import 'side_navigation.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell>
    with SingleTickerProviderStateMixin {
  int _selectedIndex = 0;

  late final AnimationController _fadeController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );

  late final Animation<double> _fade = CurvedAnimation(
    parent: _fadeController,
    curve: Curves.easeOut,
  );

  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _searchOpen = ValueNotifier<bool>(false);
  final _searchQuery = ValueNotifier<String>('');
  final _pageController = PageController();
  bool _syncing = false;

  @override
  void dispose() {
    _fadeController.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _searchOpen.dispose();
    _searchQuery.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _select(int index) {
    final changed = index != _selectedIndex;
    _resetSearch();
    setState(() => _selectedIndex = index);
    if (_pageController.hasClients) {
      _pageController.jumpToPage(index);
    }
    if (changed) _fadeController.forward(from: 0);
  }

  void _openLibrary(int index) => _select(index);

  /// 左侧栏展开为搜索输入框，右侧内容区显示结果。
  // TEMP-SCREENSHOT
  @override
  void initState() {
    super.initState();
    if (const String.fromEnvironment('FRAMELET_OPEN_SEARCH') == '1') {
      _searchOpen.value = true;
    }
  }

  void _openSearch() {
    _searchOpen.value = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searchOpen.value) _searchFocus.requestFocus();
    });
  }

  void _openMobileSearch() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const MobileSearchPage()));
  }

  void _closeSearch() {
    if (!_searchOpen.value) return;
    _resetSearch();
  }

  void _resetSearch() {
    _searchOpen.value = false;
    _searchQuery.value = '';
    _searchController.clear();
    _searchFocus.unfocus();
  }

  void _onSearchChanged(String value) {
    _searchQuery.value = value;
    _searchOpen.value = true;
  }

  Future<void> _syncNow() async {
    if (_syncing) return;
    final library = MediaLibrary.instance;
    if (library.sources.isEmpty) {
      _showMessage('还没有媒体源，请先在设置中添加');
      return;
    }
    setState(() => _syncing = true);
    try {
      final count = await library.syncAll();
      if (!mounted) return;
      if (count > 0) {
        _showMessage(
          '媒体库已同步 · 共 ${library.sources.length} 个媒体源、'
          '${_totalVideoCount(library)} 个视频文件',
        );
      } else {
        _showMessage('同步未成功，请在设置中检查媒体源配置');
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  int _totalVideoCount(MediaLibrary library) {
    var total = 0;
    for (final kind in MediaKind.values) {
      for (final video in library.byKind(kind)) {
        total += video.episodeCount;
      }
    }
    return total;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// F4：把最近帧时间统计写入 %TEMP%\framelet_perf.log 并提示。
  void _dumpPerf() {
    final report = PerfDiagnostics.instance.dump();
    debugPrint('[Perf]\n$report');
    if (!mounted) return;
    final lines = report.split('\n');
    _showMessage(
      lines.isEmpty || report == '无帧数据'
          ? '没有帧数据，先滚动几秒再按 F4'
          : '帧统计已记录：${lines.first}（详见 %TEMP%\\framelet_perf.log）',
    );
  }

  List<MediaItem> _itemsFor(MediaKind kind) {
    final scanned = MediaLibrary.instance.byKind(kind);
    return [for (final video in scanned) ?toMediaItem(video)];
  }

  @override
  Widget build(BuildContext context) {
    final phone = isPhoneLayout(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): phone
            ? _openMobileSearch
            : _openSearch,
        const SingleActivator(LogicalKeyboardKey.escape): _closeSearch,
        // 性能诊断：F3 切换叠加层，F4 落盘最近帧时间统计
        const SingleActivator(LogicalKeyboardKey.f3):
            PerfDiagnostics.instance.toggleOverlay,
        const SingleActivator(LogicalKeyboardKey.f4): _dumpPerf,
      },
      child: Focus(
        autofocus: true,
        child: AnimatedBuilder(
          animation: MediaLibrary.instance,
          builder: (context, _) =>
              phone ? _buildPhoneLayout(context) : _buildDesktopLayout(context),
        ),
      ),
    );
  }

  Widget _buildDesktopLayout(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // 只让侧栏自己响应搜索状态，避免每次展开/输入都重建整个页面区。
          ValueListenableBuilder<bool>(
            valueListenable: _searchOpen,
            builder: (context, searchActive, _) => SideNavigation(
              selectedIndex: _selectedIndex,
              onSelected: _select,
              onSearch: _openSearch,
              searchActive: searchActive,
              searchController: _searchController,
              searchFocusNode: _searchFocus,
              onSearchChanged: _onSearchChanged,
              onCloseSearch: _closeSearch,
              onSync: _syncNow,
              syncing: _syncing,
            ),
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: Stack(
              children: [
                _buildPageView(phone: false),
                Positioned.fill(
                  child: ValueListenableBuilder<String>(
                    valueListenable: _searchQuery,
                    builder: (context, query, _) {
                      if (!_searchOpen.value || query.trim().isEmpty) {
                        return const SizedBox.shrink();
                      }
                      return SearchResultsPage(query: query);
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhoneLayout(BuildContext context) {
    final colors = context.colors;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: colors.surface,
        systemNavigationBarIconBrightness: dark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Expanded(child: _buildPageView(phone: true)),
              MobileBottomNavigation(
                selectedPage: _selectedIndex,
                onSelected: _select,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPageView({required bool phone}) {
    Widget category(String title, MediaKind kind) {
      final items = _itemsFor(kind);
      if (phone) {
        return MobileLibraryPage(
          title: title,
          items: items,
          onSearch: _openMobileSearch,
        );
      }
      return LibraryPage(title: title, items: items);
    }

    return FadeTransition(
      opacity: _fade,
      child: PageView(
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          HomePage(
            onOpenLibrary: _openLibrary,
            onOpenSettings: () => _select(5),
          ),
          category('电影', MediaKind.movie),
          category('电视剧', MediaKind.series),
          category('动漫', MediaKind.anime),
          category('综艺', MediaKind.variety),
          const SettingsPage(),
        ],
      ),
    );
  }
}
