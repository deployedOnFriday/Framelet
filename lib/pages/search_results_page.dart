import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/media_item.dart';
import '../models/media_source.dart';
import '../services/media_library.dart';
import '../widgets/poster_card.dart';

/// 全库搜索结果页。
class SearchResultsPage extends StatelessWidget {
  const SearchResultsPage({required this.query, super.key});

  final String query;

  @override
  Widget build(BuildContext context) {
    final library = MediaLibrary.instance;
    final keyword = query.toLowerCase();
    final results = <MediaItem>[
      for (final kind in MediaKind.values)
        for (final video in MediaLibrary.aggregate(library.byKind(kind)))
          if (video.title.toLowerCase().contains(keyword)) ?toMediaItem(video),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 28, 30, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('搜索「$query」', style: Theme.of(context).textTheme.headlineLarge),
          const SizedBox(height: 6),
          Text(
            '找到 ${results.length} 个条目',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 22),
          Expanded(
            child: results.isEmpty
                ? Center(
                    child: Text(
                      '没有找到「$query」\n试试更短的关键词，或先在设置里同步媒体库',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.muted),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final count = (constraints.maxWidth / 170).floor().clamp(
                        2,
                        8,
                      );
                      return GridView.builder(
                        itemCount: results.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: count,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 18,
                          mainAxisExtent: 258,
                        ),
                        itemBuilder: (context, index) =>
                            PosterCard(item: results[index]),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
