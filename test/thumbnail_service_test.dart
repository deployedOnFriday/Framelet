import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/services/thumbnail_service.dart';

void main() {
  test('同一视频的新截图使用新文件名并清理旧图', () async {
    final directory = await Directory.systemTemp.createTemp(
      'framelet_thumbnail_',
    );
    addTearDown(() => directory.delete(recursive: true));

    final first = await ThumbnailService.saveTo(
      directory,
      Uint8List.fromList([1, 2, 3]),
      'source',
      '/media/episode-01.mkv',
    );
    final second = await ThumbnailService.saveTo(
      directory,
      Uint8List.fromList([4, 5, 6]),
      'source',
      '/media/episode-01.mkv',
    );

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(second, isNot(first));
    expect(await File(second!).readAsBytes(), [4, 5, 6]);
    expect(await File(first!).exists(), isFalse);
    expect(
      await directory
          .list()
          .where((entity) => entity is File)
          .map((entity) => entity.path)
          .toList(),
      hasLength(1),
    );
  });

  test('不同视频的缩略图互不清理', () async {
    final directory = await Directory.systemTemp.createTemp(
      'framelet_thumbnail_',
    );
    addTearDown(() => directory.delete(recursive: true));

    final first = await ThumbnailService.saveTo(
      directory,
      Uint8List.fromList([1]),
      'source',
      '/media/episode-01.mkv',
    );
    final second = await ThumbnailService.saveTo(
      directory,
      Uint8List.fromList([2]),
      'source',
      '/media/episode-02.mkv',
    );

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(await File(first!).exists(), isTrue);
    expect(await File(second!).exists(), isTrue);
  });
}
