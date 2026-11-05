import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';
import 'services/perf_diagnostics.dart';
import 'services/theme_controller.dart';
import 'widgets/app_shell.dart';

class FrameletApp extends StatelessWidget {
  const FrameletApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeController.instance,
        PerfDiagnostics.instance,
      ]),
      builder: (context, _) => MaterialApp(
        title: '拾帧 - Framelet',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeController.instance.value,
        scrollBehavior: const _FrameletScrollBehavior(),
        // F3 切换：性能叠加层直接叠在内容之上（3.47 起 MaterialApp
        // 不再提供 debugShowPerformanceOverlay 参数）
        builder: (context, child) => Stack(
          children: [
            ?child,
            if (PerfDiagnostics.instance.overlayVisible)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 160,
                child: PerformanceOverlay.allEnabled(),
              ),
          ],
        ),
        home: const AppShell(),
      ),
    );
  }
}

/// 桌面端统一给可滚动区域套上 Scrollbar，样式交给主题层控制。
class _FrameletScrollBehavior extends MaterialScrollBehavior {
  const _FrameletScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return Scrollbar(controller: details.controller, child: child);
  }
}
