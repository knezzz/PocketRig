import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/host_store.dart' show HostStore, isDesktop;
import 'package:pocket_rig/models.dart' show Host;
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/new_sheet.dart';
import 'package:pocket_rig/ui/theme.dart' show Tokens;

import 'golden/fixtures.dart';

HostStore? installedStore;

void main() {
  /// Opens the sheet over a button and returns what Start (or Close) gave back.
  Future<Future<NewChoice?> Function()> open(WidgetTester tester, NewSheet sheet) async {
    NewChoice? got;
    var done = false;
    await tester.pumpWidget(MaterialApp(
        home: phone(
            installedStore!,
            Builder(
                builder: (context) => TextButton(
                    onPressed: () async {
                      got = await showModalBottomSheet<NewChoice>(context: context, isScrollControlled: true, builder: (_) => sheet);
                      done = true;
                    },
                    child: const Text('open'))))));
    return () async {
      for (var i = 0; i < 40 && !done; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return got;
    };
  }

  testWidgets('the New sheet: a location, the worktrees of that project (main, existing, New worktree…), and Start gives the choice',
      (tester) async {
    installedStore = await installFakes();
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
    addTearDown(() => SshExec.debugConnect = null);
    await fleet.feedFor(homelab).refresh();
    final result = await open(tester, NewSheet(kind: NewKind.shell, host: homelab, path: app));
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('LOCATION'), findsOneWidget);
    expect(find.text('WORKTREE'), findsOneWidget);
    expect(find.text('~/code/app'), findsOneWidget, reason: 'the location in the host\'s ~ form');
    expect(find.textContaining('main checkout'), findsOneWidget);
    expect(find.text('Start shell'), findsOneWidget);

    // The worktree list: main first, then an existing worktree, then New worktree….
    await tester.tap(find.byTooltip('Worktree'));
    await tester.pumpAndSettle();
    expect(find.text('main checkout'), findsWidgets);
    expect(find.text('flaky-ci'), findsOneWidget, reason: 'an existing worktree of app');
    expect(find.text('New worktree…'), findsOneWidget);
    expect(find.text('from the main checkout'), findsOneWidget, reason: 'a short hint that is not cut');
    // A long path is cut in the middle, so its end (what tells worktrees apart) stays.
    expect(find.byWidgetPredicate((w) => w is Text && (w.data ?? '').contains('…') && (w.data ?? '').contains('flaky-ci')), findsOneWidget);
    await tester.tap(find.text('flaky-ci'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start shell'));
    await tester.pumpAndSettle();
    final c = (await result())!;
    expect((c.kind, c.host, c.project), (NewKind.shell, homelab, app));
    expect(c.worktree, '$app/.claude/worktrees/flaky-ci');
    expect(c.newBranch, isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('New worktree… asks a branch name (Start waits for it) and hands it back to create', (tester) async {
    installedStore = await installFakes();
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
    addTearDown(() => SshExec.debugConnect = null);
    await fleet.feedFor(homelab).refresh();
    final result = await open(tester, NewSheet(host: homelab, path: app));
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Worktree'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New worktree…'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    FilledButton start() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Create worktree and start'));
    expect(start().onPressed, isNull, reason: 'no name yet');
    // A name with a space, or one a worktree already has, is refused in place with its reason.
    await tester.enterText(find.byType(TextField), 'fix this');
    await tester.pump();
    expect(find.textContaining('no spaces'), findsOneWidget);
    expect(start().onPressed, isNull);
    expect(Theme.of(tester.element(find.byType(TextField))).colorScheme.error, Tokens.light.removed,
        reason: 'a refused name is the error red, not the needs-you orange');
    await tester.enterText(find.byType(TextField), 'fix/flaky-ci');
    await tester.pump();
    expect(find.textContaining('already exists'), findsOneWidget);
    expect(start().onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'fix/x');
    await tester.pump();
    expect(find.textContaining('no spaces'), findsNothing);
    expect(find.textContaining('already exists'), findsNothing);
    await tester.tap(find.text('Codex'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Create worktree and start'));
    await tester.pumpAndSettle();
    final c = (await result())!;
    expect((c.kind, c.newBranch), (NewKind.agent, 'fix/x'));
    expect(c.worktree, isNull);
    expect(c.runtime.wire, 'codex');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  test('createWorktree adds a worktree on the new branch from the main checkout and returns its path', () async {
    final ran = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          ran.add(cmd);
          return cmd.contains('worktree add') ? '@@pocketrig-git-ok\n' : fakeShell(cmd);
        });
    addTearDown(() => SshExec.debugConnect = null);
    final path = await createWorktree(homelab, app, 'fix/x');
    expect(path, endsWith('/.claude/worktrees/fix-x'));
    expect(ran.where((c) => c.contains('worktree add -b')).length, 1);
  });

  testWidgets('on the Mac the New sheet is a dialog (in the root navigator, outside the screen\'s scope) and still opens',
      (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
    addTearDown(() => SshExec.debugConnect = null);
    await fleet.feedFor(homelab).refresh();
    await tester.pumpWidget(MaterialApp(
        home: phone(store, Builder(builder: (c) => TextButton(onPressed: () => showNew(c), child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Start agent'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('on the Mac, for this Mac\'s host, the Location menu ends with a hairline and Choose another folder…',
      (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    final me = Host.local('me');
    store.all.insert(0, me);
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
    addTearDown(() => SshExec.debugConnect = null);
    await tester.pumpWidget(MaterialApp(
        home: phone(store, Builder(builder: (c) => TextButton(onPressed: () => showNew(c, host: me), child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Location'));
    await tester.pumpAndSettle();
    expect(find.text('Choose another folder…'), findsOneWidget);
    expect(find.byType(PopupMenuDivider), findsOneWidget, reason: 'a hairline above it');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the Mac dialog takes the page\'s theme: opened from a dark page it is dark', (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
    addTearDown(() => SshExec.debugConnect = null);
    await fleet.feedFor(homelab).refresh();
    await tester.pumpWidget(MaterialApp(
        home: phone(store, dark: true, Builder(builder: (c) => TextButton(onPressed: () => showNew(c), child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(Tokens.of(tester.element(find.byType(NewSheet))).isDark, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
