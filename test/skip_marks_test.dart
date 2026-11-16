import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/services/skip_marks.dart';
import 'package:framelet/services/skip_marks_service.dart';

void main() {
  const marks = SeriesSkipMarks(introEndSec: 90, outroStartSec: 1320);

  group('片头片尾提示', () {
    test('片头区间内提示跳过片头', () {
      expect(
        SkipPromptResolver.resolve(
          marks: marks,
          positionSec: 12,
          durationSec: 1500,
          introSkipped: false,
          outroSkipped: false,
        ),
        SkipPrompt.intro,
      );
    });

    test('刚开播不提示（避免还没看到片头就跳）', () {
      expect(
        SkipPromptResolver.resolve(
          marks: marks,
          positionSec: 0,
          durationSec: 1500,
          introSkipped: false,
          outroSkipped: false,
        ),
        SkipPrompt.none,
      );
    });

    test('跳过片头后不再提示，回拖重看也不重复打扰', () {
      expect(
        SkipPromptResolver.resolve(
          marks: marks,
          positionSec: 20,
          durationSec: 1500,
          introSkipped: true,
          outroSkipped: false,
        ),
        SkipPrompt.none,
      );
    });

    test('片头结束后进入正片不提示', () {
      expect(
        SkipPromptResolver.resolve(
          marks: marks,
          positionSec: 600,
          durationSec: 1500,
          introSkipped: false,
          outroSkipped: false,
        ),
        SkipPrompt.none,
      );
    });

    test('进入片尾区间提示跳过片尾', () {
      expect(
        SkipPromptResolver.resolve(
          marks: marks,
          positionSec: 1330,
          durationSec: 1500,
          introSkipped: true,
          outroSkipped: false,
        ),
        SkipPrompt.outro,
      );
    });

    test('跳过片尾后不再提示', () {
      expect(
        SkipPromptResolver.resolve(
          marks: marks,
          positionSec: 1400,
          durationSec: 1500,
          introSkipped: true,
          outroSkipped: true,
        ),
        SkipPrompt.none,
      );
    });

    test('没有标记时永远不提示', () {
      expect(
        SkipPromptResolver.resolve(
          marks: const SeriesSkipMarks(),
          positionSec: 30,
          durationSec: 1500,
          introSkipped: false,
          outroSkipped: false,
        ),
        SkipPrompt.none,
      );
    });

    test('在线识别带片头起点时，只在片头区间内提示', () {
      const online = SeriesSkipMarks(
        introStartSec: 473.681,
        introEndSec: 571.154,
        outroStartSec: 3630.04,
      );
      expect(
        SkipPromptResolver.resolve(
          marks: online,
          positionSec: 400,
          durationSec: 3900,
          introSkipped: false,
          outroSkipped: false,
        ),
        SkipPrompt.none,
      );
      expect(
        SkipPromptResolver.resolve(
          marks: online,
          positionSec: 500,
          durationSec: 3900,
          introSkipped: false,
          outroSkipped: false,
        ),
        SkipPrompt.intro,
      );
    });
  });

  group('片头片尾标记持久化格式', () {
    test('往返保留片头与片尾', () {
      final restored = SeriesSkipMarks.fromJson(marks.toJson());
      expect(restored?.introEndSec, 90);
      expect(restored?.outroStartSec, 1320);
    });

    test('损坏或非法数据当成没有标记', () {
      expect(SeriesSkipMarks.fromJson('bad'), isNull);
      expect(SeriesSkipMarks.fromJson({'intro': 0, 'outro': -3}), isNull);
      expect(SeriesSkipMarks.fromJson({'intro': 'abc'}), isNull);
    });

    test('只标片头时片尾保持为空', () {
      const onlyIntro = SeriesSkipMarks(introEndSec: 88);
      final restored = SeriesSkipMarks.fromJson(onlyIntro.toJson());
      expect(restored?.hasIntro, isTrue);
      expect(restored?.hasOutro, isFalse);
    });

    test('copyWith 可单独清除某一侧', () {
      final cleared = marks.copyWith(clearIntro: true);
      expect(cleared.introEndSec, isNull);
      expect(cleared.outroStartSec, 1320);
    });
  });

  group('TheIntroDB 返回解析', () {
    test('剧集：片头有起止、片尾只有开始', () {
      // 真实返回：无耻之徒 S01E01
      final marks = SkipMarksService.parseSegments(
        '{"tmdb_id":1399,"type":"tv","season":1,"episode":1,'
        '"intro":[{"start_ms":473681,"end_ms":571154}],'
        '"credits":[{"start_ms":3630040,"end_ms":null}]}',
      );
      expect(marks?.introStartSec, closeTo(473.681, 0.001));
      expect(marks?.introEndSec, closeTo(571.154, 0.001));
      expect(marks?.outroStartSec, closeTo(3630.04, 0.001));
    });

    test('片头没有起点时按 0 处理，仍能跳过片头', () {
      final marks = SkipMarksService.parseSegments(
        '{"intro":[{"start_ms":null,"end_ms":106019}],'
        '"credits":[{"start_ms":3248300,"end_ms":null}]}',
      );
      expect(marks?.introStartSec, isNull);
      expect(marks?.introEndSec, closeTo(106.019, 0.001));
      expect(marks?.hasIntro, isTrue);
    });

    test('电影没有季集参数也能解析', () {
      final marks = SkipMarksService.parseSegments(
        '{"tmdb_id":687163,"type":"movie",'
        '"intro":[{"start_ms":null,"end_ms":36000}],'
        '"credits":[{"start_ms":9033000,"end_ms":null}]}',
      );
      expect(marks?.introEndSec, 36);
      expect(marks?.outroStartSec, 9033);
    });

    test('空数据与错误返回都不当成有效标记', () {
      expect(SkipMarksService.parseSegments('{}'), isNull);
      expect(
        SkipMarksService.parseSegments('{"intro":[],"credits":[]}'),
        isNull,
      );
      expect(
        SkipMarksService.parseSegments(
          '{"error":"Invalid tmdb_id: must be between 1 and 10000000"}',
        ),
        isNull,
      );
      expect(SkipMarksService.parseSegments('not json'), isNull);
    });
  });
}
