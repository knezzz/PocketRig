import 'package:flutter/material.dart';

import '../../data/fleet.dart' show fleet;
import '../../data/host_store.dart' show isDesktop;
import '../../main.dart';
import '../../models.dart';
import '../../terminal/transport.dart';
import '../action_rows.dart';
import '../agent_details.dart';
import '../chat_screen.dart' show ChatScreen;
import '../common.dart';
import '../desktop_menu.dart' show menuBreak;
import '../desktop_shell.dart' show detailNavigator;
import '../kit.dart';
import '../project_actions.dart' show projectNameOf;
import '../rig_screen.dart' show editRigSpec;
import '../send_guard.dart';
import '../terminal_screen.dart';
import '../theme.dart';
import 'add_to_queue_sheet.dart' show canQueue, showAddToQueue;
import 'rig_bar.dart' show showRigSheet;

/// Runs the seat sheet's context picks: 'clear' and 'compact'.
Future<void> runSeatAction(
  BuildContext context,
  String pick,
  Seat s, {
  required Future<void> Function() onRefresh,
}) async {
  switch (pick) {
    case 'clear':
      if (await confirmClear(context, s) && context.mounted) {
        await _send(context, s, '/clear', 'Sent /clear to ${s.logicalId}', onRefresh);
      }
    case 'compact':
      final api = AppScope.clientOf(context);
      if (api == null ||
          !await confirmSheet(context,
              title: 'Compact ${s.logicalId}\'s context?',
              body: 'Runs OpenRig\'s guided compaction (rig compact): the seat writes down where it is, '
                  'runs /compact, then reads its notes back. It only starts while the seat is idle.',
              action: 'Compact',
              destructive: false) ||
          !context.mounted) {
        return;
      }
      try {
        await api.compact(s.sessionName!);
        if (context.mounted) toast(context, 'Compaction started on ${s.logicalId}');
        await onRefresh();
      } catch (e) {
        if (context.mounted) toast(context, e.toString());
      }
  }
}

/// "42%", or "unknown" when the daemon has no reading.
String contextLabel(Seat s) => s.contextUsedPercent == null ? 'unknown' : '${s.contextUsedPercent!.round()}%';

/// /clear wipes the seat's conversation, so it asks first.
Future<bool> confirmClear(BuildContext context, Seat s) => confirmSheet(context,
    title: 'Clear ${s.logicalId}\'s context?',
    body: [
      'Types /clear into the seat. It forgets this conversation (${contextLabel(s)} of its context) '
          'and starts empty. Files, the queue and the seat itself stay. This can\'t be undone.',
      if (s.state == SeatState.working) '\n\nIt\'s working right now; clearing mid-task drops what it was doing.',
    ].join(),
    action: 'Clear');

Future<void> _send(BuildContext context, Seat s, String text, String done, Future<void> Function() onRefresh) async {
  final api = AppScope.clientOf(context);
  if (api == null) return;
  // Typed into a seat that has a question open, it would answer it: ask first.
  final host = AppScope.read(context).active;
  if (host != null) {
    final nav = detailNavigator(context);
    final rigName = fleet.feedFor(host).rigs.where((r) => r.rig.id == s.rigId).firstOrNull?.rig.name ?? 'no rig';
    switch (await askBeforeSending(context, host, s)) {
      case SendGuard.cancel:
        return;
      case SendGuard.answer:
        nav.push(MaterialPageRoute(builder: (_) => ChatScreen(rigName: rigName, seat: s, asChat: true)));
        return;
      case SendGuard.send:
    }
    if (!context.mounted) return;
  }
  try {
    await api.send(s.sessionName!, text);
    if (context.mounted) toast(context, done);
    await onRefresh();
  } catch (e) {
    if (context.mounted) toast(context, e.toString());
  }
}

/// The seat's member in the spec its rig was launched from. [beforeOpen] runs once the rig is read, just before the
/// editor opens (the seat sheet closes itself there); false from it means the caller went away: nothing opens.
Future<void> editSeatInSpec(BuildContext context, Seat s, String rigName, {bool Function()? beforeOpen}) async {
  final api = AppScope.clientOf(context);
  if (api == null) return;
  final messenger = ScaffoldMessenger.of(context);
  final k = Tokens.of(context);
  try {
    final rig = await api.rig(s.rigId);
    final seats = await api.seats(s.rigId);
    if (rig == null) return toastOn(messenger, k, 'That rig no longer exists on the daemon.');
    if (beforeOpen != null && !beforeOpen()) return;
    if (!context.mounted) return;
    await editRigSpec(context, rig, seats,
        projectName: RigWithSeats(rig, seats).primaryCwd?.split('/').last ?? rigName, member: s.logicalId);
  } catch (e) {
    toastOn(messenger, k, e.toString());
  }
}

RigWithSeats? _rigOf(BuildContext context, Seat s) {
  final host = AppScope.read(context).active;
  return host == null ? null : fleet.feedFor(host).rigs.where((r) => r.rig.id == s.rigId).firstOrNull;
}

/// The one ⋯ list of an agent, for its header, its tile, the sidebar and the command palette: Open as chat / terminal,
/// then Agent details (the seat sheet), Compact, Clear context…, Add to queue…, Edit this seat in the spec, and the red
/// Kill session… and Remove from rig…. The caller says what differs: [onChat] / [onTerminal] open the view in its own way
/// (the terminal swaps itself for the chat), [fromChat] / [fromTerminal] drop the one it already is, [onDetails] shows the
/// sheet (null: no row), [extra] are the screen's own rows (Reconnect, Reflow) after Agent details. [onGone] runs after a
/// kill or remove went through, so a screen showing the seat can leave.
ActionRows seatMenuRows(BuildContext context, String rigName, Seat s,
    {Future<void> Function()? onRefresh,
    VoidCallback? onGone,
    VoidCallback? onChat,
    VoidCallback? onTerminal,
    VoidCallback? onDetails,
    bool fromChat = false,
    bool fromTerminal = false,
    List<ActionRow> extra = const []}) {
  final live = s.sessionName != null && s.state != SeatState.stopped;
  final nav = detailNavigator(context);
  final refresh = onRefresh ?? () async {};
  return (items: [
    if (s.isClaude && !fromChat)
      (
        Icons.chat_bubble_outline,
        'Open as chat',
        null,
        onChat ?? () => nav.push(MaterialPageRoute(builder: (_) => ChatScreen(rigName: rigName, seat: s, asChat: true)))
      ),
    if (s.sessionName != null && !fromTerminal)
      (
        Icons.terminal,
        'Open as terminal',
        null,
        onTerminal ?? () => nav.push(MaterialPageRoute(builder: (_) => TerminalScreen(target: SeatTarget(rigName, s))))
      ),
    if (s.isClaude && s.resumeToken != null) (Icons.open_in_new, 'Open in Claude', null, () => openInClaude(context, s)),
    menuBreak,
    if (onDetails != null) (Icons.info_outline, 'Agent details', null, onDetails),
    ...extra,
    if (s.isClaude && live) (Icons.compress_outlined, 'Compact', null, () => runSeatAction(context, 'compact', s, onRefresh: refresh)),
    if (s.isClaude && live)
      (Icons.cleaning_services_outlined, 'Clear context…', null, () => runSeatAction(context, 'clear', s, onRefresh: refresh)),
    if (canQueue(s))
      (
        Icons.playlist_add,
        'Add to queue…',
        null,
        () async {
          final agent = await showAddToQueue(context, seat: s);
          if (agent != null && context.mounted) toast(context, 'Added to $agent\'s queue');
          await refresh();
        }
      ),
    if (s.nodeId != null && s.rigId.isNotEmpty)
      (Icons.edit_outlined, 'Edit this seat in the spec', null, () => editSeatInSpec(context, s, rigName)),
    // The phone has no rig row above the agent: its rig's ⋯ sheet is one row away. A rig seat only; the Mac leaves it out.
    if (!isDesktop && s.rigId.isNotEmpty && rigName != 'no rig' && _rigOf(context, s) != null)
      (
        Icons.account_tree_outlined,
        'Rig actions…',
        null,
        () {
          final r = _rigOf(context, s);
          if (r != null) showRigSheet(context, r.rig, r.seats, projectName: projectNameOf(r.primaryCwd ?? r.rig.name));
        }
      ),
  ], danger: [
    if (s.nodeId != null && live)
      (
        'Kill session…',
        Icons.dangerous_outlined,
        () async {
          if (await killSeatSession(context, s, rigName)) onGone?.call();
        }
      ),
    if (s.nodeId != null)
      (
        'Remove from rig…',
        Icons.delete_outline,
        () async {
          if (await removeSeatFromRig(context, s, rigName)) onGone?.call();
        }
      ),
  ]);
}
