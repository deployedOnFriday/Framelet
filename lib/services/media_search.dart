import '../models/media_item.dart';
import '../models/media_source.dart';
import 'media_library.dart';

/// 全媒体库片名搜索，供桌面搜索面板与手机搜索页共用。
List<MediaItem> searchMediaItems(String query) {
  final keyword = query.trim().toLowerCase();
  if (keyword.isEmpty) return const [];
  final library = MediaLibrary.instance;
  final results = <MediaItem>[];
  for (final kind in MediaKind.values) {
    for (final video in library.byKind(kind)) {
      if (!video.title.toLowerCase().contains(keyword)) continue;
      final item = toMediaItem(video);
      if (item != null) results.add(item);
    }
  }
  return results;
}
