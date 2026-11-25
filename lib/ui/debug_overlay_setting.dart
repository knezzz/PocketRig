import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Whether the Borealis debug overlay is on, from Settings › App. On in debug builds and off in release ones
/// until the person chooses. Kept in a small file next to the app's other data. The app shell reads it
/// (`BorealisSettings(enabled: …)`).
final debugOverlay = ValueNotifier<bool>(kDebugMode);

/// A saved 'on' or 'off' wins; anything else (nothing saved, a damaged file) keeps [fallback].
bool debugOverlayFrom(String saved, bool fallback) => switch (saved.trim()) {
      'on' => true,
      'off' => false,
      _ => fallback,
    };

const _file = 'debug-overlay';

Future<File?> _path() async {
  try {
    return File('${(await getApplicationSupportDirectory()).path}/$_file');
  } catch (_) {
    return null; // tests and platforms without a support folder: keep the default
  }
}

/// Reads the saved choice, if any.
Future<void> loadDebugOverlay() async {
  try {
    final f = await _path();
    if (f == null || !await f.exists()) return;
    debugOverlay.value = debugOverlayFrom(await f.readAsString(), debugOverlay.value);
  } catch (_) {}
}

Future<void> setDebugOverlay(bool on) async {
  debugOverlay.value = on;
  try {
    await (await _path())?.writeAsString(on ? 'on' : 'off');
  } catch (_) {}
}
