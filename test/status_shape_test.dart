import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/kit.dart' show labelFor;
import 'package:pocket_rig/ui/project_tally.dart';
import 'package:pocket_rig/ui/app_icon.dart';
import 'package:pocket_rig/ui/status_shape.dart';
import 'app_icon_finders.dart';
import 'package:pocket_rig/ui/theme.dart';

Seat seat(String activity, {String status = 'running'}) => Seat.fromJson({
      'rigId': 'r1',
      'logicalId': 'a',
      'runtime': 'claude-code',
      'sessionStatus': status,
      'activityState': {'activity': activity},
    });

RigWithSeats rig(List<Seat> seats, {String status = 'running', int attention = 0}) => RigWithSeats(
    Rig(id: 'r1', name: 'conveyor', nodeCount: seats.length, runningCount: seats.length, attentionCount: attention, status: status),
    seats);

Future<RenderObject> _paint(WidgetTester tester, Status s, {bool dark = false, bool still = false}) async {
  await tester.pumpWidget(MediaQuery(
    data: MediaQueryData(disableAnimations: still),
    child: MaterialApp(
      theme: dark ? buildTheme(Tokens.dark, Brightness.dark) : buildTheme(Tokens.light, Brightness.light),
      home: Center(child: StatusShape(s, size: 12)),
    ),
  ));
  return tester.renderObject(find.descendant(of: find.byType(StatusShape), matching: find.byType(CustomPaint)));
}

void main() {
  group('every status is a circle, told apart by style', () {
    testWidgets('idle is a plain grey dot, shell one ring, working a disc', (tester) async {
      final idle = await _paint(tester, Status.idle);
      expect(idle, paints..circle(radius: 12 * 0.35), reason: 'a dot at 70% of the 12 dp mark');
      expect(idle, paintsExactlyCountTimes(#drawArc, 0));
      expect(await _paint(tester, Status.shell), paintsExactlyCountTimes(#drawArc, 1));
      expect(await _paint(tester, Status.working), paints..circle());
    });

    testWidgets('stopped is six dashes over a faint fill, in a colour near muted, with no square', (tester) async {
      final r = await _paint(tester, Status.stopped);
      expect(r, paintsExactlyCountTimes(#drawArc, 6));
      expect(r, paintsExactlyCountTimes(#drawCircle, 1), reason: 'the faint fill');
      expect(r, paintsExactlyCountTimes(#drawRect, 0));
      // The dashes lean toward muted in dark too: plain faint is under 3:1 on the card.
      await _paint(tester, Status.stopped, dark: true);
      await tester.pump(const Duration(seconds: 1)); // MaterialApp animates the switch from light
      final k = Tokens.of(tester.element(find.byType(StatusShape)));
      expect(k.isDark, isTrue, reason: 'the dark tokens');
      expect(tester.renderObject(find.descendant(of: find.byType(StatusShape), matching: find.byType(CustomPaint))),
          paints..arc(color: Color.lerp(k.faint, k.muted, 0.7), strokeWidth: 1.5));
    });

    testWidgets('failed is a disc with a bar cut out, degraded a ring with a half fill', (tester) async {
      expect(await _paint(tester, Status.failed), paints..circle()..rect());
      expect(await _paint(tester, Status.degraded), paints..arc(useCenter: true)..arc(useCenter: false));
    });

    testWidgets('needs you pulses, and with reduce-motion is a static ring', (tester) async {
      animateStatusSpinners = true; // tests turn it off globally
      addTearDown(() => animateStatusSpinners = false);
      final r = await _paint(tester, Status.needsYou);
      expect(r, paints..circle()..circle(style: PaintingStyle.stroke));
      await tester.pump(const Duration(milliseconds: 400));
      final grown = tester.renderObject(find.descendant(of: find.byType(StatusShape), matching: find.byType(CustomPaint)));
      expect(grown, paints..circle()..circle(style: PaintingStyle.stroke));
      expect(tester.hasRunningAnimations, isTrue);

      await _paint(tester, Status.needsYou, still: true);
      await tester.pump(const Duration(seconds: 2));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('a status shape is never smaller than 11dp, so dashes and the bar stay readable', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Center(child: StatusShape(Status.idle, size: 8))));
      expect(tester.getSize(find.byType(StatusShape)).width, 11);
    });
  });

  group('a rig shows the most urgent state among its seats', () {
    test('needs you > working > shell > idle > stopped', () {
      expect(rigStatus(rig([seat('working'), Seat(rigId: 'r1', logicalId: 'b', runtime: 'claude-code', needsInput: true)]), null),
          Status.needsYou);
      expect(rigStatus(rig([seat('working')], attention: 1), null), Status.working, reason: 'a daemon item alone is no ask');
      expect(rigStatus(rig([seat('idle-at-prompt'), seat('working')]), null), Status.working);
      expect(rigStatus(rig([seat('idle-at-prompt'), seat('idle-at-prompt')]), null), Status.idle);
      expect(rigStatus(rig([seat('working')], status: 'stopped'), null), Status.stopped);
    });
  });

  test('a seat state has one label, the status label (on shell, not on shell, no tokens)', () {
    for (final st in SeatState.values) {
      expect(labelFor(st), Status.of(st).label);
    }
    expect(labelFor(SeatState.shell), 'waiting on shell');
  });

  test('text takes the state color, except idle and stopped, which read muted', () {
    const k = Tokens.dark;
    expect(Status.working.textColor(k), k.added);
    expect(Status.needsYou.textColor(k), k.accent);
    expect(Status.shell.textColor(k), k.shell);
    expect(Status.idle.textColor(k), k.muted);
    expect(Status.stopped.textColor(k), k.muted, reason: 'not the mark\'s faint');
  });

  testWidgets('the rig and agent icons differ and carry one labelled status badge', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Column(children: [StatusIcon.rig(Status.working), StatusIcon.agent(Status.needsYou)]),
    ));
    expect(appIcon(AppIconKind.rig), findsOneWidget);
    expect(appIcon(AppIconKind.agent), findsOneWidget);
    expect(find.bySemanticsLabel('working'), findsOneWidget);
    expect(find.bySemanticsLabel('Agent, needs you'), findsOneWidget, reason: 'an agent has no dot: its icon says the state');
    expect(tester.getSize(find.byType(StatusIcon).first), const Size(28, 28));
    // The badge is at the icon's top right, not level with a tally under the title.
    final box = tester.getRect(find.byType(StatusIcon).first);
    final badge = tester.getCenter(find.descendant(of: find.byType(StatusIcon).first, matching: find.byType(StatusShape)));
    expect(badge.dx, greaterThan(box.center.dx));
    expect(badge.dy, lessThan(box.center.dy));
  });

  testWidgets('an agent in a rig is the loose agent\'s robot plus a hub badge at its bottom right; a loose agent has none',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Column(children: [StatusIcon.seat(Status.working), StatusIcon.agent(Status.working)]),
    ));
    final seat = find.byType(StatusIcon).first;
    expect(find.descendant(of: seat, matching: appIcon(AppIconKind.agent)), findsOneWidget);
    expect(find.descendant(of: find.byType(StatusIcon).last, matching: appIcon(AppIconKind.rig)), findsNothing);
    final box = tester.getRect(seat);
    final hub = tester.getCenter(find.descendant(of: seat, matching: appIcon(AppIconKind.rig)));
    expect(hub.dx, greaterThan(box.center.dx));
    expect(hub.dy, greaterThan(box.center.dy));
  });

  testWidgets('a subagent takes its state colour (grey when idle) and a shell is blue, both 17dp; the subagent has a state dot, the shell none: its blue icon is enough',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Column(children: [
        StatusIcon.agent(Status.working, compact: true),
        StatusIcon.subagent(Status.working),
        StatusIcon.subagent(Status.idle),
        StatusIcon.shell(Status.working),
      ]),
    ));
    const k = Tokens.light;
    final subs = tester.widgetList<AppIcon>(appIcon(AppIconKind.subagent)).toList();
    expect(subs[0].color, Status.working.color(k), reason: 'green while it works');
    expect(subs[1].color, k.muted, reason: 'grey when idle');
    final shell = tester.widget<AppIcon>(appIcon(AppIconKind.shell));
    expect(shell.color, k.terminal);
    expect([subs[0].size, shell.size], [17, 17]);
    expect(find.byType(StatusShape), findsNWidgets(2), reason: 'a state dot on the subagents; the agent\'s icon is its state colour and a shell has none');
    expect(find.descendant(of: find.byType(StatusIcon).last, matching: find.byType(StatusShape)), findsNothing, reason: 'a shell row has no green (or any) dot');
  });

  test('the shell blue reads on every ground the rows sit on: at least 3:1', () {
    double lum(Color c) {
      double f(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
    }

    double ratio(Color a, Color b) {
      final x = lum(a), y = lum(b);
      return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
    }

    for (final k in [Tokens.light, Tokens.dark]) {
      for (final ground in [k.ground, k.headerFill, k.surface]) {
        expect(ratio(k.terminal, ground), greaterThanOrEqualTo(3));
      }
    }
  });
}
