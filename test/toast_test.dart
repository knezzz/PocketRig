import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/common.dart';
import 'package:pocket_rig/ui/kit.dart' show RowTile;
import 'package:pocket_rig/ui/recent_screen.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

void main() {
  setUp(() {
    animateStatusSpinners = false;
    toastProblems.value = const [];
  });

  Future<void> app(WidgetTester tester, void Function(BuildContext) onTap) {
    // A phone with a status bar: the toast sits in the app's overlay, so the window's padding is what it sees.
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(390, 844)
      ..padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.reset);
    return tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(child: TextButton(onPressed: () => onTap(context), child: const Text('go'))),
        ),
      ),
    ));
  }

  testWidgets('a done toast shows at the top, under the status bar, and is gone after 3 s', (tester) async {
    await app(tester, (c) => toast(c, 'Saved', kind: ToastKind.done));
    await tester.tap(find.text('go'));
    await tester.pump(); // the toast's first frame starts its clock
    await tester.pump(const Duration(milliseconds: 300));
    final y = tester.getTopLeft(find.text('Saved')).dy;
    expect(y, inInclusiveRange(47, 120), reason: 'at the top, below the safe area');
    await tester.pump(const Duration(milliseconds: 2600));
    expect(find.text('Saved'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Saved'), findsNothing);
  });

  testWidgets('a problem toast goes on its own after 6 s; a swipe up dismisses early; one at a time', (tester) async {
    var n = 0;
    await app(tester, (c) => toast(c, n++ == 0 ? "Couldn't send" : 'Second', kind: n == 1 ? ToastKind.problem : null));
    await tester.tap(find.text('go'));
    await tester.pump(); // the toast's first frame starts its clock
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text("Couldn't send"), findsOneWidget);
    expect(find.byTooltip('Dismiss'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 5500));
    expect(find.text("Couldn't send"), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text("Couldn't send"), findsNothing);

    await tester.tap(find.text('go'));
    await tester.pump(); // the toast's first frame starts its clock
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('go'));
    await tester.pump(); // the toast's first frame starts its clock
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Second'), findsOneWidget, reason: 'one at a time');
    await tester.fling(find.text('Second'), const Offset(0, -200), 1000);
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsNothing);
  });

  testWidgets('a problem toast stays in the Inbox after it goes, with its action; done toasts do not', (tester) async {
    final store = await installFakes();
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: phone(store, const RecentScreen(visible: false))));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final c = tester.element(find.byType(RecentScreen));
    var retried = 0;
    toast(c, 'Saved', kind: ToastKind.done);
    toast(c, "Couldn't stop conveyor", kind: ToastKind.problem, action: 'Retry', onAction: () => retried++);
    await tester.pump();
    await tester.pump(const Duration(seconds: 7)); // the toast is gone
    // Under the Needs you cards.
    await tester.scrollUntilVisible(find.text('PROBLEMS · 1'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('PROBLEMS · 1'), findsOneWidget);
    expect(find.text("Couldn't stop conveyor"), findsOneWidget, reason: 'the Inbox row, not the toast');
    expect(find.text('Saved'), findsNothing, reason: 'done toasts stay out of the Inbox');
    final row = find.ancestor(of: find.text("Couldn't stop conveyor"), matching: find.byType(RowTile));
    await tester.ensureVisible(row);
    await tester.pump();
    await tester.tap(find.descendant(of: row, matching: find.text('Retry')));
    expect(retried, 1);
    await tester.tap(find.byTooltip('Clear'));
    await tester.pump();
    expect(find.textContaining('PROBLEMS'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('with a screen reader on, a toast with an action stays until closed', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await app(tester, (c) => toast(c, 'Relaunching', kind: ToastKind.info, action: 'Open', onAction: () {}));
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('Open'), findsOneWidget);
    // Closable without taking the action.
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(find.text('Relaunching'), findsNothing);
  });
}
