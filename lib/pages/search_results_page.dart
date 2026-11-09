import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../services/media_search.dart';
import '../widgets/poster_grid.dart';

/// 搜索结果区：只占用右侧内容区域，搜索输入仍在展开的左侧栏里。
class SearchResultsPage extends StatelessWidget {
  const SearchResultsPage({required this.query, super.key});

  final String query;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final results = searchMediaItems(query);
    return Material(
      color: colors.background,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(30, 24, 30, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('搜索结果', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: colors.primarySoft,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    '${results.length}',
                    style: TextStyle(
                      color: colors.primary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  '“${query.trim()}”',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.muted, fontSize: 12.5),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Expanded(
              child: results.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.search_off_rounded,
                            size: 30,
                            color: colors.iconMuted,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '没有找到「${query.trim()}」',
                            style: TextStyle(
                              color: colors.text,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '试试更短的关键词，或先在设置里同步媒体库。',
                            style: TextStyle(
                              color: colors.muted,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    )
                  : PosterGrid(
                      key: const ValueKey('search-results-grid'),
                      items: results,
                      targetColumnWidth: 168,
                      maxColumns: 8,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 24,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
