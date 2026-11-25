import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/host_store.dart' show isDesktop;
import 'package:pocket_rig/data/subagents.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ui/chat_screen.dart' show ChatPage;
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;
import 'package:pocket_rig/ui/terminal_screen.dart' show TerminalScreen;
import 'package:pocket_rig/ui/progress_bar.dart' show ProgressBar;
import 'package:pocket_rig/ui/theme.dart';
import 'package:pocket_rig/ui/usage_strip.dart' show contextColor, contextWeight;

import 'golden/fixtures.dart';

void main() {
  test('context colour: grey (no amber) to 79, red from 80; the % bolder from 60', () {
    for (final k in [Tokens.light, Tokens.dark]) {
      expect(contextColor(0, k), k.muted);
      expect(contextColor(40, k), k.muted);
      expect(contextColor(60, k), k.muted, reason: 'no amber: orange is for needs-you');
      expect(contextColor(79, k), k.muted);
      expect(contextColor(80, k), k.removed);
      expect(contextWeight(59), isNull);
      expect(contextWeight(60), FontWeight.w700, reason: 'the % is bolder from 60');
      expect(contextColor(100, k), k.removed);
    }
  });

  testWidgets('sidebar agent rows show their context % at the right edge in the shared colour, and a subagent row is '
      'the same row but still opens its agent', (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    showBarRigs = false;
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final feed = fleet.feedFor(homelab);
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: AppShell(key: UniqueKey()))));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // conveyor: review 31% (grey), lead 62% (grey, bolder), impl 84% (red).
    const k = Tokens.light;
    Color colorOf(String text) => tester.widget<Text>(find.text(text).first).style!.color!;
    expect(colorOf('31%'), k.muted);
    expect(colorOf('62%'), k.muted);
    expect(colorOf('84%'), k.removed);
    expect(find.text('0%'), findsNothing, reason: 'only a seat that reports a value shows one');
    // The percent sits over a thin bar in the same colour, and a working agent shows how long since it worked
    // (its last reply or hook event, here the daemon's older fallback): 'now' for impl, 1m for attacker.
    final impl = find.ancestor(of: find.text('84%'), matching: find.byType(InkWell)).first;
    expect(find.descendant(of: impl, matching: find.byType(ProgressBar)), findsOneWidget);
    // The bar is on its own line under the name, wider than the old 30dp slot, and the percent ends the line at its right.
    final bar = tester.getRect(find.descendant(of: impl, matching: find.byType(ProgressBar)));
    final name = tester.getRect(find.descendant(of: impl, matching: find.text('impl')).first);
    final pct = tester.getRect(find.descendant(of: impl, matching: find.text('84%')));
    expect(bar.top - name.bottom, inInclusiveRange(1, 3), reason: 'a hairline under the name');
    expect(bar.width, greaterThan(60));
    expect(bar.right, lessThan(pct.left));
    expect(tester.getSize(impl).height, 36, reason: 'a bar row is 36dp on a mouse (32 without a bar)');
    // The percents are one column the trailing column's width, centred under the row's ⋯ icon, so every bar ends at one x.
    final more = tester.getRect(find.descendant(of: impl, matching: find.byIcon(Icons.more_horiz)));
    expect(pct.center.dx, closeTo(more.center.dx, 0.5), reason: 'the percent is centred under the row\'s ⋯');
    for (final t in ['31%', '62%', '40%']) {
      final row = find.ancestor(of: find.text(t), matching: find.byType(InkWell)).first;
      expect(tester.getRect(find.descendant(of: row, matching: find.text(t))).right, closeTo(pct.right, 0.5), reason: t);
      expect(tester.getRect(find.descendant(of: row, matching: find.byType(ProgressBar))).right, closeTo(bar.right, 0.5), reason: '$t bar');
    }
    expect(find.descendant(of: impl, matching: find.text('now')), findsOneWidget);
    expect(find.descendant(of: find.ancestor(of: find.text('40%'), matching: find.byType(InkWell)).first, matching: find.text('1m')),
        findsOneWidget);
    expect(find.descendant(of: find.ancestor(of: find.text('62%'), matching: find.byType(InkWell)).first, matching: find.textContaining(RegExp(r'^\d+[mhd]$|^now$'))),
        findsNothing, reason: 'lead has no work time: no ago, not the pane\'s');

    feed.subagents = {
      'sess-lead': [Subagent(sessionId: 'sess-lead', agentId: 'a1', description: 'Write the parser', type: 'general-purpose')],
    };
    await feed.refresh();
    await tester.pump(const Duration(milliseconds: 400));
    double rowHeight(String text) =>
        tester.getSize(find.ancestor(of: find.text(text), matching: find.byType(InkWell)).first).height;
    expect(rowHeight('Write the parser'), 32, reason: 'the same row as an agent\'s without a bar');
    expect(rowHeight('lead'), greaterThanOrEqualTo(32));
    expect(
        find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Write the parser, subagent, running' && w.properties.button == true),
        findsWidgets,
        reason: 'still a button for a screen reader; the whole row is the target (one under each rig whose lead runs it)');
  });

  testWidgets('on touch a row with a context bar is still 48dp tall, has no dots button (a long press opens its list), with the '
      'bar 2dp under the name', (tester) async {
    final store = await installFakes();
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: AppShell(key: UniqueKey()))));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byIcon(Icons.menu).first);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    final row = find.ancestor(of: find.text('84%'), matching: find.byType(InkWell)).first;
    expect(tester.getSize(row).height, 48);
    expect(find.descendant(of: row, matching: find.byTooltip('Actions for impl')), findsNothing);
    final bar = tester.getRect(find.descendant(of: row, matching: find.byType(ProgressBar)));
    final name = tester.getRect(find.descendant(of: row, matching: find.text('impl')).first);
    expect(bar.top - name.bottom, inInclusiveRange(1, 3));
    expect(bar.bottom, lessThan(tester.getRect(row).bottom));
  });

  testWidgets('a subagent row is a button on touch and opens its log as a chat; with no log yet it opens its agent; '
      'the agent\'s own row still opens the agent', (tester) async {
    final store = await installFakes();
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final feed = fleet.feedFor(homelab);
    const log = '/h/.claude/projects/p/sess-lead/subagents/agent-a1.jsonl';
    final handle = tester.ensureSemantics();
    Future<void> openDrawer() async {
      await tester.tap(find.byIcon(Icons.menu).first);
      await tester.pumpAndSettle();
      await feed.refresh();
      await tester.pump(const Duration(milliseconds: 400));
    }

    feed.subagents = {
      'sess-lead': [Subagent(sessionId: 'sess-lead', agentId: 'a1', description: 'Write the parser', type: 'general-purpose', path: log)],
    };
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: AppShell(key: UniqueKey()))));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await openDrawer();
    final label = find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Write the parser, subagent, running');
    expect(label, findsWidgets);
    expect(tester.widgetList<Semantics>(label).every((w) => w.properties.button == true), isTrue, reason: 'a button for a screen reader');
    expect(tester.getSemantics(label.first).getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    // The whole row, from edge to edge, is the target; the row is not taller than before.
    final row = find.ancestor(of: find.text('Write the parser').first, matching: find.byType(InkWell)).first;
    final r = tester.getRect(row);
    expect(r.height, 48, reason: 'the same row as an agent\'s');
    await tester.tapAt(Offset(r.left + 3, r.center.dy));
    await tester.pumpAndSettle();
    final page = tester.widget<ChatPage>(find.byType(ChatPage));
    expect(page.seat.transcriptPath, log, reason: 'the subagent\'s own log');
    expect(find.byType(TerminalScreen), findsNothing);

    // No log yet: its agent opens.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    feed.subagents = {
      'sess-lead': [Subagent(sessionId: 'sess-lead', agentId: 'a1', description: 'Write the parser', type: 'general-purpose')],
    };
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: AppShell(key: UniqueKey()))));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await openDrawer();
    await tester.tap(find.text('Write the parser').first);
    await tester.pumpAndSettle();
    expect(find.byType(TerminalScreen), findsOneWidget, reason: 'the parent agent (a phone opens agents on their terminal)');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));

    // The agent's own row opens the agent, not a subagent.
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: AppShell(key: UniqueKey()))));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await openDrawer();
    await tester.tap(find.text('lead').first);
    await tester.pumpAndSettle();
    expect(find.byType(TerminalScreen), findsOneWidget);
    handle.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('on desktop a click on a subagent row opens its log in the content panel', (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    showBarRigs = false;
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const log = '/h/.claude/projects/p/sess-lead/subagents/agent-a1.jsonl';
    final feed = fleet.feedFor(homelab);
    feed.subagents = {
      'sess-lead': [Subagent(sessionId: 'sess-lead', agentId: 'a1', description: 'Write the parser', type: 'general-purpose', path: log)],
    };
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: AppShell(key: UniqueKey()))));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await feed.refresh();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Write the parser').first);
    await tester.pumpAndSettle();
    expect(tester.widget<ChatPage>(find.byType(ChatPage)).seat.transcriptPath, log);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
