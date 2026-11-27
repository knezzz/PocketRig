import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/git_status.dart';
import 'package:pocket_rig/data/projects.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/project/worktree_rows.dart' show WorktreeHead;
import 'package:pocket_rig/ui/theme.dart';


void main() {
  group('with a real repo (a temp one, never a real one)', () {
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
      tmp = await Directory.systemTemp.createTemp('pr-wt-missing');
      repo = '${tmp.resolveSymbolicLinksSync()}/app';
      await sh(tmp.path, 'git init -q -b main app');
      await sh(repo, 'git -c user.email=t@t -c user.name=t commit -q --allow-empty -m one');
    });
    tearDown(() => tmp.delete(recursive: true));

    test('a worktree whose folder was deleted by hand is listed as missing; one click (git worktree prune) clears it', () async {
      final keep = await ssh.addWorktree(repo, 'feat/keep');
      final path = await ssh.addWorktree(repo, 'feat/gone');
      Directory(path).deleteSync(recursive: true); // by hand, not through git
      var list = await ssh.worktrees(repo);
      expect(list.firstWhere((w) => w.path == path).missing, isTrue, reason: 'git lists it, its folder is gone');
      expect(list.firstWhere((w) => w.path == keep).missing, isFalse, reason: 'the others are untouched');
      expect(list.first.missing, isFalse, reason: 'the main checkout');
      await ssh.pruneWorktrees(repo);
      list = await ssh.worktrees(repo);
      expect(list.map((w) => w.path), isNot(contains(path)), reason: 'cleared from the list');
      expect(list.map((w) => w.path), contains(keep));
      expect(await sh(repo, 'git branch --list feat/gone'), contains('feat/gone'), reason: 'the branch stays');
    });
  });

  test('missing reads from git\'s prunable line or the script\'s missing marker', () {
    final list = Worktree.parse('worktree /r\nHEAD a\nbranch refs/heads/main\nchanged 0\n\n'
        'worktree /r/w1\nHEAD b\nbranch refs/heads/w1\nprunable gitdir file points to non-existent location\n\n'
        'worktree /r/w2\nmissing 1\nHEAD c\nbranch refs/heads/w2\n');
    expect([for (final w in list) w.missing], [false, true, true]);
  });

  testWidgets('a missing worktree\'s header is greyed, says missing, and has Remove from list instead of ⋯ (and opens nothing)', (tester) async {
    var removed = 0, opened = 0, menu = 0;
    Widget head(Worktree w) => MaterialApp(
        theme: buildTheme(Tokens.light, Brightness.light),
        home: Scaffold(
            body: WorktreeHead(
                title: w.name, main: false, worktree: w, onOpen: () => opened++, onMenu: () => menu++, onRemove: () => removed++)));
    await tester.pumpWidget(head(Worktree('/r/w1', 'w1', missing: true)));
    expect(find.text('Remove from list'), findsOneWidget);
    expect(find.byTooltip('Worktree actions'), findsNothing);
    expect(find.textContaining('missing: its folder is gone'), findsOneWidget);
    expect(tester.widget<Text>(find.text('w1')).style?.color, Tokens.light.faint);
    await tester.tap(find.text('w1'));
    expect(opened, 0, reason: 'nothing to open');
    await tester.tap(find.text('Remove from list'));
    expect(removed, 1);
    // A worktree that is there keeps its ⋯.
    await tester.pumpWidget(head(Worktree('/r/w2', 'w2')));
    expect(find.text('Remove from list'), findsNothing);
    expect(find.byTooltip('Worktree actions'), findsOneWidget);
    expect(menu, 0);
  });
}
