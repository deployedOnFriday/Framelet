import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/media_source.dart';
import '../services/media_library.dart';
import '../services/playback_history.dart';
import '../models/media_item.dart';
import '../widgets/media_artwork.dart';
import 'player_page.dart';

/// 影片详情页：信息、播放入口与剧集列表。
class DetailPage extends StatelessWidget {
  const DetailPage({required this.video, super.key});

  final ScannedVideo video;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        PlaybackHistory.instance,
        MediaLibrary.instance,
      ]),
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final library = MediaLibrary.instance;
    final source = library.sourceById(video.sourceId);
    final episodes = library.episodesOf(video);
    final isSeries = video.episodeCount > 1;

    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 28, 30, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context),
          const SizedBox(height: 24),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 230,
                  child: Column(
                    children: [
                      SizedBox(
                        height: 330,
                        child: MediaArtwork(
                          item: _posterItem(context),
                          showQuality: true,
                          borderRadius: 16,
                        ),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        height: 46,
                        child: FilledButton.icon(
                          onPressed: () => _play(context, episodes.first),
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: Text(_playLabel(episodes.first)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 30),
                Expanded(
                  child: _buildInfoPanel(context, source, episodes, isSeries),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      children: [
        Text(
          video.kind == MediaKind.movie
              ? '电影'
              : video.kind == MediaKind.series
              ? '电视剧'
              : video.kind == MediaKind.anime
              ? '动漫'
              : '综艺',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(width: 14),
        Text(
          video.title,
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(color: AppColors.muted, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  MediaItem _posterItem(BuildContext context) {
    final history = PlaybackHistory.instance;
    final entry = history.entryOf(video.sourceId, video.path);
    return MediaItem(
      title: video.title,
      subtitle: video.episodeCount > 1 ? '共 ${video.episodeCount} 集' : '',
      year: video.modified == null ? '' : video.modified!.year.toString(),
      colors: const [AppColors.primary, Color(0xFF7FB89F)],
      icon: Icons.movie_outlined,
      quality: video.episodeCount > 1 ? '${video.episodeCount} 集' : null,
      progress: entry?.progress ?? 0,
    );
  }

  String _playLabel(ScannedVideo episode) {
    final entry = PlaybackHistory.instance.entryOf(
      episode.sourceId,
      episode.path,
    );
    if (entry == null || entry.positionSec <= 1) return '立即播放';
    if (entry.finished) return '重新播放';
    final left = (entry.durationSec - entry.positionSec) / 60;
    return '继续播放 · 剩余 ${left.ceil()} 分钟';
  }

  Widget _buildInfoPanel(
    BuildContext context,
    MediaSource? source,
    List<ScannedVideo> episodes,
    bool isSeries,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            if (video.modified != null) _chip('年份 ${video.modified!.year}'),
            if (video.episodeCount > 1) _chip('共 ${video.episodeCount} 集'),
            _chip(_sizeLabel()),
            if (source != null) _chip('来自「${source.name}」'),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          video.path,
          style: Theme.of(context).textTheme.bodySmall,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 22),
        Expanded(
          child: isSeries
              ? _buildEpisodeList(context, episodes)
              : Center(
                  child: Text(
                    '单文件影片，点击左侧「立即播放」开始观看。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
        ),
      ],
    );
  }

  String _sizeLabel() {
    final gb = video.sizeBytes / (1024 * 1024 * 1024);
    if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
    return '${(video.sizeBytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }

  Widget _buildEpisodeList(BuildContext context, List<ScannedVideo> episodes) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: episodes.length,
        separatorBuilder: (_, _) =>
            const Divider(height: 1, indent: 16, endIndent: 16),
        itemBuilder: (context, index) {
          final episode = episodes[index];
          final entry = PlaybackHistory.instance.entryOf(
            episode.sourceId,
            episode.path,
          );
          return ListTile(
            dense: true,
            leading: Icon(
              Icons.play_circle_outline_rounded,
              color: entry != null && entry.finished
                  ? AppColors.muted
                  : AppColors.primary,
            ),
            title: Text(
              _episodeTitle(episode, index),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            subtitle: entry != null && entry.positionSec > 1
                ? Text(
                    entry.finished
                        ? '已看完'
                        : '看到 ${(entry.progress * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.primary,
                    ),
                  )
                : null,
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap: () => _play(context, episode),
          );
        },
      ),
    );
  }

  String _episodeTitle(ScannedVideo episode, int index) {
    final base = episode.title;
    return base.contains(
          RegExp(
            r'[Ss]\d{1,2}[Ee]|第\s*\d+\s*[集期]|\bEP?\d+',
            caseSensitive: false,
          ),
        )
        ? base
        : '第 ${index + 1} 集 · $base';
  }

  Widget _chip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 12, color: AppColors.primary),
      ),
    );
  }

  void _play(BuildContext context, ScannedVideo episode) {
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
