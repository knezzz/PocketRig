import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/rig_git.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/rig/rig_subline.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

void main() {
  Future<void> open(WidgetTester tester, {String? git}) async {
    final store = await installFakes();
    RigGit.reset();
    addTearDown(RigGit.reset);
    if (git != null) {
      SshExec.debugConnect = (h) async => SshExec.fake((cmd) async => cmd.contains('pocketrig-status') ? git : fakeShell(cmd));
    }
    final r = rigsWithSeatsFromFixture().firstWhere((r) => r.rig.id == 'r-conveyor');
    await tester.pumpWidget(MaterialApp(home: phone(store, Scaffold(body: RigSubLine(rig: r.rig, seats: r.seats, projectName: 'app')))));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('a PR with a failing check: branch, ↑, changed, PR #n state ↗, checks in the removed colour, and the agents', (tester) async {
    await open(tester, git: gitOutput.replaceFirst('"status":"IN_PROGRESS","conclusion":""', '"status":"COMPLETED","conclusion":"FAILURE"'));
    expect(find.text('feat/409-retry'), findsOneWidget);
    expect(find.text('↑2'), findsOneWidget);
    expect(find.text('3 changed'), findsOneWidget);
    expect(find.text('PR #42'), findsOneWidget);
    expect(find.text('open'), findsOneWidget);
    expect(tester.widget<Text>(find.text('checks 2/3')).style!.color, Tokens.light.removed);
    expect(find.textContaining('agents'), findsOneWidget);
    expect(find.byIcon(Icons.north_east), findsOneWidget, reason: '↗ says the PR opens in the browser');
  });

  testWidgets('no PR, and gh missing: the branch and its changes, no PR words, no error', (tester) async {
    // gh missing prints nothing after the PR marker, the same as a branch with no PR.
    await open(tester, git: gitOutput.substring(0, gitOutput.indexOf('@@pocketrig-pr') + '@@pocketrig-pr\n'.length));
    expect(find.text('feat/409-retry'), findsOneWidget);
    expect(find.text('3 changed'), findsOneWidget);
    expect(find.textContaining('PR #'), findsNothing);
    expect(find.textContaining('checks'), findsNothing);
    expect(find.textContaining('gh'), findsNothing);
  });

  testWidgets('a draft PR says draft in the muted colour', (tester) async {
    await open(tester, git: gitOutput.replaceFirst('"state":"OPEN"', '"state":"OPEN","isDraft":true'));
    expect(find.text('draft'), findsOneWidget);
    expect(find.text('open'), findsNothing);
  });

  testWidgets('not a repo: the worktree chip stays, as before', (tester) async {
    await open(tester, git: '');
    expect(find.text('feat/409-retry'), findsNothing);
    expect(find.text('main'), findsOneWidget);
  });

  testWidgets('one reading per rig: two lines on the same folder ask once, and not again before 60 s', (tester) async {
    var reads = 0;
    final store = await installFakes();
    RigGit.reset();
    addTearDown(RigGit.reset);
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          if (cmd.contains('pocketrig-status')) reads++;
          return cmd.contains('pocketrig-status') ? gitOutput : fakeShell(cmd);
        });
    final r = rigsWithSeatsFromFixture().firstWhere((r) => r.rig.id == 'r-conveyor');
    final line = RigSubLine(rig: r.rig, seats: r.seats, projectName: 'app');
    await tester.pumpWidget(MaterialApp(home: phone(store, Scaffold(body: Column(children: [line, RigSubLine(rig: r.rig, seats: r.seats, projectName: 'app')])))));
    await tester.pump(const Duration(seconds: 30));
    expect(reads, 1, reason: 'one git and gh read for the rig, however many views show it');
    await tester.pump(const Duration(seconds: 31));
    expect(reads, 2, reason: 'then every 60 s');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 120));
    expect(reads, 2, reason: 'and nothing once no view shows it');
  });
}
