import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

class SectionHeader extends StatelessWidget {
  const SectionHeader({required this.title, this.onViewAll, super.key});

  final String title;
  final VoidCallback? onViewAll;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const Spacer(),
        if (onViewAll != null)
          TextButton.icon(
            onPressed: onViewAll,
            iconAlignment: IconAlignment.end,
            icon: const Icon(Icons.arrow_forward_rounded, size: 16),
            label: const Text('查看全部'),
            style: TextButton.styleFrom(foregroundColor: AppColors.muted),
          ),
      ],
    );
  }
}
