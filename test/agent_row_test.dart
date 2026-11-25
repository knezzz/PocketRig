import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/agent_jobs.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/host_store.dart' show isDesktop;
import 'package:pocket_rig/data/subagents.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/kit.dart';
import 'package:pocket_rig/ui/rig/seats_tab.dart' show SeatList;
import 'package:pocket_rig/ui/subagent_open.dart' show lastSubagentRequest;
import 'package:pocket_rig/ui/status_shape.dart';
import 'package:pocket_rig/ui/theme.dart';
import 'package:pocket_rig/ui/usage_strip.dart' show contextColor;

import 'golden/fixtures.dart';

void main() {
  testWidgets('an AgentRow shows icon, name, NEEDS YOU, the task, age and context; its ⋯ and tap both work; starting is inert', (tester) async {
    var tapped = 0, more = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          AgentRow(
              name: 'lead',
              status: Status.needsYou,
              needsYou: true,
              task: 'asks to run git push',
              age: '2m',
              context: 62,
              onTap: () => tapped++,
              onMore: () => more++,
              moreTooltip: 'lead details'),
          const AgentRow(name: 'booting', status: Status.stopped, task: 'not ready', dim: true),
        ]),
      ),
    ));
    expect(find.byType(StatusIcon), findsNWidgets(2));
    expect(find.textContaining('NEEDS YOU', findRichText: true), findsOneWidget);
    expect(find.text('asks to run git push'), findsOneWidget);
    expect(find.text('2m'), findsOneWidget);
    expect(find.text('62%'), findsOneWidget);
    expect(tester.widget<Text>(find.text('62%')).style?.color, contextColor(62, Tokens.light));
    await tester.tap(find.text('asks to run git push'));
    await tester.longPress(find.text('asks to run git push'));
    expect((tapped, more), (1, 1), reason: 'a long press opens its list');
    expect(find.text('NEEDS YOU'), findsNothing);
  });

  testWidgets('an AgentRow that opens in place shows a chevron, up when open', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Column(children: [AgentRow(name: 'a', status: Status.idle, expanded: false), AgentRow(name: 'b', status: Status.idle, expanded: true), AgentRow(name: 'c', status: Status.idle)]))));
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    expect(find.byIcon(Icons.expand_less), findsOneWidget);
  });

  testWidgets('the rig page list nests a seat\'s subagents and shells one step in under it; a subagent opens its log, a shell its agent', (tester) async {
    final store = await installFakes();
    final feed = fleet.feedFor(homelab);
    feed.subagents = {
      'sess-lead': [Subagent(sessionId: 'sess-lead', agentId: 'a1', description: 'Write the parser', type: 'general-purpose', path: '/h/.claude/projects/p/sess-lead/subagents/agent-a1.jsonl')],
    };
    final lead = Seat(rigId: 'r', logicalId: 'lead', runtime: 'claude-code', resumeToken: 'sess-lead', activity: 'working')
      ..jobs = AgentJob.parse("J\t9\tS\t02:00:00\t0\t0\t/bin/zsh -c source /h/.claude/shell-snapshots/s.sh && eval 'flutter run -d macos' < /dev/null\n");
    final opened = <String>[];
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(
        store: store,
        child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: SeatList(seats: [lead], onOpen: (s) => opened.add(s.logicalId), onMore: (_) {}))))));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Write the parser'), findsOneWidget);
    expect(find.textContaining('flutter run', findRichText: true), findsOneWidget);
    expect(tester.getTopLeft(find.text('Write the parser')).dx, greaterThan(tester.getTopLeft(find.textContaining('lead', findRichText: true).first).dx),
        reason: 'one step in');
    await tester.tap(find.textContaining('flutter run', findRichText: true));
    expect(opened, ['lead'], reason: 'a shell opens its agent');
    await tester.tap(find.text('Write the parser'));
    expect(lastSubagentRequest?.sub.agentId, 'a1', reason: 'a subagent asks the shell for its log');
  });

  testWidgets('with a mouse the ⋯ shows only while the row is hovered', (tester) async {
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AgentRow(name: 'lead', status: Status.idle, onMore: () {}, moreTooltip: 'lead details'))));
    double dots() => tester.widget<Opacity>(find.ancestor(of: find.byTooltip('lead details'), matching: find.byType(Opacity)).first).opacity;
    expect(dots(), 0);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('lead')));
    await tester.pump();
    expect(dots(), 1);
  });

  testWidgets('with a mouse a row without a ⋯ but with moreSlot ends its age at the same right edge as one with a ⋯', (tester) async {
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Column(children: [
      AgentRow(name: 'a', status: Status.idle, age: '2m', context: 40, onMore: () {}),
      const AgentRow(name: 'b', status: Status.working, kind: StatusKind.shell, age: 'up 41m', moreSlot: true),
    ]))));
    expect(tester.getTopRight(find.text('up 41m')).dx, tester.getTopRight(find.text('40%')).dx);
  });
}
