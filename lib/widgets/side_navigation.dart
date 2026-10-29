import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import 'brand_logo.dart';

class SideNavigation extends StatelessWidget {
  const SideNavigation({
    required this.selectedIndex,
    required this.onSelected,
    super.key,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const items = <(String, IconData, IconData)>[
    ('首页', Icons.home_outlined, Icons.home_rounded),
    ('电影', Icons.movie_outlined, Icons.movie_rounded),
    ('电视剧', Icons.tv_outlined, Icons.tv_rounded),
    ('动漫', Icons.auto_awesome_outlined, Icons.auto_awesome_rounded),
    ('综艺', Icons.star_outline_rounded, Icons.star_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 216,
      color: AppColors.sidebar,
      padding: const EdgeInsets.fromLTRB(22, 28, 22, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(padding: EdgeInsets.only(left: 4), child: BrandLogo()),
          const SizedBox(height: 38),
          for (var i = 0; i < items.length; i++) ...[
            _NavigationTile(
              key: ValueKey(
                'nav-${['home', 'movie', 'series', 'anime', 'variety'][i]}',
              ),
              label: items[i].$1,
              icon: items[i].$2,
              selectedIcon: items[i].$3,
              selected: selectedIndex == i,
              onTap: () => onSelected(i),
            ),
            const SizedBox(height: 8),
          ],
          const Spacer(),
          const Divider(color: AppColors.border, height: 24),
          _NavigationTile(
            key: const ValueKey('nav-settings'),
            label: '设置',
            icon: Icons.settings_outlined,
            selectedIcon: Icons.settings_rounded,
            selected: selectedIndex == 5,
            onTap: () => onSelected(5),
          ),
        ],
      ),
    );
  }
}

class _NavigationTile extends StatelessWidget {
  const _NavigationTile({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.primarySoft : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Icon(
                selected ? selectedIcon : icon,
                size: 22,
                color: selected ? AppColors.primary : AppColors.muted,
              ),
              const SizedBox(width: 14),
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? AppColors.primary : AppColors.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
