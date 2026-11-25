import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/theme.dart';
import 'package:pocket_rig/ui/thinking_dots.dart';

Widget _app({bool still = false}) => MaterialApp(
      builder: (context, child) =>
          MediaQuery(data: MediaQueryData(disableAnimations: still), child: child!),
      home: const Center(child: ThinkingDots(d: 10)),
    );

void main() {
  setUp(() => animateStatusSpinners = true); // tests turn it off globally
  tearDown(() => animateStatusSpinners = false);

  test('a dot hops 0.7 d by 0.32 s, settles to 0.5 d by 0.71 s and lands by 0.88 s', () {
    expect(ThinkingDots.rise(0), 0);
    expect(ThinkingDots.rise(0.32), closeTo(0.7, 1e-3));
    expect(ThinkingDots.rise(0.71), closeTo(0.5, 1e-3));
    expect(ThinkingDots.rise(0.88), closeTo(0, 1e-3));
    expect(ThinkingDots.rise(1.5), 0);
  });

  test('the hole opens to 0.67 d by 0.45 s, closes by 0.8 s, and breathes between 1.98 s and 2.83 s', () {
    expect(ThinkingDots.hole(0), 0);
    expect(ThinkingDots.hole(0.45), closeTo(0.67, 1e-3));
    expect(ThinkingDots.hole(0.8), closeTo(0, 1e-3));
    expect(ThinkingDots.hole(1.2), 0);
    expect(ThinkingDots.hole(1.98 + 0.425), closeTo(0.67, 1e-3));
    expect(ThinkingDots.hole(2.84), 0);
  });

  testWidgets('one controller drives all three dots', (tester) async {
    await tester.pumpWidget(_app());
    expect(tester.binding.transientCallbackCount, 1);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(CustomPaint), findsWidgets);
    expect(tester.binding.transientCallbackCount, 1);
  });

  testWidgets('with reduce-motion it is three static dots and nothing ticks', (tester) async {
    await tester.pumpWidget(_app(still: true));
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.hasRunningAnimations, isFalse);
  });
}
