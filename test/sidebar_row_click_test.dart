import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/host_store.dart' show isDesktop;
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;

import 'golden/fixtures.dart';

void main() {
  testWidgets('a right click or long press on a host, project or rig row opens its action list', (tester) async {
    final store = await installFakes();
    showBarRigs = true;
    addTearDown(() => showBarRigs = false);
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(store: store, child: const MaterialApp(home: AppShell())));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    Future<void> check(String text) async {
      final at = tester.getCenter(find.text(text).first);
      final click = await tester.startGesture(at, kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await click.up();
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget, reason: '$text: a right click opens the action list');
      await tester.tapAt(const Offset(1200, 50));
      await tester.pumpAndSettle();
      await tester.longPressAt(at);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget, reason: '$text: a long press opens it too');
      await tester.tapAt(const Offset(1200, 50));
      await tester.pumpAndSettle();
    }

    for (final t in ['HOMELAB', 'bars', 'six-seat-pipeline']) {
      await check(t);
    }
  });

  testWidgets('on desktop the sidebar rows are dense from the first frame, before any mouse event', (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(store: store, child: const MaterialApp(home: AppShell())));
    await tester.pump();
    // The sidebar's rows only: a page header's title row is 48dp on the Mac by design.
    bool row(double h) => find
        .descendant(
            of: find.byKey(const ValueKey('sidebar')),
            matching: find.byWidgetPredicate((w) => w is ConstrainedBox && w.constraints.minHeight == h && w.constraints.maxHeight.isInfinite))
        .evaluate()
        .isNotEmpty;
    expect(row(32), isTrue, reason: 'mouse density');
    expect(row(48), isFalse, reason: 'no touch rows on the Mac');
  });
}
