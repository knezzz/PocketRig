import 'package:flutter/material.dart';

import '../api/openrig_client.dart';
import '../data/fleet.dart';
import '../data/restore_all.dart';
import '../main.dart';
import '../models.dart';
import 'check_row.dart';
import 'kit.dart';
import 'theme.dart';

/// How many rigs restore at once: each is a `rig up` that launches seats on the host.
const restoreAllAtOnce = 3;

/// The host's stopped rigs, as the feed has them now.
List<Rig> stoppedRigs(Host host) => [for (final r in fleet.feedFor(host).rigs) if (r.rig.status == 'stopped') r.rig];

/// Restore all stopped rigs on [host]: lists them with the count, asks, then restores [restoreAllAtOnce] at a time through
/// the same call as a single Restore, with each rig's progress and failure in a sheet. One failing rig doesn't stop the rest.
Future<void> restoreAllStopped(BuildContext context, Host host) async {
  final rigs = stoppedRigs(host);
  if (rigs.isEmpty) return;
  final n = rigs.length;
  if (!await confirmSheet(context,
      title: 'Restore $n stopped rig${n == 1 ? '' : 's'} on ${host.name}?',
      body: '${rigs.map((r) => host.rigLabel(r.name)).join(', ')}.\nThey start from their last snapshots, $restoreAllAtOnce at a time.',
      action: 'Restore $n',
      destructive: false)) {
    return;
  }
  if (!context.mounted) return;
  final store = AppScope.read(context);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => AppScope(store: store, child: RestoreAllSheet(host: host, rigs: rigs)),
  );
}

enum _Step { waiting, restoring, restored, failed }

class RestoreAllSheet extends StatefulWidget {
  const RestoreAllSheet({super.key, required this.host, required this.rigs});
  final Host host;
  final List<Rig> rigs;

  @override
  State<RestoreAllSheet> createState() => _RestoreAllSheetState();
}

class _RestoreAllSheetState extends State<RestoreAllSheet> {
  final _step = <String, _Step>{};
  final _error = <String, String>{};
  bool _done = false;

  @override
  void initState() {
    super.initState();
    for (final r in widget.rigs) {
      _step[r.id] = _Step.waiting;
    }
    _run();
  }

  Future<void> _run() async {
    final api = AppScope.clientFor(widget.host);
    await runPool(widget.rigs, restoreAllAtOnce, (rig) async {
      _set(rig, _Step.restoring);
      try {
        final r = await api.up(rig.name);
        if (!r.ok) throw OpenRigException(r.errors.isEmpty ? 'Restore ${r.status}' : r.errors.first);
        _set(rig, _Step.restored);
      } catch (e) {
        _error[rig.id] = e is OpenRigException ? e.message : '$e';
        _set(rig, _Step.failed);
      }
    });
    fleet.feedFor(widget.host).refresh().ignore();
    if (mounted) setState(() => _done = true);
  }

  void _set(Rig rig, _Step s) {
    if (mounted) setState(() => _step[rig.id] = s);
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final failed = _step.values.where((s) => s == _Step.failed).length;
    final finished = _step.values.where((s) => s == _Step.restored || s == _Step.failed).length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
              _done
                  ? (failed == 0 ? 'Restored ${widget.rigs.length}' : 'Restored ${widget.rigs.length - failed} of ${widget.rigs.length}')
                  : 'Restoring · $finished of ${widget.rigs.length}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              child: BorderedList(children: [
                for (final r in widget.rigs)
                  RowTile(
                    minHeight: 52,
                    leading: switch (_step[r.id]!) {
                      _Step.restored => const CheckMark(CheckState.ok, size: 20),
                      _Step.failed => const CheckMark(CheckState.bad, size: 20),
                      _Step.restoring => SizedBox.square(
                          dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: k.ink, backgroundColor: k.border)),
                      _Step.waiting => const SizedBox.square(dimension: 20),
                    },
                    title: widget.host.rigLabel(r.name),
                    meta: switch (_step[r.id]!) {
                      _Step.restored => 'Restored',
                      _Step.failed => 'Couldn\'t restore: ${_error[r.id]}',
                      _Step.restoring => 'Restoring…',
                      _Step.waiting => 'Waiting',
                    },
                    metaColor: switch (_step[r.id]!) {
                      _Step.restored => k.added,
                      _Step.failed => k.removed,
                      _ => null,
                    },
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _done ? () => Navigator.pop(context) : null, style: sheetAction, child: const Text('Done')),
        ]),
      ),
    );
  }
}
