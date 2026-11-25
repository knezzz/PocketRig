import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/debug_overlay_setting.dart';

void main() {
  test('the overlay follows the build until the person chooses: on in debug, off in release', () {
    expect(debugOverlay.value, kDebugMode);
    expect(debugOverlayFrom('', false), isFalse, reason: 'nothing saved, a release build: off');
    expect(debugOverlayFrom('', true), isTrue, reason: 'nothing saved, a debug build: on');
    expect(debugOverlayFrom('garbage', false), isFalse);
  });

  test('a saved on or off wins over the build default', () {
    expect(debugOverlayFrom('on\n', false), isTrue);
    expect(debugOverlayFrom('off', true), isFalse);
  });
}
