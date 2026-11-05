import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/media_item.dart';
import 'media_artwork.dart';

class RecentPlaybackCard extends StatefulWidget {
  const RecentPlaybackCard({
    required this.item,
    this.onTap,
    this.onDelete,
    super.key,
  });

  final MediaItem item;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  State<RecentPlaybackCard> createState() => _RecentPlaybackCardState();
}

class _RecentPlaybackCardState extends State<RecentPlaybackCard> {
  bool _hovered = false;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return GestureDetector(
      onSecondaryTapDown: widget.onDelete == null
          ? null
          : (details) => _showContextMenu(context, details.globalPosition),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          transform: Matrix4.translationValues(0, _hovered ? -1 : 0, 0),
          decoration: BoxDecoration(
            color: context.colors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _hovered
                  ? context.colors.primary.withValues(alpha: 0.4)
                  : context.colors.border,
            ),
            boxShadow: [
              BoxShadow(
                color: _hovered
                    ? context.colors.primary.withValues(alpha: 0.12)
                    : Colors.black.withValues(alpha: _isDark ? 0.3 : 0.05),
                blurRadius: _hovered ? 25 : 12,
                offset: Offset(0, _hovered ? 8 : 2),
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
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    _buildThumbnail(item),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    height: 1.2,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.1,
                                    color: _hovered
                                        ? context.colors.primary
                                        : context.colors.text,
                                  ),
                                ),
                              ),
                              if (item.episodeLabel != null) ...[
                                const SizedBox(width: 5),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: context.colors.primarySoft,
                                    borderRadius: BorderRadius.circular(5),
                                    border: Border.all(
                                      color: context.colors.primary.withValues(
                                        alpha: 0.16,
                                      ),
                                    ),
                                  ),
                                  child: Text(
                                    item.episodeLabel!,
                                    style: TextStyle(
                                      color: context.colors.primary,
                                      fontSize: 10,
                                      height: 1.15,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 5),
                          Text(
                            item.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.2,
                              fontWeight: FontWeight.w500,
                              color: context.colors.muted,
                            ),
                          ),
                          const SizedBox(height: 9),
                          _buildProgress(item.progress),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail(MediaItem item) {
    return Container(
      width: 120,
      height: 68,
      decoration: BoxDecoration(
        color: context.colors.hover,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: context.colors.border.withValues(alpha: 0.8),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: MediaArtwork(item: item, borderRadius: 10),
      ),
    );
  }

  Widget _buildProgress(double progress) {
    return SizedBox(
      height: 6,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: context.colors.hover),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: progress.clamp(0, 1),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [context.colors.primary, const Color(0xFF6366F1)],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showContextMenu(
    BuildContext context,
    Offset globalPosition,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;

    final selection = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(globalPosition, globalPosition),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.remove_circle_outline_rounded, size: 18),
              SizedBox(width: 10),
              Text('从最近播放移除'),
            ],
          ),
        ),
      ],
    );
    if (selection == 'delete') widget.onDelete?.call();
  }
}
