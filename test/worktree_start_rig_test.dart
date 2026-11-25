import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/projects.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/project_screen.dart';
import 'package:pocket_rig/ui/spec_screen.dart';
import 'package:pocket_rig/ui/theme.dart' show animateStatusSpinners;

import 'golden/fixtures.dart';

/// A worktree's screen can start a rig in it: the same spec picker and launch preview the project's worktree ⋯
/// opens, with the worktree's own path filled in.
void main() {
  setUp(() => animateStatusSpinners = false);

  testWidgets('Start rig on a worktree opens the launch sheet with that worktree\'s path, and the rig lands under it',
      (tester) async {
    final store = await installFakes();
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
    addTearDown(() => SshExec.debugConnect = null);
    final feed = fleet.feedFor(homelab);
    await tester.pumpWidget(MaterialApp(home: phone(store, const SizedBox())));
    await feed.refresh();
    final project = feed.projects.firstWhere((p) => p.path == app);
    await tester.pumpWidget(MaterialApp(
        home: phone(store, WorktreeScreen.load(host: homelab, project: project, name: 'flaky-ci'))));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byWidgetPredicate((w) => w is Text && (w.data ?? '').contains('…') && (w.data ?? '').endsWith('flaky-ci')), findsOneWidget,
        reason: 'the path under the title is cut in the middle, so the folder still shows');
    // The Changes section is above Rigs now: scroll down to it.
    await tester.scrollUntilVisible(find.text('+ Start rig'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('+ Start rig'), findsOneWidget);
    await tester.tap(find.text('+ Start rig'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Three specs in the project: pick one.
    expect(find.text('Start in flaky-ci'.toUpperCase()), findsOneWidget);
    await tester.tap(find.text('conveyor').last);
    await tester.pumpAndSettle();
    final screen = tester.widget<SpecScreen>(find.byType(SpecScreen));
    const path = '$app/.claude/worktrees/flaky-ci';
    expect(screen.cwd, path, reason: 'the launch sheet starts in this worktree');
    expect(screen.previewNow, isTrue, reason: 'it opens on the launch sheet');
    expect(screen.rigName, 'conveyor-flaky-ci', reason: 'named for the worktree, so it can run beside the main one');

    // A rig launched there (its seats' cwd is that path) is listed under that worktree on Projects.
    final launched = RigWithSeats(
        Rig(id: 'r-new', name: screen.rigName!, nodeCount: 1, runningCount: 1, attentionCount: 0, status: 'running'),
        [Seat.fromJson({'rigId': 'r-new', 'logicalId': 'lead', 'runtime': 'claude-code', 'cwd': path})]);
    final grouped = byWorktree(groupIntoProjects([launched], const []).single);
    expect(grouped.single.$1, 'flaky-ci');
    expect(grouped.single.$2.single.rig.name, 'conveyor-flaky-ci');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the branch row keeps "tracks origin/…" whole; its push counts are on a line of their own', (tester) async {
    final store = await installFakes();
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
    addTearDown(() => SshExec.debugConnect = null);
    final feed = fleet.feedFor(homelab);
    await tester.pumpWidget(MaterialApp(home: phone(store, const SizedBox())));
    await feed.refresh();
    final project = feed.projects.firstWhere((p) => p.path == app);
    await tester.pumpWidget(MaterialApp(home: phone(store, WorktreeScreen.load(host: homelab, project: project, name: null))));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final tracks = find.text('tracks origin/feat/409-retry');
    final counts = find.text('2 to push · 3 changed');
    expect(tracks, findsOneWidget);
    expect(counts, findsOneWidget);
    expect(tester.getTopLeft(counts).dy, greaterThan(tester.getBottomLeft(tracks).dy - 1), reason: 'under it, not beside it');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
