import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/theme/app_theme.dart';
import '../models/media_source.dart';
import '../services/danmaku_service.dart';
import '../services/media_library.dart';
import '../services/playback_preferences.dart';
import '../services/scraper_service.dart';
import '../services/theme_controller.dart';
import '../widgets/match_dialog.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with AutomaticKeepAliveClientMixin {
  static const tabs = ['常规', '媒体源', '播放', '刮削', '弹幕', '关于'];
  int _selectedTab = 1;

  final _tmdbKeyController = TextEditingController();
  final _proxyController = TextEditingController();
  final _danmakuBaseUrlController = TextEditingController();
  final _danmakuAppIdController = TextEditingController();
  final _danmakuAppSecretController = TextEditingController();
  bool _scrapeFieldsFilled = false;
  bool _danmakuFieldsFilled = false;
  bool _obscureDanmakuSecret = true;
  DanmakuProvider _danmakuProvider = DanmakuProvider.dandanplay;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 28, 30, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('设置', style: Theme.of(context).textTheme.headlineLarge),
          const SizedBox(height: 6),
          Text('管理拾帧的媒体来源与播放偏好', style: TextStyle(color: context.colors.muted)),
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
                  selectedColor: context.colors.primarySoft,
                  backgroundColor: context.colors.surface,
                  side: BorderSide(
                    color: _selectedTab == i
                        ? context.colors.primary.withValues(alpha: 0.25)
                        : context.colors.border,
                  ),
                  labelStyle: TextStyle(
                    color: _selectedTab == i
                        ? context.colors.primary
                        : context.colors.muted,
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
    _danmakuBaseUrlController.dispose();
    _danmakuAppIdController.dispose();
    _danmakuAppSecretController.dispose();
    super.dispose();
  }

  Widget _buildContent() {
    if (_selectedTab == 0) return _buildGeneral();
    if (_selectedTab == 1) return _buildMediaSources();
    if (_selectedTab == 2) return _buildPlayback();
    if (_selectedTab == 3) return _buildScraper();
    if (_selectedTab == 4) return _buildDanmaku();
    if (_selectedTab == 5) return _buildAbout();
    return const SizedBox.shrink();
  }

  /// 播放：行为开关 + 默认播放参数，改动立即保存，下次播放生效。
  Widget _buildPlayback() {
    final prefs = PlaybackPreferences.instance;
    return AnimatedBuilder(
      animation: prefs,
      builder: (context, _) => ListView(
        children: [
          Text('播放行为', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            '连播、音量记忆与弹幕的默认行为。',
            style: TextStyle(color: context.colors.muted, fontSize: 13),
          ),
          const SizedBox(height: 18),
          _playbackCard(
            children: [
              _playbackSwitch(
                key: 'playback-auto-next',
                title: '自动连播',
                subtitle: '剧集播完自动播放下一集，关闭后停留在结尾画面',
                value: prefs.autoPlayNext,
                onChanged: prefs.setAutoPlayNext,
              ),
              _divider(),
              _playbackSwitch(
                key: 'playback-remember-volume',
                title: '记住音量',
                subtitle: '下次播放沿用上次的音量与静音状态',
                value: prefs.rememberVolume,
                onChanged: prefs.setRememberVolume,
              ),
              _divider(),
              _playbackSwitch(
                key: 'playback-auto-danmaku',
                title: '自动加载弹幕',
                subtitle: '播放时自动匹配并加载弹幕，需先在「弹幕」页配置服务',
                value: prefs.autoLoadDanmaku,
                onChanged: prefs.setAutoLoadDanmaku,
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text('默认播放参数', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            '每次打开播放器时使用的初始值。',
            style: TextStyle(color: context.colors.muted, fontSize: 13),
          ),
          const SizedBox(height: 18),
          _playbackCard(
            children: [
              _chipRow<double>(
                keyPrefix: 'playback-speed',
                title: '默认倍速',
                subtitle: '打开播放器时的初始播放速度',
                options: [
                  for (final speed in PlaybackPreferences.speedOptions)
                    (value: speed, label: speed == 1.0 ? '正常' : '$speed×'),
                ],
                current: prefs.defaultSpeed,
                onChanged: prefs.setDefaultSpeed,
              ),
              _divider(),
              _chipRow<int>(
                keyPrefix: 'playback-seek',
                title: '快进快退步长',
                subtitle: '按 ← / → 方向键跳转的秒数（J / L 固定 ±10 秒）',
                options: [
                  for (final step in PlaybackPreferences.seekStepOptions)
                    (value: step, label: '$step 秒'),
                ],
                current: prefs.seekStep,
                onChanged: prefs.setSeekStep,
              ),
              _divider(),
              _chipRow<int>(
                keyPrefix: 'playback-rewind',
                title: '续播回退',
                subtitle: '从上次进度继续时向前回退，帮助衔接剧情',
                options: [
                  for (final sec in PlaybackPreferences.rewindOptions)
                    (value: sec, label: sec == 0 ? '不回退' : '$sec 秒'),
                ],
                current: prefs.rewindSeconds,
                onChanged: prefs.setRewindSeconds,
              ),
              _divider(),
              _playbackSwitch(
                key: 'playback-hwdec',
                title: '硬件解码',
                subtitle: '用显卡硬解视频，CPU 占用低；遇到花屏或黑屏时可关闭改用软解',
                value: prefs.hardwareDecode,
                onChanged: prefs.setHardwareDecode,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _playbackCard({required List<Widget> children}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: context.colors.border),
      ),
      // stretch：行内容统一撑满卡宽，标题与选项严格左对齐
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _divider() => Divider(height: 1, color: context.colors.border);

  Widget _playbackSwitch({
    required String key,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 13.5, color: context.colors.text)),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 11.5, color: context.colors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Switch(
            key: ValueKey(key),
            value: value,
            activeThumbColor: context.colors.primary,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _chipRow<T>({
    required String keyPrefix,
    required String title,
    required String subtitle,
    required List<({T value, String label})> options,
    required T current,
    required ValueChanged<T> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(fontSize: 13.5, color: context.colors.text)),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(fontSize: 11.5, color: context.colors.muted)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in options)
                ChoiceChip(
                  key: ValueKey('$keyPrefix-${option.value}'),
                  label: Text(option.label),
                  selected: option.value == current,
                  showCheckmark: false,
                  selectedColor: context.colors.primarySoft,
                  backgroundColor: context.colors.surface,
                  side: BorderSide(
                    color: option.value == current
                        ? context.colors.primary.withValues(alpha: 0.25)
                        : context.colors.border,
                  ),
                  labelStyle: TextStyle(
                    fontSize: 12.5,
                    color: option.value == current
                        ? context.colors.primary
                        : context.colors.muted,
                    fontWeight:
                        option.value == current ? FontWeight.w600 : FontWeight.w400,
                  ),
                  onSelected: (_) => onChanged(option.value),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 常规：目前只有外观（浅色/深色/跟随系统）。
  Widget _buildGeneral() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('外观', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '选择界面明暗。「跟随系统」会随 Windows 的浅色/深色设置自动切换。',
            style: TextStyle(color: context.colors.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: ThemeController.instance,
            builder: (context, mode, _) => Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final option in const [
                  (ThemeMode.light, '浅色', Icons.light_mode_outlined),
                  (ThemeMode.dark, '深色', Icons.dark_mode_outlined),
                  (ThemeMode.system, '跟随系统', Icons.brightness_auto_outlined),
                ])
                  _ThemeOptionTile(
                    key: ValueKey('theme-${option.$1.name}'),
                    mode: option.$1,
                    label: option.$2,
                    icon: option.$3,
                    selected: mode == option.$1,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: context.colors.primarySoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 19,
                  color: context.colors.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '外观选择会立即生效并记住，下次启动沿用上次的设置。'
                    '深色模式下海报墙、详情页和播放器界面统一压暗，减少夜间观影的眩光。',
                    style: TextStyle(
                      color: context.colors.primary,
                      fontSize: 12.5,
                      height: 1.6,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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
          final items = library.byKind(kind);
          total += items.length;
          withPoster += items.where((v) => v.posterPath != null).length;
        }
        final missing = total - withPoster;

        return ListView(
          children: [
            Text('海报刮削', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              '根据片名自动匹配海报、简介与评分。数据源为 TVmaze（免费、无需配置）。',
              style: TextStyle(color: context.colors.muted, fontSize: 13),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: context.colors.surface,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: context.colors.border),
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
                      color: context.colors.primary,
                      backgroundColor: context.colors.border,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      library.scrapeProgress,
                      style: TextStyle(
                        color: context.colors.primary,
                        fontSize: 13,
                      ),
                    ),
                  ] else if (library.scrapeProgress.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Icon(
                          Icons.check_circle_outline_rounded,
                          size: 17,
                          color: context.colors.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          library.scrapeProgress,
                          style: TextStyle(
                            color: context.colors.primary,
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
                            : () => library.scrapeAll(force: missing == 0),
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
                              ? '重新刮削（覆盖已有）'
                              : '开始刮削',
                        ),
                      ),
                      const SizedBox(width: 12),
                      if (!library.scraping)
                        TextButton(
                          key: const ValueKey('rescrape-all'),
                          onPressed: () => library.scrapeAll(force: true),
                          child: const Text('全部重新刮削'),
                        ),
                      const SizedBox(width: 8),
                      if (missing > 0 && !library.scraping)
                        Expanded(
                          child: Text(
                            '还有 $missing 个条目需要匹配',
                            style: TextStyle(
                              color: context.colors.muted,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 4, 10, 4),
              decoration: BoxDecoration(
                color: context.colors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: context.colors.border),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '同步后自动刮削',
                          style: TextStyle(
                            fontSize: 13.5,
                            color: context.colors.text,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '扫描完成自动补齐未匹配的条目，已有海报的会跳过',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: context.colors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: library.autoScrapeAfterScan,
                    activeThumbColor: context.colors.primary,
                    onChanged: (value) => library.setAutoScrapeAfterScan(value),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Builder(
              builder: (context) {
                final unscraped = library.unscrapedItems();
                return unscraped.isEmpty
                    ? const SizedBox.shrink()
                    : _UnmatchedSection(items: unscraped);
              },
            ),
            const SizedBox(height: 18),
            _buildScrapeSourceSettings(context, library),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: context.colors.primarySoft,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.lightbulb_outline_rounded,
                    size: 19,
                    color: context.colors.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '匹配依据文件名中的片名与年份，如「Apocalypse.Hotel.2025.S01E01」可正确识别。'
                      '若文件名过于随意（如「新建文件夹」）可能匹配不到，会保留渐变封面。'
                      '海报下载后缓存到本地，重复刮削不会重复下载。',
                      style: TextStyle(
                        color: context.colors.primary,
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
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: context.colors.border),
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
                      ? context.colors.primarySoft
                      : context.colors.background,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '当前：${library.scraperSourceLabel}',
                  style: TextStyle(
                    fontSize: 11,
                    color: library.hasTmdb
                        ? context.colors.primary
                        : context.colors.muted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'TVmaze 免费开箱即用，但只能按英文片名检索，且几乎不收录电影。'
            '想要中文片名和电影海报，填一个免费的 TMDB 密钥即可——'
            '已内置国内直连线路，无需任何代理。',
            style: TextStyle(
              color: context.colors.muted,
              fontSize: 12.5,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
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
            spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
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
              Expanded(
                child: Text(
                  '密钥保存在系统安全存储中。TMDB 走内置直连线路，海报由图片 CDN 直连下载。',
                  style: TextStyle(color: context.colors.muted, fontSize: 11.5),
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
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: context.colors.primary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(fontSize: 11.5, color: context.colors.muted),
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
            Text(
              '本地目录与 WebDAV 统一在这里管理，不会出现在首页。',
              style: TextStyle(color: context.colors.muted, fontSize: 13),
            ),
            const SizedBox(height: 18),
            if (library.scanStatus == ScanStatus.scanning)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: context.colors.primarySoft,
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
                        style: TextStyle(
                          color: context.colors.primary,
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

  Widget _buildDanmaku() {
    return AnimatedBuilder(
      animation: MediaLibrary.instance,
      builder: (context, _) {
        final library = MediaLibrary.instance;
        if (!_danmakuFieldsFilled) {
          _danmakuProvider = library.danmakuProvider;
          _danmakuBaseUrlController.text = library.danmakuBaseUrl;
          _danmakuAppIdController.text = library.danmakuAppId ?? '';
          _danmakuAppSecretController.text = library.danmakuAppSecret ?? '';
          _danmakuFieldsFilled = true;
        }
        final custom = _danmakuProvider == DanmakuProvider.custom;
        return ListView(
          children: [
            Text('弹幕设置', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: context.colors.surface,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: context.colors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<DanmakuProvider>(
                      segments: const [
                        ButtonSegment(
                          value: DanmakuProvider.dandanplay,
                          icon: Icon(Icons.public_outlined),
                          label: Text('DanDanPlay'),
                        ),
                        ButtonSegment(
                          value: DanmakuProvider.custom,
                          icon: Icon(Icons.dns_outlined),
                          label: Text('御坂 / 自定义'),
                        ),
                      ],
                      selected: {_danmakuProvider},
                      onSelectionChanged: (value) {
                        setState(() {
                          _danmakuProvider = value.first;
                          if (_danmakuProvider == DanmakuProvider.dandanplay) {
                            _danmakuBaseUrlController.text =
                                DanmakuService.officialBaseUrl;
                          } else if (_danmakuBaseUrlController.text.trim() ==
                              DanmakuService.officialBaseUrl) {
                            _danmakuBaseUrlController.clear();
                          }
                        });
                      },
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Text(
                        custom ? '自托管服务' : 'DanDanPlay 凭据',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: library.hasDanmaku
                              ? context.colors.primarySoft
                              : context.colors.background,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          library.hasDanmaku ? '已配置' : '未配置',
                          style: TextStyle(
                            fontSize: 11,
                            color: library.hasDanmaku
                                ? context.colors.primary
                                : context.colors.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    custom
                        ? '填写御坂网络弹幕服务的完整接口地址，例如 '
                              'http://192.168.1.100:7768/api/v1/<Token>。'
                              '也可以填写其它兼容 DanDanPlay API 的服务。'
                        : '在 doc.dandanplay.com 开发者中心申请 AppId/AppSecret。'
                              '非商业项目可免费使用标准配额，凭据只保存在本机。',
                    style: TextStyle(
                      color: context.colors.muted,
                      fontSize: 12.5,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (custom)
                    TextField(
                      key: const ValueKey('danmaku-base-url'),
                      controller: _danmakuBaseUrlController,
                      spellCheckConfiguration:
                          const SpellCheckConfiguration.disabled(),
                      decoration: const InputDecoration(
                        labelText: '弹幕接口地址',
                        hintText: 'http://192.168.1.100:7768/api/v1/<Token>',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    )
                  else ...[
                    TextField(
                      key: const ValueKey('dandanplay-app-id'),
                      controller: _danmakuAppIdController,
                      spellCheckConfiguration:
                          const SpellCheckConfiguration.disabled(),
                      decoration: const InputDecoration(
                        labelText: 'AppId',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('dandanplay-app-secret'),
                      controller: _danmakuAppSecretController,
                      obscureText: _obscureDanmakuSecret,
                      spellCheckConfiguration:
                          const SpellCheckConfiguration.disabled(),
                      decoration: InputDecoration(
                        labelText: 'AppSecret',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        suffixIcon: IconButton(
                          onPressed: () => setState(
                            () =>
                                _obscureDanmakuSecret = !_obscureDanmakuSecret,
                          ),
                          icon: Icon(
                            _obscureDanmakuSecret
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  FilledButton.tonal(
                    key: const ValueKey('save-danmaku-settings'),
                    onPressed: () async {
                      final customUrl = _danmakuBaseUrlController.text.trim();
                      if (custom) {
                        final uri = Uri.tryParse(customUrl);
                        if (uri == null ||
                            !uri.hasScheme ||
                            uri.host.isEmpty ||
                            !const ['http', 'https'].contains(uri.scheme)) {
                          _showMessage('请填写有效的弹幕接口地址');
                          return;
                        }
                      }
                      await library.saveDanmakuSettings(
                        provider: _danmakuProvider,
                        baseUrl: custom
                            ? customUrl
                            : DanmakuService.officialBaseUrl,
                        appId: custom ? '' : _danmakuAppIdController.text,
                        appSecret: custom
                            ? ''
                            : _danmakuAppSecretController.text,
                      );
                      if (!context.mounted) return;
                      _showMessage(
                        library.hasDanmaku ? '弹幕凭据已保存' : '弹幕配置不完整，请检查',
                      );
                    },
                    child: const Text('保存弹幕设置'),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildAbout() {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: context.colors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: context.colors.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.movie_filter_rounded,
              size: 56,
              color: context.colors.primary,
            ),
            const SizedBox(height: 14),
            Text(
              '拾帧',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: context.colors.primary,
              ),
            ),
            Text(
              '拾帧',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: context.colors.primary,
              ),
            ),
            // 版本运行时读取构建注入值（CI 按 tag 注入 build-name），
            // 不再硬编码——否则发新版这里永远是旧数字。
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snapshot) {
                final info = snapshot.data;
                final platform = switch (Platform.operatingSystem) {
                  'windows' => 'Windows',
                  'macos' => 'macOS',
                  'android' => 'Android',
                  'ios' => 'iOS',
                  'linux' => 'Linux',
                  _ => Platform.operatingSystem,
                };
                return Text(
                  'Framelet ${info?.version ?? ''} · $platform',
                  style: TextStyle(color: context.colors.muted),
                );
              },
            ),
            const SizedBox(height: 18),
            const Text('拾起每一帧，让媒体库重新清晰。', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Future<void> _editSource({MediaSource? existing}) async {
    final result = await showDialog<(MediaSource, String?)>(
      context: context,
      builder: (_) => MediaSourceDialog(existing: existing),
    );
    if (result == null || !mounted) return;
    final (source, password) = result;
    await MediaLibrary.instance.addOrUpdateSource(source, password: password);
    final needsScan =
        existing == null ||
        existing.kind != source.kind ||
        existing.address != source.address;
    if (!mounted) return;
    if (needsScan) {
      _showMessage(existing == null ? '媒体源已保存，开始扫描…' : '媒体源已更新，开始重新扫描…');
      await _scanSource(source);
    } else {
      _showMessage('媒体源已更新');
    }
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

/// 未匹配内容区：列出没刮出来的条目，逐条手动匹配后才进入前端。
class _UnmatchedSection extends StatelessWidget {
  const _UnmatchedSection({required this.items});

  final List<ScannedVideo> items;

  Future<void> _match(BuildContext context, ScannedVideo item) async {
    final library = MediaLibrary.instance;
    final episodes = library.episodesOf(item);
    final parsed = ScraperService.parseTitle(item.title);
    final initialQuery = parsed.queries.isEmpty
        ? item.title
        : parsed.queries.first;
    final candidate = await showDialog<ScrapeCandidate>(
      context: context,
      builder: (_) => MatchSearchDialog(
        initialQuery: initialQuery,
        preferTv: episodes.length > 1,
      ),
    );
    if (candidate == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    await library.applyCandidate(item, episodes, candidate);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('「${candidate.name}」已匹配，已在前端展示')));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '未匹配内容（${items.length}）',
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            '这些没能自动匹配到 TMDB，暂不显示在前端。点「匹配」手动搜索选一下，匹配成功就会出现在海报墙上。',
            style: TextStyle(
              color: context.colors.muted,
              fontSize: 12,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 10),
          ...items.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: context.colors.text,
                          ),
                        ),
                        Text(
                          item.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: context.colors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    height: 34,
                    child: OutlinedButton.icon(
                      onPressed: () => _match(context, item),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: context.colors.primary,
                        side: BorderSide(color: context.colors.primary),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        textStyle: const TextStyle(fontSize: 12.5),
                      ),
                      icon: const Icon(Icons.manage_search_rounded, size: 16),
                      label: const Text('匹配'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
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
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: error != null
              ? context.colors.danger.withValues(alpha: 0.5)
              : context.colors.border,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: context.colors.primarySoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              source.isLocal ? Icons.folder_outlined : Icons.cloud_outlined,
              color: context.colors.primary,
            ),
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
                        color: context.colors.primarySoft,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        source.kindLabel,
                        style: TextStyle(
                          fontSize: 10,
                          color: context.colors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                Text(
                  source.location,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 5),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.colors.danger,
                    ),
                  )
                else
                  Row(
                    children: [
                      Icon(
                        Icons.circle,
                        size: 8,
                        color: connected
                            ? context.colors.success
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

class MediaSourceDialog extends StatefulWidget {
  const MediaSourceDialog({this.existing, super.key});

  final MediaSource? existing;

  @override
  State<MediaSourceDialog> createState() => _MediaSourceDialogState();
}

class _MediaSourceDialogState extends State<MediaSourceDialog> {
  final _formKey = GlobalKey<FormState>();
  late MediaSourceKind _kind = widget.existing?.kind ?? MediaSourceKind.webdav;
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
    final isLocal = _kind == MediaSourceKind.local;
    return AlertDialog(
      title: Text(widget.existing == null ? '添加媒体源' : '编辑媒体源'),
      content: SizedBox(
        width: 500,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<MediaSourceKind>(
                    segments: const [
                      ButtonSegment(
                        value: MediaSourceKind.local,
                        icon: Icon(Icons.folder_outlined),
                        label: Text('本地目录'),
                      ),
                      ButtonSegment(
                        value: MediaSourceKind.webdav,
                        icon: Icon(Icons.cloud_outlined),
                        label: Text('WebDAV'),
                      ),
                    ],
                    selected: {_kind},
                    onSelectionChanged: (value) {
                      setState(() {
                        _kind = value.first;
                        _testResult = null;
                        _testOk = false;
                      });
                    },
                  ),
                ),
                const SizedBox(height: 16),
                _field(
                  _nameController,
                  '显示名称',
                  '例如：家里的影音库',
                  key: const ValueKey('source-name'),
                ),
                const SizedBox(height: 14),
                if (isLocal)
                  TextFormField(
                    key: const ValueKey('source-local-path'),
                    controller: _addressController,
                    spellCheckConfiguration:
                        const SpellCheckConfiguration.disabled(),
                    validator: _validateLocalPath,
                    decoration: InputDecoration(
                      labelText: '目录路径',
                      hintText: r'例如：D:\Movies',
                      border: const OutlineInputBorder(),
                      suffixIcon: TextButton.icon(
                        onPressed: _pickDirectory,
                        icon: const Icon(Icons.folder_open_outlined, size: 18),
                        label: const Text('浏览'),
                      ),
                    ),
                  )
                else ...[
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
                    spellCheckConfiguration:
                        const SpellCheckConfiguration.disabled(),
                    validator: (value) {
                      if (widget.existing != null) return null;
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
                        onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                  ),
                ],
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
      return Text(
        '正在连接…',
        style: TextStyle(color: context.colors.muted, fontSize: 13),
      );
    }
    if (_testResult == null) {
      return Text(
        _testOk ? '连接成功' : '',
        style: TextStyle(color: context.colors.success, fontSize: 13),
      );
    }
    return Text(
      _testResult!,
      style: TextStyle(color: context.colors.danger, fontSize: 13),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  MediaSource _buildSource() {
    final existing = widget.existing;
    final isLocal = _kind == MediaSourceKind.local;
    final rawAddress = _addressController.text.trim();
    return MediaSource(
      id: existing?.id ?? MediaSource.newId(),
      name: _nameController.text.trim(),
      kind: _kind,
      address: isLocal
          ? rawAddress
          : rawAddress.replaceFirst(RegExp(r'/+$'), ''),
      username: isLocal ? '' : _usernameController.text.trim(),
      directory: isLocal || _directoryController.text.trim().isEmpty
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
    if (_kind == MediaSourceKind.local) {
      setState(() {
        _testing = true;
        _testResult = null;
        _testOk = false;
      });
      final error = await MediaLibrary.instance.testConnection(source, '');
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = error == null;
        _testResult = error;
      });
      return;
    }
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
    if (_kind == MediaSourceKind.local &&
        !Directory(_addressController.text.trim()).existsSync()) {
      setState(() {
        _testOk = false;
        _testResult = '目录不存在，请重新选择';
      });
      return;
    }
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
      spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
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

  String? _validateLocalPath(String? value) {
    final path = value?.trim() ?? '';
    if (path.isEmpty) return '请选择本地目录';
    if (!Directory(path).isAbsolute) return '请填写完整的绝对路径';
    return null;
  }

  Future<void> _pickDirectory() async {
    final selected = await getDirectoryPath(confirmButtonText: '选择目录');
    if (selected == null || !mounted) return;
    setState(() {
      _addressController.text = selected;
      if (_nameController.text.trim().isEmpty) {
        _nameController.text = _basename(selected);
      }
      _testResult = null;
      _testOk = false;
    });
  }

  String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    return parts.isEmpty ? '本地媒体库' : parts.last;
  }
}

/// 外观选项卡片：图标 + 界面缩略预览 + 名称，选中态用主色描边。
class _ThemeOptionTile extends StatelessWidget {
  const _ThemeOptionTile({
    required this.mode,
    required this.label,
    required this.icon,
    required this.selected,
    super.key,
  });

  final ThemeMode mode;
  final String label;
  final IconData icon;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => ThemeController.instance.setMode(mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          width: 172,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? colors.primarySoft : colors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? colors.primary.withValues(alpha: 0.45)
                  : colors.border,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: selected ? colors.primary : colors.iconMuted,
                  ),
                  const Spacer(),
                  if (selected)
                    Icon(
                      Icons.check_circle_rounded,
                      size: 16,
                      color: colors.primary,
                    ),
                ],
              ),
              const SizedBox(height: 10),
              _ThemePreview(mode: mode),
              const SizedBox(height: 9),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? colors.primary : colors.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 缩略预览：一块侧栏 + 两行内容条，按模式给出对应明暗。
class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.mode});

  final ThemeMode mode;

  static const _lightPage = Color(0xFFFFFFFF);
  static const _lightBar = Color(0xFFE3E3DA);
  static const _lightSide = Color(0xFFF5F6F8);
  static const _darkPage = Color(0xFF15171A);
  static const _darkBar = Color(0xFF4A5158);
  static const _darkSide = Color(0xFF1B1E22);

  @override
  Widget build(BuildContext context) {
    if (mode == ThemeMode.system) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: 54,
          child: Row(
            children: [
              Expanded(child: _panel(_lightSide, _lightPage, _lightBar)),
              Expanded(child: _panel(_darkSide, _darkPage, _darkBar)),
            ],
          ),
        ),
      );
    }
    final dark = mode == ThemeMode.dark;
    return _panel(
      dark ? _darkSide : _lightSide,
      dark ? _darkPage : _lightPage,
      dark ? _darkBar : _lightBar,
    );
  }

  Widget _panel(Color side, Color page, Color bar) {
    return Container(
      height: 54,
      decoration: BoxDecoration(
        color: page,
        border: Border.all(color: bar, width: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(width: 14, height: double.infinity, color: side),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _bar(bar, 0.62),
                const SizedBox(height: 5),
                _bar(bar, 0.42),
              ],
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _bar(Color color, double widthFactor) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: 5,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }
}
