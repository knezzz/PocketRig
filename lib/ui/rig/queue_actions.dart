import 'package:flutter/material.dart';

import '../../api/openrig_client.dart' show OpenRigException;
import '../../data/fleet.dart' show fleet;
import '../../data/rig_spec.dart' show SpecMember;
import '../../main.dart';
import '../../models.dart';
import '../action_rows.dart';
import '../common.dart';
import '../kit.dart';
import '../theme.dart';

/// How an open item can be closed from the app: the daemon's closure reasons that need no target (`handed_off_to`,
/// `escalation` and `superseded` carry one; Reassign is the handoff). The daemon's own message answers any other refusal.
const closureChoices = [
  ('no-follow-on', 'Done', 'Finished, nothing else needed'),
  ('canceled', 'Canceled', 'Withdrawn, not worth doing'),
  ('denied', 'Denied', 'Rejected, won\'t be done'),
];

String _msg(Object e) => e is OpenRigException ? e.message : e.toString();

/// Reassign [item] to another seat of [rig]: a handoff, so its history shows the move (the daemon closes this row as handed
/// off and creates the successor on the new seat). Picks the seat, confirms, writes, then [onDone] refreshes the list.
Future<void> reassignItem(BuildContext context, Rig rig, QueueItem item, {required VoidCallback onDone}) async {
  final host = AppScope.read(context).active;
  final api = AppScope.clientOf(context);
  if (host == null || api == null) return;
  final seats = [
    for (final s in fleet.feedFor(host).rigs.where((r) => r.rig.id == rig.id).firstOrNull?.seats ?? const <Seat>[])
      if (s.isAgent && s.sessionName != null && s.sessionName != item.destinationSession) s
  ];
  if (seats.isEmpty) return toast(context, 'No other seat in ${rig.name} to hand it to', kind: ToastKind.info);
  final messenger = ScaffoldMessenger.of(context);
  final k = Tokens.of(context);
  Seat? to;
  await showActionRows(context, 'Reassign to', (
    items: [for (final s in seats) (Icons.person_outline, s.logicalId, SpecMember.runtimeLabel(s.runtime ?? ''), () => to = s)],
    danger: const [],
  ));
  if (to == null || !context.mounted) return;
  if (!await confirmSheet(context,
      title: 'Hand this to ${to!.logicalId}?',
      body: '${item.summary}\n\nIt closes here as handed off and appears on ${to!.logicalId}\'s queue.',
      action: 'Reassign',
      destructive: false)) {
    return;
  }
  try {
    // The handoff has no compare-and-set: read the item again, and stop if it moved since it was shown.
    final now = await api.queueItem(item.id);
    if (now == null || now.state != item.state || now.destinationSession != item.destinationSession) {
      toastOn(messenger, k, 'This item changed since you opened it (${now?.state ?? 'gone'}). Nothing was sent.', kind: ToastKind.problem);
      onDone();
      return;
    }
    await api.queueReassign(item.id, to!.sessionName!);
    toastOn(messenger, k, 'Handed to ${to!.logicalId}');
  } catch (e) {
    toastOn(messenger, k, _msg(e), kind: ToastKind.problem);
  }
  onDone();
}

/// Mark [item] closed: asks for a closure reason, then confirms, writes, and [onDone] refreshes the list.
Future<void> markItemDone(BuildContext context, QueueItem item, {required VoidCallback onDone}) async {
  final api = AppScope.clientOf(context);
  if (api == null) return;
  final messenger = ScaffoldMessenger.of(context);
  final k = Tokens.of(context);
  (String, String, String)? reason;
  await showActionRows(context, 'Close as…', (
    items: [for (final c in closureChoices) (Icons.check_circle_outline, c.$2, c.$3, () => reason = c)],
    danger: const [],
  ));
  if (reason == null || !context.mounted) return;
  if (!await confirmSheet(context,
      title: 'Mark this ${reason!.$2.toLowerCase()}?',
      body: '${item.summary}\n\nIt closes as ${reason!.$1} and leaves the queue.',
      action: 'Mark ${reason!.$2.toLowerCase()}',
      destructive: false)) {
    return;
  }
  try {
    await api.queueMarkDone(item.id, reason!.$1, expectState: item.state);
    toastOn(messenger, k, 'Marked ${reason!.$2.toLowerCase()}');
  } catch (e) {
    toastOn(messenger, k, _msg(e), kind: ToastKind.problem);
  }
  onDone();
}
