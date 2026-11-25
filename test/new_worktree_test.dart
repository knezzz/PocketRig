import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart' show fleet;
import 'package:pocket_rig/data/new_worktree.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/kit.dart' show NavRow;
import 'package:pocket_rig/ui/project_screen.dart' show ProjectScreen, WorktreeScreen;
import 'package:pocket_rig/ui/worktree_name_field.dart';

import 'golden/fixtures.dart';

void main() {
  /// Opens the project's New worktree sheet on [host] and hands back what it popped.
  Future<Future<String?> Function()> openSheet(WidgetTester tester, Host host,
      {Future<SshExec> Function(Host)? connect}) async {
    final store = await installFakes();
    SshExec.debugConnect = connect ?? (h) async => SshExec.fake(fakeShell);
    addTearDown(() => SshExec.debugConnect = null);
    String? result;
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: phone(
        store,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  result = await showModalBottomSheet<String>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => NewWorktreeSheet(host: host, project: app));
                  done = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
        root: true,
      ),
    ));
    await tester.tap(find.text('open'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return () async => done ? result : null;
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('the sheet shows the branch, where it branches from (the main checkout\'s current branch) and the folder, live',
      (tester) async {
    await openSheet(tester, homelab);
    expect(find.text('Branch  …  from feat/409-retry'), findsOneWidget, reason: 'before a name: the base is already known');
    expect(find.text('Folder  app/.claude/worktrees/…'), findsOneWidget);
    await type(tester, 'fix/new-thing');
    expect(find.text('Branch  fix/new-thing  from feat/409-retry'), findsOneWidget);
    expect(find.text('Folder  app/.claude/worktrees/fix-new-thing'), findsOneWidget, reason: 'the folder addWorktree makes');
    expect(find.textContaining('HEAD'), findsNothing);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Create')).onPressed, isNotNull);
    await close(tester);
  });

  testWidgets('bad characters, an existing branch and an existing folder (also fix/a-b vs fix-a-b) are refused in place',
      (tester) async {
    await openSheet(tester, homelab);
    FilledButton create() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'));
    expect(create().onPressed, isNull, reason: 'no name yet');
    await type(tester, 'fix this');
    expect(find.textContaining('no spaces'), findsOneWidget);
    expect(create().onPressed, isNull);
    await type(tester, 'fix/flaky-ci');
    expect(find.text('A branch named fix/flaky-ci already exists.'), findsOneWidget);
    expect(create().onPressed, isNull);
    // The folder flaky-ci exists (a worktree): flaky/ci would make the same one.
    await type(tester, 'flaky/ci');
    expect(find.textContaining('.claude/worktrees/flaky-ci already exists (flaky/ci and flaky-ci make the same folder)'), findsOneWidget);
    expect(create().onPressed, isNull);
    await type(tester, 'fix/ok');
    expect(find.textContaining('already exists'), findsNothing);
    expect(create().onPressed, isNotNull);
    await close(tester);
  });

  test('worktreeNameError and the folder name', () {
    const s = WorktreeSetup(repo: '/r', base: 'dev', branches: {'old'}, folders: {'a-b'});
    expect(worktreeFolderName('fix/a-b'), 'fix-a-b');
    expect(worktreeNameError('', s), isNull);
    expect(worktreeNameError('a..b', s), contains('no spaces'));
    expect(worktreeNameError('old', s), 'A branch named old already exists.');
    expect(worktreeNameError('a/b', s), contains('already exists (a/b and a-b make the same folder)'));
    expect(worktreeNameError('a-b', s), 'The folder .claude/worktrees/a-b already exists.');
    expect(worktreeNameError('fine', s), isNull);
    expect(worktreeNameError('x', null), isNull, reason: 'not read yet: nothing to collide with');
  });

  testWidgets('Create runs on the project\'s own host, not the active one, and returns the new folder', (tester) async {
    final hosts = <String>[];
    final ran = <String>[];
    final result = await openSheet(tester, macbook, connect: (h) async { // homelab is the active host
      hosts.add(h.id);
      return SshExec.fake((cmd) async {
        ran.add(cmd);
        return cmd.contains('worktree add') ? '@@pocketrig-git-ok\n' : fakeShell(cmd);
      });
    });
    await type(tester, 'fix/new-thing');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(hosts, isNotEmpty);
    expect(hosts.toSet(), {'h2'}, reason: 'every connection goes to the macbook');
    expect(ran.where((c) => c.contains('worktree add') && c.contains('fix/new-thing')), hasLength(1));
    expect(await result(), '$app/.claude/worktrees/fix-new-thing');
    await close(tester);
  });

  testWidgets('a refusal from git shows under the name, in the sheet, not as a toast', (tester) async {
    await openSheet(tester, homelab,
        connect: (h) async => SshExec.fake((cmd) async =>
            cmd.contains('worktree add') ? 'fatal: could not create work tree dir: Permission denied\n' : fakeShell(cmd)));
    await type(tester, 'fix/new-thing');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Permission denied'), findsOneWidget);
    expect(find.byType(NewWorktreeSheet), findsOneWidget, reason: 'still open');
    await type(tester, 'fix/new-thing2');
    expect(find.textContaining('Permission denied'), findsNothing, reason: 'cleared when the name changes');
    await close(tester);
  });

  testWidgets('the Worktrees tab ends with a dashed New worktree row; Create opens the new worktree\'s page', (tester) async {
    final store = await installFakes();
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async => cmd.contains('worktree add') ? '@@pocketrig-git-ok\n' : fakeShell(cmd));
    addTearDown(() => SshExec.debugConnect = null);
    final feed = fleet.feedFor(homelab);
    await tester.pumpWidget(MaterialApp(home: phone(store, const SizedBox())));
    await feed.refresh();
    await tester.pumpWidget(MaterialApp(home: phone(store, const ProjectScreen(path: app, tab: 2))));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('+ New worktree'), findsNothing, reason: 'one button, not a second one on the label');
    final row = find.widgetWithText(NavRow, 'New worktree');
    await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).last);
    expect(tester.widget<NavRow>(row).dashed, isTrue, reason: 'the same dashed row as Add project folder');
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(NewWorktreeSheet), findsOneWidget);
    await type(tester, 'fix/new-thing');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final page = tester.widget<WorktreeScreen>(find.byType(WorktreeScreen));
    expect(page.name, 'fix-new-thing', reason: 'its own page, by the folder name');
    expect(page.host, homelab);
    await close(tester);
  });
}
