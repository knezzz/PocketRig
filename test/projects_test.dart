import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/git_status.dart';
import 'package:pocket_rig/data/projects.dart';
import 'package:pocket_rig/models.dart';

Seat seat(String rig, String id, String? cwd) =>
    Seat(rigId: rig, logicalId: id, cwd: cwd, runtime: 'claude-code');

RigWithSeats rig(String id, int attention, List<Seat> seats) => RigWithSeats(
      Rig(id: id, name: id, nodeCount: seats.length, runningCount: seats.length,
          attentionCount: attention, status: 'running'),
      seats,
    );

void main() {
  test('rigs group under the folder most of their seats use', () {
    final projects = groupIntoProjects([
      rig('a', 0, [seat('a', 'lead', '/w/app'), seat('a', 'impl', '/w/app'), seat('a', 'x', '/tmp')]),
      rig('b', 0, [Seat(rigId: 'b', logicalId: 'lead', cwd: '/w/hako', runtime: 'claude-code', needsInput: true)]),
      rig('c', 0, [seat('c', 'lead', null)]),
    ], ['~/dotfiles', '/w/app']);

    expect(projects.map((p) => p.path), ['/w/hako', '/w/app', '~/dotfiles', '(no folder)']);
    expect(projects[1].rigs.single.rig.id, 'a');
    expect(projects[1].pinned, isTrue);
    expect(projects[2].rigs, isEmpty);
  });

  test('worktrees join their main checkout and say which one they are', () {
    const repo = '/w/app';
    LooseAgent agent(String id, String cwd) => LooseAgent(id: id, cwd: cwd);
    final projects = groupIntoProjects([
      rig('a', 0, [seat('a', 'lead', '$repo/.worktrees/fix')]),
    ], const [], [
      agent('main', repo),
      agent('wt', '$repo/.claude/worktrees/design-pass'),
      agent('sub', '$repo/.claude/worktrees/design-pass/lib/ui'),
      agent('nested', '$repo/.claude/worktrees/one/.claude/worktrees/two'),
    ]);
    expect(projects.single.path, repo);
    expect(projects.single.rigs.single.rig.id, 'a');
    expect(projects.single.loose.map((a) => a.id), ['main', 'wt', 'sub', 'nested']);
    expect(worktreeName(projects.single.loose[1].cwd), 'design-pass');
    expect(worktreeName(projects.single.loose[0].cwd), isNull);
    expect(seatTitle('no rig', projects.single.loose[1].toSeat()), 'claude · design-pass');
    expect(seatTitle('no rig', projects.single.loose[0].toSeat()), 'no rig · claude');
    expect(seatTitle('build', seat('build', 'lead', '$repo/.worktrees/fix')), 'build · lead · fix');

    // A folder merely called worktrees is not one, and a pinned worktree stays put.
    expect(mainCheckout('/w/worktrees/app'), '/w/worktrees/app');
    final pinned = groupIntoProjects(const [], ['$repo/.worktrees/fix'], [agent('p', '$repo/.worktrees/fix')]);
    expect(pinned.single.path, '$repo/.worktrees/fix');
    expect(pinned.single.loose.single.id, 'p');
  });

  test('a folder under a project path joins it, in any order; a home folder does not swallow projects', () {
    LooseAgent agent(String id, String cwd) => LooseAgent(id: id, cwd: cwd);
    final projects = groupIntoProjects([
      rig('sub', 0, [seat('sub', 'lead', '/w/app/apps/web')]),
      rig('wt', 0, [seat('wt', 'lead', '/w/app/worktrees/fix')]),
      rig('root', 0, [seat('root', 'lead', '/w/app')]),
      rig('other', 0, [seat('other', 'lead', '/w/application')]),
    ], ['/Users/me', '/w/pinned'], [
      agent('home', '/Users/me'),
      agent('repo', '/Users/me/code/repo'),
      agent('pin', '/w/pinned/x/y'),
    ]);
    final by = {for (final p in projects) p.path: p};
    expect(by['/w/app']!.rigs.map((r) => r.rig.id), ['sub', 'wt', 'root']);
    expect(by['/w/application']!.rigs.single.rig.id, 'other');
    expect(by['/Users/me']!.loose.map((a) => a.id), ['home']);
    expect(by['/Users/me/code/repo']!.loose.single.id, 'repo');
    expect(by['/w/pinned']!.loose.single.id, 'pin');
    expect(by.keys, isNot(contains('/w/app/apps/web')));
  });

  test('project shell command quotes paths and names one tmux session per folder', () {
    expect(projectShellCommand('~/code/My Proj'),
        'if command -v tmux >/dev/null 2>&1; then exec tmux -u new-session -A -s \'rp-my-proj\' '
        '-c "\$HOME"/\'code/My Proj\'; else cd "\$HOME"/\'code/My Proj\' && clear; fi');
    expect(projectShellCommand("/srv/o'neil"), contains("-c '/srv/o'\\''neil'"));
  });

  test('~ itself is the home folder, not a folder named ~: one shellDir rule for every cd', () {
    expect(shellDir('~'), '"\$HOME"');
    expect(shellDir('~/a b'), '"\$HOME"/\'a b\'');
    expect(shellDir('/srv/x'), "'/srv/x'");
    expect(projectShellCommand('~'), contains('-c "\$HOME";'));
    expect(projectShellCommand('~'), contains('cd "\$HOME" && clear'));
  });

  test('seat parsing tolerates the daemon\'s needs-input shapes', () {
    final s = Seat.fromJson({
      'rigId': 'r',
      'logicalId': 'lead',
      'canonicalSessionName': 'lead@r',
      'runtime': 'claude-code',
      'activityState': {
        'display': 'waiting',
        'needsInput': {'count': 1, 'reason': 'Bash: npm test'}
      },
    });
    expect(s.needsInput, isTrue);
    expect(s.needsInputReason, 'Bash: npm test');
    expect(s.sessionStatus, 'waiting');
    expect(Seat.fromJson({'logicalId': 'x'}).needsInput, isFalse);
  });

  test('git worktree list --porcelain parses, main first, detached has no branch', () {
    final w = Worktree.parse('worktree /w/app\nHEAD abc\nbranch refs/heads/main\n\n'
        'worktree /w/app/.claude/worktrees/fix\nHEAD def\nbranch refs/heads/feat/x\n\n'
        'worktree /w/other\nHEAD 123\ndetached\n');
    expect(w.map((e) => e.path), ['/w/app', '/w/app/.claude/worktrees/fix', '/w/other']);
    expect(w.map((e) => e.branch), ['main', 'feat/x', null]);
    expect(w[1].name, 'fix');
    expect(Worktree.parse(''), isEmpty);
  });

  test('a project splits by worktree, main checkout first, empty ones left out', () {
    const repo = '/w/app';
    LooseAgent loose(String id, String cwd, {bool waiting = false}) => LooseAgent(id: id, cwd: cwd, waiting: waiting);
    final p = Project(path: repo, rigs: [
      rig('wt', 0, [seat('wt', 'lead', '$repo/.claude/worktrees/fix-ci')]),
      rig('main', 1, [seat('main', 'lead', repo)]),
    ], loose: [
      loose('a', '$repo/.worktrees/tabs/lib'),
      loose('b', '$repo/.claude/worktrees/fix-ci', waiting: true),
    ]);

    final groups = byWorktree(p);
    expect(groups.map((g) => g.$1), [null, 'fix-ci', 'tabs']);
    expect(groups[0].$2.single.rig.id, 'main');
    expect(groups[1].$2.single.rig.id, 'wt');
    expect(groups[1].$3.single.id, 'b');
    expect(groups[2].$3.single.id, 'a');
    expect(byWorktree(Project(path: '/w/empty')), isEmpty);
  });

  test('groupByWorktree is the one grouping: main first, shells too, names from the path; byWorktree is it without the shells', () {
    const repo = '/w/app';
    final p = Project(path: repo, rigs: [
      rig('wt', 0, [seat('wt', 'lead', '$repo/.claude/worktrees/fix-ci')]),
    ], loose: [
      LooseAgent(id: 'a', cwd: repo, waiting: false),
    ]);
    p.shells
      ..add(const ProjectShell('rp-main', repo))
      ..add(const ProjectShell('rp-fix', '$repo/.claude/worktrees/fix-ci/lib'))
      ..add(const ProjectShell('rp-only', '$repo/.worktrees/only-shell'));
    final groups = groupByWorktree(p);
    expect(groups.map((g) => g.name), [null, 'fix-ci', 'only-shell']);
    expect(groups[0].loose.single.id, 'a');
    expect(groups[0].shells.single.name, 'rp-main');
    expect(groups[1].rigs.single.rig.id, 'wt');
    expect(groups[1].shells.single.name, 'rp-fix');
    expect(groups[2].rigs, isEmpty);
    expect(groups[2].shells.single.name, 'rp-only', reason: 'a worktree with only a shell is a group');
    expect(byWorktree(p).map((g) => g.$1), [null, 'fix-ci'], reason: 'the Worktrees tab has no shell-only group');
    expect(groupByWorktree(Project(path: '/w/empty')), isEmpty);
  });

  test('a rig belongs to one place, the worktree where most of its seats with a known folder run, with every seat; a seat elsewhere gets a chip, an unknown folder never moves it', () {
    const repo = '/w/app', wt = '$repo/.claude/worktrees/x';
    final rg = rig('wtrig', 4, [
      seat('wtrig', 'lead', wt),
      seat('wtrig', 'impl', '$wt/lib'),
      seat('wtrig', 'qa', repo), // launched in the main checkout
      Seat(rigId: 'wtrig', logicalId: 'doc', cwd: null, runtime: 'claude-code', sessionName: 'doc@wtrig', activity: 'idle'), // unknown
    ]);
    final p = Project(path: repo, rigs: [rg]);
    final groups = groupByWorktree(p);
    expect(groups.map((g) => g.name), ['x'], reason: 'listed once, under the worktree (the main checkout has nothing)');
    expect(groups.single.rigs.single, same(rg), reason: 'the rig as it is: all four seats');
    expect(groups.single.rigs.single.seats, hasLength(4));
    expect([for (final s in rg.seats) seatPlaceChip(s, rg.primaryCwd)], [null, null, 'in main', null],
        reason: 'one chip, on the seat that runs in main; the unknown one has none');
    // A tie goes to the first listed folder, the same every time.
    final tie = rig('tie', 2, [seat('tie', 'a', repo), seat('tie', 'b', wt)]);
    expect(tie.primaryCwd, repo);
    expect(byWorktree(p).map((g) => g.$1), ['x']);
  });

  test('the adopt picker offers the agent\'s worktree, else its project, else every rig', () {
    const repo = '/w/app', wtX = '$repo/.claude/worktrees/x', wtY = '$repo/.claude/worktrees/y';
    RigWithSeats at(String id, String cwd) => rig(id, 0, [seat(id, 'lead', cwd)]);
    final inX = at('in-x', wtX), inY = at('in-y', wtY), inMain = at('in-main', repo), other = at('other', '/w/other');
    List<String> names(List<RigWithSeats> l) => [for (final r in l) r.rig.id];
    final agentInX = LooseAgent(id: 'a', cwd: '$wtX/lib');

    expect(names(adoptCandidates([inX, inY, inMain, other], agentInX, const [])), ['in-x'], reason: 'its worktree');
    expect(names(adoptCandidates([inY, inMain, other], agentInX, const [])), ['in-y', 'in-main'],
        reason: 'no rig in x: its project');
    expect(names(adoptCandidates([other], agentInX, const [])), ['other'], reason: 'none in the project: all');
    expect(names(adoptCandidates([inX, inMain], LooseAgent(id: 'm', cwd: repo), const [])), ['in-main'],
        reason: 'the main checkout is a worktree scope of its own');
    final noFolder = rig('nf', 0, [seat('nf', 'lead', null)]);
    expect(names(adoptCandidates([noFolder, inX, other], LooseAgent(id: 'n'), const [])), ['nf', 'in-x', 'other'],
        reason: 'an agent with no folder has no scope: every rig');
  });
}
