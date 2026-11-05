import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

class SideNavigation extends StatelessWidget {
  const SideNavigation({
    required this.selectedIndex,
    required this.onSelected,
    this.onSearch,
    this.searchActive = false,
    this.searchController,
    this.searchFocusNode,
    this.onSearchChanged,
    this.onCloseSearch,
    this.onSync,
    this.syncing = false,
    super.key,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// 点击顶部搜索入口（搜索面板由外层控制）。
  final VoidCallback? onSearch;

  /// 搜索面板是否展开，用于高亮入口。
  final bool searchActive;
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
  final ValueChanged<String>? onSearchChanged;
  final VoidCallback? onCloseSearch;
  final VoidCallback? onSync;
  final bool syncing;

  static const double width = 68;
  static const double expandedWidth = 320;

  static const items = <(String, IconData)>[
    ('首页', Icons.home_outlined),
    ('电影', Icons.movie_outlined),
    ('电视剧', Icons.tv_outlined),
    ('动漫', Icons.auto_awesome_outlined),
    ('综艺', Icons.star_outline_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final expanded = searchActive;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: expanded ? expandedWidth : width,
      color: context.colors.surface,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: expanded ? expandedWidth : width,
          maxWidth: expanded ? expandedWidth : width,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              expanded ? 14 : 8,
              20,
              expanded ? 14 : 8,
              18,
            ),
            child: Column(
              children: [
                if (expanded)
                  _buildSearchField(context)
                else
                  _NavigationTile(
                    key: const ValueKey('nav-search'),
                    label: '搜索',
                    icon: Icons.search_rounded,
                    selected: false,
                    accent: false,
                    onTap: onSearch ?? () {},
                  ),
                const SizedBox(height: 14),
                Divider(
                  color: context.colors.border,
                  height: 1,
                  indent: 10,
                  endIndent: 10,
                ),
                const SizedBox(height: 14),
                for (var i = 0; i < items.length; i++) ...[
                  _NavigationTile(
                    key: ValueKey(
                      'nav-${['home', 'movie', 'series', 'anime', 'variety'][i]}',
                    ),
                    label: items[i].$1,
                    icon: items[i].$2,
                    selected: selectedIndex == i,
                    expanded: expanded,
                    onTap: () => onSelected(i),
                  ),
                  const SizedBox(height: 6),
                ],
                const Spacer(),
                Divider(color: context.colors.border, height: 24),
                _NavigationTile(
                  key: const ValueKey('sidebar-sync'),
                  label: syncing ? '同步中' : '同步',
                  icon: Icons.sync_rounded,
                  selected: false,
                  accent: false,
                  expanded: expanded,
                  busy: syncing,
                  onTap: syncing ? () {} : onSync ?? () {},
                ),
                const SizedBox(height: 6),
                _NavigationTile(
                  key: const ValueKey('nav-settings'),
                  label: '设置',
                  icon: Icons.settings_outlined,
                  selected: selectedIndex == 5,
                  showLabel: expanded,
                  expanded: expanded,
                  onTap: () => onSelected(5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    final colors = context.colors;
    final hasText = searchController?.text.isNotEmpty ?? false;
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 44,
            child: TextField(
              key: const ValueKey('search-field'),
              controller: searchController,
              focusNode: searchFocusNode,
              autofocus: true,
              spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
              textInputAction: TextInputAction.search,
              onChanged: onSearchChanged,
              style: TextStyle(fontSize: 14, color: colors.text),
              decoration: InputDecoration(
                hintText: '搜索片名',
                hintStyle: TextStyle(color: colors.muted, fontSize: 13.5),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: 18,
                  color: colors.muted,
                ),
                suffixIcon: hasText
                    ? IconButton(
                        onPressed: () {
                          searchController?.clear();
                          onSearchChanged?.call('');
                          searchFocusNode?.requestFocus();
                        },
                        tooltip: '清空',
                        iconSize: 16,
                        color: colors.muted,
                        icon: const Icon(Icons.close_rounded),
                      )
                    : null,
                filled: true,
                fillColor: colors.background,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 11),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: colors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: colors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: colors.primary, width: 1.4),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          key: const ValueKey('search-close'),
          onPressed: onCloseSearch,
          tooltip: '关闭搜索 (Esc)',
          iconSize: 18,
          color: colors.muted,
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    );
  }
}

class _NavigationTile extends StatefulWidget {
  const _NavigationTile({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.showLabel = true,
    this.accent = true,
    this.expanded = false,
    this.busy = false,
    super.key,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final bool showLabel;
  final bool expanded;
  final bool busy;

  /// 选中时是否使用「当前页面」样式（蓝色底 + 左侧指示条）。
  /// 搜索这类动作入口不用页面样式，避免和导航项混淆。
  final bool accent;
  final VoidCallback onTap;

  @override
  State<_NavigationTile> createState() => _NavigationTileState();
}

class _NavigationTileState extends State<_NavigationTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final active = selected && widget.accent;
    final foreground = selected
        ? context.colors.primary
        : _hovered
        ? context.colors.iconHover
        : context.colors.iconMuted;

    return Tooltip(
      message: widget.label,
      waitDuration: const Duration(milliseconds: 450),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            width: widget.expanded ? double.infinity : 52,
            height: widget.showLabel || widget.expanded ? 48 : 44,
            decoration: BoxDecoration(
              color: active
                  ? context.colors.primarySoft
                  : _hovered
                  ? context.colors.hover
                  : selected
                  ? context.colors.hover
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: active
                    ? context.colors.primary.withValues(alpha: 0.16)
                    : Colors.transparent,
              ),
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: context.colors.primary.withValues(alpha: 0.07),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Stack(
              children: [
                if (active)
                  Positioned(
                    left: 0,
                    top: 18,
                    child: Container(
                      width: 3,
                      height: 16,
                      decoration: BoxDecoration(
                        color: context.colors.primary,
                        borderRadius: const BorderRadius.horizontal(
                          right: Radius.circular(3),
                        ),
                      ),
                    ),
                  ),
                Center(
                  child: widget.expanded
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 13),
                          child: Row(
                            children: [
                              widget.busy
                                  ? SizedBox(
                                      width: 17,
                                      height: 17,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: foreground,
                                      ),
                                    )
                                  : Icon(
                                      widget.icon,
                                      size: 19,
                                      color: foreground,
                                    ),
                              const SizedBox(width: 12),
                              Text(
                                widget.label,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: foreground,
                                ),
                              ),
                            ],
                          ),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            widget.busy
                                ? SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: foreground,
                                    ),
                                  )
                                : Icon(
                                    widget.icon,
                                    size: 20,
                                    color: foreground,
                                  ),
                            if (widget.showLabel) ...[
                              const SizedBox(height: 3),
                              Text(
                                widget.label,
                                maxLines: 1,
                                style: TextStyle(
                                  fontSize: 10,
                                  height: 1,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: foreground,
                                ),
                              ),
                            ],
                          ],
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
