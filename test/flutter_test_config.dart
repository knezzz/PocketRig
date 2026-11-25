import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/theme.dart';

/// Runs before every test file: loads the app's real fonts (Inter,
/// JetBrains Mono, Material icons) so platform goldens read like the app,
/// and configures Alchemist.
///
/// CI goldens (`goldens/ci/`, text as blocks) are what CI compares.
/// Platform goldens (`goldens/<os>/`) are readable references; they're
/// skipped when `CI=true` because text rendering differs between machines.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await _loadAppFonts();
  animateStatusSpinners = false;
  final inCi = Platform.environment['CI'] == 'true';
  return AlchemistConfig.runWithConfig(
    config: AlchemistConfig(
      theme: buildTheme(Tokens.light, Brightness.light),
      platformGoldensConfig: PlatformGoldensConfig(enabled: !inCi),
    ),
    run: testMain,
  );
}

Future<void> _loadAppFonts() async {
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final entry in manifest.cast<Map<String, dynamic>>()) {
    final family = entry['family'] as String;
    final loader = FontLoader(family.startsWith('packages/') ? family : family);
    for (final f in (entry['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(f['asset'] as String));
    }
    await loader.load();
  }
}
