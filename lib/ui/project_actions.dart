import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/openrig_client.dart' show OpenRigException;
import '../data/fleet.dart' show RigView, fleet;
import '../data/loose_agents.dart' show closeShell;
import '../main.dart';
import '../models.dart' show Host, Project, ProjectShell, folderName, worktreeName;
import '../ssh/ssh_exec.dart';
import '../terminal/transport.dart';
import 'action_rows.dart';
import 'common.dart';
import 'desktop_shell.dart';
import 'kit.dart';
import 'new_session_sheet.dart';
import 'project/specs.dart' show startRigInProject;
import 'project/worktree_screen.dart' show openWorktreeScreen;
import 'worktree_name_field.dart' show NewWorktreeSheet;
import 'terminal_screen.dart';
import 'theme.dart' show Tokens;

String projectNameOf(String path) => folderName(path);

/// The one ⋯ list for a project folder, whichever row or screen asks. Everything it needs it reads on the spot,
/// so it works from a bare sidebar row; [onChanged] lets an open project screen reload what it shows. A row that
/// can open the project (the sidebar) passes [onOpen]; one that can fold it passes its [view], whether it has agents
/// [anyActive] and [onView]; [onUnpinned] runs after Unpin (the sidebar leaves the project it had open).
Future<void> showProjectActions(BuildContext context, String path,
        {VoidCallback? onChanged, VoidCallback? onOpen, RigView? view, bool anyActive = false, void Function(RigView)? onView, VoidCallback? onUnpinned}) =>
    showActionRows(context, projectNameOf(path),
        projectActionRows(context, path, onChanged: onChanged, onOpen: onOpen, view: view, anyActive: anyActive, onView: onView, onUnpinned: onUnpinned));

/// The rows of [showProjectActions], for the command palette too.
ActionRows projectActionRows(BuildContext context, String path,
    {VoidCallback? onChanged, VoidCallback? onOpen, RigView? view, bool anyActive = false, void Function(RigView)? onView, VoidCallback? onUnpinned}) {
  final host = AppScope.read(context).active;
  final specFolder = host?.specFolders[path];
  return (items: [
    if (onOpen != null) (Icons.open_in_new_outlined, 'Open', null, onOpen),
    if (view != null && onView != null) ...viewRows(view, anyActive, onView),
    (Icons.add_comment_outlined, 'New agent', null, () => startAgentInFolder(context, path)),
    // Reads the project's specs first (one spec starts directly, several ask which): the same flow as the project
    // page's Start rig, so a project with no spec says so.
    if (host != null)
      (
        Icons.rocket_launch_outlined,
        'Start rig…',
        'From this project\'s specs',
        () => startRigInProject(context, host, path, projectNameOf(path),
            push: (screen) => detailNavigator(context).push(MaterialPageRoute(builder: (_) => screen)))
      ),
    (
      Icons.terminal_outlined,
      'Shell here',
      null,
      () => detailNavigator(context)
          .push(MaterialPageRoute(builder: (_) => TerminalScreen(target: ProjectShellTarget(path))))
    ),
    if (host != null) (Icons.call_split_outlined, 'New worktree…', null, () => newWorktree(context, host, path, onChanged)),
    (Icons.open_in_new_outlined, 'Open on GitHub', null, () => openOnGitHub(context, path)),
    (
      Icons.create_new_folder_outlined,
      specFolder == null ? 'Connect spec folder…' : 'Change spec folder…',
      specFolder ?? 'Another folder with rig.yaml files',
      () => connectSpecFolder(context, path, onChanged)
    ),
    if (host?.pinnedFolders.contains(path) ?? false)
      (
        Icons.push_pin_outlined,
        'Unpin',
        'Drop it from Projects when nothing runs here',
        () async {
          final store = AppScope.read(context);
          // The row that opened this unmounts with the unpin, so the toast goes through a messenger taken before it.
          final messenger = ScaffoldMessenger.of(context);
          final k = Tokens.of(context);
          await store.unpinFolder(host!, path);
          onUnpinned?.call();
          toastOn(messenger, k, 'Unpinned ${projectNameOf(path)}', kind: ToastKind.info);
        }
      ),
  ], danger: const []);
}

/// A running project shell's ⋯ list: open its terminal, or close the session (after a confirm).
Future<void> showShellActions(BuildContext context, Host host, ProjectShell s) => showActionRows(context, host.shellLabel(s.name), (
      items: [
        (Icons.terminal_outlined, 'Open terminal', null, () => openShell(context, s)),
        (Icons.edit_outlined, 'Rename…', 'Only shown in this app', () => renameShellLabel(context, host, s)),
      ],
      danger: [('Close shell…', Icons.close, () => confirmCloseShell(context, host, s).ignore())],
    ));

/// Closes a project shell after a confirm: the one call behind every Close shell (the sidebar's list, the project's Shells
/// tab, the terminal's menu). True when the shell was closed; false on cancel or error (the error is toasted).
Future<bool> confirmCloseShell(BuildContext context, Host host, ProjectShell s) async {
  final messenger = ScaffoldMessenger.of(context);
  final k = Tokens.of(context);
  final store = AppScope.read(context);
  if (!await confirmSheet(context,
      title: 'Close ${host.shellLabel(s.name)}?',
      body: 'This ends the tmux session and anything running in it.',
      action: 'Close shell')) {
    return false;
  }
  try {
    await closeShell(host, s);
    // A new shell with this session name is a different shell: it starts without the label.
    if (host.rigNames.remove(s.name) != null) await store.save();
    toastOn(messenger, k, 'Closed ${host.shellLabel(s.name)}');
    fleet.feedFor(host).refresh().ignore();
    return true;
  } catch (e) {
    toastOn(messenger, k, '$e');
    return false;
  }
}

/// A name for the shell in the app only; empty clears it.
Future<void> renameShellLabel(BuildContext context, Host host, ProjectShell s) async {
  final store = AppScope.read(context);
  final name = await inputSheet(context,
      title: 'Rename shell',
      initial: host.rigNames[s.name] ?? '',
      hint: s.name,
      helper: 'Only shown in this app. The tmux session keeps "${s.name}".',
      capitalization: TextCapitalization.sentences);
  if (name == null) return;
  final clean = name.trim();
  if (clean.isEmpty || clean == s.name) {
    host.rigNames.remove(s.name);
  } else {
    host.rigNames[s.name] = clean;
  }
  await store.save();
}

/// Attaches to a project shell: the same `tmux new-session -A` that "Shell here" runs.
void openShell(BuildContext context, ProjectShell s) => detailNavigator(context)
    .push(MaterialPageRoute(builder: (_) => TerminalScreen(target: ProjectShellTarget(s.cwd))));

/// Another folder on the host to search for this project's rig specs; an empty answer disconnects it.
Future<void> connectSpecFolder(BuildContext context, String path, [VoidCallback? onChanged]) async {
  final store = AppScope.read(context);
  final host = store.active;
  if (host == null) return;
  final answer = await inputSheet(
    context,
    title: 'Connect a rig folder',
    initial: host.specFolders[path] ?? '',
    hint: '~/.openrig/specs',
    helper: 'A folder on ${host.name} with rig.yaml files',
    action: 'Connect',
    code: true,
  );
  if (answer == null) return;
  final clean = answer.trim();
  if (clean.isEmpty) {
    host.specFolders.remove(path);
  } else {
    host.specFolders[path] = clean;
  }
  await store.save();
  onChanged?.call();
}

void _problem(BuildContext context, Object e) =>
    toast(context, e is OpenRigException ? e.message : e.toString(), kind: ToastKind.problem);

/// The New worktree sheet for [path] on [host] (the project's own, not whichever is active by the time it is used): the
/// name with its live preview, then Create. After Create the new worktree's own page opens; [onChanged] lets an open
/// project screen reload what it shows.
Future<void> newWorktree(BuildContext context, Host host, String path, [VoidCallback? onChanged, String? typed]) async {
  final store = AppScope.read(context);
  final made = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => AppScope(store: store, child: NewWorktreeSheet(host: host, project: path, initialName: typed)),
  );
  if (made == null || !context.mounted) return;
  onChanged?.call();
  final name = worktreeName(made);
  try {
    final project = fleet.feedFor(host).projects.where((p) => p.path == path).firstOrNull ?? Project(path: path);
    if (name == null) throw StateError('no worktree name in $made');
    openWorktreeScreen(context, host, project, name);
  } catch (_) {
    // Only when its page can't open: the worktree exists, so say so.
    if (context.mounted) toast(context, 'Created ${name ?? made}', kind: ToastKind.done);
  }
}

/// Opens the folder's GitHub repo, when `gh` knows it.
Future<void> openOnGitHub(BuildContext context, String path) async {
  final host = AppScope.read(context).active;
  if (host == null) return;
  SshExec? ssh;
  try {
    ssh = await SshExec.connect(host);
    final github = await ssh.github(path);
    if (!context.mounted) return;
    if (github == null) return toast(context, 'gh doesn\'t know this folder', kind: ToastKind.info);
    await launchUrl(Uri.parse(github.$1), mode: LaunchMode.externalApplication);
  } catch (e) {
    if (context.mounted) _problem(context, e);
  } finally {
    ssh?.close();
  }
}
