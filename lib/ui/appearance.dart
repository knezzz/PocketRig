import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Light, dark or follow the system. Dark is the default: the redesign's
/// primary theme. Kept in a small file next to the app's other data.
final appearance = ValueNotifier<ThemeMode>(ThemeMode.dark);

const _file = 'appearance';

Future<File?> _path() async {
  try {
    return File('${(await getApplicationSupportDirectory()).path}/$_file');
  } catch (_) {
    return null; // tests and platforms without a support folder: keep the default
  }
}

/// Reads the saved choice, if any.
Future<void> loadAppearance() async {
  try {
    final f = await _path();
    if (f == null || !await f.exists()) return;
    appearance.value = switch ((await f.readAsString()).trim()) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
  } catch (_) {}
}

Future<void> setAppearance(ThemeMode mode) async {
  appearance.value = mode;
  try {
    await (await _path())?.writeAsString(mode.name);
  } catch (_) {}
}

String appearanceLabel(ThemeMode m) => switch (m) {
      ThemeMode.dark => 'Dark',
      ThemeMode.light => 'Light',
      ThemeMode.system => 'System',
    };
