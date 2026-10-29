import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../data/demo_data.dart';
import '../models/media_source.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const tabs = ['常规', '媒体源', '播放', '刮削', '关于'];
  final _sources = List<MediaSource>.of(DemoData.sources);
  int _selectedTab = 1;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 28, 30, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('设置', style: Theme.of(context).textTheme.headlineLarge),
          const SizedBox(height: 6),
          const Text(
            '管理拾帧的媒体来源与播放偏好',
            style: TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: 22),
          Wrap(
            spacing: 8,
            children: [
              for (var i = 0; i < tabs.length; i++)
                ChoiceChip(
                  key: ValueKey('settings-tab-$i'),
                  label: Text(tabs[i]),
                  selected: _selectedTab == i,
                  onSelected: (_) => setState(() => _selectedTab = i),
                  selectedColor: AppColors.primarySoft,
                  backgroundColor: AppColors.surface,
                  side: BorderSide(
                    color: _selectedTab == i
                        ? AppColors.primary.withValues(alpha: 0.25)
                        : AppColors.border,
                  ),
                  labelStyle: TextStyle(
                    color: _selectedTab == i
                        ? AppColors.primary
                        : AppColors.muted,
                    fontWeight: _selectedTab == i
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_selectedTab == 1) return _buildMediaSources();
    if (_selectedTab == 4) return _buildAbout();
    final placeholders = [
      ('常规设置', Icons.tune_rounded, '启动行为、界面语言和缓存策略'),
      ('播放设置', Icons.play_circle_outline_rounded, '默认音量、倍速、字幕和硬件解码'),
      ('刮削设置', Icons.auto_fix_high_rounded, '影片信息来源、匹配规则和语言偏好'),
    ];
    final item = placeholders[_selectedTab == 0 ? 0 : _selectedTab - 1];
    return _PreferencePlaceholder(
      title: item.$1,
      icon: item.$2,
      description: item.$3,
    );
  }

  Widget _buildMediaSources() {
    return ListView(
      children: [
        Row(
          children: [
            Text('媒体源', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            FilledButton.icon(
              key: const ValueKey('add-source'),
              onPressed: () => _editSource(),
              icon: const Icon(Icons.add_rounded),
              label: const Text('添加媒体源'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'WebDAV、SMB 与本地目录统一在这里管理，不会出现在首页。',
          style: TextStyle(color: AppColors.muted, fontSize: 13),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Row(
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 20,
                color: AppColors.primary,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '第一阶段为界面演示：新增配置仅保留在本次运行中，不会连接真实服务器。',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        for (var i = 0; i < _sources.length; i++) ...[
          _MediaSourceCard(
            source: _sources[i],
            onEdit: () => _editSource(index: i),
            onSync: () => _syncSource(i),
          ),
          const SizedBox(height: 12),
        ],
        if (_sources.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Center(child: Text('还没有媒体源，点击右上角添加')),
          ),
      ],
    );
  }

  Widget _buildAbout() {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.border),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.movie_filter_rounded,
              size: 56,
              color: AppColors.primary,
            ),
            SizedBox(height: 14),
            Text(
              '拾帧',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
              ),
            ),
            Text(
              'Framelet 0.1.0 · Windows',
              style: TextStyle(color: AppColors.muted),
            ),
            SizedBox(height: 18),
            Text('拾起每一帧，让媒体库重新清晰。', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Future<void> _editSource({int? index}) async {
    final result = await showDialog<MediaSource>(
      context: context,
      builder: (_) =>
          WebDavSourceDialog(existing: index == null ? null : _sources[index]),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (index == null) {
        _sources.add(result);
      } else {
        _sources[index] = result;
      }
    });
    _showMessage(index == null ? '已添加演示媒体源' : '已保存媒体源配置');
  }

  void _syncSource(int index) {
    setState(() => _sources[index] = _sources[index].copyWith(lastSync: '刚刚'));
    _showMessage('演示刷新完成，未访问真实服务器');
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _MediaSourceCard extends StatelessWidget {
  const _MediaSourceCard({
    required this.source,
    required this.onEdit,
    required this.onSync,
  });

  final MediaSource source;
  final VoidCallback onEdit;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.cloud_outlined, color: AppColors.primary),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        source.name,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primarySoft,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'WebDAV',
                        style: TextStyle(
                          fontSize: 10,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                Text(
                  '${source.address}${source.directory}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    const Icon(Icons.circle, size: 8, color: Color(0xFF4F8C68)),
                    const SizedBox(width: 6),
                    Text(
                      '演示已连接 · 最近同步 ${source.lastSync}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            onPressed: onSync,
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            key: const ValueKey('edit-source'),
            onPressed: onEdit,
            tooltip: '编辑',
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
    );
  }
}

class WebDavSourceDialog extends StatefulWidget {
  const WebDavSourceDialog({this.existing, super.key});

  final MediaSource? existing;

  @override
  State<WebDavSourceDialog> createState() => _WebDavSourceDialogState();
}

class _WebDavSourceDialogState extends State<WebDavSourceDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _nameController = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final _addressController = TextEditingController(
    text: widget.existing?.address ?? '',
  );
  late final _usernameController = TextEditingController(
    text: widget.existing?.username ?? '',
  );
  late final _directoryController = TextEditingController(
    text: widget.existing?.directory ?? '/Movies',
  );
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _usernameController.dispose();
    _directoryController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '添加 WebDAV 媒体源' : '编辑 WebDAV 媒体源'),
      content: SizedBox(
        width: 500,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _field(
                  _nameController,
                  '显示名称',
                  '例如：家里的影音库',
                  key: const ValueKey('source-name'),
                ),
                const SizedBox(height: 14),
                _field(
                  _addressController,
                  '服务器地址',
                  'https://example.com/dav',
                  key: const ValueKey('source-address'),
                  validator: _validateAddress,
                ),
                const SizedBox(height: 14),
                _field(_directoryController, '媒体目录', '/Movies'),
                const SizedBox(height: 14),
                _field(_usernameController, '用户名', 'WebDAV 用户名'),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: '密码',
                    hintText: widget.existing == null ? '仅用于本次界面演示' : '留空表示不修改',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('save-source'),
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    String hint, {
    Key? key,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      key: key,
      controller: controller,
      validator:
          validator ??
          (value) => value == null || value.trim().isEmpty ? '请填写$label' : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
    );
  }

  String? _validateAddress(String? value) {
    if (value == null || value.trim().isEmpty) return '请填写服务器地址';
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !uri.hasScheme ||
        uri.host.isEmpty ||
        !['http', 'https'].contains(uri.scheme)) {
      return '请输入有效的 http 或 https 地址';
    }
    return null;
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.pop(
      context,
      MediaSource(
        name: _nameController.text.trim(),
        address: _addressController.text.trim().replaceFirst(RegExp(r'/$'), ''),
        username: _usernameController.text.trim(),
        directory: _directoryController.text.trim(),
        lastSync: widget.existing?.lastSync ?? '尚未同步',
      ),
    );
  }
}

class _PreferencePlaceholder extends StatelessWidget {
  const _PreferencePlaceholder({
    required this.title,
    required this.icon,
    required this.description,
  });

  final String title;
  final IconData icon;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        padding: const EdgeInsets.all(30),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: AppColors.primary),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 18),
            const Text('将在对应功能阶段开放', style: TextStyle(color: AppColors.muted)),
          ],
        ),
      ),
    );
  }
}
