import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/projects.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/kit.dart' show BorderedList, NavRow;
import 'package:pocket_rig/ui/project_screen.dart' show ProjectScreen;
import 'package:pocket_rig/ui/theme.dart' show animateStatusSpinners;

import 'golden/fixtures.dart';

void main() {
  setUp(() => animateStatusSpinners = false);

  const ext = '/Users/me/code/app-x';
  const wt = '$app/.claude/worktrees/flaky-ci';

  test('withListedWorktrees pulls a worktree outside .claude/worktrees back into its project', () {
    final p = Project(path: app);
    final x = Project(path: '$ext/packages/api', rigs: [
      RigWithSeats(Rig(id: 'r', name: 'r', nodeCount: 1, runningCount: 1, attentionCount: 1, status: 'running'),
          [Seat(rigId: 'r', logicalId: 'lead', cwd: '$ext/packages/api', runtime: 'claude-code')])
    ])
      ..attention = 1;
    final other = Project(path: '/w/other');
    expect(withListedWorktrees(p, [p, x, other], const []), same(p), reason: 'nothing listed: as it was');
    final merged = withListedWorktrees(p, [p, x, other], [ext]);
    expect(merged.path, app);
    expect(merged.rigs.single.rig.id, 'r');
    expect(merged.attention, 1);
    expect(withListedWorktrees(p, [p, x, other], ['/w/else']), same(p), reason: 'not under a listed worktree');
  });

  testWidgets('the project page groups rigs by worktree: a rig with one seat in main is listed once, in its worktree; a rig in ../app-x under app',
      (tester) async {
    final store = await installFakes();
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          final out = await fakeShell(cmd);
          // git also lists a worktree made outside .claude/worktrees.
          return cmd.contains('git worktree list') && cmd.contains('app')
              ? '$out\nworktree $ext\nchanged 0\nbranch refs/heads/ext\n'
              : out;
        });
    addTearDown(() => SshExec.debugConnect = null);
    final feed = fleet.feedFor(homelab);
    await tester.pumpWidget(MaterialApp(home: phone(store, const SizedBox())));
    await feed.refresh();
    Rig rig(String id) => Rig(id: id, name: id, nodeCount: 2, runningCount: 2, attentionCount: 0, status: 'running');
    Seat seat(String rigId, String id, String cwd) =>
        Seat(rigId: rigId, logicalId: id, cwd: cwd, runtime: 'claude-code', sessionName: '$id@$rigId', activity: 'idle');
    await tester.pumpWidget(MaterialApp(home: phone(store, const ProjectScreen(path: app, tab: 2))));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    feed.rigs = [
      ...feed.rigs,
      RigWithSeats(rig('splitrig'), [seat('splitrig', 'boss', app), seat('splitrig', 'helper', wt), seat('splitrig', 'helper2', wt)]),
      RigWithSeats(rig('extrig'), [seat('extrig', 'a1', ext), seat('extrig', 'a2', '$ext/lib')]),
    ];
    // ignore: invalid_use_of_protected_member
    feed.notifyListeners();
    await tester.pump(const Duration(milliseconds: 100));
    Future<void> show(Finder f) async {
      await tester.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).last);
    }
    for (final head in ['Main checkout', 'flaky-ci', 'app-x']) {
      await show(find.text(head));
      expect(find.text(head), findsOneWidget, reason: 'a group for $head');
    }
    await show(find.text('extrig'));
    expect(find.text('extrig'), findsOneWidget, reason: 'the rig in ../app-x is on app\'s page, in its own group');
    // Most of its seats run in the worktree: one row, there, not a second copy in the main checkout's group.
    expect(find.text('splitrig', skipOffstage: false), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a worktree git does not list but the path rule finds still gets its header; atlas\'s two worktrees are listed',
      (tester) async {
    final store = await installFakes();
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
    addTearDown(() => SshExec.debugConnect = null);
    final feed = fleet.feedFor(homelab);
    await tester.pumpWidget(MaterialApp(home: phone(store, const SizedBox())));
    await feed.refresh();
    // app's list has main and flaky-ci; a rig runs in stale-one, which git does not list.
    Rig rig(String id) => Rig(id: id, name: id, nodeCount: 1, runningCount: 1, attentionCount: 0, status: 'running');
    await tester.pumpWidget(MaterialApp(home: phone(store, const ProjectScreen(path: app, tab: 2))));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    feed.rigs = [
      ...feed.rigs,
      RigWithSeats(rig('stalerig'), [
        Seat(rigId: 'stalerig', logicalId: 'a', cwd: '$app/.claude/worktrees/stale-one', runtime: 'claude-code', sessionName: 'a@stalerig', activity: 'idle')
      ]),
    ];
    // ignore: invalid_use_of_protected_member
    feed.notifyListeners();
    await tester.pump(const Duration(milliseconds: 100));
    Future<void> show(Finder f) => tester.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).last);
    await show(find.text('stale-one'));
    expect(find.text('stale-one'), findsOneWidget, reason: 'the rig keeps its worktree header');
    await show(find.text('stalerig'));
    expect(find.text('stalerig'), findsOneWidget);

    // atlas: git lists api-retry and docs-pass, so the page groups its rigs and the worktree page loads.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(home: phone(store, const ProjectScreen(path: '/Users/me/code/atlas', tab: 2))));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    for (final head in ['Main checkout', 'api-retry', 'docs-pass']) {
      await show(find.text(head));
      expect(find.text(head), findsOneWidget, reason: head);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the dashed New worktree row has the list cards\' edges, not the sidebar\'s inset', (tester) async {
    final store = await installFakes();
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
    addTearDown(() => SshExec.debugConnect = null);
    final feed = fleet.feedFor(homelab);
    await tester.pumpWidget(MaterialApp(home: phone(store, const SizedBox())));
    await feed.refresh();
    await tester.pumpWidget(MaterialApp(home: phone(store, const ProjectScreen(path: app, tab: 2))));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final row = find.widgetWithText(NavRow, 'New worktree');
    await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).last);
    final dashed = tester.getRect(find.descendant(of: row, matching: find.byType(Material)).first);
    final card = tester.getRect(find.byType(BorderedList).first);
    expect(dashed.left, closeTo(card.left, 0.5));
    expect(dashed.right, closeTo(card.right, 0.5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
