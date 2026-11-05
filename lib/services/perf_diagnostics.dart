import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// 开发期性能诊断：性能叠加层开关 + 帧时间统计落盘。
///
/// - F3：切换性能叠加层（PerformanceOverlay），肉眼分辨 UI 线程
///   （构建/布局）与 Raster 线程（绘制/合成）谁在拖慢帧率。
/// - F4：把最近 600 帧的 UI / Raster / 整帧耗时分位数（p50/p90/p99/max，
///   单位毫秒）追加到 %TEMP%\framelet_perf.log，release 下同样可用。
class PerfDiagnostics extends ChangeNotifier {
  PerfDiagnostics._() {
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  static final PerfDiagnostics instance = PerfDiagnostics._();

  bool overlayVisible = false;

  final List<FrameTiming> _timings = [];
  static const _maxTimings = 600;

  void toggleOverlay() {
    overlayVisible = !overlayVisible;
    notifyListeners();
  }

  void _onTimings(List<FrameTiming> timings) {
    _timings.addAll(timings);
    if (_timings.length > _maxTimings) {
      _timings.removeRange(0, _timings.length - _maxTimings);
    }
  }

  /// 把帧时间统计追加到临时目录日志，并返回报告文本。
  String dump() {
    final sample = List.of(_timings);
    if (sample.isEmpty) return '无帧数据';

    String ms(List<int> values, double p) {
      final sorted = List.of(values)..sort();
      final index = ((sorted.length - 1) * p).round();
      return (sorted[index] / 1000).toStringAsFixed(1);
    }

    final ui = sample.map((t) => t.buildDuration.inMicroseconds).toList();
    final raster = sample.map((t) => t.rasterDuration.inMicroseconds).toList();
    final total = sample.map((t) => t.totalSpan.inMicroseconds).toList();
    final report = [
      '${DateTime.now().toIso8601String()}  frames=${sample.length}',
      'UI      ms  p50=${ms(ui, 0.5)}  p90=${ms(ui, 0.9)}  p99=${ms(ui, 0.99)}  max=${ms(ui, 1)}',
      'Raster  ms  p50=${ms(raster, 0.5)}  p90=${ms(raster, 0.9)}  p99=${ms(raster, 0.99)}  max=${ms(raster, 1)}',
      'Total   ms  p50=${ms(total, 0.5)}  p90=${ms(total, 0.9)}  p99=${ms(total, 0.99)}  max=${ms(total, 1)}',
    ].join('\n');
    try {
      File('${Directory.systemTemp.path}/framelet_perf.log').writeAsStringSync(
        '$report\n\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 日志失败不影响应用
    }
    return report;
  }
}
