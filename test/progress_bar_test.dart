import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/progress_bar.dart';
import 'package:pocket_rig/ui/theme.dart';

void main() {
  Widget host(Widget bar) => MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: Scaffold(body: Center(child: SizedBox(width: 100, child: bar))));

  testWidgets('the one bar: a track, a fill to the value, and an optional pace tick as tall as the box', (tester) async {
    const k = Tokens.light;
    await tester.pumpWidget(host(ProgressBar(value: 0.4, color: k.added, height: 4, boxHeight: 12, tick: 0.5)));
    expect(tester.getSize(find.byType(ProgressBar)), const Size(100, 12));
    expect(
        find.byType(ProgressBar),
        paints
          ..rrect(rrect: RRect.fromLTRBR(0, 4, 100, 8, const Radius.circular(2)), color: k.divider)
          ..rrect(rrect: RRect.fromLTRBR(0, 4, 40, 8, const Radius.circular(2)), color: k.added)
          ..rrect(rrect: RRect.fromLTRBR(49, 0, 51, 12, const Radius.circular(1)), color: k.ink));
    await tester.pumpWidget(host(ProgressBar(value: 0, color: k.added, height: 3)));
    expect(tester.getSize(find.byType(ProgressBar)), const Size(100, 3));
  });

  testWidgets('a context bar takes its colour from the context ramp and reads itself out unless told not to', (tester) async {
    const k = Tokens.light;
    for (final (pct, color) in [(20.0, k.muted), (90.0, k.removed)]) {
      await tester.pumpWidget(host(ContextBar(pct)));
      expect(find.byType(ProgressBar), paints..rrect()..rrect(color: color), reason: '$pct%');
    }
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(const ContextBar(62)));
    expect(find.bySemanticsLabel('context 62 percent used'), findsOneWidget);
    await tester.pumpWidget(host(const ContextBar(62, label: false)));
    expect(find.bySemanticsLabel('context 62 percent used'), findsNothing);
    await tester.pumpWidget(host(const ContextBar(null)));
    expect(find.bySemanticsLabel('context unknown'), findsOneWidget);
    handle.dispose();
  });
}
