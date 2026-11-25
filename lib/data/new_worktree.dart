import '../models.dart';
import '../ssh/ssh_exec.dart';

/// What a new worktree is made from and must not collide with, read from the project's main checkout.
class WorktreeSetup {
  const WorktreeSetup({required this.repo, required this.base, required this.branches, required this.folders});

  /// The main checkout's path: the folder `<repo>/.claude/worktrees/<name>` is made under.
  final String repo;

  /// The main checkout's current branch (what the new branch starts from); null when its HEAD is detached.
  final String? base;
  final Set<String> branches;

  /// Names already under `.claude/worktrees`.
  final Set<String> folders;
}

/// The folder name addWorktree makes for a branch: slashes become dashes, so `fix/a-b` and `fix-a-b` share one.
String worktreeFolderName(String branch) => branch.replaceAll('/', '-');

final _validName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._/-]*$');

/// What is wrong with [name] as a new worktree's branch, as one sentence; null when it is fine (or empty, or [setup] is
/// not read yet).
String? worktreeNameError(String name, WorktreeSetup? setup) {
  if (name.isEmpty) return null;
  if (!_validName.hasMatch(name) || name.contains('..') || name.endsWith('/') || name.endsWith('.lock')) {
    return 'Use letters, digits, ".", "_", "-" and "/" (no spaces).';
  }
  if (setup == null) return null;
  if (setup.branches.contains(name)) return 'A branch named $name already exists.';
  final folder = worktreeFolderName(name);
  if (setup.folders.contains(folder)) {
    return 'The folder .claude/worktrees/$folder already exists${folder == name ? '' : ' ($name and $folder make the same folder)'}.';
  }
  return null;
}

/// Reads [project]'s main checkout on [host]. Throws when it is not a git repository or the host can't be reached.
Future<WorktreeSetup> readWorktreeSetup(Host host, String project) async {
  final ssh = await SshExec.connect(host);
  try {
    final all = await ssh.worktrees(project);
    final main = all.firstOrNull;
    if (main == null) throw StateError('No git repository in ${project.split('/').where((p) => p.isNotEmpty).lastOrNull ?? project}.');
    return WorktreeSetup(
      repo: main.path,
      base: main.branch,
      // The worktrees git lists, and what the host's own listing adds (a branch with no worktree, a stray folder).
      branches: {...await ssh.localBranches(main.path), for (final w in all) if (w.branch != null) w.branch!},
      folders: {...await ssh.worktreeFolders(main.path), for (final w in all.skip(1)) if (worktreeName(w.path) != null) worktreeName(w.path)!},
    );
  } finally {
    ssh.close();
  }
}
