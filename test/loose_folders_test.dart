import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/projects.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/rigs_home.dart' show projectHeading;

/// A hand-started agent or shell is filed the way a rig is: under the project whose folder holds it (a subfolder, a
/// worktree), else under a folder row of its own, the home folder last. Never a bare row.
void main() {
  LooseAgent at(String id, String cwd) => LooseAgent(id: id, cwd: cwd, tmuxSession: id, runtime: 'claude-code');

  test('subfolder and worktree agents join their project; an unrelated folder, a lone shell and home are rows of their own, home last', () {
    final sub = at('api', '/Users/me/code/app/packages/api');
    final wt = at('retry', '/Users/me/code/app/.claude/worktrees/retry');
    final home = at('chat', '/Users/me');
    final other = at('scratch', '/Users/me/code/other');
    const shell = ProjectShell('rp-lonely', '/Users/me/code/lonely');

    final list = groupIntoProjects([], ['/Users/me/code/app'], [home, other, wt, sub], const [], [shell]);

    expect([for (final p in list) p.name], ['app', 'lonely', 'other', 'Home'], reason: 'the known project, other folders by name, home last');
    final app = list.first;
    expect(app.loose, containsAll([sub, wt]), reason: 'a subfolder and a worktree are under the project, not projects of their own');
    expect(worktreeName(wt.cwd), 'retry', reason: 'the worktree line (S1)');
    expect(list[1].shells, [shell], reason: 'a lone shell: a folder row with the shell under it');
    expect(list[2].loose, [other]);
    expect(list.last.loose, [home]);
    expect([for (final p in list) projectGroup(p)], [0, 1, 1, 2], reason: 'the Rigs home lists by the same groups');
    expect(projectHeading(list.last), (title: 'Home', sub: '~', unknown: false));
    expect(projectHeading(list[2]).title, 'other');
  });

  test('a folder with a rig is a known project and sorts before a folder with only an agent, even when the agent needs you', () {
    final ask = LooseAgent(id: 'ask', cwd: '/Users/me/code/zeta', tmuxSession: 'ask', runtime: 'claude-code', waiting: true, waitingKind: 'permission');
    final list = groupIntoProjects([], ['/Users/me/code/app'], [ask]);
    expect([for (final p in list) p.name], ['app', 'zeta']);
  });
}
