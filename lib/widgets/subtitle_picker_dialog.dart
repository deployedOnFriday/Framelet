import 'package:flutter/material.dart';

/// 字幕弹窗里的一行：普通选项 / 分隔线 / 灰色提示。
class SubtitlePickerEntry {
  const SubtitlePickerEntry({
    required this.value,
    required this.label,
    this.selected = false,
  }) : divider = false,
       hint = false;

  const SubtitlePickerEntry.divider()
    : value = null,
      label = '',
      selected = false,
      divider = true,
      hint = false;

  const SubtitlePickerEntry.hint(this.label)
    : value = null,
      selected = false,
      divider = false,
      hint = true;

  final String? value;
  final String label;
  final bool selected;
  final bool divider;
  final bool hint;
}

/// 独立字幕选择弹窗。
///
/// 播放器控制条里的 PopupMenuButton 在部分窗口尺寸/缩放下点不中选项
/// （菜单会关闭但不触发选择），所以这里用正常路由的 Dialog。
class SubtitlePickerDialog extends StatelessWidget {
  const SubtitlePickerDialog({required this.entries, super.key});

  final List<SubtitlePickerEntry> entries;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1C1C1E),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 400,
          maxHeight: MediaQuery.sizeOf(context).height * 0.62,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
              child: Row(
                children: [
                  const Icon(
                    Icons.subtitles_rounded,
                    size: 18,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '字幕',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    iconSize: 18,
                    color: Colors.white54,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  if (entry.divider) {
                    return const Divider(height: 9, color: Colors.white12);
                  }
                  if (entry.hint) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(18, 6, 18, 8),
                      child: Text(
                        entry.label,
                        style: const TextStyle(
                          color: Colors.white30,
                          fontSize: 12,
                        ),
                      ),
                    );
                  }
                  return InkWell(
                    onTap: () => Navigator.of(context).pop(entry.value),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 11,
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 24,
                            child: entry.selected
                                ? const Icon(
                                    Icons.check_rounded,
                                    size: 17,
                                    color: Color(0xFF5B8CFF),
                                  )
                                : null,
                          ),
                          Expanded(
                            child: Text(
                              entry.label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: entry.selected
                                    ? Colors.white
                                    : Colors.white70,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
