import 'package:flutter/material.dart';

import '../../api/openrig_client.dart' show OpenRigException;
import '../../data/git_status.dart';
import '../../models.dart';
import '../../ssh/ssh_exec.dart';
import '../common.dart';
import '../kit.dart';
import '../theme.dart' show Tokens;

/// What the Delete worktree dialog says, apart from the dialog. A clean worktree gets a plain confirm; one with uncommitted or
/// untracked files lists a few and its action is "Delete anyway" (git's --force). Agents and shells running in it are named:
/// deleting does not stop them. The branch is always kept, and the dialog says so.
({String title, String body, String action, bool dirty}) deleteWorktreeText({
  required String name,
  required String? branch,
  required String shownPath,
  required List<String> changes,
  List<String> agents = const [],
  List<String> shells = const [],
}) {
  final dirty = changes.isNotEmpty;
  final shown = changes.take(5).join(', ');
  final more = changes.length - 5;
  return (
    title: 'Delete $name?',
    dirty: dirty,
    action: dirty ? 'Delete anyway' : 'Delete',
    body: [
      'Deletes the folder $shownPath. The branch ${branch ?? '(detached HEAD)'} is kept.',
      if (dirty)
        '${changes.length} changed ${changes.length == 1 ? 'file' : 'files'} will be lost: $shown${more > 0 ? ' and $more more' : ''}.',
      'Ignored files in it (like .env or build output) are deleted too.',
      if (agents.isNotEmpty || shells.isNotEmpty)
        'Still running here: ${[...agents.map((a) => '$a (agent)'), ...shells.map((s) => '$s (shell)')].join(', ')}. '
            'They are not stopped; they will be left in a folder that no longer exists.',
    ].join('\n\n'),
  );
}

/// Deletes worktree [w] of the project at [repo] over SSH, after the confirm [deleteWorktreeText] describes. True when it is
/// gone. Never the main checkout (the repo's own folder). Reads what is uncommitted first, so the dialog is about the
/// folder as it is now; git itself still refuses a dirty folder that was not forced.
Future<bool> deleteWorktree(
  BuildContext context, {
  required Host host,
  required String repo,
  required Worktree w,
  required String name,
  List<String> agents = const [],
  List<String> shells = const [],
}) async {
  if (w.path == repo) return false;
  final messenger = ScaffoldMessenger.of(context);
  final k = Tokens.of(context);
  Future<List<String>?> read() async {
    SshExec? ssh;
    try {
      ssh = await SshExec.connect(host);
      return await ssh.worktreeChanges(w.path);
    } catch (e) {
      toastOn(messenger, k, e is OpenRigException ? e.message : '$e');
      return null;
    } finally {
      ssh?.close();
    }
  }

  var changes = await read();
  if (changes == null) return false;
  var dirty = false;
  // A forced delete asks again when the folder changed since the dialog listed it (the agents there keep writing): the list
  // the person confirms is the list that is deleted. git itself refuses an unforced remove of a dirty folder.
  for (;;) {
    if (!context.mounted) return false;
    final text = deleteWorktreeText(
        name: name, branch: w.branch, shownPath: displayPath(w.path), changes: changes!, agents: agents, shells: shells);
    if (!await confirmSheet(context, title: text.title, body: text.body, action: text.action, destructive: text.dirty)) {
      return false;
    }
    dirty = text.dirty;
    if (!dirty) break;
    final fresh = await read();
    if (fresh == null) return false;
    if (fresh.length == changes.length && fresh.toSet().containsAll(changes)) break;
    changes = fresh;
  }
  SshExec? ssh;
  try {
    ssh = await SshExec.connect(host);
    await ssh.removeWorktree(repo, w.path, force: dirty);
  } catch (e) {
    toastOn(messenger, k, e is OpenRigException ? e.message : '$e');
    return false;
  } finally {
    ssh?.close();
  }
  toastOn(messenger, k, 'Deleted $name', kind: ToastKind.done);
  return true;
}
