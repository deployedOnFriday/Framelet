import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key});

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        SizedBox(
          width: 46,
          height: 46,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                Icons.movie_filter_rounded,
                size: 44,
                color: AppColors.primary,
              ),
              Icon(
                Icons.play_arrow_rounded,
                size: 22,
                color: AppColors.surface,
              ),
            ],
          ),
        ),
        SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '拾帧',
              style: TextStyle(
                fontSize: 26,
                height: 1.15,
                fontWeight: FontWeight.w700,
                letterSpacing: 3,
                color: AppColors.primary,
              ),
            ),
            SizedBox(height: 3),
            Text(
              'Framelet',
              style: TextStyle(
                fontSize: 13,
                letterSpacing: 0.6,
                color: AppColors.primary,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
