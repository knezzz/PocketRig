import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/host_store.dart' show isDesktop;
import 'package:pocket_rig/data/usage_rings.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;
import 'package:pocket_rig/ui/progress_bar.dart' show ProgressBar;
import 'package:pocket_rig/ui/theme.dart';
import 'package:pocket_rig/ui/usage_strip.dart';

import 'golden/fixtures.dart';

void main() {
  final now = DateTime.utc(2026, 11, 2, 12);
  HostUsage claude({int five = 20, int week = 90, Duration age = Duration.zero, String provider = 'claude'}) =>
      HostUsage(host: 'local', provider: provider, windows: [
        UsageWindow(window: 'five_hour', usedPercent: five, resetsAt: now.add(const Duration(hours: 1, minutes: 10)), asOf: now.subtract(age)),
        UsageWindow(window: 'weekly', usedPercent: week, resetsAt: now.add(const Duration(days: 3, hours: 4)), asOf: now.subtract(age)),
      ]);

  testWidgets('each host shows its Claude 5h and week as one compact display-only line in the pace colour; no reading, '
      'no line; a stale reading is faint; other providers are left out', (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    debugUsageClock = now;
    addTearDown(() {
      debugUsageClock = null;
      usageNow.reset();
    });
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    usageNow.set([
      (homelab, [claude()]),
      (macbook, [claude(provider: 'codex')]),
    ]);
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: AppShell(key: UniqueKey()))));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    const k = Tokens.light;
    final sidebar = find.byKey(const ValueKey('sidebar'));
    Color colorOf(String text) => tester.widget<Text>(find.descendant(of: sidebar, matching: find.text(text))).style!.color!;
    // One line per host: '5h ▮ 20%  wk ▮ 90%', in the pace colour; the codex-only host has none.
    expect(find.descendant(of: sidebar, matching: find.text('5h')), findsOneWidget, reason: 'one host has it');
    expect(find.descendant(of: sidebar, matching: find.text('wk')), findsOneWidget);
    expect(find.descendant(of: sidebar, matching: find.textContaining('resets in')), findsNothing, reason: 'the resets are in the tooltip');
    expect(colorOf('20%'), k.added, reason: '5h: under pace');
    expect(colorOf('90%'), k.removed, reason: 'week: far over pace');
    final line = find.ancestor(of: find.text('20%'), matching: find.byType(InkWell)).first;
    final bars = find.descendant(of: line, matching: find.byType(ProgressBar));
    expect(bars, findsNWidgets(2), reason: 'a bar for each window, before its percent');
    expect(bars.first, paints..rrect()..rrect(color: k.added));
    expect(tester.getSize(line).height, lessThanOrEqualTo(20), reason: 'one compact row');
    // The line starts at the host name's left edge, the bars fill it on a visible track, and each pace tick is where even use would be:
    // the 5h window has 1h 10m of 5h left (77% through it), the week 3d 4h of 7d (55% through).
    expect(tester.getTopLeft(find.descendant(of: sidebar, matching: find.text('5h'))).dx,
        closeTo(tester.getTopLeft(find.descendant(of: sidebar, matching: find.text('HOMELAB'))).dx, 0.5), reason: 'level with the host name');
    final progress = [for (final b in tester.widgetList<ProgressBar>(bars)) b];
    expect(progress[0].tick, closeTo(1 - 70 / 300, 0.001), reason: '5h pace');
    expect(progress[1].tick, closeTo(1 - (3 * 24 + 4) / 168, 0.001), reason: 'week pace');
    expect(progress.every((b) => b.track == k.border), isTrue, reason: 'a visible hairline track');
    expect(tester.getSize(bars.first).width, greaterThanOrEqualTo(40), reason: 'bars fill the line');
    expect(tester.widget<InkWell>(line).onTap, isNull, reason: 'display only');
    expect(tester.widget<Tooltip>(find.descendant(of: line, matching: find.byType(Tooltip))).message, '5h: 20% used, resets in 1h 10m\nweek: 90% used, resets in 3d 4h');
    bool said(String l) => find.byWidgetPredicate((w) => w is Semantics && w.properties.label == l).evaluate().isNotEmpty;
    expect(said('Claude usage, 5h · resets in 1h 10m, 20% used; week · resets in 3d 4h, 90% used'), isTrue);

    usageNow.set([(homelab, [claude(age: const Duration(hours: 2))]), (macbook, [claude(five: 50, week: 50)])]);
    await tester.pump();
    expect(find.descendant(of: sidebar, matching: find.text('5h')), findsNWidgets(2), reason: 'both hosts');
    expect(colorOf('90%'), k.faint, reason: 'stale');
    expect(said('Claude usage, 5h · resets in 1h 10m, 20% used, stale; week · resets in 3d 4h, 90% used, stale'), isTrue);

    usageNow.set(const []);
    await tester.pump();
    expect(find.descendant(of: sidebar, matching: find.text('5h')), findsNothing, reason: 'no reading, no line');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
