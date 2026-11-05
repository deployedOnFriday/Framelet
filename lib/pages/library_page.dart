import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../widgets/poster_grid.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({required this.title, required this.items, super.key});

  final String title;
  final List<MediaItem> items;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final items = widget.items;

    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 28, 30, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, style: Theme.of(context).textTheme.headlineLarge),
          const SizedBox(height: 6),
          Text(
            '共 ${items.length} 个条目',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      '这里还没有内容，去「设置 → 媒体源」添加并同步你的媒体库',
                      textAlign: TextAlign.center,
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) => PosterGrid(
                      items: items,
                      targetColumnWidth: 168,
                      maxColumns: 7,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 24,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
