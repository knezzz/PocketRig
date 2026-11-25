import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/models.dart' show Project;
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/chat/diff_view.dart' show DiffScreen;
import 'package:pocket_rig/ui/project/worktree_screen.dart';
import 'package:pocket_rig/ui/theme.dart' show animateStatusSpinners;

import 'golden/fixtures.dart';

void main() {
  setUp(() => animateStatusSpinners = false);

  testWidgets('a worktree page lists its changes: edited files with +/− and a total, new files too; a tap opens the diff',
      (tester) async {
    final store = await installFakes();
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          final out = await fakeShell(cmd);
          // One new file git does not track yet, beside the three edits the fixture has.
          return cmd.contains('pocketrig-status') ? out.replaceFirst('@@pocketrig-numstat', '? docs/notes.md\n@@pocketrig-numstat') : out;
        });
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
    expect(find.text('CHANGES · 4'), findsOneWidget, reason: 'three edited files and one new');
    expect(find.text('4 files changed'), findsOneWidget);
    expect(find.text('+42 −6'), findsWidgets, reason: 'the total, and the sum of the lines');
    for (final f in ['src/rig/router.ts', 'src/rig/retry.ts', 'test/router.test.ts', 'docs/notes.md']) {
      expect(find.text(f), findsOneWidget, reason: f);
    }
    expect(find.text('new'), findsOneWidget, reason: 'an untracked file has no line counts');

    await tester.ensureVisible(find.text('docs/notes.md'));
    await tester.pump();
    await tester.tap(find.text('docs/notes.md'));
    await tester.pump(const Duration(milliseconds: 500));
    final diff = tester.widget<DiffScreen>(find.byType(DiffScreen));
    expect(diff.path, 'docs/notes.md');
    expect(diff.untracked, isTrue);
    expect(diff.root, '/Users/me/code/app');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('atlas\'s worktree page loads: git lists api-retry', (tester) async {
    final store = await installFakes();
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
    addTearDown(() => SshExec.debugConnect = null);
    await tester.pumpWidget(MaterialApp(
        home: phone(store, WorktreeScreen.load(host: homelab, project: Project(path: '/Users/me/code/atlas'), name: 'api-retry'))));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('doesn\'t list this worktree'), findsNothing);
    expect(find.text('api-retry'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
