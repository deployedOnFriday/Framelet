import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../models/media_source.dart';
import '../pages/detail_page.dart';
import 'media_artwork.dart';

class PosterCard extends StatelessWidget {
  const PosterCard({required this.item, this.width = 148, super.key});

  final MediaItem item;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: () => _openDetail(context),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: MediaArtwork(item: item, showQuality: true)),
              const SizedBox(height: 10),
              Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                '${item.year} · ${item.subtitle}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openDetail(BuildContext context) {
    final payload = item.payload;
    if (payload is ScannedVideo) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => DetailPage(video: payload)),
      );
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('「${item.title}」是演示内容，去设置里添加你的媒体源吧')),
      );
  }
}
