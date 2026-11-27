import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';

import '../tool/demo/main_demo.dart';
import 'golden/fixtures.dart';

void main() {
  test('the demo host answers an agent\'s own shell list (what the Shells page polls) with the same shells the scan lists', () async {
    await demoSetup();
    final ssh = await SshExec.connect(homelab);
    final impl = await ssh.agentJobs('impl@conveyor', lines: 20);
    expect([for (final j in impl.where((j) => j.isShell)) j.short],
        unorderedEquals(['dev server', 'storybook', 'test --watch', 'docker compose up db', 'tail -f logs/app.log']));
    expect(impl.where((j) => j.isShell), hasLength(5), reason: 'the live check of the 3 + \'+2 more\' cap');
    final dev = impl.firstWhere((j) => j.short == 'dev server');
    expect(dev.output, contains('listening on http://localhost:8080'), reason: 'with its output tail');
    expect(dev.elapsed, const Duration(minutes: 41));
    final codex = await ssh.agentJobs('codex-fix', lines: 20);
    expect([for (final j in codex) j.short], ['npm run dev']);
    expect(await ssh.agentJobs('lead@conveyor', lines: 20), isEmpty);
    ssh.close();
  });

  test('the demo host has a dirty worktree for the worktree screens: changed files for its page and for Delete worktree…', () async {
    await demoSetup();
    final ssh = await SshExec.connect(homelab);
    expect(await ssh.worktreeChanges('$app/.claude/worktrees/flaky-ci'), ['src/rig/router.ts', 'notes.md']);
    expect((await ssh.gitStatus('$app/.claude/worktrees/flaky-ci')).changeRows, isNotEmpty);
    expect([for (final w in await ssh.worktrees(app)) w.branch], ['feat/409-retry', 'fix/flaky-ci']);
    ssh.close();
  });
}
