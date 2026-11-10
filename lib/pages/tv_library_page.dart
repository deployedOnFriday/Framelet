import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/media_item.dart';
import '../widgets/tv_poster_grid.dart';

enum TvLibrarySort { defaultOrder, rating, year, title }

extension on TvLibrarySort {
  String get label => switch (this) {
    TvLibrarySort.defaultOrder => '默认排序',
    TvLibrarySort.rating => '评分最高',
    TvLibrarySort.year => '年份最新',
    TvLibrarySort.title => '标题 A-Z',
  };
}

/// 电视端分类页：大标题 + 大卡片海报墙，遥控器方向键浏览。
class TvLibraryPage extends StatefulWidget {
  const TvLibraryPage({
    required this.title,
    required this.items,
    required this.onSearch,
    super.key,
  });

  final String title;
  final List<MediaItem> items;
  final VoidCallback onSearch;

  @override
  State<TvLibraryPage> createState() => _TvLibraryPageState();
}

class _TvLibraryPageState extends State<TvLibraryPage>
    with AutomaticKeepAliveClientMixin {
  TvLibrarySort _sort = TvLibrarySort.defaultOrder;
  bool _onlyRated = false;

  @override
  bool get wantKeepAlive => true;

  bool get _filterActive => _sort != TvLibrarySort.defaultOrder || _onlyRated;

  List<MediaItem> get _visibleItems {
    final items = _onlyRated
        ? widget.items.where((item) => item.rating != null).toList()
        : [...widget.items];
    switch (_sort) {
      case TvLibrarySort.defaultOrder:
        break;
      case TvLibrarySort.rating:
        items.sort((a, b) => _ratingValue(b).compareTo(_ratingValue(a)));
        break;
      case TvLibrarySort.year:
        items.sort((a, b) => _yearValue(b).compareTo(_yearValue(a)));
        break;
      case TvLibrarySort.title:
        items.sort((a, b) => a.title.compareTo(b.title));
        break;
    }
    return items;
  }

  double _ratingValue(MediaItem item) =>
      double.tryParse(item.rating ?? '') ?? -1;

  int _yearValue(MediaItem item) => int.tryParse(item.year) ?? 0;

  Future<void> _openFilter() async {
    final result = await showDialog<({TvLibrarySort sort, bool onlyRated})>(
      context: context,
      builder: (context) =>
          _TvFilterDialog(initialSort: _sort, initialOnlyRated: _onlyRated),
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
          padding: const EdgeInsets.fromLTRB(40, 28, 32, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      key: const ValueKey('tv-library-title'),
                      style: const TextStyle(
                        fontSize: 44,
                        height: 1.1,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '共 ${widget.items.length} 个条目',
                      key: const ValueKey('tv-library-count'),
                      style: TextStyle(fontSize: 18, color: colors.muted),
                    ),
                  ],
                ),
              ),
              TvIconButton(
                key: const ValueKey('tv-search'),
                tooltip: '搜索',
                icon: Icons.search_rounded,
                onTap: widget.onSearch,
              ),
              const SizedBox(width: 12),
              TvIconButton(
                key: const ValueKey('tv-filter'),
                tooltip: '筛选',
                icon: Icons.filter_alt_outlined,
                badge: _filterActive,
                onTap: _openFilter,
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Expanded(
          child: items.isEmpty
              ? _EmptyLibrary(
                  filtered: widget.items.isNotEmpty && _filterActive,
                )
              : TvPosterGrid(items: items),
        ),
      ],
    );
  }
}

/// 电视端图标按钮：48dp 命中区 + 白色焦点框。
class TvIconButton extends StatefulWidget {
  const TvIconButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.badge = false,
    this.size = 52,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool badge;
  final double size;

  @override
  State<TvIconButton> createState() => _TvIconButtonState();
}

class _TvIconButtonState extends State<TvIconButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      message: widget.tooltip,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: _focused ? colors.primarySoft : colors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _focused ? colors.primary : colors.border,
            width: _focused ? 3 : 1,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            focusColor: Colors.transparent,
            onFocusChange: (value) {
              if (_focused != value) setState(() => _focused = value);
            },
            onTap: widget.onTap,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                Icon(widget.icon, size: widget.size * 0.5, color: colors.text),
                if (widget.badge)
                  Positioned(
                    right: 10,
                    top: 10,
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: colors.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: colors.surface, width: 1.5),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
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
        padding: const EdgeInsets.only(bottom: 80),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              filtered ? Icons.filter_alt_off_rounded : Icons.movie_outlined,
              size: 56,
              color: colors.iconMuted,
            ),
            const SizedBox(height: 18),
            Text(
              filtered ? '没有符合筛选条件的条目' : '这里还没有内容',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w600,
                color: colors.text,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              filtered ? '试试关闭「只看已评分」，或换一个排序方式。' : '去「设置 → 媒体源」添加并同步你的媒体库。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, height: 1.5, color: colors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _TvFilterDialog extends StatefulWidget {
  const _TvFilterDialog({
    required this.initialSort,
    required this.initialOnlyRated,
  });

  final TvLibrarySort initialSort;
  final bool initialOnlyRated;

  @override
  State<_TvFilterDialog> createState() => _TvFilterDialogState();
}

class _TvFilterDialogState extends State<_TvFilterDialog> {
  late TvLibrarySort _sort = widget.initialSort;
  late bool _onlyRated = widget.initialOnlyRated;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(36, 32, 36, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '筛选与排序',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  color: colors.text,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                '排序方式',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: colors.muted,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final sort in TvLibrarySort.values)
                    ChoiceChip(
                      label: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 6,
                        ),
                        child: Text(
                          sort.label,
                          style: const TextStyle(fontSize: 17),
                        ),
                      ),
                      selected: _sort == sort,
                      onSelected: (_) => setState(() => _sort = sort),
                      selectedColor: colors.primarySoft,
                      backgroundColor: colors.surface,
                      side: BorderSide(
                        color: _sort == sort
                            ? colors.primary.withValues(alpha: 0.3)
                            : colors.border,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              SwitchListTile.adaptive(
                value: _onlyRated,
                onChanged: (value) => setState(() => _onlyRated = value),
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '只看已评分',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                    color: colors.text,
                  ),
                ),
                subtitle: Text(
                  '隐藏还没有刮削到评分的条目',
                  style: TextStyle(fontSize: 15, color: colors.muted),
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  TextButton(
                    onPressed: () => setState(() {
                      _sort = TvLibrarySort.defaultOrder;
                      _onlyRated = false;
                    }),
                    child: const Text('重置', style: TextStyle(fontSize: 17)),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () =>
                        Navigator.of(context)
                            .pop((sort: _sort, onlyRated: _onlyRated)),
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.primary,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(150, 52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text('应用', style: TextStyle(fontSize: 17)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
