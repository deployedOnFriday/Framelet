import 'dart:io';

import 'package:flutter/material.dart';

import '../models/media_source.dart';
import '../services/media_library.dart';
import '../services/playback_history.dart';
import '../services/scraper_service.dart';
import '../services/webdav_service.dart';
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
        final seasons = library.seasonsOf(current);
        final season = seasons[_seasonIndex.clamp(0, seasons.length - 1)];
        final source = library.sourceById(season.sourceId);
        final episodes = library.episodesOf(season);
        final isSeries = episodes.length > 1;
        void Function(int)? onSeasonSelected;
        if (seasons.length > 1) {
          onSeasonSelected = (index) => setState(() => _seasonIndex = index);
        }

        return Scaffold(
          backgroundColor: Colors.white,
          body: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _HeroSection(
                  video: current,
                  source: source,
                  episodes: episodes,
                  isSeries: isSeries,
                  seasons: seasons,
                  onSeasonSelected: onSeasonSelected ?? (_) {},
                ),
                const SizedBox(height: 30),
                if (isSeries) ...[
                  if (seasons.length > 1)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(32, 0, 32, 16),
                      child: Row(
                        children: [
                          _SeasonDropdown(
                            seasons: seasons,
                            currentIndex: _seasonIndex,
                            onSelected: (i) => onSeasonSelected!(i),
                          ),
                        ],
                      ),
                    ),
                  _EpisodeCarousel(
                    episodes: episodes,
                    posterPath: season.posterPath,
                    seasonLabel:
                        '第 ${MediaLibrary.seasonOf(seasons[_seasonIndex])} 季',
                  ),
                ] else
                  const SizedBox(height: 20),
                const SizedBox(height: 34),
                if (current.cast.isNotEmpty) ...[
                  _CastSection(cast: current.cast),
                  const SizedBox(height: 32),
                ],
                _FileInfo(video: season, source: source, episodes: episodes),
                const SizedBox(height: 44),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _HeroSection extends StatelessWidget {
  const _HeroSection({
    required this.video,
    required this.source,
    required this.episodes,
    required this.isSeries,
    required this.seasons,
    required this.onSeasonSelected,
  });

  final ScannedVideo video;
  final MediaSource? source;
  final List<ScannedVideo> episodes;
  final bool isSeries;

  /// 多季时非空：季列表（含当前内容）与切换回调。
  final List<ScannedVideo> seasons;
  final ValueChanged<int> onSeasonSelected;

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

  double _currentDuration() {
    final episode = _currentEpisode();
    final entry = PlaybackHistory.instance.entryOf(
      episode.sourceId,
      episode.path,
    );
    final duration = entry?.durationSec ?? 0;
    return duration > 0 ? duration : (video.runtimeSec ?? 0);
  }

  @override
  Widget build(BuildContext context) {
    final currentEpisode = _currentEpisode();
    final duration = _currentDuration();
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
                    ),
                  ),
                );
              },
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF141414),
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        icon: const Icon(Icons.play_arrow, size: 20),
        label: Text(
          isSeries
              ? '播放 第 ${episodes.indexOf(currentEpisode) + 1} 集 ${_formatDuration(duration)}'
              : '播放 ${_formatDuration(duration)}',
        ),
      ),
    );

    return SizedBox(
      height: 460,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (backdropPath != null && File(backdropPath).existsSync())
            Image.file(
              File(backdropPath),
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, _, _) =>
                  Container(color: const Color(0xFFEFF1F4)),
            )
          else
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: _paletteFor(video.title),
                ),
              ),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.0, 0.55, 0.85, 1.0],
                colors: [
                  Color(0x00FFFFFF),
                  Color(0x00FFFFFF),
                  Color(0xD9FFFFFF),
                  Colors.white,
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
                          foregroundColor: const Color(0xFF333333),
                          side: BorderSide(
                            color: Colors.black.withValues(alpha: 0.12),
                          ),
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
                            video.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1A1A1A),
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
                            children: [
                              if (video.rating != null) ...[
                                const Icon(
                                  Icons.star_rounded,
                                  color: Color(0xFFF5A623),
                                  size: 18,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  video.rating!,
                                  style: const TextStyle(
                                    color: Color(0xFFF5A623),
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const _MetadataDivider(),
                              ],
                              if (_yearOf(video) != null)
                                _MetadataText(_yearOf(video)!),
                              if (isSeries)
                                _MetadataText(
                                  '共 ${episodes.length} 集（库中有 ${episodes.length} 集）',
                                ),
                              if (video.genres.isEmpty) _MetadataText('剧情'),
                              if (video.genres.isNotEmpty)
                                _MetadataText(video.genres.join(' ')),
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
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: Color(0xFF888888),
                                      height: 1.5,
                                      decoration: TextDecoration.none,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                GestureDetector(
                                  onTap: () => _showFullSummary(context),
                                  child: const Text(
                                    '更多',
                                    style: TextStyle(
                                      color: Color(0xFF2B65FF),
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
        title: Text(video.title),
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

  Future<void> _matchManually(BuildContext context) async {
    final parsed = ScraperService.parseTitle(video.title);
    final query = parsed.queries.isEmpty ? video.title : parsed.queries.first;
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

  List<Color> _paletteFor(String title) {
    const palettes = <List<Color>>[
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
      style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
    );
  }
}

class _MetadataDivider extends StatelessWidget {
  const _MetadataDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 10),
      child: Text(
        '|',
        style: TextStyle(fontSize: 12, color: Color(0xFFDDDDDD)),
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
      color: Colors.white.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: const Color(0xFF333333)),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(color: Color(0xFF333333), fontSize: 13),
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
  });

  final List<ScannedVideo> episodes;

  /// 剧集海报——花絮卡片没有独立缩略图时用它兜底。
  final String? posterPath;

  /// 季标题（如「第 8 季」）；花絮归在该季内部。
  final String seasonLabel;

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
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        widget.seasonLabel,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A1A1A),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '共 ${shown.length} 集',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF888888),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const SizedBox(
                    width: 16,
                    height: 3,
                    child: ColoredBox(color: Color(0xFF141414)),
                  ),
                ],
              ),
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
              itemBuilder: (context, index) =>
                  _EpisodeCard(episode: shown[index], index: index),
            ),
          ),
          if (extras.isNotEmpty) ...[
            const SizedBox(height: 26),
            Row(
              children: [
                const Text(
                  '花絮与相关',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '共 ${extras.length} 个',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF888888),
                  ),
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

/// 季切换下拉框（不占版面，点击展开）。
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F2F2),
        borderRadius: BorderRadius.circular(9),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: currentIndex,
          isDense: true,
          borderRadius: BorderRadius.circular(10),
          icon: const Icon(Icons.keyboard_arrow_down, size: 18),
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1A1A1A),
          ),
          items: [
            for (var i = 0; i < seasons.length; i++)
              DropdownMenuItem<int>(
                value: i,
                child: Text(
                  '第 ${MediaLibrary.seasonOf(seasons[i])} 季',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
          ],
          onChanged: (index) {
            if (index != null && index != currentIndex) onSelected(index);
          },
        ),
      ),
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
      color: const Color(0xFFF2F3F5),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(icon, size: 18, color: const Color(0xFF666666)),
        ),
      ),
    );
  }
}

class _EpisodeCard extends StatelessWidget {
  const _EpisodeCard({required this.episode, required this.index});

  final ScannedVideo episode;
  final int index;

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
                      if (thumbnailPath != null &&
                          File(thumbnailPath).existsSync())
                        Image.file(
                          File(thumbnailPath),
                          fit: BoxFit.cover,
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
                            valueColor: const AlwaysStoppedAnimation(
                              Color(0xFF2B65FF),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                episode.episodeTitle != null && episode.episodeTitle!.isNotEmpty
                    ? '${index + 1}. ${episode.episodeTitle}'
                    : '${index + 1}. ${episode.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: Color(0xFF222222)),
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
          const Text(
            '相关演员',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Color(0xFF141414),
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
                      CircleAvatar(
                        radius: 42,
                        backgroundColor: const Color(0xFFE5E6EB),
                        backgroundImage: _photo(member),
                        child: _photo(member) == null
                            ? const Icon(
                                Icons.person,
                                size: 48,
                                color: Colors.white,
                              )
                            : null,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        member.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF222222),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        member.role,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF999999),
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

  NetworkImage? _photo(CastMember member) =>
      member.photoUrl == null ? null : NetworkImage(member.photoUrl!);
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
    final runtime = video.runtimeSec;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(color: Color(0xFFF0F0F0), thickness: 1, height: 1),
          const SizedBox(height: 16),
          Text(
            current.title,
            style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
          ),
          const SizedBox(height: 6),
          Text(
            '${source?.name ?? '媒体库'} · ${current.path}',
            style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
          ),
          const SizedBox(height: 6),
          Text(
            [
              if (runtime != null && runtime > 0) _formatSeconds(runtime),
              sizeLabel,
            ].join('  '),
            style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
          ),
        ],
      ),
    );
  }

  String _formatSeconds(double seconds) {
    final total = seconds.round();
    final minutes = total ~/ 60;
    final secs = total % 60;
    return '$minutes 分钟 $secs 秒';
  }
}

/// 花絮/相关视频小卡片（较小，无集号）。
class _ExtraCard extends StatelessWidget {
  const _ExtraCard({required this.episode, this.posterPath});

  final ScannedVideo episode;

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
            ),
          ),
        );
      },
      child: Container(
        width: 150,
        decoration: BoxDecoration(
          color: const Color(0xFFEFEFEF),
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
                child: posterPath != null && File(posterPath!).existsSync()
                    ? Image.file(
                        File(posterPath!),
                        fit: BoxFit.cover,
                        color: Colors.black.withValues(alpha: 0.25),
                        colorBlendMode: BlendMode.darken,
                      )
                    : const ColoredBox(
                        color: Color(0xFFE0E0E0),
                        child: Icon(
                          Icons.movie_filter_outlined,
                          size: 20,
                          color: Color(0xFF999999),
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
                style: const TextStyle(
                  fontSize: 11.5,
                  color: Color(0xFF333333),
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

/// 影片年份：优先 TMDB 首播/上映年份，回退文件修改时间年份。
String? _yearOf(ScannedVideo video) {
  final release = video.releaseDate;
  if (release != null && release.trim().length >= 4) {
    return release.trim().substring(0, 4);
  }
  if (video.modified != null) return '${video.modified!.year}';
  return null;
}
