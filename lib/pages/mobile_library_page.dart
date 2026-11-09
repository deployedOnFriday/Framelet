import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/media_item.dart';
import '../widgets/mobile_poster_grid.dart';

enum _LibrarySort { defaultOrder, rating, year, title }

extension on _LibrarySort {
  String get label => switch (this) {
    _LibrarySort.defaultOrder => '默认排序',
    _LibrarySort.rating => '评分最高',
    _LibrarySort.year => '年份最新',
    _LibrarySort.title => '标题 A-Z',
  };
}

/// 手机端媒体分类页：顶部大标题 + 搜索/筛选，双列海报墙。
class MobileLibraryPage extends StatefulWidget {
  const MobileLibraryPage({
    required this.title,
    required this.items,
    required this.onSearch,
    super.key,
  });

  final String title;
  final List<MediaItem> items;
  final VoidCallback onSearch;

  @override
  State<MobileLibraryPage> createState() => _MobileLibraryPageState();
}

class _MobileLibraryPageState extends State<MobileLibraryPage>
    with AutomaticKeepAliveClientMixin {
  _LibrarySort _sort = _LibrarySort.defaultOrder;
  bool _onlyRated = false;

  @override
  bool get wantKeepAlive => true;

  bool get _filterActive => _sort != _LibrarySort.defaultOrder || _onlyRated;

  List<MediaItem> get _visibleItems {
    final items = _onlyRated
        ? widget.items.where((item) => item.rating != null).toList()
        : [...widget.items];
    switch (_sort) {
      case _LibrarySort.defaultOrder:
        break;
      case _LibrarySort.rating:
        items.sort((a, b) => _ratingValue(b).compareTo(_ratingValue(a)));
        break;
      case _LibrarySort.year:
        items.sort((a, b) => _yearValue(b).compareTo(_yearValue(a)));
        break;
      case _LibrarySort.title:
        items.sort((a, b) => a.title.compareTo(b.title));
        break;
    }
    return items;
  }

  double _ratingValue(MediaItem item) =>
      double.tryParse(item.rating ?? '') ?? -1;

  int _yearValue(MediaItem item) => int.tryParse(item.year) ?? 0;

  Future<void> _openFilter() async {
    final result =
        await showModalBottomSheet<({_LibrarySort sort, bool onlyRated})>(
          context: context,
          backgroundColor: context.colors.surface,
          isScrollControlled: true,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          builder: (context) =>
              _FilterSheet(initialSort: _sort, initialOnlyRated: _onlyRated),
        );
    if (result == null || !mounted) return;
    setState(() {
      _sort = result.sort;
      _onlyRated = result.onlyRated;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colors = context.colors;
    final items = _visibleItems;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      key: const ValueKey('mobile-library-title'),
                      style: const TextStyle(
                        fontSize: 30,
                        height: 1.15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.6,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      '共 ${widget.items.length} 个条目',
                      key: const ValueKey('mobile-library-count'),
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.2,
                        color: colors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              _HeaderIconButton(
                key: const ValueKey('mobile-search'),
                tooltip: '搜索',
                icon: Icons.search_rounded,
                onTap: widget.onSearch,
              ),
              const SizedBox(width: 2),
              _HeaderIconButton(
                key: const ValueKey('mobile-filter'),
                tooltip: '筛选',
                icon: Icons.filter_alt_outlined,
                badge: _filterActive,
                onTap: _openFilter,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: items.isEmpty
              ? _EmptyLibrary(
                  filtered: widget.items.isNotEmpty && _filterActive,
                )
              : MobilePosterGrid(items: items),
        ),
      ],
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.badge = false,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool badge;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      iconSize: 24,
      color: colors.text,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 42, height: 42),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(icon),
          if (badge)
            Positioned(
              right: -1,
              top: 1,
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: colors.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.background, width: 1.4),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.filtered});

  final bool filtered;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 60),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              filtered ? Icons.filter_alt_off_rounded : Icons.movie_outlined,
              size: 34,
              color: colors.iconMuted,
            ),
            const SizedBox(height: 12),
            Text(
              filtered ? '没有符合筛选条件的条目' : '这里还没有内容',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: colors.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              filtered ? '试试关闭「只看已评分」，或换一个排序方式。' : '去「设置 → 媒体源」添加并同步你的媒体库。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: colors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({
    required this.initialSort,
    required this.initialOnlyRated,
  });

  final _LibrarySort initialSort;
  final bool initialOnlyRated;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late _LibrarySort _sort = widget.initialSort;
  late bool _onlyRated = widget.initialOnlyRated;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '筛选与排序',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: colors.text,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              '排序方式',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colors.muted,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final sort in _LibrarySort.values)
                  ChoiceChip(
                    label: Text(sort.label),
                    selected: _sort == sort,
                    onSelected: (_) => setState(() => _sort = sort),
                    selectedColor: colors.primarySoft,
                    backgroundColor: colors.surface,
                    side: BorderSide(
                      color: _sort == sort
                          ? colors.primary.withValues(alpha: 0.3)
                          : colors.border,
                    ),
                    labelStyle: TextStyle(
                      fontSize: 13,
                      color: _sort == sort ? colors.primary : colors.muted,
                      fontWeight: _sort == sort
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            SwitchListTile.adaptive(
              value: _onlyRated,
              onChanged: (value) => setState(() => _onlyRated = value),
              contentPadding: EdgeInsets.zero,
              activeThumbColor: colors.primary,
              title: Text(
                '只看已评分',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: colors.text,
                ),
              ),
              subtitle: Text(
                '隐藏还没有刮削到评分的条目',
                style: TextStyle(fontSize: 12, color: colors.muted),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    _sort = _LibrarySort.defaultOrder;
                    _onlyRated = false;
                  }),
                  child: const Text('重置'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(context)
                          .pop((sort: _sort, onlyRated: _onlyRated)),
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(132, 44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('应用'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
