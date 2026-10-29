import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/media_source.dart';
import '../services/media_library.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const tabs = ['常规', '媒体源', '播放', '刮削', '关于'];
  int _selectedTab = 1;

  final _tmdbKeyController = TextEditingController();
  final _proxyController = TextEditingController();
  bool _scrapeFieldsFilled = false;

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

  @override
  void dispose() {
    _tmdbKeyController.dispose();
    _proxyController.dispose();
    super.dispose();
  }

  Widget _buildContent() {
    if (_selectedTab == 1) return _buildMediaSources();
    if (_selectedTab == 3) return _buildScraper();
    if (_selectedTab == 4) return _buildAbout();
    final placeholders = [
      ('常规设置', Icons.tune_rounded, '启动行为、界面语言和缓存策略'),
      ('播放设置', Icons.play_circle_outline_rounded, '默认音量、倍速、字幕和硬件解码'),
    ];
    final item = placeholders[_selectedTab == 0 ? 0 : _selectedTab - 1];
    return _PreferencePlaceholder(
      title: item.$1,
      icon: item.$2,
      description: item.$3,
    );
  }

  Widget _buildScraper() {
    return AnimatedBuilder(
      animation: MediaLibrary.instance,
      builder: (context, _) {
        final library = MediaLibrary.instance;
        var total = 0;
        var withPoster = 0;
        for (final kind in MediaKind.values) {
          final items = MediaLibrary.aggregate(library.byKind(kind));
          total += items.length;
          withPoster += items.where((v) => v.posterPath != null).length;
        }
        final missing = total - withPoster;

        return ListView(
          children: [
            Text('海报刮削', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              '根据片名自动匹配海报、简介与评分。数据源为 TVmaze（免费、无需配置）。',
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _scrapeStat(
                        '${library.byKind(MediaKind.movie).length + library.byKind(MediaKind.series).length + library.byKind(MediaKind.anime).length + library.byKind(MediaKind.variety).length}',
                        '媒体库条目',
                      ),
                      const SizedBox(width: 26),
                      _scrapeStat('$withPoster', '已匹配海报'),
                      const SizedBox(width: 26),
                      _scrapeStat('$missing', '待匹配'),
                    ],
                  ),
                  if (library.scraping) ...[
                    const SizedBox(height: 18),
                    LinearProgressIndicator(
                      value: library.scrapeTotal == 0
                          ? null
                          : library.scrapeDone / library.scrapeTotal,
                      minHeight: 6,
                      color: AppColors.primary,
                      backgroundColor: AppColors.border,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      library.scrapeProgress,
                      style: const TextStyle(
                        color: AppColors.primary,
                        fontSize: 13,
                      ),
                    ),
                  ] else if (library.scrapeProgress.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Icon(
                          Icons.check_circle_outline_rounded,
                          size: 17,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          library.scrapeProgress,
                          style: const TextStyle(
                            color: AppColors.primary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      FilledButton.icon(
                        key: const ValueKey('start-scrape'),
                        onPressed: library.scraping || total == 0
                            ? null
                            : () => library.scrapeAll(),
                        icon: library.scraping
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.auto_awesome_rounded),
                        label: Text(
                          library.scraping
                              ? '刮削中…'
                              : missing == 0 && total > 0
                              ? '重新刮削'
                              : '开始刮削',
                        ),
                      ),
                      const SizedBox(width: 14),
                      if (missing > 0 && !library.scraping)
                        Text(
                          '还有 $missing 个条目需要匹配',
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 12.5,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            _buildScrapeSourceSettings(context, library),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.primarySoft,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.lightbulb_outline_rounded,
                    size: 19,
                    color: AppColors.primary,
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '匹配依据文件名中的片名与年份，如「Apocalypse.Hotel.2025.S01E01」可正确识别。'
                      '若文件名过于随意（如「新建文件夹」）可能匹配不到，会保留渐变封面。'
                      '海报下载后缓存到本地，重复刮削不会重复下载。',
                      style: TextStyle(
                        color: AppColors.primary,
                        fontSize: 12.5,
                        height: 1.6,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// 刮削数据源配置：TMDB 密钥（可选）与 HTTP 代理（可选）。
  Widget _buildScrapeSourceSettings(
    BuildContext context,
    MediaLibrary library,
  ) {
    if (!_scrapeFieldsFilled) {
      _tmdbKeyController.text = library.tmdbKey ?? '';
      _proxyController.text = library.scrapeProxy ?? '';
      _scrapeFieldsFilled = true;
    }
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('数据源', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: library.hasTmdb
                      ? AppColors.primarySoft
                      : AppColors.background,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '当前：${library.scraperSourceLabel}',
                  style: TextStyle(
                    fontSize: 11,
                    color: library.hasTmdb
                        ? AppColors.primary
                        : AppColors.muted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'TVmaze 免费开箱即用，但只能按英文片名检索，且几乎不收录电影。'
            '想要中文片名和电影海报，填一个免费的 TMDB 密钥即可——'
            '已内置国内直连线路，无需任何代理。',
            style: TextStyle(
              color: AppColors.muted,
              fontSize: 12.5,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('tmdb-key'),
            controller: _tmdbKeyController,
            decoration: const InputDecoration(
              labelText: 'TMDB API Key（可选，免费申请）',
              hintText: 'themoviedb.org → 设置 → API → 申请 v3 Key',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('scrape-proxy'),
            controller: _proxyController,
            decoration: const InputDecoration(
              labelText: '备用代理（一般不需要）',
              hintText: '仅当直连线路失效时填写，例如 127.0.0.1:7890',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              FilledButton.tonal(
                key: const ValueKey('save-scrape-settings'),
                onPressed: () async {
                  await library.saveScrapeSettings(
                    proxy: _proxyController.text,
                    tmdbKey: _tmdbKeyController.text,
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        SnackBar(
                          content: Text(
                            library.hasTmdb
                                ? '已启用 TMDB，下次刮削生效'
                                : '已保存，当前使用 TVmaze',
                          ),
                        ),
                      );
                  }
                },
                child: const Text('保存数据源设置'),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  '密钥保存在系统安全存储中。TMDB 走内置直连线路，海报由图片 CDN 直连下载。',
                  style: TextStyle(color: AppColors.muted, fontSize: 11.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _scrapeStat(String value, String label) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(fontSize: 11.5, color: AppColors.muted),
        ),
      ],
    );
  }

  Widget _buildMediaSources() {
    return AnimatedBuilder(
      animation: MediaLibrary.instance,
      builder: (context, _) {
        final library = MediaLibrary.instance;
        final sources = library.sources;
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
            if (library.scanStatus == ScanStatus.scanning)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        library.scanProgress,
                        style: const TextStyle(
                          color: AppColors.primary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (library.scanStatus == ScanStatus.scanning)
              const SizedBox(height: 18),
            for (final source in sources) ...[
              _MediaSourceCard(
                source: source,
                busy: library.scanStatus == ScanStatus.scanning,
                error: library.errorOf(source.id),
                videoCount: _countVideos(source.id),
                onEdit: () => _editSource(existing: source),
                onSync: () => _scanSource(source),
                onDelete: () => _deleteSource(source),
              ),
              const SizedBox(height: 12),
            ],
            if (sources.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: Text('还没有媒体源，点击右上角添加')),
              ),
          ],
        );
      },
    );
  }

  int _countVideos(String sourceId) {
    final library = MediaLibrary.instance;
    var count = 0;
    for (final kind in MediaKind.values) {
      count += library
          .byKind(kind)
          .where((video) => video.sourceId == sourceId)
          .length;
    }
    return count;
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

  Future<void> _editSource({MediaSource? existing}) async {
    final result = await showDialog<(MediaSource, String?)>(
      context: context,
      builder: (_) => WebDavSourceDialog(existing: existing),
    );
    if (result == null || !mounted) return;
    final (source, password) = result;
    await MediaLibrary.instance.addOrUpdateSource(source, password: password);
    _showMessage(existing == null ? '媒体源已保存' : '媒体源已更新');
  }

  Future<void> _scanSource(MediaSource source) async {
    await MediaLibrary.instance.scan(source.id);
    if (!mounted) return;
    final library = MediaLibrary.instance;
    if (library.scanStatus == ScanStatus.failed) {
      _showMessage('扫描失败：${library.errorOf(source.id) ?? '未知错误'}');
    } else {
      _showMessage(library.scanProgress);
    }
  }

  Future<void> _deleteSource(MediaSource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除媒体源'),
        content: Text('确定删除「${source.name}」吗？已扫描的内容将从媒体库移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await MediaLibrary.instance.deleteSource(source.id);
      _showMessage('已删除「${source.name}」');
    }
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
    required this.busy,
    required this.error,
    required this.videoCount,
    required this.onEdit,
    required this.onSync,
    required this.onDelete,
  });

  final MediaSource source;
  final bool busy;
  final String? error;
  final int videoCount;
  final VoidCallback onEdit;
  final VoidCallback onSync;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final connected = source.connected && error == null;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: error != null
              ? AppColors.danger.withValues(alpha: 0.5)
              : AppColors.border,
        ),
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
                if (error != null)
                  Text(
                    error!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.danger,
                    ),
                  )
                else
                  Row(
                    children: [
                      Icon(
                        Icons.circle,
                        size: 8,
                        color: connected
                            ? const Color(0xFF4F8C68)
                            : Colors.orange.shade600,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          connected
                              ? '已连接 · $videoCount 个条目 · 最近同步 ${source.lastSync}'
                              : '未同步 · 最近同步 ${source.lastSync}',
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            onPressed: busy ? null : onSync,
            tooltip: '同步扫描',
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            key: const ValueKey('edit-source'),
            onPressed: busy ? null : onEdit,
            tooltip: '编辑',
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            onPressed: busy ? null : onDelete,
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline_rounded),
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
    text: widget.existing?.directory ?? '/',
  );
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _testing = false;
  String? _testResult; // null=未测或成功，否则错误文本
  bool _testOk = false;

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
                  'http://192.168.1.10:5244',
                  key: const ValueKey('source-address'),
                  validator: _validateAddress,
                ),
                const SizedBox(height: 14),
                _field(
                  _directoryController,
                  '媒体目录',
                  'openlist / alist 网盘填 /dav',
                ),
                const SizedBox(height: 14),
                _field(_usernameController, '用户名', 'WebDAV 用户名'),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  validator: (value) {
                    if (widget.existing != null) return null; // 编辑可留空沿用旧密码
                    if (value == null || value.isEmpty) return '请填写密码';
                    return null;
                  },
                  decoration: InputDecoration(
                    labelText: '密码',
                    hintText: widget.existing == null
                        ? '将保存在系统安全存储中'
                        : '留空表示不修改',
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
                const SizedBox(height: 18),
                Row(
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('test-connection'),
                      onPressed: _testing ? null : _testConnection,
                      icon: _testing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wifi_tethering_rounded, size: 18),
                      label: const Text('测试连接'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: _buildTestFeedback()),
                  ],
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

  Widget _buildTestFeedback() {
    if (_testing) {
      return const Text(
        '正在连接…',
        style: TextStyle(color: AppColors.muted, fontSize: 13),
      );
    }
    if (_testResult == null) {
      return Text(
        _testOk ? '连接成功' : '',
        style: const TextStyle(color: Color(0xFF4F8C68), fontSize: 13),
      );
    }
    return Text(
      _testResult!,
      style: const TextStyle(color: AppColors.danger, fontSize: 13),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  MediaSource _buildSource() {
    final existing = widget.existing;
    return MediaSource(
      id: existing?.id ?? MediaSource.newId(),
      name: _nameController.text.trim(),
      address: _addressController.text.trim().replaceFirst(RegExp(r'/+$'), ''),
      username: _usernameController.text.trim(),
      directory: _directoryController.text.trim().isEmpty
          ? '/'
          : _directoryController.text.trim(),
      connected: existing?.connected ?? false,
      lastSync: existing?.lastSync ?? '尚未同步',
    );
  }

  Future<void> _testConnection() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final source = _buildSource();
    final password = _passwordController.text;
    final stored = widget.existing == null || password.isNotEmpty
        ? password
        : null;
    if (stored == null) {
      setState(() {
        _testing = true;
        _testResult = null;
      });
      // 编辑时留空密码：用已保存密码测试
      final library = MediaLibrary.instance;
      final error = library.hasPassword(source.id) ? null : '未保存过密码，请先输入密码';
      setState(() {
        _testing = false;
        _testOk = false;
        _testResult = error;
      });
      if (error != null) return;
      setState(() => _testing = true);
      final result = await library.testConnection(source, '');
      setState(() {
        _testing = false;
        _testOk = result == null;
        _testResult = result;
      });
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
      _testOk = false;
    });
    final error = await MediaLibrary.instance.testConnection(source, stored);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = error == null;
      _testResult = error;
    });
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final password = _passwordController.text;
    Navigator.pop(context, (
      _buildSource(),
      password.isEmpty ? null : password,
    ));
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
