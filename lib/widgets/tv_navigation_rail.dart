import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import 'brand_logo.dart';

/// 电视端左侧导航：大号图标 + 文字，遥控器方向键切换焦点。
class TvNavigationRail extends StatelessWidget {
  const TvNavigationRail({
    required this.selectedIndex,
    required this.onSelected,
    required this.onSearch,
    super.key,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final VoidCallback onSearch;

  static const double width = 236;

  static const items = <(String, IconData)>[
    ('首页', Icons.home_rounded),
    ('电影', Icons.movie_rounded),
    ('电视剧', Icons.tv_rounded),
    ('动漫', Icons.auto_awesome_rounded),
    ('综艺', Icons.emoji_events_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(right: BorderSide(color: colors.border)),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 26, 16, 22),
              child: Row(
                children: [
                  const BrandLogo(size: 34),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '拾帧',
                        style: TextStyle(
                          fontSize: 19,
                          height: 1.1,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.4,
                          color: colors.text,
                        ),
                      ),
                      Text(
                        'Framelet',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.1,
                          color: colors.muted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            _TvRailTile(
              key: const ValueKey('tv-nav-search'),
              label: '搜索',
              icon: Icons.search_rounded,
              selected: false,
              onTap: onSearch,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
              child: Divider(height: 1, color: colors.border),
            ),
            for (var i = 0; i < items.length; i++)
              _TvRailTile(
                key: ValueKey(
                  'tv-nav-${['home', 'movie', 'series', 'anime', 'variety'][i]}',
                ),
                label: items[i].$1,
                icon: items[i].$2,
                selected: selectedIndex == i,
                autofocus: i == 0,
                onTap: () => onSelected(i),
              ),
            const Spacer(),
            _TvRailTile(
              key: const ValueKey('tv-nav-settings'),
              label: '设置',
              icon: Icons.settings_rounded,
              selected: selectedIndex == 5,
              onTap: () => onSelected(5),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

class _TvRailTile extends StatefulWidget {
  const _TvRailTile({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.autofocus = false,
    super.key,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  State<_TvRailTile> createState() => _TvRailTileState();
}

class _TvRailTileState extends State<_TvRailTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final active = widget.selected;
    final Color foreground;
    if (_focused) {
      foreground = colors.text;
    } else if (active) {
      foreground = colors.primary;
    } else {
      foreground = colors.muted;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 3, 14, 3),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: _focused
              ? colors.primarySoft
              : (active ? colors.primarySoft.withValues(alpha: 0.55) : null),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _focused ? colors.primary : Colors.transparent,
            width: 2.5,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            autofocus: widget.autofocus,
            borderRadius: BorderRadius.circular(12),
            focusColor: Colors.transparent,
            onFocusChange: (value) {
              if (_focused != value) setState(() => _focused = value);
            },
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
              child: Row(
                children: [
                  Icon(
                    widget.icon,
                    size: 25,
                    color: _focused ? colors.primary : foreground,
                  ),
                  const SizedBox(width: 14),
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: active || _focused
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: foreground,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
