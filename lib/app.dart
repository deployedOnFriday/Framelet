import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';
import 'widgets/app_shell.dart';

class FrameletApp extends StatelessWidget {
  const FrameletApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '拾帧 - Framelet',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const AppShell(),
    );
  }
}
