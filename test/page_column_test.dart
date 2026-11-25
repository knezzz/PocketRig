import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/hosts_screen.dart';
import 'package:pocket_rig/ui/kit.dart';
import 'package:pocket_rig/ui/page_column.dart';

import 'golden/fixtures.dart';

void main() {
  for (final (name, width, body) in [
    ('Hosts and settings', 390.0, 390.0),
  ]) {
    testWidgets('$name at $width: the header is full width and the body is at most $body wide', (tester) async {
      final store = await installFakes();
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const screen = HostsScreen();
      await tester.pumpWidget(MaterialApp(home: phone(store, screen)));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.getSize(find.byType(PageHeader)).width, width);
      // Hosts and settings has its title at the pane's edge (after the back button this test's route shows).
      expect(tester.getTopLeft(find.text(name)).dx,
          lessThanOrEqualTo(60),
          reason: 'the title is at the pane edge');
      expect(tester.getSize(find.descendant(of: find.byType(PageColumn), matching: find.byType(ListView)).first).width, body);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  }

  testWidgets('the wheel scrolls the page over the side margins too', (tester) async {
    final store = await installFakes();
    tester.view.physicalSize = const Size(1280, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: phone(store, Scaffold(body: PageColumn(child: ListView(children: [for (var i = 0; i < 30; i++) SizedBox(height: 60, child: Text('row $i'))]))))));
    await tester.pump(const Duration(milliseconds: 200));
    final list = find.descendant(of: find.byType(PageColumn), matching: find.byType(Scrollable)).first;
    double offset() => tester.state<ScrollableState>(list).position.pixels;
    expect(offset(), 0);
    final margin = Offset(40, tester.getCenter(list).dy);
    expect(tester.getRect(list).left, greaterThan(margin.dx), reason: 'the point is outside the column');
    final pointer = TestPointer(1, PointerDeviceKind.mouse)..hover(margin);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await tester.pump();
    expect(offset(), greaterThan(0), reason: 'a wheel turn at the far left moved the list');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
