import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/agent_jobs.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/host_store.dart' show HostStore;
import 'package:pocket_rig/data/subagents.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/agent_panels.dart';
import 'package:pocket_rig/ui/agent_panels_sheet.dart';
import 'package:pocket_rig/ui/chat_screen.dart';

import 'golden/fixtures.dart';

const _jobsOut =
    "J\t41\tS\t01:00\t0\t12\tzsh -c source /h/shell-snapshots/s.sh && eval 'npm run dev' < /dev/null && pwd -P >| /tmp/x";

void main() {
  final lead = seatFromFixture('r-conveyor', 'lead');
  late List<String> ran;

  /// The pane's own process polls: not the host feed's scan, which runs anyway.
  List<String> polls() => [for (final c in ran) if (!c.contains('@@pocketrig-subagents')) c];

  Future<HostStore> setUpFeed(WidgetTester tester) async {
    final store = await installFakes();
    ran = [];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          ran.add(cmd);
          return _jobsOut;
        });
    addTearDown(() => SshExec.debugConnect = null);
    agentPanelsFile = () async => null;
    agentPanels.value = const PanelLayout();
    final feed = fleet.feedFor(store.active!);
    feed.subagents = {
      claudeSessionOf(lead)!: [
        Subagent(
            sessionId: claudeSessionOf(lead)!,
            agentId: 'a1',
            path: '/h/.claude/projects/p/s/subagents/agent-a1.jsonl',
            type: 'Explore',
            description: 'Write the parser',
            started: DateTime.now().subtract(const Duration(minutes: 4))),
      ],
    };
    feed.jobs = {lead.sessionName!: AgentJob.parse(_jobsOut)};
    return store;
  }

  testWidgets('the dock has Subagents and Shells panes: the running subagents (a tap opens its log as a chat) and the shells list',
      (tester) async {
    final store = await setUpFeed(tester);
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: phone(store, Scaffold(body: Row(children: [const Spacer(), AgentPanelDock(seat: lead)])))));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Subagents · 1'), findsOneWidget);
    expect(find.text('Shells · 1'), findsOneWidget);
    expect(find.text('Write the parser'), findsOneWidget);
    expect(find.textContaining('running · started 4m ago'), findsOneWidget);
    expect(find.textContaining('npm run dev'), findsOneWidget, reason: 'the same list the chat\'s processes sheet shows');

    await tester.tap(find.text('Write the parser'));
    await tester.pump(const Duration(milliseconds: 500));
    final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
    expect(chat.seat.transcriptPath, '/h/.claude/projects/p/s/subagents/agent-a1.jsonl');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the Shells list polls only while the Info tab is on screen', (tester) async {
    final store = await setUpFeed(tester);
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: phone(store, Scaffold(body: Row(children: [const Spacer(), AgentPanelDock(seat: lead)])))));
    await tester.pump(const Duration(seconds: 7));
    expect(polls(), isNotEmpty, reason: 'Info shows the shells: it polls');

    await tester.pump(const Duration(milliseconds: 500)); // an in-flight refresh lands
    await tester.tap(find.text('Files 0'));
    await tester.pump();
    ran.clear();
    await tester.pump(const Duration(seconds: 7));
    expect(polls(), isEmpty, reason: 'another tab: it stops');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('phone: the strip counts Subagents and Shells too, and the sheet has a tab for each', (tester) async {
    final store = await setUpFeed(tester);
    await tester.pumpWidget(MaterialApp(home: phone(store, PanelsStrip(seat: lead), root: true)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Subagents 1 · Shells 1'), findsOneWidget, reason: 'no files or images: the strip shows for these alone');

    await tester.tap(find.textContaining('Subagents 1 · Shells 1'));
    await tester.pumpAndSettle();
    expect(find.text('Subagents 1'), findsOneWidget);
    expect(find.text('Shells 1'), findsOneWidget);
    await tester.tap(find.text('Subagents 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Write the parser'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(ChatScreen), findsOneWidget, reason: 'the sheet closes and the subagent\'s chat opens');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
