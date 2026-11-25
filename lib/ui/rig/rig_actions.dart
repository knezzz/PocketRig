import 'package:flutter/material.dart';

import '../../api/openrig_client.dart' show OpenRigClient, OpenRigException;
import '../../data/fleet.dart';
import '../../main.dart';
import '../../models.dart';
import '../../terminal/transport.dart';
import '../action_rows.dart';
import '../busy.dart';
import '../common.dart';
import '../desktop_shell.dart';
import '../kit.dart';
import '../project_actions.dart' show projectNameOf;
import '../rig_screen.dart' show editRigSpec;
import '../stop_rig.dart';
import '../terminal_screen.dart';
import '../theme.dart';

/// The one ⋯ list for a rig, from any trigger (its screen, a project's row, the sidebar): running rigs get
/// Snapshot and Stop, stopped ones Restore and Delete (a running rig can't be deleted). Every action is
/// self-contained and runs once per rig however many triggers fire ([busyKeys]). [onOpen] is null on the rig's own
/// screen, [onWorktree] only where the project can start it elsewhere, [onDeleted] lets a screen leave. A row that
/// can open the rig's tiles (the sidebar) passes [onOpen]; one that can fold it passes its [view], whether it has agents
/// [anyActive] and [onView]. Open and the view choices come first.
Future<void> showRigActions(
  BuildContext context,
  Rig rig,
  List<Seat> seats, {
  String? title,
  String? projectName,
  VoidCallback? onOpen,
  RigView? view,
  bool anyActive = false,
  void Function(RigView)? onView,
  VoidCallback? onWorktree,
  VoidCallback? onOpenWorktree,
  VoidCallback? onDeleted,
}) =>
    showActionRows(
        context,
        title ?? rig.name,
        rigActionRows(context, rig, seats,
            projectName: projectName,
            onOpen: onOpen,
            view: view,
            anyActive: anyActive,
            onView: onView,
            onWorktree: onWorktree,
            onOpenWorktree: onOpenWorktree,
            onDeleted: onDeleted));

/// The rows of [showRigActions], for the command palette too.
ActionRows rigActionRows(
  BuildContext context,
  Rig rig,
  List<Seat> seats, {
  String? projectName,
  VoidCallback? onOpen,
  RigView? view,
  bool anyActive = false,
  void Function(RigView)? onView,
  VoidCallback? onWorktree,
  VoidCallback? onOpenWorktree,
  VoidCallback? onDeleted,
}) {
  final stopped = rig.status == 'stopped';
  final cwd = RigWithSeats(rig, seats).primaryCwd;
  return (items: [
    if (onOpen != null) (Icons.open_in_new_outlined, 'Open rig', null, onOpen),
    // A rig that runs in a worktree: the worktree's own page (the sidebar has no row for it).
    if (onOpenWorktree != null) (Icons.call_split, 'Open worktree', null, onOpenWorktree),
    if (view != null && onView != null) ...viewRows(view, anyActive, onView),
    (Icons.edit_outlined, 'Rename label', 'Only shown in this app', () => renameRigLabel(context, rig)),
    (
      Icons.description_outlined,
      'Edit spec',
      null,
      () => exclusive(
          rig.id, () => editRigSpec(context, rig, seats, projectName: projectName ?? projectNameOf(cwd ?? rig.name)))
    ),
    if (stopped)
      (Icons.restore_outlined, 'Restore', rig.latestSnapshot, () => restoreRigOnce(context, rig))
    else
      (Icons.photo_camera_outlined, 'Snapshot', 'Save its state to restore later', () => snapshotRig(context, rig)),
    if (cwd != null)
      (
        Icons.terminal_outlined,
        'Shell here',
        null,
        () => detailNavigator(context)
            .push(MaterialPageRoute(builder: (_) => TerminalScreen(target: ProjectShellTarget(cwd))))
      ),
    if (onWorktree != null) (Icons.call_split_outlined, 'Start in another worktree…', null, onWorktree),
  ], danger: [
    if (stopped)
      ('Delete rig…', Icons.delete_outline, () => deleteRig(context, rig, onDeleted: onDeleted))
    else
      ('Stop rig…', Icons.stop_circle_outlined, () => stopRig(context, rig, seats)),
  ]);
}

/// [work] against the daemon with a toast for how it went, once per rig, then a fresh look at the host. True when it worked.
Future<bool> _rigWork(BuildContext context, Rig rig, String done, Future<void> Function(OpenRigClient api) work) async {
  final api = AppScope.clientOf(context);
  final host = AppScope.read(context).active;
  if (api == null) return false;
  final messenger = ScaffoldMessenger.of(context);
  final k = Tokens.of(context);
  var ok = false;
  await exclusive(rig.id, () async {
    try {
      await work(api);
      ok = true;
      toastOn(messenger, k, done, kind: ToastKind.done);
    } catch (e) {
      toastOn(messenger, k, e is OpenRigException ? e.message : e.toString(), kind: ToastKind.problem);
    }
    if (host != null) await fleet.feedFor(host).refresh();
  });
  return ok;
}

Future<bool> snapshotRig(BuildContext context, Rig rig) =>
    _rigWork(context, rig, 'Snapshot saved', (api) => api.snapshot(rig.id));

/// Asks with the shared stop sheet (snapshot first, on by default), then stops it.
Future<void> stopRig(BuildContext context, Rig rig, List<Seat> seats) async {
  if (busyKeys.value.contains(rig.id)) return;
  final snapshot = await confirmStopRig(context, rig, seats);
  if (snapshot == null || !context.mounted) return;
  await _rigWork(context, rig, 'Stopped ${rig.name}', (api) => api.down(rig.id, snapshot: snapshot));
}

Future<void> restoreRigOnce(BuildContext context, Rig rig) async {
  final host = AppScope.read(context).active;
  if (host == null) return;
  await exclusive(rig.id, () => restoreRig(context, host, rig));
}

Future<void> deleteRig(BuildContext context, Rig rig, {VoidCallback? onDeleted}) async {
  if (busyKeys.value.contains(rig.id)) return;
  if (!await confirmDeleteRig(context, rig) || !context.mounted) return;
  if (await _rigWork(context, rig, 'Deleted ${rig.name}', (api) => api.deleteRig(rig.id))) onDeleted?.call();
}

/// A name for the rig in the app only; empty clears it.
Future<void> renameRigLabel(BuildContext context, Rig rig) async {
  final store = AppScope.read(context);
  final host = store.active;
  if (host == null) return;
  final name = await inputSheet(context,
      title: 'Rename rig',
      initial: host.rigNames[rig.name] ?? '',
      hint: rig.name,
      helper: 'Only shown in this app. Seats and rig commands keep "${rig.name}".',
      capitalization: TextCapitalization.sentences);
  if (name == null) return;
  final clean = name.trim();
  if (clean.isEmpty || clean == rig.name) {
    host.rigNames.remove(rig.name);
  } else {
    host.rigNames[rig.name] = clean;
  }
  await store.save();
}
