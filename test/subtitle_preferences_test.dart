import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/services/subtitle_preferences.dart';
import 'package:framelet/services/subtitle_service.dart';
import 'package:media_kit/media_kit.dart';

SubtitleTrack track(String id, {String? title, String? language}) =>
    SubtitleTrack(id, title, language);

void main() {
  group('字幕记忆解析', () {
    final tracks = [
      track('1', title: '简体中文', language: 'chi'),
      track('2', title: '中上英下-ASS', language: 'chi'),
      track('3', title: 'English', language: 'eng'),
    ];

    test('按轨道 id 精确命中', () {
      final choice = SubtitleChoice.track(
        id: '2',
        language: 'chi',
        title: '中上英下-ASS',
      );
      expect(SubtitleChoiceResolver.trackIndex(choice, tracks), 1);
    });

    test('轨道顺序变了仍能按语言命中', () {
      final choice = SubtitleChoice.track(id: '9', language: 'eng');
      expect(SubtitleChoiceResolver.trackIndex(choice, tracks), 2);
    });

    test('id 与语言都对不上时按标题兜底', () {
      final choice = SubtitleChoice.track(id: '9', title: '中上英下-ass');
      expect(SubtitleChoiceResolver.trackIndex(choice, tracks), 1);
    });

    test('本集没有对应轨道时返回 null（不要乱选一条）', () {
      final choice = SubtitleChoice.track(
        id: '9',
        language: 'jpn',
        title: '日本語',
      );
      expect(SubtitleChoiceResolver.trackIndex(choice, tracks), isNull);
    });

    test('关闭字幕的选择不会被当成某条轨道', () {
      expect(
        SubtitleChoiceResolver.trackIndex(const SubtitleChoice.off(), tracks),
        isNull,
      );
    });

    test('《无耻之徒》实测轨道：换集后仍选中同一条官方字幕', () {
      // 轨道路径来自 2026-11-14 的实机日志：
      // S01E01 / S01E02 的 id、标题、语言完全一致，因此按 id 命中。
      List<SubtitleTrack> yyeTs() => [
        track('1', title: '中上英下-ASS_YYeTs字幕￡cXcY', language: 'chi'),
        track('2', title: '简体中文-SRT_YYeTs字幕￡cXcY', language: 'chi'),
        track('3', title: '简体中文-ASS_官方字幕￡cXcY', language: 'chi'),
      ];

      final choice = SubtitleChoice.track(
        id: '3',
        language: 'chi',
        title: '简体中文-ASS_官方字幕￡cXcY',
      );
      final index = SubtitleChoiceResolver.trackIndex(choice, yyeTs());
      expect(index, 2);
      expect(yyeTs()[index!].title, contains('官方字幕'));
    });
  });

  group('外挂字幕记忆解析', () {
    const files = [
      SubtitleFile(path: '/a/EP01.zh.srt', title: '简体中文', language: '中文'),
      SubtitleFile(path: '/a/EP01.en.srt', title: 'English', language: '英语'),
    ];

    test('同集重开按路径命中', () {
      final choice = SubtitleChoice.external(path: '/a/EP01.en.srt');
      expect(
        SubtitleChoiceResolver.externalFile(choice, files)?.path,
        '/a/EP01.en.srt',
      );
    });

    test('换集后按标题/语言找回同名字幕', () {
      const next = [
        SubtitleFile(path: '/a/EP02.zh.srt', title: '简体中文', language: '中文'),
        SubtitleFile(path: '/a/EP02.en.srt', title: 'English', language: '英语'),
      ];
      final choice = SubtitleChoice.external(
        path: '/a/EP01.en.srt',
        title: 'English',
        language: '英语',
      );
      expect(
        SubtitleChoiceResolver.externalFile(choice, next)?.path,
        '/a/EP02.en.srt',
      );
    });

    test('下一集没有同名外挂字幕时返回 null', () {
      final choice = SubtitleChoice.external(
        path: '/a/EP01.en.srt',
        title: 'English',
        language: '英语',
      );
      expect(SubtitleChoiceResolver.externalFile(choice, const []), isNull);
    });
  });

  group('记忆序列化', () {
    test('轨道/关闭/外挂都能往返', () {
      final cases = [
        const SubtitleChoice.off(),
        SubtitleChoice.track(id: '2', language: 'chi', title: '中上英下-ASS'),
        SubtitleChoice.external(path: '/a/x.srt', title: '简体中文'),
      ];
      for (final choice in cases) {
        final restored = SubtitleChoice.fromJson(choice.toJson());
        expect(restored, isNotNull, reason: choice.kind);
        expect(restored!.kind, choice.kind);
        expect(restored.trackId, choice.trackId);
        expect(restored.language, choice.language);
        expect(restored.title, choice.title);
        expect(restored.path, choice.path);
      }
    });

    test('损坏的存储数据不会当成有效记忆', () {
      expect(SubtitleChoice.fromJson('garbage'), isNull);
      expect(
        SubtitleChoice.fromJson(<String, Object?>{'k': 'unknown'}),
        isNull,
      );
      expect(SubtitleChoice.fromJson(<String, Object?>{}), isNull);
    });
  });
}
