import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'services/media_library.dart';
import 'services/playback_history.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await MediaLibrary.instance.load();
  await PlaybackHistory.instance.load();
  runApp(const FrameletApp());
}
