import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// 手机端底部 5 个常驻 Tab，自动避让底部安全区。
class MobileBottomNavigation extends StatelessWidget {
  const MobileBottomNavigation({
    required this.selectedPage,
    required this.onSelected,
    super.key,
  });

  final int selectedPage;
  final ValueChanged<int> onSelected;

  static const tabs =
      <({String label, IconData icon, IconData activeIcon, int page})>[
        (
          label: '首页',
          icon: Icons.home_outlined,
          activeIcon: Icons.home_rounded,
          page: 0,
        ),
        (
          label: '电影',
          icon: Icons.movie_outlined,
          activeIcon: Icons.movie_rounded,
          page: 1,
        ),
        (
          label: '电视剧',
          icon: Icons.tv_outlined,
          activeIcon: Icons.tv_rounded,
          page: 2,
        ),
        (
          label: '动漫',
          icon: Icons.auto_awesome_outlined,
          activeIcon: Icons.auto_awesome_rounded,
          page: 3,
        ),
        (
          label: '我的/设置',
          icon: Icons.person_outline_rounded,
          activeIcon: Icons.person_rounded,
          page: 5,
        ),
      ];

  static const _keys = [
    'mobile-nav-home',
    'mobile-nav-movie',
    'mobile-nav-series',
    'mobile-nav-anime',
    'mobile-nav-settings',
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 4),
        child: SizedBox(
          height: 62,
          child: Row(
            children: [
              for (var i = 0; i < tabs.length; i++)
                Expanded(
                  child: _BottomTab(
                    key: ValueKey(_keys[i]),
                    label: tabs[i].label,
                    icon: tabs[i].icon,
                    activeIcon: tabs[i].activeIcon,
                    selected: selectedPage == tabs[i].page,
                    onTap: () => onSelected(tabs[i].page),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomTab extends StatelessWidget {
  const _BottomTab({
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final foreground = selected ? colors.primary : colors.iconMuted;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkResponse(
        onTap: onTap,
        radius: 38,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              width: 40,
              height: 27,
              decoration: BoxDecoration(
                color: selected ? colors.primarySoft : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                selected ? activeIcon : icon,
                size: 22,
                color: foreground,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontSize: 10.5,
                height: 1,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: foreground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
