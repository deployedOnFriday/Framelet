import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/media_item.dart';
import 'media_artwork.dart';

class RecentPlaybackCard extends StatefulWidget {
  const RecentPlaybackCard({required this.item, this.onTap, super.key});

  final MediaItem item;
  final VoidCallback? onTap;

  @override
  State<RecentPlaybackCard> createState() => _RecentPlaybackCardState();
}

class _RecentPlaybackCardState extends State<RecentPlaybackCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: _hovered ? Colors.white : AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _hovered
                ? AppColors.primary.withValues(alpha: 0.25)
                : AppColors.border,
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.text.withValues(alpha: _hovered ? 0.08 : 0.025),
              blurRadius: _hovered ? 16 : 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap:
                widget.onTap ??
                () {
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      SnackBar(content: Text('继续观看「${item.title}」')),
                    );
                },
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  SizedBox(
                    width: 126,
                    height: 90,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        MediaArtwork(item: item, borderRadius: 10),
                        if (_hovered)
                          const Center(
                            child: CircleAvatar(
                              radius: 20,
                              backgroundColor: Colors.black54,
                              child: Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          item.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 16),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: item.progress,
                            minHeight: 4,
                            color: AppColors.accent,
                            backgroundColor: AppColors.border,
                          ),
                        ),
                      ],
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
