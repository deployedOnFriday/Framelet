import 'dart:io';

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../core/utils/decode_width.dart';
import '../models/media_source.dart';
import '../services/media_library.dart';
import '../services/playback_history.dart';
import '../services/scraper_service.dart';
import '../services/webdav_service.dart';
import '../widgets/hide_media_action.dart';
import '../widgets/match_dialog.dart';
import 'player_page.dart';

/// 网易爆米花风格详情页：顶部剧照渐隐 + 双栏信息 + 横向选集 + 演员区。
///
/// 同一部剧有多季时按 TMDB ID 关联，顶部可切换季。
class DetailPage extends StatefulWidget {
  const DetailPage({required this.video, super.key});

  final ScannedVideo video;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  int _seasonIndex = 0;
  String? _versionPath;

  /// 按季补全简介/首播日期/单集时长；只用于展示，不写回媒体库。
  final Map<String, ({String? overview, String? airDate, double? runtimeSec})>
  _seasonInfo = {};
  final Set<String> _seasonInfoLoading = {};

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        MediaLibrary.instance,
        PlaybackHistory.instance,
      ]),
      builder: (context, _) {
        final library = MediaLibrary.instance;
        final current = library.resolveAggregated(widget.video);
        final isMovie = current.kind == MediaKind.movie;
        final versions = isMovie
            ? library.versionsOf(current)
            : const <ScannedVideo>[];
        final selectedVersion = isMovie ? _selectedVersion(versions) : null;
        final seasons = isMovie
            ? <ScannedVideo>[current]
            : library.seasonsOf(current);
        final seasonIndex = _seasonIndex.clamp(0, seasons.length - 1);
        final season = seasons[seasonIndex];
        final playbackVideo = isMovie ? (selectedVersion ?? current) : season;
        final source = library.sourceById(playbackVideo.sourceId);
        final episodes = isMovie
            ? <ScannedVideo>[playbackVideo]
            : library.episodesOf(season);
        final isSeries = episodes.length > 1;
        final normalizedTitle = seasons.length > 1
            ? MediaLibrary.normalizeSeriesTitle(current.title)
            : current.title;
        final displayTitle = normalizedTitle.trim().isEmpty
            ? current.title
            : normalizedTitle;
        final info = _seasonInfo[_seasonKey(season)];
        final hero = _seasonView(playbackVideo, current).copyWith(
          summary: info?.overview,
          releaseDate: info?.airDate,
          runtimeSec: info?.runtimeSec,
        );
        if (seasons.length > 1 && season.tmdbId != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _ensureSeasonInfo(season);
          });
        }
        void Function(int)? onSeasonSelected;
        if (seasons.length > 1) {
          onSeasonSelected = (index) => setState(() => _seasonIndex = index);
        }

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onSecondaryTapDown: (details) =>
              _showContextMenu(context, details.globalPosition, current),
          child: Scaffold(
            backgroundColor: context.colors.background,
            body: Stack(
              children: [
                SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _HeroSection(
                        title: displayTitle,
                        video: hero,
                        source: source,
                        episodes: episodes,
                        isSeries: isSeries,
                      ),
                      const SizedBox(height: 30),
                      if (isSeries) ...[
                        _EpisodeCarousel(
                          episodes: episodes,
                          posterPath: season.posterPath,
                          seasonLabel:
                              '第 ${MediaLibrary.seasonOf(seasons[seasonIndex])} 季',
                          seasons: seasons,
                          seasonIndex: seasonIndex,
                          onSeasonSelected: onSeasonSelected,
                        ),
                      ] else if (versions.length > 1) ...[
                        _VersionCarousel(
                          versions: versions,
                          selectedPath: selectedVersion?.path,
                          onSelected: (path) =>
                              setState(() => _versionPath = path),
                        ),
                      ] else
                        const SizedBox(height: 20),
                      const SizedBox(height: 34),
                      if (hero.cast.isNotEmpty) ...[
                        _CastSection(cast: hero.cast),
                        const SizedBox(height: 32),
                      ],
                      _FileInfo(
                        video: playbackVideo,
                        source: source,
                        episodes: episodes,
                      ),
                      const SizedBox(height: 44),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 优先沿用当前选择，其次恢复最近播放过的版本，最后取最高画质。
  ScannedVideo? _selectedVersion(List<ScannedVideo> versions) {
    if (versions.isEmpty) return null;
    final path = _versionPath;
    if (path != null) {
      for (final version in versions) {
        if (version.path == path) return version;
      }
    }
    for (final entry in PlaybackHistory.instance.entries) {
      for (final version in versions) {
        if (entry.sourceId == version.sourceId && entry.path == version.path) {
          return version;
        }
      }
    }
    return versions.first;
  }

  /// 右键菜单：目前提供「隐藏该影片」，隐藏后从海报墙移除。
  Future<void> _showContextMenu(
    BuildContext context,
    Offset globalPosition,
    ScannedVideo target,
  ) async {
    await showMediaContextMenu(
      context: context,
      globalPosition: globalPosition,
      video: target,
      displayName: target.title,
      popOnHidden: true,
    );
  }

  /// 季详情优先，缺失字段回退到整剧条目。
  static ScannedVideo _seasonView(ScannedVideo season, ScannedVideo show) {
    return season.copyWith(
      summary: season.summary ?? show.summary,
      backdropPath: season.backdropPath ?? show.backdropPath,
      rating: season.rating ?? show.rating,
      genres: season.genres.isEmpty ? show.genres : null,
      cast: season.cast.isEmpty ? show.cast : null,
      releaseDate: season.releaseDate ?? show.releaseDate,
      runtimeSec: season.runtimeSec ?? show.runtimeSec,
    );
  }

  String _seasonKey(ScannedVideo season) =>
      '${season.tmdbId}_${MediaLibrary.seasonOf(season)}';

  void _ensureSeasonInfo(ScannedVideo season) {
    final tmdbId = season.tmdbId;
    if (tmdbId == null) return;
    final key = _seasonKey(season);
    if (_seasonInfo.containsKey(key) || !_seasonInfoLoading.add(key)) return;
    final seasonNumber = MediaLibrary.seasonOf(season);
    ScraperService.fetchSeasonDetails(
      tvId: tmdbId,
      seasonNumber: seasonNumber,
    ).then((details) {
      if (!mounted) return;
      setState(() {
        _seasonInfoLoading.remove(key);
        _seasonInfo[key] = (
          overview: details?.overview,
          airDate: details?.airDate,
          runtimeSec: details?.runtimeSec,
        );
      });
    });
  }
}

class _HeroSection extends StatelessWidget {
  const _HeroSection({
    required this.title,
    required this.video,
    required this.source,
    required this.episodes,
    required this.isSeries,
  });

  /// 展示用剧名（多季时是去掉季号的整剧名）。
  final String title;
  final ScannedVideo video;
  final MediaSource? source;
  final List<ScannedVideo> episodes;
  final bool isSeries;

  ScannedVideo _currentEpisode() {
    if (episodes.isEmpty) return video;
    for (final episode in episodes) {
      final entry = PlaybackHistory.instance.entryOf(
        episode.sourceId,
        episode.path,
      );
      if (entry != null && !entry.finished && entry.positionSec > 1) {
        return episode;
      }
    }
    return episodes.first;
  }

  /// 只有播放历史里记录过真实时长时才显示，避免拿 TMDB 时长冒充文件时长。
  double _knownDuration() {
    final episode = _currentEpisode();
    final entry = PlaybackHistory.instance.entryOf(
      episode.sourceId,
      episode.path,
    );
    return entry?.durationSec ?? 0;
  }

  /// 详情页头图的兜底渐变（背景图缺失/未加载时）。
  Widget _backdropGradient(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: _paletteFor(context, video.title),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final currentEpisode = _currentEpisode();
    final knownDuration = _knownDuration();
    final backdropPath = video.backdropPath;

    Widget playButton(BuildContext context) => SizedBox(
      height: 44,
      width: 260,
      child: ElevatedButton.icon(
        key: const ValueKey('detail-play'),
        onPressed: episodes.isEmpty
            ? null
            : () {
                final entry = PlaybackHistory.instance.entryOf(
                  currentEpisode.sourceId,
                  currentEpisode.path,
                );
                final resume =
                    entry != null && !entry.finished && entry.positionSec > 1;
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PlayerPage(
                      video: currentEpisode,
                      startPosition: resume ? entry.positionSec : null,
                      episodes: episodes,
                    ),
                  ),
                );
              },
        style: ElevatedButton.styleFrom(
          // 浅色下是深色药丸，暗色下反转为浅色药丸，保持主 CTA 的对比度
          backgroundColor: _isDark(context)
              ? context.colors.text
              : const Color(0xFF141414),
          foregroundColor: _isDark(context)
              ? context.colors.background
              : Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        icon: const Icon(Icons.play_arrow, size: 20),
        label: Text(
          [
            isSeries ? '播放 第 ${episodes.indexOf(currentEpisode) + 1} 集' : '播放',
            if (knownDuration > 0) _formatDuration(knownDuration),
          ].join('  '),
        ),
      ),
    );

    return SizedBox(
      height: 460,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (backdropPath != null)
            LayoutBuilder(
              builder: (context, constraints) {
                final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
                final cacheWidth = decodeCacheWidth(
                  constraints.maxWidth,
                  dpr,
                  step: 96,
                  min: 192,
                  max: 2400,
                );
                return Image.file(
                  File(backdropPath),
                  fit: BoxFit.cover,
                  cacheWidth: cacheWidth,
                  alignment: Alignment.topCenter,
                  // 文件缺失/损坏时回退到标题调色板渐变
                  errorBuilder: (_, _, _) => _backdropGradient(context),
                );
              },
            )
          else
            _backdropGradient(context),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.0, 0.55, 0.85, 1.0],
                colors: [
                  context.colors.background.withValues(alpha: 0),
                  context.colors.background.withValues(alpha: 0),
                  context.colors.background.withValues(alpha: 0.85),
                  context.colors.background,
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 20, 32, 32),
            child: Column(
              children: [
                Row(
                  children: [
                    _GhostButton(
                      icon: Icons.arrow_back_rounded,
                      label: '返回',
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const Spacer(),
                    SizedBox(
                      height: 40,
                      child: OutlinedButton.icon(
                        key: const ValueKey('manual-match'),
                        onPressed: () => _matchManually(context),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: context.colors.text,
                          side: BorderSide(color: context.colors.border),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        icon: const Icon(Icons.manage_search_rounded, size: 18),
                        label: const Text('修正匹配'),
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    SizedBox(
                      width: 280,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: context.colors.text,
                            ),
                          ),
                          const SizedBox(height: 16),
                          playButton(context),
                        ],
                      ),
                    ),
                    const SizedBox(width: 40),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Wrap(
                            spacing: 0,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              for (final (index, item) in _metaItems(
                                context,
                              ).indexed) ...[
                                if (index > 0) const _MetadataDivider(),
                                item,
                              ],
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (video.summary != null &&
                              video.summary!.isNotEmpty)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(
                                  child: Text(
                                    video.summary!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      color: context.colors.text.withValues(
                                        alpha: 0.82,
                                      ),
                                      height: 1.55,
                                      decoration: TextDecoration.none,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                GestureDetector(
                                  onTap: () => _showFullSummary(context),
                                  child: Text(
                                    '更多',
                                    style: TextStyle(
                                      color: context.colors.primary,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showFullSummary(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(video.summary ?? '')),
        actions: [
          TextButton(
            onPressed: Navigator.of(context).pop,
            child: const Text('收起'),
          ),
        ],
      ),
    );
  }

  List<Widget> _metaItems(BuildContext context) {
    final items = <Widget>[];
    final rating = video.rating?.trim() ?? '';
    if (rating.isNotEmpty) {
      items.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.star_rounded, color: context.colors.accent, size: 18),
            const SizedBox(width: 3),
            Text(
              rating,
              style: TextStyle(
                color: context.colors.accent,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }
    final year = _yearOf(video);
    if (year != null) items.add(_MetadataText(year));
    if (isSeries) items.add(_MetadataText('共 ${episodes.length} 集'));
    final runtime = video.runtimeSec;
    if (runtime != null && runtime > 0) {
      final minutes = (runtime / 60).round();
      if (minutes > 0) {
        items.add(
          _MetadataText(isSeries ? '每集约 $minutes 分钟' : '片长 $minutes 分钟'),
        );
      }
    }
    if (video.genres.isEmpty) {
      items.add(const _MetadataText('剧情'));
    } else {
      items.add(_MetadataText(video.genres.join(' ')));
    }
    return items;
  }

  Future<void> _matchManually(BuildContext context) async {
    final sourcePath = episodes.isNotEmpty ? episodes.first.path : video.path;
    final suggested = MediaLibrary.suggestedQueryForPath(sourcePath);
    final parsed = ScraperService.parseTitle(title);
    final query =
        suggested ?? (parsed.queries.isEmpty ? title : parsed.queries.first);
    final candidate = await showDialog<ScrapeCandidate>(
      context: context,
      builder: (_) =>
          MatchSearchDialog(initialQuery: query, preferTv: isSeries),
    );
    if (candidate == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final poster = await MediaLibrary.instance.applyCandidate(
      video,
      episodes,
      candidate,
    );
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            poster != null
                ? '已应用「${candidate.name}」的海报与信息'
                : '已应用「${candidate.name}」的信息（未取到海报）',
          ),
        ),
      );
  }

  static String _formatDuration(double sec) {
    if (sec <= 0) return '';
    return '${(sec / 60).round()} 分钟';
  }

  List<Color> _paletteFor(BuildContext context, String title) {
    final palettes = Theme.of(context).brightness == Brightness.dark
        ? const <List<Color>>[
            [Color(0xFF1C2A31), Color(0xFF243139)],
            [Color(0xFF2B241D), Color(0xFF332A22)],
            [Color(0xFF222D26), Color(0xFF2A372E)],
            [Color(0xFF2A2433), Color(0xFF332B3D)],
          ]
        : const <List<Color>>[
            [Color(0xFFDCEDF7), Color(0xFFD9E2F5)],
            [Color(0xFFF4E8D8), Color(0xFFEFDCD2)],
            [Color(0xFFE7EFE5), Color(0xFFDDE9E2)],
            [Color(0xFFF0E7F2), Color(0xFFE7DFF0)],
          ];
    var hash = 0;
    for (final code in title.codeUnits) {
      hash = (hash * 31 + code) & 0x7FFFFFFF;
    }
    return palettes[hash % palettes.length];
  }
}

class _MetadataText extends StatelessWidget {
  const _MetadataText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(fontSize: 13, color: context.colors.muted),
    );
  }
}

class _MetadataDivider extends StatelessWidget {
  const _MetadataDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Text(
        '|',
        style: TextStyle(fontSize: 12, color: context.colors.border),
      ),
    );
  }
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.colors.surface.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: context.colors.text),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(color: context.colors.text, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EpisodeCarousel extends StatefulWidget {
  const _EpisodeCarousel({
    required this.episodes,
    required this.seasonLabel,
    this.posterPath,
    this.seasons = const [],
    this.seasonIndex = 0,
    this.onSeasonSelected,
  });

  final List<ScannedVideo> episodes;

  /// 剧集海报——花絮卡片没有独立缩略图时用它兜底。
  final String? posterPath;

  /// 季标题（如「第 8 季」）；花絮归在该季内部。
  final String seasonLabel;

  /// 多季时用于在选集标题处直接切换季。
  final List<ScannedVideo> seasons;
  final int seasonIndex;
  final ValueChanged<int>? onSeasonSelected;

  @override
  State<_EpisodeCarousel> createState() => _EpisodeCarouselState();
}

class _EpisodeCarouselState extends State<_EpisodeCarousel> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scroll(bool forward) {
    if (!_controller.hasClients) return;
    final target = (_controller.offset + (forward ? 660 : -660)).clamp(
      0.0,
      _controller.position.maxScrollExtent,
    );
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 正片与花絮分开：花絮（精编回顾/集结篇等）放独立区块
    final mainEpisodes = widget.episodes
        .where((e) => !WebDavService.isExtraFile(e.title))
        .toList();
    final extras = widget.episodes
        .where((e) => WebDavService.isExtraFile(e.title))
        .toList();
    final shown = mainEpisodes.isEmpty ? widget.episodes : mainEpisodes;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (widget.seasons.length > 1 && widget.onSeasonSelected != null)
                _SeasonDropdown(
                  seasons: widget.seasons,
                  currentIndex: widget.seasonIndex,
                  onSelected: widget.onSeasonSelected!,
                )
              else
                Text(
                  widget.seasonLabel,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: context.colors.text,
                  ),
                ),
              const SizedBox(width: 10),
              Text(
                '共 ${shown.length} 集',
                style: TextStyle(fontSize: 12, color: context.colors.muted),
              ),
              const Spacer(),
              Row(
                children: [
                  _CircleArrow(
                    onTap: () => _scroll(false),
                    icon: Icons.arrow_left,
                  ),
                  const SizedBox(width: 10),
                  _CircleArrow(
                    onTap: () => _scroll(true),
                    icon: Icons.arrow_right,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 148,
            child: ListView.separated(
              clipBehavior: Clip.none,
              controller: _controller,
              scrollDirection: Axis.horizontal,
              itemCount: shown.length,
              separatorBuilder: (_, _) => const SizedBox(width: 16),
              itemBuilder: (context, index) => _EpisodeCard(
                episode: shown[index],
                index: index,
                playlist: shown,
              ),
            ),
          ),
          if (extras.isNotEmpty) ...[
            const SizedBox(height: 26),
            Row(
              children: [
                Text(
                  '花絮与相关',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: context.colors.text,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '共 ${extras.length} 个',
                  style: TextStyle(fontSize: 12, color: context.colors.muted),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 108,
              child: ListView.separated(
                clipBehavior: Clip.none,
                scrollDirection: Axis.horizontal,
                itemCount: extras.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) => _ExtraCard(
                  episode: extras[index],
                  playlist: shown,
                  posterPath: widget.posterPath,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 电影多版本列表：与剧集选集相同的横向卡片，卡片显示版本标签与文件大小。
class _VersionCarousel extends StatefulWidget {
  const _VersionCarousel({
    required this.versions,
    required this.selectedPath,
    required this.onSelected,
  });

  final List<ScannedVideo> versions;
  final String? selectedPath;
  final ValueChanged<String> onSelected;

  @override
  State<_VersionCarousel> createState() => _VersionCarouselState();
}

class _VersionCarouselState extends State<_VersionCarousel> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scroll(bool forward) {
    if (!_controller.hasClients) return;
    final target = (_controller.offset + (forward ? 660 : -660)).clamp(
      0.0,
      _controller.position.maxScrollExtent,
    );
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  void _play(BuildContext context, ScannedVideo version) {
    widget.onSelected(version.path);
    final entry = PlaybackHistory.instance.entryOf(
      version.sourceId,
      version.path,
    );
    final resume = entry != null && !entry.finished && entry.positionSec > 1;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          video: version,
          startPosition: resume ? entry.positionSec : null,
          episodes: [version],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '版本',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: context.colors.text,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '共 ${widget.versions.length} 个版本',
                style: TextStyle(fontSize: 12, color: context.colors.muted),
              ),
              const Spacer(),
              Row(
                children: [
                  _CircleArrow(
                    onTap: () => _scroll(false),
                    icon: Icons.arrow_left,
                  ),
                  const SizedBox(width: 10),
                  _CircleArrow(
                    onTap: () => _scroll(true),
                    icon: Icons.arrow_right,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 166,
            child: ListView.separated(
              clipBehavior: Clip.none,
              controller: _controller,
              scrollDirection: Axis.horizontal,
              itemCount: widget.versions.length,
              separatorBuilder: (_, _) => const SizedBox(width: 16),
              itemBuilder: (context, index) {
                final version = widget.versions[index];
                return _VersionCard(
                  version: version,
                  selected: version.path == widget.selectedPath,
                  onSelected: () => widget.onSelected(version.path),
                  onPlay: () => _play(context, version),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _VersionCard extends StatelessWidget {
  const _VersionCard({
    required this.version,
    required this.selected,
    required this.onSelected,
    required this.onPlay,
  });

  final ScannedVideo version;
  final bool selected;
  final VoidCallback onSelected;
  final VoidCallback onPlay;

  Widget get _placeholder => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(colors: [Color(0xFF48506A), Color(0xFF252B3D)]),
    ),
    child: Center(
      child: Icon(Icons.movie_outlined, color: Colors.white38, size: 28),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final entry = PlaybackHistory.instance.entryOf(
      version.sourceId,
      version.path,
    );
    final progress = entry?.progress ?? 0;
    final thumbnailPath = version.stillPath ?? version.backdropPath;
    final label = MediaLibrary.versionLabelOf(version);
    final sizeLabel = version.sizeBytes > 0 ? version.sizeLabel : null;
    return SizedBox(
      width: 250,
      child: Tooltip(
        message: version.path,
        child: InkWell(
          key: ValueKey('detail-version-${version.path}'),
          onTap: onSelected,
          borderRadius: BorderRadius.circular(9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 115,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: selected
                        ? context.colors.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (thumbnailPath != null)
                      Image.file(
                        File(thumbnailPath),
                        fit: BoxFit.cover,
                        cacheWidth:
                            (250 *
                                    (MediaQuery.maybeDevicePixelRatioOf(
                                          context,
                                        ) ??
                                        1))
                                .round(),
                        alignment: Alignment.topCenter,
                        errorBuilder: (context, error, stackTrace) =>
                            _placeholder,
                      )
                    else
                      _placeholder,
                    if (selected)
                      Align(
                        alignment: Alignment.topRight,
                        child: Container(
                          margin: const EdgeInsets.all(6),
                          padding: const EdgeInsets.all(2),
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.check_rounded,
                            size: 14,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    Align(
                      alignment: Alignment.bottomRight,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Material(
                          color: Colors.black54,
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            key: ValueKey(
                              'detail-version-play-${version.path}',
                            ),
                            onTap: onPlay,
                            child: const SizedBox(
                              width: 32,
                              height: 32,
                              child: Icon(
                                Icons.play_arrow_rounded,
                                size: 20,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (progress > 0)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: LinearProgressIndicator(
                          value: entry!.finished ? 1 : progress,
                          minHeight: 3,
                          backgroundColor: Colors.black26,
                          valueColor: AlwaysStoppedAnimation(
                            context.colors.primary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.3,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? context.colors.primary
                      : context.colors.text,
                ),
              ),
              if (sizeLabel != null) ...[
                const SizedBox(height: 1),
                Text(
                  sizeLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.2,
                    color: context.colors.muted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 季切换下拉框：收起时只占一个圆角按钮，展开后是圆角菜单。
class _SeasonDropdown extends StatelessWidget {
  const _SeasonDropdown({
    required this.seasons,
    required this.currentIndex,
    required this.onSelected,
  });

  final List<ScannedVideo> seasons;
  final int currentIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    String labelOf(int index) => '第 ${MediaLibrary.seasonOf(seasons[index])} 季';
    return MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(colors.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(10),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 6),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: colors.border),
          ),
        ),
      ),
      menuChildren: [
        for (var i = 0; i < seasons.length; i++)
          SizedBox(
            width: 200,
            child: MenuItemButton(
              onPressed: () {
                if (i != currentIndex) onSelected(i);
              },
              style: ButtonStyle(
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
                minimumSize: const WidgetStatePropertyAll(Size.zero),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                backgroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.hovered) ||
                      states.contains(WidgetState.focused)) {
                    return colors.hover;
                  }
                  return Colors.transparent;
                }),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      labelOf(i),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: i == currentIndex
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: i == currentIndex ? colors.primary : colors.text,
                      ),
                    ),
                  ),
                  if (i == currentIndex)
                    Icon(Icons.check_rounded, size: 16, color: colors.primary)
                  else
                    Text(
                      '${seasons[i].episodeCount} 集',
                      style: TextStyle(fontSize: 11.5, color: colors.muted),
                    ),
                ],
              ),
            ),
          ),
      ],
      builder: (context, controller, _) {
        final open = controller.isOpen;
        return Material(
          color: colors.surface,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => open ? controller.close() : controller.open(),
            child: Container(
              height: 38,
              padding: const EdgeInsets.only(left: 14, right: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: open
                      ? colors.primary.withValues(alpha: 0.55)
                      : colors.border,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    labelOf(currentIndex),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colors.text,
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: colors.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CircleArrow extends StatelessWidget {
  const _CircleArrow({required this.onTap, required this.icon});

  final VoidCallback onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.colors.hover,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(icon, size: 18, color: context.colors.muted),
        ),
      ),
    );
  }
}

class _EpisodeCard extends StatelessWidget {
  const _EpisodeCard({
    required this.episode,
    required this.index,
    required this.playlist,
  });

  final ScannedVideo episode;
  final int index;

  /// 本季所有正片（播放器内选集用）。
  final List<ScannedVideo> playlist;

  Widget get _placeholder => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(colors: [Color(0xFF48506A), Color(0xFF252B3D)]),
    ),
    child: Center(
      child: Text(
        '第 ${index + 1} 集',
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final entry = PlaybackHistory.instance.entryOf(
      episode.sourceId,
      episode.path,
    );
    final progress = entry?.progress ?? 0;
    final thumbnailPath = episode.stillPath ?? episode.backdropPath;
    return Material(
      color: Colors.transparent,
      child: SizedBox(
        width: 200,
        child: InkWell(
          onTap: () => _play(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 200,
                  height: 115,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 不做 existsSync 预检：集列表滚动时每张卡片都会
                      // 触发同步磁盘 IO；缺失/损坏由 errorBuilder 兜底。
                      if (thumbnailPath != null)
                        Image.file(
                          File(thumbnailPath),
                          fit: BoxFit.cover,
                          cacheWidth:
                              (200 *
                                      (MediaQuery.maybeDevicePixelRatioOf(
                                            context,
                                          ) ??
                                          1))
                                  .round(),
                          alignment: Alignment.topCenter,
                          errorBuilder: (context, error, stackTrace) =>
                              _placeholder,
                        )
                      else
                        _placeholder,
                      if (progress > 0)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: LinearProgressIndicator(
                            value: entry!.finished ? 1 : progress,
                            minHeight: 3,
                            backgroundColor: Colors.black26,
                            valueColor: AlwaysStoppedAnimation(
                              context.colors.primary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                () {
                  final title = episode.episodeTitle;
                  // 占位集名（第1话/第2集/Episode 1）没有信息量，只显示集号
                  if (title != null &&
                      title.trim().isNotEmpty &&
                      !MediaLibrary.isPlaceholderEpisodeTitle(title)) {
                    return '${index + 1}. $title';
                  }
                  return '第 ${index + 1} 集';
                }(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: context.colors.text),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _play(BuildContext context) {
    final entry = PlaybackHistory.instance.entryOf(
      episode.sourceId,
      episode.path,
    );
    final resume = entry != null && !entry.finished && entry.positionSec > 1;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          video: episode,
          startPosition: resume ? entry.positionSec : null,
          episodes: playlist,
        ),
      ),
    );
  }
}

class _CastSection extends StatelessWidget {
  const _CastSection({required this.cast});

  final List<CastMember> cast;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '相关演员',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: context.colors.text,
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 20,
            runSpacing: 18,
            children: [
              for (final member in cast)
                SizedBox(
                  width: 90,
                  child: Column(
                    children: [
                      _CastAvatar(member: member),
                      const SizedBox(height: 8),
                      Text(
                        member.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: context.colors.text,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        member.role,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.colors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 演员头像走刮削服务的下载/缓存通道，避免 NetworkImage 在受限网络下全空。
class _CastAvatar extends StatefulWidget {
  const _CastAvatar({required this.member});

  final CastMember member;

  @override
  State<_CastAvatar> createState() => _CastAvatarState();
}

class _CastAvatarState extends State<_CastAvatar> {
  Future<String?>? _photoFuture;

  @override
  void initState() {
    super.initState();
    final url = widget.member.photoUrl;
    if (url != null) {
      _photoFuture = ScraperService.downloadPoster(
        url,
        cacheKey: 'cast_${widget.member.name}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _photoFuture,
      builder: (context, snapshot) {
        final path = snapshot.data;
        return CircleAvatar(
          radius: 42,
          backgroundColor: context.colors.hover,
          backgroundImage: path == null ? null : FileImage(File(path)),
          child: path == null
              ? Icon(Icons.person, size: 48, color: context.colors.iconMuted)
              : null,
        );
      },
    );
  }
}

class _FileInfo extends StatelessWidget {
  const _FileInfo({
    required this.video,
    required this.source,
    required this.episodes,
  });

  final ScannedVideo video;
  final MediaSource? source;
  final List<ScannedVideo> episodes;

  @override
  Widget build(BuildContext context) {
    final current = episodes.isEmpty ? video : episodes.first;
    final sizeMb = current.sizeBytes / (1024 * 1024);
    final sizeLabel = sizeMb >= 1024
        ? '${(sizeMb / 1024).toStringAsFixed(1)} GB'
        : '${sizeMb.toStringAsFixed(0)} MB';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: context.colors.border, thickness: 1, height: 1),
          const SizedBox(height: 16),
          Text(
            current.title,
            style: TextStyle(fontSize: 12, color: context.colors.muted),
          ),
          const SizedBox(height: 6),
          Text(
            '${source?.name ?? '媒体库'} · ${current.path}',
            style: TextStyle(fontSize: 12, color: context.colors.muted),
          ),
          const SizedBox(height: 6),
          Text(
            sizeLabel,
            style: TextStyle(fontSize: 12, color: context.colors.muted),
          ),
        ],
      ),
    );
  }
}

/// 花絮/相关视频小卡片（较小，无集号）。
class _ExtraCard extends StatelessWidget {
  const _ExtraCard({
    required this.episode,
    required this.playlist,
    this.posterPath,
  });

  final ScannedVideo episode;

  /// 本季所有正片（播放器内选集用）。
  final List<ScannedVideo> playlist;

  /// 花絮没有独立缩略图，用剧集海报兜底。
  final String? posterPath;

  @override
  Widget build(BuildContext context) {
    final entry = PlaybackHistory.instance.entryOf(
      episode.sourceId,
      episode.path,
    );
    return GestureDetector(
      onTap: () {
        final resume =
            entry != null && !entry.finished && entry.positionSec > 1;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PlayerPage(
              video: episode,
              startPosition: resume ? entry.positionSec : null,
              episodes: playlist,
            ),
          ),
        );
      },
      child: Container(
        width: 150,
        decoration: BoxDecoration(
          color: context.colors.hover,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(10),
              ),
              child: SizedBox(
                height: 74,
                width: double.infinity,
                // 不做 existsSync 预检，缺失/损坏由 errorBuilder 兜底
                child: posterPath != null
                    ? Image.file(
                        File(posterPath!),
                        fit: BoxFit.cover,
                        cacheWidth:
                            (150 *
                                    (MediaQuery.maybeDevicePixelRatioOf(
                                          context,
                                        ) ??
                                        1))
                                .round(),
                        color: Colors.black.withValues(alpha: 0.25),
                        colorBlendMode: BlendMode.darken,
                        errorBuilder: (_, _, _) => ColoredBox(
                          color: context.colors.border,
                          child: Icon(
                            Icons.movie_filter_outlined,
                            size: 20,
                            color: context.colors.iconMuted,
                          ),
                        ),
                      )
                    : ColoredBox(
                        color: context.colors.border,
                        child: Icon(
                          Icons.movie_filter_outlined,
                          size: 20,
                          color: context.colors.iconMuted,
                        ),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Text(
                episode.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: context.colors.text,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 当前是否暗色主题（少量需要反转对比度的地方用）。
bool _isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

/// 影片年份：优先 TMDB 首播/上映年份，回退文件修改时间年份。
String? _yearOf(ScannedVideo video) {
  final release = video.releaseDate;
  if (release != null && release.trim().length >= 4) {
    return release.trim().substring(0, 4);
  }
  if (video.modified != null) return '${video.modified!.year}';
  return null;
}
