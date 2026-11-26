import '../models.dart';
import 'needs_you.dart';

/// OpenRig has no rig→project link in its API, so a "project" here is a
/// folder: each rig lands under the cwd most of its seats run in, and pinned
/// folders show up even with no rig. Agents started by hand ([loose]) join
/// the folder they run in. Worktrees count as their main checkout, unless
/// pinned on their own.
/// Where a folder sits among the others: 0 a known project (pinned, or a rig runs there), 1 any other folder where only agents or
/// shells run (or the '(no folder)' bucket), 2 the home folder, last. The sidebar and the Rigs home both list by it.
int projectGroup(Project p) =>
    isHomeFolder(p.path) ? 2 : (p.path != '(no folder)' && (p.pinned || p.rigs.isNotEmpty) ? 0 : 1);

List<Project> groupIntoProjects(List<RigWithSeats> rigs, List<String> pinned,
    [List<LooseAgent> loose = const [], List<AttentionItem> attention = const [], List<ProjectShell> shells = const []]) {
  final byPath = <String, Project>{};
  for (final p in pinned) {
    byPath[p] = Project(path: p, pinned: true);
  }
  // A folder under another project's path (a worktree, a subfolder) joins it, whatever order the rigs come in.
  // A home folder takes only its own agents: everything is under it.
  bool contains(String root, String cwd) => cwd == root || (!isHomeFolder(root) && isUnder(cwd, root));
  final cwds = [
    for (final r in rigs)
      if (r.primaryCwd case final c?) c,
    for (final a in loose)
      if (a.cwd case final c?) c,
    for (final s in shells) s.cwd,
  ];
  final derived = {for (final c in cwds) mainCheckout(c)};
  final all = {...pinned, ...derived};
  final roots = {...pinned, ...derived.where((d) => !all.any((o) => o != d && contains(o, d)))};
  Project projectFor(String cwd) {
    String? best;
    for (final path in roots) {
      if (contains(path, cwd) && (best == null || path.length > best.length)) best = path;
    }
    final path = best ?? mainCheckout(cwd);
    return byPath[path] ??= Project(path: path);
  }

  final noFolder = Project(path: '(no folder)');
  for (final r in rigs) {
    final cwd = r.primaryCwd;
    (cwd == null ? noFolder : projectFor(cwd)).rigs.add(r);
  }
  for (final a in loose) {
    final cwd = a.cwd;
    (cwd == null ? noFolder : projectFor(cwd)).loose.add(a);
  }
  for (final s in shells) {
    projectFor(s.cwd).shells.add(s);
  }
  final asks = needsYouList(rigs, loose, attention);
  for (final p in [...byPath.values, noFolder]) {
    p.attention = asks.where((i) => i.inProject(p)).length;
  }
  final list = byPath.values.toList()
    ..sort((a, b) {
      // Known projects (pinned, or with a rig) first, then the other folders where something runs, the home folder last;
      // within each, needs-you first, then by name.
      final byTier = projectGroup(a).compareTo(projectGroup(b));
      if (byTier != 0) return byTier;
      final byAttention = b.attention.compareTo(a.attention);
      if (byAttention != 0) return byAttention;
      return a.name.compareTo(b.name);
    });
  if (noFolder.rigs.isNotEmpty || noFolder.loose.isNotEmpty) list.add(noFolder);
  return list;
}

/// Quote a string for a POSIX shell.
String shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

/// A folder for `cd` or `-c`, with `~` and `~/` expanded on the host (quoted, so a folder name is never a command).
String shellDir(String path) =>
    path.startsWith('~/') ? '"\$HOME"/${shQuote(path.substring(2))}' : (path == '~' ? '"\$HOME"' : shQuote(path));

/// tmux session names may not contain '.' or ':'.
String tmuxSafe(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

/// The tmux session a project's shell runs in.
String projectShellSession(String path) => 'rp-${tmuxSafe(path.split('/').where((p) => p.isNotEmpty).lastOrNull ?? 'home')}';

/// The project shells among the host's tmux sessions (`name`, `folder` pairs from the scan): the `rp-*` ones.
List<ProjectShell> projectShells(Iterable<(String, String)> sessions) =>
    [for (final (name, path) in sessions) if (name.startsWith('rp-') && path.startsWith('/')) ProjectShell(name, path)];

/// The command typed into a fresh login shell to open a project shell.
///
/// With tmux on the host it creates — or reattaches to — one persistent
/// session per folder (`rp-<folder>`), so dropping off the network on the
/// phone never kills what was running. Without tmux it just cd's there.
String projectShellCommand(String path) {
  final name = projectShellSession(path);
  final dir = shellDir(path);
  return 'if command -v tmux >/dev/null 2>&1; '
      'then exec tmux -u new-session -A -s ${shQuote(name)} -c $dir; '
      'else cd $dir && clear; fi';
}

/// What runs in one place of a project: its main checkout ([name] null) or a worktree, by the worktree's name.
class WorktreeGroup {
  WorktreeGroup(this.name);
  final String? name;
  final List<RigWithSeats> rigs = [];
  final List<LooseAgent> loose = [];
  final List<ProjectShell> shells = [];
  bool get isEmpty => rigs.isEmpty && loose.isEmpty && shells.isEmpty;
}

/// Which worktree a rig runs in (null: the main checkout): where most of its seats with a known folder run. A rig belongs to
/// one place, with all its seats; a seat elsewhere is told apart by [seatPlaceChip], not listed twice. Seats with no known
/// folder never move it.
String? rigWorktree(RigWithSeats r) => worktreeName(r.primaryCwd);

/// A project's rigs, hand-started agents and shells grouped by the worktree they run in: the main checkout first (null
/// name), then the others as first seen; a group with nothing in it is left out. The worktree is read from the path
/// (worktreeName), so this makes no git call: the sidebar, the Rigs home and the project's Worktrees tab all group by it.
List<WorktreeGroup> groupByWorktree(Project p) {
  final groups = <String?, WorktreeGroup>{null: WorktreeGroup(null)};
  WorktreeGroup of(String? name) => groups.putIfAbsent(name, () => WorktreeGroup(name));
  for (final r in p.rigs) {
    of(rigWorktree(r)).rigs.add(r);
  }
  for (final a in p.loose) {
    of(worktreeName(a.cwd)).loose.add(a);
  }
  for (final sh in p.shells) {
    of(worktreeName(sh.cwd)).shells.add(sh);
  }
  return [for (final g in groups.values) if (!g.isEmpty) g];
}

/// [p] with what runs in the worktrees git lists for it ([worktreePaths], the main checkout left out) that the path rule filed
/// as projects of their own (`git worktree add ../x` puts one outside `.claude/worktrees`): their rigs, agents and shells
/// join it. No git call: the project page already has git's list.
Project withListedWorktrees(Project p, Iterable<Project> all, Iterable<String> worktreePaths) {
  final others = [
    for (final q in all)
      if (q.path != p.path && worktreePaths.any((w) => isUnder(q.path, w))) q
  ];
  if (others.isEmpty) return p;
  final merged = Project(
    path: p.path,
    rigs: [...p.rigs, for (final q in others) ...q.rigs],
    loose: [...p.loose, for (final q in others) ...q.loose],
    pinned: p.pinned,
  )
    ..shells.addAll([...p.shells, for (final q in others) ...q.shells])
    ..attention = p.attention + others.fold(0, (n, q) => n + q.attention);
  return merged;
}

/// A project's rigs and hand-started agents grouped by the worktree they run in (null: the main checkout), main checkout
/// first: [groupByWorktree] without the shells.
List<(String?, List<RigWithSeats>, List<LooseAgent>)> byWorktree(Project p) => [
      for (final g in groupByWorktree(p))
        if (g.rigs.isNotEmpty || g.loose.isNotEmpty) (g.name, g.rigs, g.loose),
    ];

/// The rigs [agent] could be adopted into, in the narrowest scope that has any: its own worktree, else its
/// project, else all of [rigs]. Scopes are the Projects card's (groupIntoProjects, byWorktree), so the picker
/// agrees with where the agent and the rigs are listed.
List<RigWithSeats> adoptCandidates(List<RigWithSeats> rigs, LooseAgent agent, List<String> pinned) {
  if (agent.cwd == null) return rigs; // no folder, so no scope to narrow to
  final project = groupIntoProjects(rigs, pinned, [agent]).where((p) => p.loose.contains(agent)).firstOrNull;
  if (project == null) return rigs;
  final worktree = byWorktree(project).where((g) => g.$3.contains(agent)).firstOrNull;
  if (worktree != null && worktree.$2.isNotEmpty) return worktree.$2;
  return project.rigs.isNotEmpty ? project.rigs : rigs;
}
