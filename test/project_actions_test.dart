import 'package:flutter/material.dart';
import 'package:pocket_rig/data/fleet.dart' show RigView;
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/busy.dart';
import 'package:pocket_rig/ui/project_actions.dart';
import 'package:pocket_rig/ui/spec_screen.dart';

import 'golden/fixtures.dart';

void main() {
  testWidgets('from a bare row: the project list, and New worktree… runs once over SSH and frees its key',
      (tester) async {
    final store = await installFakes();
    final ran = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          ran.add(cmd);
          return fakeShell(cmd);
        });
    addTearDown(() => SshExec.debugConnect = null);
    await tester.pumpWidget(AppScope(
        store: store,
        child: MaterialApp(
            home: Builder(
                builder: (context) =>
                    TextButton(onPressed: () => showProjectActions(context, app), child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final labels = ['New agent', 'Start rig…', 'Shell here', 'New worktree…', 'Open on GitHub', 'Connect spec folder…'];
    for (final l in labels) {
      expect(find.text(l), findsOneWidget, reason: l);
    }

    await tester.tap(find.text('New worktree…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'fix/x');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(ran.where((c) => c.contains('worktree add')).length, 1, reason: 'one git worktree add over SSH');
    expect(busyKeys.value, isEmpty, reason: 'the key is free again, however it ended');
  });

  testWidgets('a row that can open and fold the project gets Open first, then the views it is not on', (tester) async {
    final store = await installFakes();
    var opened = 0;
    final views = <RigView>[];
    await tester.pumpWidget(AppScope(
        store: store,
        child: MaterialApp(
            home: Builder(
                builder: (context) => TextButton(
                    onPressed: () => showProjectActions(context, app,
                        onOpen: () => opened++, view: RigView.all, anyActive: true, onView: (v) => views.add(v)),
                    child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Open')).dy, lessThan(tester.getTopLeft(find.text('New agent')).dy));
    expect(find.text('Show all'), findsNothing, reason: 'it is the current view');
    expect(find.text('Show active only'), findsOneWidget);
    await tester.tap(find.text('Fold'));
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(views, [RigView.collapsed]);
  });

  testWidgets('a project row\'s ⋯ has Start rig…: it reads the specs, asks which of several, and opens the launch sheet in the '
      'main checkout (the project page\'s flow)', (tester) async {
    final store = await installFakes();
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
    addTearDown(() => SshExec.debugConnect = null);
    await tester.pumpWidget(AppScope(
        store: store,
        child: MaterialApp(
            home: Builder(
                builder: (context) =>
                    TextButton(onPressed: () => showProjectActions(context, app), child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start rig…'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Start in Main checkout'.toUpperCase()), findsOneWidget, reason: 'three specs: pick one');
    await tester.tap(find.text('conveyor').last);
    await tester.pumpAndSettle();
    final screen = tester.widget<SpecScreen>(find.byType(SpecScreen));
    expect(screen.previewNow, isTrue, reason: 'it opens on the launch sheet, as the spec page\'s Start rig does');
    expect(screen.cwd, isNotNull);
    expect(screen.rigName, isNull, reason: 'the main checkout keeps the spec\'s own name');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  test('exclusive: a second start with the same key is ignored while the first runs', () async {
    var runs = 0;
    final first = exclusive('rig-1', () async {
      runs++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await exclusive('rig-1', () async => runs++);
    await first;
    expect(runs, 1);
    expect(busyKeys.value, isEmpty);
  });
}
