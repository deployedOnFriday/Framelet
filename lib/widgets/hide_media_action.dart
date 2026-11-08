import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/media_source.dart';
import '../services/media_library.dart';

/// 海报卡与详情页共用的右键菜单：目前提供「隐藏该影片」。
///
/// 隐藏按整张海报卡生效（同一 TMDB 条目 / 同一部剧的所有聚合条目一起
/// 隐藏），因此重扫后不会因为重新聚类又把卡片刷回来。
Future<bool> showMediaContextMenu({
  required BuildContext context,
  required Offset globalPosition,
  required ScannedVideo video,
  String? displayName,
  bool popOnHidden = false,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject();
  if (overlay is! RenderBox) return false;
  final action = await showMenu<String>(
    context: context,
    color: Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF1F1F1F)
        : Colors.white,
    position: RelativeRect.fromRect(
      Rect.fromPoints(globalPosition, globalPosition),
      Offset.zero & overlay.size,
    ),
    items: [
      PopupMenuItem<String>(
        value: 'hide',
        height: 40,
        child: Row(
          children: [
            Icon(
              Icons.visibility_off_rounded,
              size: 17,
              color: context.colors.muted,
            ),
            const SizedBox(width: 8),
            const Text('隐藏该影片', style: TextStyle(fontSize: 13)),
          ],
        ),
      ),
    ],
  );
  if (action != 'hide' || !context.mounted) return false;

  final title = (displayName ?? '').trim().isEmpty
      ? video.title
      : displayName!.trim();
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('隐藏该影片'),
      content: Text(
        '「$title」将不再显示在海报墙、最近播放与未匹配列表，'
        '也不参与自动刮削。\n'
        '文件不会被删除，可在 设置 → 媒体源 → 已隐藏影片 恢复显示。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('隐藏'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;

  final messenger = ScaffoldMessenger.maybeOf(context);
  await MediaLibrary.instance.hideItem(video, displayName: title);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(content: Text('已隐藏，可在 设置 → 媒体源 → 已隐藏影片 恢复')));
  if (popOnHidden && context.mounted) {
    Navigator.of(context).maybePop();
  }
  return true;
}
