import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/media_source.dart';
import '../services/media_library.dart';
import '../services/playback_history.dart';
import '../services/webdav_service.dart';

/// WebDAV 文件管理：浏览媒体源目录，重命名、删除、新建文件夹。
///
/// 只允许在媒体源配置的目录范围内操作，避免误改挂载根目录。
class WebDavBrowserPage extends StatefulWidget {
  const WebDavBrowserPage({
    super.key,
    required this.source,
    required this.password,
  });

  final MediaSource source;
  final String password;

  @override
  State<WebDavBrowserPage> createState() => _WebDavBrowserPageState();
}

class _WebDavBrowserPageState extends State<WebDavBrowserPage> {
  late final String _root;
  late String _path;
  List<WebDavEntry> _entries = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _root = WebDavService.rootPathOf(widget.source);
    _path = _root;
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final entries = await WebDavService.listDirectory(
        widget.source,
        widget.password,
        _path,
      );
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } on StateError catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = WebDavService.describeManagementError(error, '读取目录');
        _loading = false;
      });
    }
  }

  void _open(String path) {
    final next = WebDavService.normalizePath(path);
    if (next != _root && !next.startsWith(_root == '/' ? '/' : '$_root/')) {
      return;
    }
    if (next == _path) return;
    setState(() {
      _path = next;
    });
    _load();
  }

  void _goUp() {
    if (_path == _root) return;
    _open(WebDavService.parentPath(_path));
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool refresh = true,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (refresh && mounted) await _load();
    } on StateError catch (error) {
      _notify(error.message, error: true);
    } catch (error) {
      _notify('操作失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _renameEntry(WebDavEntry entry) async {
    final name = await _askName(
      title: '重命名',
      initial: entry.name,
      confirm: '保存',
    );
    if (name == null || name == entry.name) return;
    await _run(() async {
      final newPath = await WebDavService.renameEntry(
        widget.source,
        widget.password,
        path: entry.path,
        newName: name,
        isDir: entry.isDir,
      );
      await MediaLibrary.instance.applyRemoteRename(
        sourceId: widget.source.id,
        oldPath: entry.path,
        newPath: newPath,
        isDir: entry.isDir,
      );
      await PlaybackHistory.instance.renamePath(
        widget.source.id,
        entry.path,
        newPath,
        isDir: entry.isDir,
      );
      _notify('已重命名为「$name」');
    });
  }

  Future<void> _deleteEntry(WebDavEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除'),
        content: Text(
          entry.isDir
              ? '将递归删除文件夹「${entry.name}」及其中的全部文件。'
                    '此操作不会进入回收站，确定继续吗？'
              : '确定删除「${entry.name}」吗？此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.danger,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      await WebDavService.removeEntry(
        widget.source,
        widget.password,
        path: entry.path,
        isDir: entry.isDir,
      );
      await MediaLibrary.instance.applyRemoteDelete(
        sourceId: widget.source.id,
        path: entry.path,
        isDir: entry.isDir,
      );
      await PlaybackHistory.instance.removePath(
        widget.source.id,
        entry.path,
        isDir: entry.isDir,
      );
      _notify('已删除「${entry.name}」');
    });
  }

  Future<void> _createFolder() async {
    final name = await _askName(
      title: '新建文件夹',
      initial: '新建文件夹',
      confirm: '创建',
    );
    if (name == null) return;
    await _run(() async {
      await WebDavService.createDirectory(
        widget.source,
        widget.password,
        parent: _path,
        name: name,
      );
      _notify('已新建文件夹「$name」');
    });
  }

  Future<String?> _askName({
    required String title,
    required String initial,
    required String confirm,
  }) async {
    return showDialog<String>(
      context: context,
      builder: (_) =>
          _NameDialog(title: title, initial: initial, confirm: confirm),
    );
  }

  void _notify(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error ? context.colors.danger : null,
        ),
      );
  }

  List<({String label, String path})> _crumbs() {
    final result = <({String label, String path})>[
      (label: widget.source.name, path: _root),
    ];
    if (_path == _root) return result;
    final relative = _root == '/'
        ? _path.substring(1)
        : _path.substring(_root.length + 1);
    var current = _root;
    for (final segment in relative.split('/').where((s) => s.isNotEmpty)) {
      current = WebDavService.joinPath(current, segment);
      result.add((label: segment, path: current));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final crumbs = _crumbs();
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('文件管理'),
            Text(
              widget.source.name,
              style: TextStyle(fontSize: 11.5, color: context.colors.muted),
            ),
          ],
        ),
        actions: [
          IconButton(
            iconSize: 20,
            onPressed: _busy ? null : _createFolder,
            tooltip: '新建文件夹',
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
          IconButton(
            iconSize: 20,
            onPressed: _busy || _loading ? null : _load,
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: context.colors.surface,
              border: Border(bottom: BorderSide(color: context.colors.border)),
            ),
            child: Row(
              children: [
                IconButton(
                  iconSize: 20,
                  onPressed: _busy || _path == _root ? null : _goUp,
                  tooltip: '上一级',
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var i = 0; i < crumbs.length; i++) ...[
                          if (i > 0)
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 17,
                              color: context.colors.muted,
                            ),
                          InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: i == crumbs.length - 1
                                ? null
                                : () => _open(crumbs[i].path),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 4,
                              ),
                              child: Text(
                                crumbs[i].label,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: i == crumbs.length - 1
                                      ? context.colors.text
                                      : context.colors.primary,
                                  fontWeight: i == crumbs.length - 1
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 36,
                color: context.colors.muted,
              ),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.colors.muted, fontSize: 13),
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_open_rounded,
              size: 36,
              color: context.colors.muted,
            ),
            const SizedBox(height: 10),
            Text(
              '这个目录是空的',
              style: TextStyle(fontSize: 13, color: context.colors.muted),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      itemCount: _entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return _EntryTile(
          entry: entry,
          enabled: !_busy,
          onOpen: entry.isDir ? () => _open(entry.path) : null,
          onRename: () => _renameEntry(entry),
          onDelete: () => _deleteEntry(entry),
        );
      },
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.initial,
    required this.confirm,
  });

  final String title;
  final String initial;
  final String confirm;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.initial.length,
      );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      final name = WebDavService.validateEntryName(_controller.text);
      Navigator.of(context).pop(name);
    } on StateError catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: '名称',
          hintText: '不能包含 / 或 \\',
          errorText: _error,
          border: const OutlineInputBorder(),
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirm)),
      ],
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.enabled,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
  });

  final WebDavEntry entry;
  final bool enabled;
  final VoidCallback? onOpen;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final subtitle = entry.isDir
        ? '文件夹'
        : [
            if (entry.sizeBytes > 0) _formatSize(entry.sizeBytes),
            if (entry.modified != null) _formatDate(entry.modified!),
          ].join('  ·  ');
    return Material(
      color: context.colors.surface,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: enabled ? onOpen : null,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 9, 6, 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: context.colors.border),
          ),
          child: Row(
            children: [
              Icon(
                _iconOf(entry),
                size: 18,
                color: entry.isDir
                    ? context.colors.primary
                    : context.colors.iconMuted,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: context.colors.text,
                        fontWeight: entry.isDir
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.colors.muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                enabled: enabled,
                iconSize: 20,
                tooltip: '更多操作',
                icon: Icon(
                  Icons.more_horiz_rounded,
                  color: context.colors.muted,
                ),
                onSelected: (value) {
                  if (value == 'rename') onRename();
                  if (value == 'delete') onDelete();
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'rename',
                    child: Row(
                      children: [
                        Icon(Icons.drive_file_rename_outline, size: 18),
                        SizedBox(width: 10),
                        Text('重命名'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline_rounded, size: 18),
                        SizedBox(width: 10),
                        Text('删除'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _iconOf(WebDavEntry entry) {
    if (entry.isDir) return Icons.folder_rounded;
    final dot = entry.name.lastIndexOf('.');
    final ext = dot < 0 ? '' : entry.name.substring(dot).toLowerCase();
    if (WebDavService.videoExtensions.contains(ext)) {
      return Icons.movie_outlined;
    }
    if (WebDavService.subtitleExtensions.contains(ext)) {
      return Icons.subtitles_outlined;
    }
    if (const {
      '.jpg',
      '.jpeg',
      '.png',
      '.webp',
      '.gif',
      '.bmp',
    }.contains(ext)) {
      return Icons.image_outlined;
    }
    if (const {'.mp3', '.flac', '.wav', '.aac', '.m4a', '.ogg'}.contains(ext)) {
      return Icons.audiotrack_rounded;
    }
    return Icons.insert_drive_file_outlined;
  }

  static String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final digits = value >= 10 || unit == 0 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }

  static String _formatDate(DateTime date) {
    String two(int value) => value.toString().padLeft(2, '0');
    final local = date.toLocal();
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
