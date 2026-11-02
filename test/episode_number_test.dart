import 'package:flutter_test/flutter_test.dart';
// ignore_for_file: avoid_print
import 'package:framelet/services/media_library.dart';

void main() {
  test('各类文件名的集号解析', () {
    print(
      'Magic.Mobile...E01: ${MediaLibrary.episodeNumberOf('Magic.Mobile.Phone.2008.E01.WEB-DL.1080p.H265')}',
    );
    print('01~: ${MediaLibrary.episodeNumberOf('01~')}');
    print('14: ${MediaLibrary.episodeNumberOf('14')}');
    print('Signal.S01E13: ${MediaLibrary.episodeNumberOf('Signal.S01E13')}');
  });
}
