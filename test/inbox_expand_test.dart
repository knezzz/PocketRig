import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/inbox/answering.dart';
import 'package:pocket_rig/ui/recent_screen.dart';

import 'golden/fixtures.dart';

Future<void> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final store = await installFakes();
  await tester.pumpWidget(MaterialApp(home: phone(store, const RecentScreen(visible: false))));
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _end(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  test('a pending ask keeps the last lines of what the agent did before it asked: commands, results, its own words', () {
    final lines = [
      '{"type":"assistant","uuid":"a0","timestamp":"2026-11-09T10:00:00Z","message":{"id":"m0","role":"assistant","content":[{"type":"tool_use","id":"t0","name":"Bash","input":{"command":"flutter test"}}]}}',
      '{"type":"user","uuid":"u0","timestamp":"2026-11-09T10:00:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t0","content":"All 412 tests passed.\\n"}]}}',
      '{"type":"assistant","uuid":"a1","timestamp":"2026-11-09T10:00:02Z","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"I\'d like to push this to main.\\nIt is ready."}]}}',
      '{"type":"assistant","uuid":"a2","timestamp":"2026-11-09T10:00:03Z","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"git push origin main"}}]}}',
    ];
    final p = PendingAsk.fromLines(lines)!;
    expect(p.command, 'git push origin main');
    expect(p.recent, [
      (r'$ flutter test', false),
      ('All 412 tests passed.', false),
      ('I\'d like to push this to main.', true),
    ], reason: 'the waiting call itself is the ask, not output');
  });

  testWidgets('phone: the first item is open in place, the others are one line; tapping a one-line item opens it and closes the first',
      (tester) async {
    await _pump(tester, const Size(390, 1400));
    final more = find.byIcon(Icons.expand_more);
    expect(find.byIcon(Icons.expand_less), findsOneWidget, reason: 'one open');
    expect(more, findsWidgets, reason: 'the rest are one line each');
    expect(find.text('CONTEXT'), findsOneWidget, reason: 'only the open one shows its context bar');
    expect(find.text('Allow once'), findsOneWidget, reason: 'and its answer');
    // The answer's small actions and Terminal / Open in chat are one set (it wraps on a phone), not two stacked rows.
    final actions = find.ancestor(of: find.text('Allow & switch to auto'), matching: find.byType(Wrap));
    expect(find.descendant(of: actions, matching: find.text('Terminal')), findsOneWidget);
    expect(find.descendant(of: actions, matching: find.text('Open in chat ›')), findsOneWidget);
    expect(find.text('Deny & tell it instead…'), findsOneWidget, reason: 'it is in the answer\'s link row, once');
    final collapsed = more.evaluate().length;
    // A screen reader hears the row: who, what, where, how long it has waited, and open or not.
    final handle = tester.ensureSemantics();
    await tester.pump();
    expect(find.bySemanticsLabel(RegExp(r'waiting \w+, expanded')), findsOneWidget, reason: 'the open card');
    expect(find.bySemanticsLabel(RegExp(r'waiting \w+, collapsed')), findsWidgets, reason: 'the others');
    handle.dispose();

    await tester.tap(more.first);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.expand_less), findsOneWidget, reason: 'still one open');
    expect(more.evaluate().length, collapsed, reason: 'the first closed as this one opened');

    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.expand_less), findsNothing, reason: 'tapping the open one closes it');
    expect(find.text('CONTEXT'), findsNothing);
    await _end(tester);
  });

  testWidgets('a wide window lists the items one line each on the left and shows the selected one open on the right',
      (tester) async {
    await _pump(tester, const Size(1280, 900));
    expect(find.byIcon(Icons.expand_less), findsNothing, reason: 'the detail has no fold');
    expect(find.text('CONTEXT'), findsOneWidget, reason: 'the open item, on the right');
    final before = tester.getTopLeft(find.text('CONTEXT')).dx;
    expect(before, greaterThan(380), reason: 'right of the 380 list');
    final rows = find.byIcon(Icons.expand_more);
    expect(rows, findsWidgets);
    await tester.tap(rows.last);
    await tester.pumpAndSettle();
    expect(find.text('CONTEXT'), findsOneWidget, reason: 'still one open, now the one picked');
    await _end(tester);
  });
}
