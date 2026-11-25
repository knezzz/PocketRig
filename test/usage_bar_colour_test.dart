import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/usage_rings.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/theme.dart';
import 'package:pocket_rig/ui/usage_strip.dart';

final now = DateTime.utc(2026, 11, 2, 12);
final a = Host(id: 'a', name: 'a', address: '10.0.0.1', sshUser: 'u');

HostUsage usage(num weekly, num five, {Duration age = Duration.zero}) => HostUsage(host: 'local', provider: 'claude', windows: [
      UsageWindow(window: 'weekly', usedPercent: weekly, resetsAt: now.add(const Duration(days: 3)), asOf: now.subtract(age)),
      UsageWindow(window: 'five_hour', usedPercent: five, resetsAt: now.add(const Duration(hours: 1)), asOf: now.subtract(age)),
    ]);

/// The fill of each bar painter under [of], in order.
List<Color> fills(WidgetTester tester, Finder of) => [
      for (final c in tester.widgetList<CustomPaint>(find.descendant(of: of, matching: find.byType(CustomPaint))))
        if (c.painter.runtimeType.toString() == '_BarPainter') (c.painter as dynamic).fill as Color,
    ];

void main() {
  setUp(usageNow.reset);
  const k = Tokens.light;
  Future<void> pump(WidgetTester tester, Widget w) =>
      tester.pumpWidget(MaterialApp(theme: buildTheme(k, Brightness.light), home: Scaffold(body: w)));

  testWidgets('the strip bar fill is its % text colour: pace colour, faint when stale', (tester) async {
    // 5h then week; week pace 57%, 5h pace 80%: 20% is under pace (green), 90% far over (red).
    usageNow.set([(a, [usage(90, 20)])]);
    await pump(tester, UsageStrip(now: now));
    expect(fills(tester, find.byType(UsageStrip)), [k.added, k.removed]);
    Color text(String t) => tester.widget<Text>(find.text(t)).style!.color!;
    expect(text('90%'), k.removed);
    expect(text('20%'), k.added);

    usageNow.set([(a, [usage(90, 20, age: const Duration(hours: 2))])]);
    await tester.pump();
    expect(fills(tester, find.byType(UsageStrip)), [k.faint, k.faint]);
  });

  testWidgets('a host bar fill is the pace colour too', (tester) async {
    usageNow.set([(a, [usage(43, 80)])]); // exactly on pace: gray
    await pump(tester, HostUsageBar(host: a, window: HostUsageBar.fiveHour, now: now));
    expect(fills(tester, find.byType(HostUsageBar)), [k.muted]);
  });
}
