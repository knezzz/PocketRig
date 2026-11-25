import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/project_files.dart';

import 'golden/fixtures.dart';

void main() {
  test('listing puts folders first', () {
    expect(parseListing('a.txt\nsrc/\n.git/\nb.md\n'), ['src/', '.git/', 'a.txt', 'b.md']);
  });

  testWidgets('the Files section shows uncommitted changes and walks the tree', (tester) async {
    final store = await installFakes();
    final listed = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          if (cmd.startsWith('ls -1Ap')) {
            listed.add(cmd);
            return cmd.contains('/src/rig') ? 'router.ts\nretry.ts\n' : cmd.contains('/src') ? 'rig/\n' : 'src/\nREADME.md\n';
          }
          return fakeShell(cmd);
        });
    addTearDown(() => SshExec.debugConnect = null);
    await tester.pumpWidget(MaterialApp(home: phone(store, const ProjectFilesScreen(path: app, name: 'app'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // The Files screen the project's Overview pushes.
    await tester.scrollUntilVisible(find.text('README.md'), 400, scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('3 files changed'), findsOneWidget);
    expect(find.text('README.md'), findsOneWidget);
    await tester.ensureVisible(find.text('src'));
    await tester.tap(find.text('src'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('rig'));
    await tester.tap(find.text('rig'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('retry.ts'), findsOneWidget);
    expect(find.text('A'), findsWidgets, reason: 'changed files carry their git status letter');
    await tester.ensureVisible(find.text('..'));
    await tester.tap(find.text('..'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('rig'), findsOneWidget);
    expect(listed.last, contains("'$app/src'"));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an empty folder, an unreadable one and a failed SSH connection each say which, and SSH failure has Retry',
      (tester) async {
    final store = await installFakes();
    var mode = 'empty';
    var connects = 0;
    SshExec.debugConnect = (h) async {
      connects++;
      if (mode == 'down') throw 'connection refused';
      return SshExec.fake((cmd) async {
        if (cmd.startsWith('ls -1Ap')) return mode == 'unreadable' ? '@@pocketrig-unreadable@@\n' : '';
        return fakeShell(cmd);
      });
    };
    addTearDown(() => SshExec.debugConnect = null);
    Future<void> open() async {
      await tester.pumpWidget(MaterialApp(home: phone(store, ProjectFilesScreen(key: UniqueKey(), path: app, name: 'app'))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    await open();
    expect(find.text('Empty folder.'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    mode = 'unreadable';
    await open();
    expect(find.textContaining('missing or SSH has no permission'), findsOneWidget);
    expect(find.text('Empty folder.'), findsNothing);
    mode = 'down';
    await open();
    expect(find.textContaining('SSH couldn\'t connect, so the files'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'nothing spins once the connection has failed');
    final before = connects;
    mode = 'empty';
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(connects, greaterThan(before), reason: 'Retry connects again');
    expect(find.text('Empty folder.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
