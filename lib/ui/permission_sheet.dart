import 'package:flutter/material.dart';

import '../main.dart';
import '../models.dart';
import '../terminal/transport.dart' show switchSeatToAuto;
import 'common.dart';
import 'kit.dart';
import 'theme.dart';

/// What the sheet's buttons do with the picked mode.
enum _Apply { switchNow, save, relaunch }

/// Whether [mode] can be applied to [seat]'s running conversation: only Auto,
/// on a live Claude seat, by pressing Shift+Tab in its pane until the footer
/// says so ([switchSeatToAuto]). Every other mode waits for the next start.
bool canSwitchLive(Seat seat, PermissionMode mode) =>
    mode == PermissionMode.auto && seat.isClaude && seat.sessionName != null && seat.state != SeatState.stopped;

/// The hint under each mode; Bypass says what it costs here.
String modeHint(PermissionMode m) => m == PermissionMode.bypass ? 'Never asks. Nothing will reach your Inbox.' : m.hint;

/// Pick how often a seat stops to ask (`rig seat set-permissions`).
///
/// * Switch now: Auto only, on a live Claude seat. Shift+Tab switches the
///   running conversation and the mode is saved for its next start too.
/// * Save (next start): any other mode; the running conversation keeps its
///   mode. The toast offers "Relaunch now".
/// * Relaunch…: saves, then starts the seat again now in the new mode
///   (`rig seat launch --fresh --stop`), in a new conversation.
Future<void> showPermissionSheet(BuildContext context, Seat seat) async {
  final api = AppScope.clientOf(context);
  if (api == null) return;
  String? wire = seat.permissionMode;
  try {
    wire = await api.permissionMode(seat) ?? wire;
  } catch (_) {/* show the sheet without a current mode */}
  if (!context.mounted) return;
  final current = PermissionMode.fromWire(wire);
  final modes = PermissionMode.forSeat(seat);
  var selected = current;

  final choice = await showModalBottomSheet<(PermissionMode, _Apply)>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final k = Tokens.of(ctx);
        final picked = selected;
        final live = picked != null && canSwitchLive(seat, picked);
        final changed = picked != null && picked != current;
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                  child: Text('Permissions · ${seat.logicalId}', style: Theme.of(ctx).textTheme.titleMedium),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
                  child: Text('How often ${seat.logicalId} stops to ask you',
                      style: TextStyle(fontSize: 13, color: k.muted)),
                ),
                for (final m in modes)
                  OptionRow(
                    leading: Icon(m == picked ? Icons.radio_button_checked : Icons.radio_button_off,
                        color: m == picked ? k.ink : k.muted),
                    title: Row(children: [
                      Text(m.label),
                      if (m == current) ...[
                        const SizedBox(width: 8),
                        Text('now', style: TextStyle(fontFamily: fontMono, fontSize: 11, color: k.muted)),
                      ],
                    ]),
                    subtitle: Text(modeHint(m)),
                    onTap: () => setSheet(() => selected = m),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: Text(
                    [
                      if (live)
                        'Switch now applies Auto to the running session. It keeps the conversation.'
                      else if (changed && seat.isClaude && seat.state != SeatState.stopped)
                        'Only Auto can be switched in a running session. ${picked.label} takes effect the next time '
                            '${seat.logicalId} starts.'
                      else
                        'Save applies it the next time ${seat.logicalId} starts.',
                      'Relaunch starts a new conversation in the new mode.',
                      if (!seat.isClaude) 'Codex seats offer Ask and Bypass only.',
                    ].join(' '),
                    style: TextStyle(fontSize: 12, color: k.muted, height: 1.4),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: picked == null ? null : () => Navigator.pop(ctx, (picked, _Apply.relaunch)),
                        style: sheetAction,
                        child: const Text('Relaunch…'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed:
                            !changed ? null : () => Navigator.pop(ctx, (picked, live ? _Apply.switchNow : _Apply.save)),
                        style: sheetAction,
                        child: Text(live ? 'Switch now' : 'Save (next start)'),
                      ),
                    ),
                  ]),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
  if (choice == null || !context.mounted) return;
  final (picked, apply) = choice;
  final messenger = ScaffoldMessenger.of(context);
  final k = Tokens.of(context);
  final host = AppScope.read(context).active;
  try {
    switch (apply) {
      case _Apply.switchNow:
        if (host == null) return;
        await switchSeatToAuto(host, seat);
        await api.setPermissionMode(seat, picked);
        toastOn(messenger, k, '${seat.logicalId} is in Auto now', kind: ToastKind.done);
      case _Apply.save:
        await api.setPermissionMode(seat, picked);
        if (!context.mounted) return;
        toastOn(messenger, k, '${seat.logicalId} will start in ${picked.label} next time', action: 'Relaunch now',
            onAction: () {
          if (context.mounted) relaunchSeatIn(context, seat, picked);
        });
      case _Apply.relaunch:
        if (!await _confirmRelaunch(context, seat) || !context.mounted) return;
        if (picked != current) await api.setPermissionMode(seat, picked);
        if (!context.mounted) return;
        await relaunchSeatIn(context, seat, picked, confirmed: true);
    }
  } catch (e) {
    toastOn(messenger, k, 'Couldn\'t change ${seat.logicalId}\'s mode: $e');
  }
}

/// Starts [seat] again now in [mode] (already saved), in a new conversation;
/// asks first unless [confirmed].
Future<void> relaunchSeatIn(BuildContext context, Seat seat, PermissionMode mode, {bool confirmed = false}) async {
  final api = AppScope.clientOf(context);
  if (api == null) return;
  if (!confirmed && (!await _confirmRelaunch(context, seat) || !context.mounted)) return;
  final messenger = ScaffoldMessenger.of(context);
  final k = Tokens.of(context);
  try {
    await api.relaunchSeat(seat, reason: 'relaunch in ${mode.label} from PocketRig');
    toastOn(messenger, k, '${seat.logicalId} relaunching in ${mode.label}');
  } catch (e) {
    toastOn(messenger, k, 'Couldn\'t relaunch ${seat.logicalId}: $e');
  }
}

Future<bool> _confirmRelaunch(BuildContext context, Seat seat) => confirmSheet(context,
    title: 'Relaunch ${seat.logicalId}?',
    body: 'It stops now, including any running tool, and starts again in a new conversation. '
        'The current conversation doesn\'t carry over.',
    action: 'Relaunch');
