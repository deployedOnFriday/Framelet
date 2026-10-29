import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/media_item.dart';
import '../widgets/poster_card.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({required this.title, required this.items, super.key});

  final String title;
  final List<MediaItem> items;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final items = widget.items
        .where(
          (item) => item.title.toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();

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
          SizedBox(
            width: 420,
            height: 44,
            child: TextField(
              onChanged: (value) => setState(() => _query = value.trim()),
              decoration: InputDecoration(
                hintText: '筛选${widget.title}',
                prefixIcon: const Icon(Icons.search_rounded, size: 21),
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      widget.items.isEmpty
                          ? '这里还没有内容，去「设置 → 媒体源」添加并同步你的媒体库'
                          : '没有找到匹配的内容',
                      textAlign: TextAlign.center,
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final count = (constraints.maxWidth / 170).floor().clamp(
                        2,
                        8,
                      );
                      return GridView.builder(
                        itemCount: items.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: count,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 18,
                          mainAxisExtent: 258,
                        ),
                        itemBuilder: (context, index) =>
                            PosterCard(item: items[index]),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
