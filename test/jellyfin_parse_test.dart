import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/models/media_source.dart';
import 'package:framelet/services/jellyfin_service.dart';

const _session = JellyfinSession(
  baseUrl: 'http://192.168.1.10:8096',
  token: 'token',
  userId: 'user',
  serverName: '家里 NAS',
  product: 'Jellyfin Server',
);

MediaSource _source() => MediaSource(
  id: 'jf1',
  name: 'Jellyfin',
  kind: MediaSourceKind.jellyfin,
  address: 'http://192.168.1.10:8096',
  username: 'demo',
);

void main() {
  test('服务器地址自动补 http 并去掉尾斜杠', () {
    expect(
      JellyfinService.normalizeBaseUrl('192.168.1.10:8096/'),
      'http://192.168.1.10:8096',
    );
    expect(
      JellyfinService.normalizeBaseUrl('https://jf.example.org/'),
      'https://jf.example.org',
    );
  });

  test('从虚拟文件名解析季集号', () {
    expect(JellyfinService.parseEpisodeName('无耻之徒 S01E05.mkv'), (
      season: 1,
      episode: 5,
    ));
    expect(JellyfinService.parseEpisodeName('Show s2e12.mp4'), (
      season: 2,
      episode: 12,
    ));
    expect(JellyfinService.parseEpisodeName('没有集号.mkv'), isNull);
  });

  test('电影条目映射为稳定的虚拟路径与元数据', () async {
    final video = await JellyfinService.videoFromItem(_source(), _session, {
      'Id': 'movie1',
      'Type': 'Movie',
      'Name': '挽救计划',
      'Overview': '一名宇航员独自醒来。',
      'CommunityRating': 8.2,
      'RunTimeTicks': 72000000000,
      'Genres': ['科幻', '冒险'],
      'ProviderIds': {'Tmdb': '12345'},
      'MediaSources': [
        {'Container': 'mkv', 'Size': 123456789},
      ],
    }, downloadImages: false);

    expect(video, isNotNull);
    expect(video!.path, 'jf://movie/movie1/挽救计划/挽救计划.mkv');
    expect(video.title, '挽救计划');
    expect(video.kind, MediaKind.movie);
    expect(video.tmdbId, 12345);
    expect(video.tmdbTitle, '挽救计划');
    expect(video.rating, '8.2');
    expect(video.runtimeSec, 7200);
    expect(video.sizeBytes, 123456789);
    expect(video.genres, ['科幻', '冒险']);
    expect(video.summary, '一名宇航员独自醒来。');
  });

  test('剧集条目按部聚合，路径带季集号', () async {
    final video = await JellyfinService.videoFromItem(_source(), _session, {
      'Id': 'ep2',
      'Type': 'Episode',
      'Name': '第 5 集',
      'SeriesId': 'show1',
      'SeriesName': '无耻之徒',
      'ParentIndexNumber': 1,
      'IndexNumber': 5,
      'Genres': ['剧情'],
      'MediaSources': [
        {'Container': 'mp4'},
      ],
    }, downloadImages: false);

    expect(video, isNotNull);
    expect(video!.path, 'jf://show/show1/无耻之徒/无耻之徒 S01E05.mp4');
    expect(video.title, '无耻之徒 S01E05');
    expect(video.kind, MediaKind.series);
    expect(video.episodeTitle, '第 5 集');
    expect(video.tmdbTitle, '无耻之徒');
  });

  test('动画类型按番剧归类', () async {
    final video = await JellyfinService.videoFromItem(_source(), _session, {
      'Id': 'ep3',
      'Type': 'Episode',
      'Name': '第 1 集',
      'SeriesId': 'show2',
      'SeriesName': '葬送的芙莉莲',
      'ParentIndexNumber': 1,
      'IndexNumber': 1,
      'Genres': ['动画'],
    }, downloadImages: false);

    expect(video!.kind, MediaKind.anime);
  });

  test('电影虚拟路径可直接解析出 itemId', () async {
    expect(
      await JellyfinService.resolveItemId(
        _session,
        'jf://movie/abc123/片名/片名.mkv',
      ),
      'abc123',
    );
  });
}
