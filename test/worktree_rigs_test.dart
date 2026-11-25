import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/project/worktree_screen.dart';
import 'package:pocket_rig/ui/theme.dart' show animateStatusSpinners;

import 'golden/fixtures.dart';

void main() {
  setUp(() => animateStatusSpinners = false);

  testWidgets('a worktree page lists the rigs that run there by the one rule (where most of their seats run), not any rig with a seat there', (tester) async {
    final store = await installFakes();
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
    addTearDown(() => SshExec.debugConnect = null);
    final feed = fleet.feedFor(homelab);
    await tester.pumpWidget(MaterialApp(home: phone(store, const SizedBox())));
    await feed.refresh();
    const wt = '$app/.claude/worktrees/flaky-ci';
    Seat seat(String rig, String id, String cwd) =>
        Seat(rigId: rig, logicalId: id, cwd: cwd, runtime: 'claude-code', sessionName: '$id@$rig', activity: 'idle');
    Rig rig(String id) => Rig(id: id, name: id, nodeCount: 3, runningCount: 3, attentionCount: 0, status: 'running');
    final project = feed.projects.firstWhere((p) => p.path == app);
    await tester.pumpWidget(MaterialApp(home: phone(store, WorktreeScreen.load(host: homelab, project: project, name: 'flaky-ci'))));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    feed.rigs = [
      RigWithSeats(rig('mostly-main'), [seat('mostly-main', 'a', app), seat('mostly-main', 'b', app), seat('mostly-main', 'c', wt)]),
      RigWithSeats(rig('mostly-wt'), [seat('mostly-wt', 'a', wt), seat('mostly-wt', 'b', wt), seat('mostly-wt', 'c', app)]),
    ];
    // ignore: invalid_use_of_protected_member
    feed.notifyListeners();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.scrollUntilVisible(find.text('mostly-wt'), 200, scrollable: find.byType(Scrollable).last);
    expect(find.text('mostly-wt'), findsOneWidget);
    expect(find.text('mostly-main'), findsNothing, reason: 'one seat here does not put the rig here');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
