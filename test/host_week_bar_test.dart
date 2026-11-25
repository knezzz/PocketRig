import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/usage_rings.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/theme.dart';
import 'package:pocket_rig/ui/usage_strip.dart';

Host host(String id) => Host(id: id, name: id, address: '10.0.0.1', sshUser: 'u');

HostUsage usage(String provider, num weekly, {String sub = 'local', num? five = 99, Duration age = Duration.zero}) {
  final now = DateTime.utc(2026, 11, 2, 12);
  final asOf = now.subtract(age);
  return HostUsage(host: sub, provider: provider, windows: [
    UsageWindow(window: 'weekly', usedPercent: weekly, resetsAt: now.add(const Duration(days: 3)), asOf: asOf),
    if (five != null)
      UsageWindow(window: 'five_hour', usedPercent: five, resetsAt: now.add(const Duration(hours: 1)), asOf: asOf),
  ]);
}

Future<void> pump(WidgetTester tester, Host h) => tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: Scaffold(body: HostUsageBar(host: h, now: DateTime.utc(2026, 11, 2, 12))),
    ));

void main() {
  setUp(usageNow.reset);

  testWidgets('shows the highest weekly use for this host only', (tester) async {
    final a = host('a'), b = host('b');
    usageNow.set([
      (a, [usage('claude', 40), usage('codex', 62, sub: 'box')]),
      (b, [usage('claude', 90)]),
    ]);
    final semantics = tester.ensureSemantics();
    await pump(tester, a);
    expect(find.bySemanticsLabel('Codex 7-day usage 62%'), findsOneWidget);
    expect(tester.getSize(find.byType(HostUsageBar)).height, 4);
    semantics.dispose();
  });

  testWidgets('no weekly reading for the host draws nothing', (tester) async {
    usageNow.set([(host('b'), [usage('claude', 90)])]);
    await pump(tester, host('a'));
    expect(tester.getSize(find.byType(HostUsageBar)), Size.zero);
  });

  testWidgets('the 5-hour bar shows the highest 5-hour use and reads like the week bar', (tester) async {
    final a = host('a');
    usageNow.set([
      (a, [usage('claude', 10, five: 31), usage('codex', 20, sub: 'box', five: 58)]),
    ]);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: Scaffold(
          body: HostUsageBar(host: a, window: HostUsageBar.fiveHour, now: DateTime.utc(2026, 11, 2, 12))),
    ));
    expect(find.bySemanticsLabel('Codex 5-hour usage 58%'), findsOneWidget);
    expect(tester.getSize(find.byType(HostUsageBar)).height, 4);
    expect(HostUsageBar.labelsFor(a), ['Codex 5-hour usage 58%', 'Codex 7-day usage 20%']);
    semantics.dispose();
  });

  testWidgets('no 5-hour reading: the bar draws nothing alone, but as a row it keeps its space', (tester) async {
    final a = host('a');
    usageNow.set([(a, [usage('claude', 40, five: null)])]);
    Widget app(Widget w) => MaterialApp(theme: buildTheme(Tokens.light, Brightness.light), home: Scaffold(body: w));
    final clock = DateTime.utc(2026, 11, 2, 12);
    await tester.pumpWidget(app(HostUsageBar(host: a, window: HostUsageBar.fiveHour, now: clock)));
    expect(tester.getSize(find.byType(HostUsageBar)), Size.zero);
    await tester.pumpWidget(app(HostUsageBar(host: a, window: HostUsageBar.fiveHour, topGap: 3, asRow: true, now: clock)));
    expect(tester.getSize(find.byType(HostUsageBar)).height, 3 + HostUsageBar.rowHeight);
    expect(HostUsageBar.labelsFor(a), ['Claude 7-day usage 40%']);
  });

  testWidgets('the two rows are labelled 5h and week and are the same height with or without a 5-hour reading',
      (tester) async {
    final a = host('a');
    Future<Size> bars(HostUsage u) async {
      usageNow.set([(a, [u])]);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Tokens.light, Brightness.light),
        home: Scaffold(body: SizedBox(width: 120, child: HostUsageBars(host: a, now: DateTime.utc(2026, 11, 2, 12)))),
      ));
      return tester.getSize(find.byType(HostUsageBars));
    }

    final both = await bars(usage('claude', 40, five: 20));
    expect(find.text('5h'), findsOneWidget);
    expect(find.text('week'), findsOneWidget);
    final weekOnly = await bars(usage('claude', 40, five: null));
    expect(find.text('week'), findsOneWidget);
    expect(find.text('5h'), findsNothing);
    expect(weekOnly.height, both.height);
    usageNow.set(const []);
    await tester.pump();
    expect(tester.getSize(find.byType(HostUsageBars)).height, 0, reason: 'no reading at all: nothing');
  });

  testWidgets('a fresh reading beats a stale one, then the highest wins', (tester) async {
    final a = host('a');
    final clock = DateTime.utc(2026, 11, 2, 12);
    usageNow.set([
      (a, [usage('claude', 90, five: 90, age: const Duration(hours: 3)), usage('codex', 40, sub: 'box', five: 25)]),
    ]);
    expect(HostUsageBar.labelFor(a, HostUsageBar.weekly, clock), 'Codex 7-day usage 40%', reason: 'stale 90 vs fresh 40');
    expect(HostUsageBar.labelFor(a, HostUsageBar.fiveHour, clock), 'Codex 5-hour usage 25%');
    usageNow.set([
      (a, [usage('claude', 90, age: const Duration(hours: 3)), usage('codex', 40, sub: 'box', age: const Duration(hours: 2))]),
    ]);
    expect(HostUsageBar.labelFor(a, HostUsageBar.weekly, clock), 'Claude 7-day usage 90%', reason: 'all stale: highest');
  });

  testWidgets('next to a short count line each bar is still at least 80 wide', (tester) async {
    final a = host('a');
    usageNow.set([(a, [usage('claude', 40, five: 20)])]);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: Scaffold(
        body: Align(
          alignment: Alignment.centerRight,
          child: IntrinsicWidth(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('1 project', textAlign: TextAlign.right),
              HostUsageBars(host: a, now: DateTime.utc(2026, 11, 2, 12)),
            ]),
          ),
        ),
      ),
    ));
    final bars = find.descendant(
        of: find.byType(HostUsageBars), matching: find.byWidgetPredicate((w) => w is SizedBox && w.height == 4));
    expect(bars, findsNWidgets(2));
    for (final e in bars.evaluate()) {
      expect(e.size!.width, greaterThanOrEqualTo(80));
    }
  });
}
