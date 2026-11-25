import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/agent_jobs.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/shells_screen.dart';
import 'package:pocket_rig/ui/status_shape.dart';

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

void main() {
  testWidgets('a shell row under an agent in the sidebar has no state dot and opens that agent\'s shells (live output, Stop)',
      (tester) async {
    final store = await installFakes();
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
    addTearDown(() => SshExec.debugConnect = null);
    await pumpDesktop(tester, store);
    final feed = fleet.feedFor(homelab);
    for (var i = 0; i < 5 && find.text('impl').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final impl = feed.rigs.firstWhere((r) => r.rig.name == 'conveyor').seats.firstWhere((s) => s.logicalId == 'impl');
    impl.jobs = AgentJob.parse(
        'J\t1\tS\t05:00\t0\t0\t/bin/zsh -c source /h/.claude/shell-snapshots/s.sh && eval \'sleep 99\' < /dev/null && pwd -P >| /tmp/x\n');
    fleet.toggleRig('r:${homelab.id}|r-conveyor', allShown: true);
    fleet.toggleRig('r:${homelab.id}|r-conveyor', allShown: false);
    await tester.pump(const Duration(seconds: 1));
    final sidebar = find.ancestor(of: find.text('Add project folder'), matching: find.byType(ListView));
    final row = find.ancestor(of: find.descendant(of: sidebar, matching: find.text('sleep 99')), matching: find.byType(InkWell)).first;
    expect(find.descendant(of: row, matching: find.byType(StatusShape)), findsNothing, reason: 'no green (or any) dot on a shell row');
    await tester.tap(find.descendant(of: sidebar, matching: find.text('sleep 99')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final screen = tester.widget<ShellsScreen>(find.byType(ShellsScreen));
    expect(screen.seat.logicalId, 'impl', reason: 'the agent\'s shells');
    expect(screen.tapped?.short, 'sleep 99', reason: 'the shell that was tapped');
    expect(find.text('impl · shells'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the shells page: breadcrumb under the title, the tapped shell first with its command and age, and never "finished" for a '
      'shell the scan saw running', (tester) async {
    final store = await installFakes();
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell); // answers no shell list: the live poll is empty
    addTearDown(() => SshExec.debugConnect = null);
    await fleet.feedFor(homelab).refresh();
    final seat = fleet.feedFor(homelab).rigs.firstWhere((r) => r.rig.name == 'conveyor').seats.firstWhere((s) => s.logicalId == 'impl');
    final job = AgentJob.parse(
        'J\t4201\tS\t00:41:00\t0\t0\t/bin/zsh -c source /h/.claude/shell-snapshots/s.sh && eval \'dev server\' < /dev/null && pwd -P >| /tmp/x\n').single;
    await tester.pumpWidget(MaterialApp(
        home: phone(store, ShellsScreen(host: homelab, seat: seat, title: 'impl', project: 'app', rigName: 'conveyor', tapped: job))));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('impl · shells'), findsOneWidget);
    expect(find.textContaining('app › conveyor', findRichText: true), findsOneWidget, reason: 'host · project › rig under the title');
    expect(find.text('dev server'), findsOneWidget, reason: 'the shell the row showed');
    expect(find.text('up 41m'), findsOneWidget);
    expect(find.textContaining('finished'), findsNothing, reason: 'the scan saw it running');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
