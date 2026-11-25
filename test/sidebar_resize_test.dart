import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/host_store.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;

import 'golden/fixtures.dart';

void main() {
  Future<HostStore> pump(WidgetTester tester, double width, [HostStore? use]) async {
    final store = use ?? await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: AppShell(key: UniqueKey()))));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return store;
  }

  double sidebarWidth(WidgetTester tester) => tester.getSize(find.byKey(const ValueKey('sidebar'))).width;
  Future<void> drag(WidgetTester tester, double dx) async {
    await tester.drag(find.byKey(const ValueKey('sidebar-resize')), Offset(dx, 0));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('dragging the sidebar border resizes it within 200 and 480 (the panel keeps 560); the width is saved '
      'when the drag ends and restored on the next launch', (tester) async {
    final store = await pump(tester, 1280);
    expect(sidebarWidth(tester), 264, reason: 'the default');
    expect(find.byWidgetPredicate((w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeColumn), findsWidgets);

    // Mid-drag nothing is written.
    final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('sidebar-resize'))));
    await g.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(sidebarWidth(tester), 324);
    expect(store.sidebarWidth, 264, reason: 'saved on drag end, not on every frame');
    await g.up();
    await tester.pump();
    expect(store.sidebarWidth, 324);

    await drag(tester, 1000);
    expect(sidebarWidth(tester), 480, reason: 'the max');
    await drag(tester, -1000);
    expect(sidebarWidth(tester), 200, reason: 'the min');
    await drag(tester, 140); // the touch slop swallows the first ~18dp of a drag
    final kept = sidebarWidth(tester);
    expect(kept, inInclusiveRange(300, 340));
    expect(store.sidebarWidth, kept);

    // The next launch: a new store over the same storage, a new shell.
    await tester.pumpWidget(const SizedBox());
    final again = HostStore();
    await again.load();
    expect(again.sidebarWidth, kept);
    await pump(tester, 1280, again);
    expect(sidebarWidth(tester), kept, reason: 'restored');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('in the smallest desktop window the widest sidebar leaves the panel 560', (tester) async {
    await pump(tester, 1000);
    await drag(tester, 600);
    expect(sidebarWidth(tester), 440);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
