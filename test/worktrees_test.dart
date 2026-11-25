import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/projects.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';

void main() {
  late Directory tmp;
  late String repo;
  final ssh = SshExec.fake((cmd) async {
    final r = await Process.run('/bin/sh', ['-c', cmd]);
    return '${r.stdout}${r.stderr}';
  });
  Future<void> git(String dir, String args) async {
    final r = await Process.run('/bin/sh', ['-c', 'cd ${shQuote(dir)} && git $args']);
    if (r.exitCode != 0) fail('git $args: ${r.stderr}');
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pr-wt');
    repo = '${tmp.resolveSymbolicLinksSync()}/app';
    await git(tmp.path, 'init -q --bare origin.git');
    await git(tmp.path, 'init -q -b main app');
    await git(repo, '-c user.email=t@t -c user.name=t commit -q --allow-empty -m one');
    await git(repo, 'remote add origin ${shQuote('${tmp.resolveSymbolicLinksSync()}/origin.git')} && git push -q -u origin main');
  });
  tearDown(() => tmp.delete(recursive: true));

  test('add, list with push state, refuse a dirty remove, remove', () async {
    final path = await ssh.addWorktree(repo, 'feat/x');
    expect(path, '$repo/.claude/worktrees/feat-x');
    await git(path, '-c user.email=t@t -c user.name=t commit -q --allow-empty -m two');
    File('$path/new.txt').writeAsStringSync('x');

    final list = await ssh.worktrees(repo);
    expect(list.map((w) => w.branch), ['main', 'feat/x']);
    expect(list[0].pushState, 'pushed');
    expect(list[1].pushState, 'not pushed · 1 changed');

    await git(path, 'push -q -u origin feat/x');
    expect((await ssh.worktrees(repo))[1].pushState, '1 changed');

    await expectLater(ssh.removeWorktree(repo, path), throwsA(anything));
    expect(Directory(path).existsSync(), isTrue);
    File('$path/new.txt').deleteSync();
    await git(path, '-c user.email=t@t -c user.name=t commit -q --allow-empty -m three');
    expect((await ssh.worktrees(repo))[1].pushState, '1 to push');
    await ssh.removeWorktree(repo, path);
    expect(Directory(path).existsSync(), isFalse);
    expect((await ssh.worktrees(repo)).length, 1);
  });

  test('outside git there are no worktrees', () async {
    expect(await ssh.worktrees(tmp.path), isEmpty);
  });
}
