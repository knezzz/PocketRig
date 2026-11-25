import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/status_shape.dart';

void main() {
  testWidgets('the runtime logos are in the image cache before the first frame, at any pixel ratio', (tester) async {
    PaintingBinding.instance.imageCache.clear();
    await tester.runAsync(warmRuntimeLogos);
    for (final a in runtimeLogoAssets) {
      for (final ratio in [1.0, 3.0]) {
        final key = await AssetImage(a).obtainKey(ImageConfiguration(devicePixelRatio: ratio));
        expect(PaintingBinding.instance.imageCache.containsKey(key), isTrue, reason: '$a at $ratio');
      }
    }
  });
}
