import 'package:flutter/material.dart';

import '../api/openrig_client.dart';
import '../data/fleet.dart';
import '../main.dart';
import '../models.dart';
import 'common.dart';
import 'kit.dart';
import 'permission_card.dart';
import 'status_shape.dart';
import 'theme.dart';

/// Brings a stopped [rig] on [host] back from its last snapshot (what
/// `rig up <name>` does). True when it's running again; says what happened.
Future<bool> restoreRig(BuildContext context, Host host, Rig rig) async {
  final messenger = ScaffoldMessenger.of(context);
  final k = Tokens.of(context);
  try {
    final r = await AppScope.clientFor(host).up(rig.name);
    if (!r.ok) throw OpenRigException(r.errors.isEmpty ? 'Restore ${r.status}' : r.errors.first);
    toastOn(messenger, k, 'Restored ${rig.name}');
    await fleet.feedFor(host).refresh();
    return true;
  } catch (e) {
    toastOn(messenger, k, 'Couldn\'t restore ${rig.name}: ${e is OpenRigException ? e.message : e}');
    return false;
  }
}

/// Asks before stopping [rig], listing what each of its agents in [seats] is
/// doing right now so nothing is cut off by surprise. Returns null when
/// cancelled, otherwise whether to take a snapshot first (on by default).
Future<bool?> confirmStopRig(BuildContext context, Rig rig, [List<Seat> seats = const []]) {
  var snapshot = true;
  final agents = seats.where((s) => s.isAgent).toList()..sort((a, b) => _urgency(a.state).compareTo(_urgency(b.state)));
  final count = agents.isNotEmpty ? agents.length : rig.nodeCount;
  return showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final k = Tokens.of(ctx);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Stop ${rig.name}?', style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text('All $count seat${count == 1 ? '' : 's'} shut down. Their sessions end; work in the queue stays.',
                    style: TextStyle(fontSize: 14, color: k.muted)),
                if (agents.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Panel(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (final s in agents)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(children: [
                            StatusShape(Status.of(s.state), size: 10, semantics: false),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text.rich(
                                TextSpan(children: [
                                  TextSpan(text: s.logicalId, style: const TextStyle(fontWeight: FontWeight.w600)),
                                  TextSpan(
                                      text: ' ${stopNote(s)}',
                                      style: TextStyle(
                                          color: s.state == SeatState.needsYou
                                              ? k.accent
                                              : s.state == SeatState.shell
                                                  ? k.shell
                                                  : k.muted)),
                                ]),
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                          ]),
                        ),
                    ]),
                  ),
                ],
                const SizedBox(height: 4),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: snapshot,
                  onChanged: (v) => setSheet(() => snapshot = v ?? true),
                  title: const Text('Take a snapshot first'),
                  subtitle: const Text('So Restore brings it back as it is now'),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: FilledButton.styleFrom(
                    backgroundColor: Tokens.of(ctx).kill,
                    foregroundColor: Tokens.of(ctx).onAccent).merge(sheetAction),
                  child: Text(snapshot ? 'Snapshot & stop' : 'Stop rig'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  style: sheetAction,
                  child: const Text('Cancel'),
                ),
              ]),
            ),
          ),
        );
      },
    ),
  ).then((go) => go == true ? snapshot : null);
}

int _urgency(SeatState s) => switch (s) {
      SeatState.needsYou => 0,
      SeatState.working => 1,
      SeatState.shell => 2,
      SeatState.idle => 3,
      SeatState.stopped => 4,
    };

/// "is waiting for you", "asked a question", "is mid-turn", "has 1 shell running", "is idle".
String stopNote(Seat s) => switch (s.state) {
      SeatState.needsYou => PermissionAsk.from(s).isPermission ? 'is waiting for you' : 'asked a question',
      SeatState.working => 'is mid-turn',
      SeatState.shell => s.jobs.isEmpty
          ? 'is waiting on subagents'
          : 'has ${s.jobs.length} ${s.jobs.length == 1 ? 'shell' : 'shells'} running',
      SeatState.idle => 'is idle',
      SeatState.stopped => 'is already stopped',
    };

/// Two separate confirmations before [rig] is deleted. True only after both.
Future<bool> confirmDeleteRig(BuildContext context, Rig rig) async {
  final running = rig.status == 'stopped' ? '' : 'All ${rig.nodeCount} seats will be shut down. ';
  if (!await confirmSheet(context,
      title: 'Delete ${rig.name}?',
      body: '${running}OpenRig forgets this rig, so it can\'t be restored. Project files and rig specs stay.',
      action: 'Continue')) {
    return false;
  }
  if (!context.mounted) return false;
  return confirmSheet(context,
      title: 'Delete ${rig.name} for good?', body: 'This can\'t be undone.', action: 'Delete rig');
}
