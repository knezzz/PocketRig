import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/git_status.dart';
import 'package:pocket_rig/data/projects.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/project/worktree_delete.dart';
import 'package:pocket_rig/ui/project/worktree_screen.dart' show WorktreeScreen;

import 'golden/fixtures.dart';

void main() {
  group('with a real repo', () {
    late Directory tmp;
    late String repo;
    final ssh = SshExec.fake((cmd) async {
      final r = await Process.run('/bin/sh', ['-c', cmd]);
      return '${r.stdout}${r.stderr}';
    });
    Future<String> sh(String dir, String args) async {
      final r = await Process.run('/bin/sh', ['-c', 'cd ${shQuote(dir)} && $args']);
      if (r.exitCode != 0) fail('$args: ${r.stderr}');
      return r.stdout as String;
    }

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('pr-wt-del');
      repo = '${tmp.resolveSymbolicLinksSync()}/app';
      await sh(tmp.path, 'git init -q -b main app');
      await sh(repo, 'git -c user.email=t@t -c user.name=t commit -q --allow-empty -m one');
    });
    tearDown(() => tmp.delete(recursive: true));

    test('a clean worktree is removed, its branch stays', () async {
      final path = await ssh.addWorktree(repo, 'feat/clean');
      expect(await ssh.worktreeChanges(path), isEmpty);
      await ssh.removeWorktree(repo, path);
      expect(Directory(path).existsSync(), isFalse);
      expect(await sh(repo, 'git branch --list feat/clean'), contains('feat/clean'), reason: 'the branch is kept');
    });

    test('a dirty one is listed, refused without force, and removed with it; the branch stays', () async {
      final path = await ssh.addWorktree(repo, 'feat/dirty');
      File('$path/new.txt').writeAsStringSync('x');
      File('$path/README').writeAsStringSync('y');
      await sh(path, 'git add README && git -c user.email=t@t -c user.name=t commit -q -m r && echo z >> README');
      expect(await ssh.worktreeChanges(path), unorderedEquals(['new.txt', 'README']));
      await expectLater(ssh.removeWorktree(repo, path), throwsA(anything));
      expect(Directory(path).existsSync(), isTrue, reason: 'git refused: nothing was lost');
      await ssh.removeWorktree(repo, path, force: true);
      expect(Directory(path).existsSync(), isFalse);
      expect(await sh(repo, 'git branch --list feat/dirty'), contains('feat/dirty'));
    });

    test('the Delete dialog and the Changes section name the same files: an edited, a staged and an untracked one', () async {
      final path = await ssh.addWorktree(repo, 'feat/same');
      const c = '-c user.email=t@t -c user.name=t';
      File('$path/edited.txt').writeAsStringSync('one\n');
      File('$path/other.txt').writeAsStringSync('one\n');
      await sh(path, 'git add edited.txt other.txt && git $c commit -q -m files');
      File('$path/edited.txt').writeAsStringSync('one\ntwo\n'); // edited, not staged
      File('$path/other.txt').writeAsStringSync('one\nthree\n');
      await sh(path, 'git add other.txt'); // staged
      File('$path/fresh.txt').writeAsStringSync('new\n'); // untracked
      final delete = (await ssh.worktreeChanges(path)).toSet();
      final changes = (await ssh.gitStatus(path)).changeRows.map((r) => r.$2).toSet();
      expect(delete, {'edited.txt', 'other.txt', 'fresh.txt'});
      expect(changes, delete, reason: 'the page lists the files the dialog says will be lost');
    });

    test('the path is one quoted argument: spaces, quotes, a dollar and a backtick survive', () async {
      for (final (i, name) in ['my wt', "it's", r'a"b$HOME`x`;y'].indexed) {
        final path = '${tmp.resolveSymbolicLinksSync()}/$name';
        await sh(repo, 'git worktree add -q -b b$i ${shQuote(path)}');
        expect(Directory(path).existsSync(), isTrue, reason: name);
        await ssh.removeWorktree(repo, path);
        expect(Directory(path).existsSync(), isFalse, reason: name);
      }
      expect((await ssh.worktrees(repo)).length, 1);
    });
  });

  test('the dialog text: clean is plain; dirty lists a few and says Delete anyway; what runs there is named; the branch is kept', () {
    final clean = deleteWorktreeText(name: 'fix', branch: 'fix/x', shownPath: '~/app/.claude/worktrees/fix', changes: const []);
    expect(clean.dirty, isFalse);
    expect(clean.action, 'Delete');
    expect(clean.body, contains('The branch fix/x is kept.'));
    expect(clean.body, contains('Ignored files in it (like .env or build output) are deleted too.'));
    expect(clean.body, isNot(contains('will be lost')));

    final dirty = deleteWorktreeText(
        name: 'fix',
        branch: 'fix/x',
        shownPath: '~/w',
        changes: ['a', 'b', 'c', 'd', 'e', 'f', 'g'],
        agents: ['lead'],
        shells: ['rp-fix']);
    expect(dirty.dirty, isTrue);
    expect(dirty.action, 'Delete anyway');
    expect(dirty.body, contains('7 changed files will be lost: a, b, c, d, e and 2 more.'));
    expect(dirty.body, contains('lead (agent), rp-fix (shell)'));
    expect(dirty.body, contains('not stopped'));
    expect(dirty.body, contains('Ignored files in it'));
    expect(deleteWorktreeText(name: 'n', branch: null, shownPath: 'p', changes: ['x']).body, contains('1 changed file will be lost: x.'));
  });

  testWidgets('the dialog: clean asks plainly and runs git worktree remove; dirty needs Delete anyway and runs --force; main is never offered',
      (tester) async {
    final store = await installFakes();
    final ran = <String>[];
    var changes = '';
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          ran.add(cmd);
          if (cmd.contains('status --porcelain')) return changes;
          return cmd.contains('worktree remove') ? '@@pocketrig-git-ok\n' : '';
        });
    addTearDown(() => SshExec.debugConnect = null);
    final w = Worktree('$app/.claude/worktrees/fix', 'fix/x');
    final main = Worktree(app, 'main');
    var result = <bool>[];
    await tester.pumpWidget(AppScope(
        store: store,
        child: MaterialApp(
            home: Builder(
                builder: (context) => Column(children: [
                      TextButton(
                          onPressed: () async => result.add(await deleteWorktree(context, host: homelab, repo: app, w: w, name: 'fix', agents: const ['lead'])),
                          child: const Text('delete')),
                      TextButton(
                          onPressed: () async => result.add(await deleteWorktree(context, host: homelab, repo: app, w: main, name: 'main')),
                          child: const Text('main')),
                    ])))));

    // The main checkout: no dialog, nothing run.
    await tester.tap(find.text('main'));
    await tester.pumpAndSettle();
    expect(result, [false]);
    expect(find.byType(BottomSheet), findsNothing);
    expect(ran, isEmpty);

    // Clean: a plain confirm, and no --force.
    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete fix?'), findsOneWidget);
    expect(find.textContaining('lead (agent)'), findsOneWidget);
    expect(find.text('Delete anyway'), findsNothing);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    final rm = ran.where((c) => c.contains('worktree remove')).single;
    expect(rm, contains("-- '$app/.claude/worktrees/fix'"));
    expect(rm, isNot(contains('--force')));
    expect(result.last, isTrue);

    await tester.pump(const Duration(seconds: 5)); // the toast goes

    // Dirty: the files are named, the action is Delete anyway, and only then --force.
    ran.clear();
    changes = ' M lib/a.dart\n?? notes.txt\n';
    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 changed files will be lost: lib/a.dart, notes.txt.'), findsOneWidget);
    expect(ran.where((c) => c.contains('worktree remove')), isEmpty, reason: 'nothing before the confirm');
    await tester.tap(find.text('Delete anyway'));
    await tester.pumpAndSettle();
    expect(ran.where((c) => c.contains('worktree remove')).single, contains('--force -- '));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a forced delete asks again when the folder changed after the dialog listed it', (tester) async {
    final store = await installFakes();
    final ran = <String>[];
    final reads = [' M a.dart\n', ' M a.dart\n?? late.log\n', ' M a.dart\n?? late.log\n'];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          ran.add(cmd);
          if (cmd.contains('status --porcelain')) return reads.removeAt(0);
          return cmd.contains('worktree remove') ? '@@pocketrig-git-ok\n' : '';
        });
    addTearDown(() => SshExec.debugConnect = null);
    final w = Worktree('$app/.claude/worktrees/fix', 'fix/x');
    final result = <bool>[];
    await tester.pumpWidget(AppScope(
        store: store,
        child: MaterialApp(
            home: Builder(
                builder: (context) => TextButton(
                    onPressed: () async => result.add(await deleteWorktree(context, host: homelab, repo: app, w: w, name: 'fix')),
                    child: const Text('delete'))))));
    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 changed file will be lost: a.dart.'), findsOneWidget);
    await tester.tap(find.text('Delete anyway'));
    await tester.pumpAndSettle();
    expect(ran.where((c) => c.contains('worktree remove')), isEmpty, reason: 'it changed: nothing is deleted yet');
    expect(find.textContaining('2 changed files will be lost: a.dart, late.log.'), findsOneWidget, reason: 'the new list is shown');
    await tester.tap(find.text('Delete anyway'));
    await tester.pumpAndSettle();
    expect(ran.where((c) => c.contains('worktree remove')).single, contains('--force -- '));
    expect(result, [true]);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the worktree page has the ⋯ with Delete worktree… only on a linked worktree, never on the main checkout', (tester) async {
    final store = await installFakes();
    Widget page({required bool main}) => AppScope(
        store: store,
        child: MaterialApp(
            home: WorktreeScreen(
                worktree: Worktree(main ? app : '$app/.claude/worktrees/fix', main ? 'main' : 'fix/x'),
                isMain: main,
                projectName: 'app',
                projectPath: app,
                pr: null,
                contains: (_) => false)));
    await tester.pumpWidget(page(main: true));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Worktree options'), findsNothing);
    await tester.pumpWidget(page(main: false));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Worktree options'));
    await tester.pumpAndSettle();
    expect(find.text('Delete worktree…'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
