import 'package:flutter/material.dart';

import '../../api/openrig_client.dart';
import '../../main.dart';
import '../../models.dart';
import '../check_row.dart';
import '../common.dart';
import '../kit.dart';
import '../status_shape.dart';
import '../theme.dart';
import 'rig_messages_section.dart';
import 'work_queue_screen.dart';

/// What the rig is getting done: the slices whose work touches it (blocked,
/// then active, then the rest, most recent first) and their missions'
/// PROGRESS.md checklists.
typedef RigProgress = ({List<SliceDetail> slices, List<ProgressFile> missions});

/// Reads [rig]'s progress: one request per slice, so callers poll slowly.
Future<RigProgress> loadRigProgress(OpenRigClient api, Rig rig) async {
  final list = await api.slices();
  final details = await Future.wait(list.map((s) => api.slice(s.name)));
  final mine = details.where((d) => d.touches(rig)).toList()
    ..sort((a, b) {
      int rank(String s) => switch (s) { 'blocked' => 0, 'active' => 1, _ => 2 };
      final r = rank(a.summary.status) - rank(b.summary.status);
      if (r != 0) return r;
      final at = a.summary.lastActivityAt, bt = b.summary.lastActivityAt;
      return bt == null ? -1 : (at == null ? 1 : bt.compareTo(at));
    });
  final missionIds = {for (final d in mine) d.summary.missionId};
  List<ProgressFile> files = [];
  try {
    files = (await api.progressFiles()).where((f) => missionIds.contains(f.missionId) && f.rows.isNotEmpty).toList();
  } catch (_) {/* the slices still show */}
  return (slices: mine, missions: files);
}

/// A slice's status as a shape: active is working, blocked failed, done stopped.
Status sliceStatus(String status) => switch (status) {
      'active' => Status.working,
      'blocked' => Status.failed,
      'done' || 'completed' => Status.stopped,
      _ => Status.idle,
    };

/// Progress: each mission's PROGRESS.md checklist, then every slice whose
/// work touches this rig, with its acceptance checks and latest story.
/// Read-only; OpenRig owns the files. The seats' handoffs are on the Work screen.
class ProgressBody extends StatefulWidget {
  const ProgressBody({super.key, required this.rig, this.active = true, this.wide = false});
  final Rig rig;

  /// The body's pane is 1000dp or more: the slices and checklists flex 560-720 beside a 360 column of the rig's messages.
  final bool wide;

  /// On screen: the rig's messages are read (over SSH) only then.
  final bool active;
  @override
  State<ProgressBody> createState() => _ProgressBodyState();
}

class _ProgressBodyState extends State<ProgressBody> with Polling {
  List<SliceDetail>? _slices;
  List<ProgressFile> _missions = [];
  String? _error;
  final Set<String> _open = {};

  // Each load is one request per slice, so poll slowly and on queue moves.
  @override
  Duration get every => const Duration(seconds: 60);
  @override
  Duration get slowEvery => const Duration(minutes: 2);
  @override
  bool wants(RigEvent e) => e.rigId == widget.rig.id && e.type.startsWith('queue.');

  @override
  Future<void> load() async {
    final api = AppScope.clientOf(context);
    if (api == null) return;
    try {
      final p = await loadRigProgress(api, widget.rig);
      if (!mounted) return;
      setState(() {
        _slices = p.slices;
        _missions = p.missions;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final slices = _slices;
    final left = <Widget>[
          if (_error != null) ErrorBanner(_error!, margin: const EdgeInsets.only(bottom: 16)),
          if (slices == null && _error == null)
            const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
          if (slices != null && slices.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No slices touch ${widget.rig.name} yet. Progress shows here once its seats work on a mission slice.',
                textAlign: TextAlign.center,
                style: TextStyle(color: k.muted),
              ),
            ),
          for (final f in _missions) ...[
            SectionLabel(f.title),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final (i, (text, status, depth)) in f.rows.indexed)
                  CheckRow(_checkState(status), text,
                      indent: depth * 16.0,
                      struck: status == 'done',
                      word: _checkWord(status),
                      note: _blockedBelow(f.rows, i)),
              ]),
            ),
            const SizedBox(height: 16),
          ],
          if (slices != null && slices.isNotEmpty) SectionLabel('Slices · ${slices.length}'),
          for (final s in slices ?? const <SliceDetail>[])
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _SliceCard(
                slice: s,
                open: _open.contains(s.summary.name),
                onToggle: () => setState(() =>
                    _open.contains(s.summary.name) ? _open.remove(s.summary.name) : _open.add(s.summary.name)),
              ),
            ),
    ];
    final right = <Widget>[
          RigMessagesSection(rig: widget.rig, active: widget.active),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => WorkScreen(rig: widget.rig, initialTab: 1))),
            icon: const Icon(Icons.forum_outlined, size: 18),
            label: const Text('Handoffs between seats'),
            style: sheetAction,
          ),
    ];
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28), // 20, as the other two tabs, narrow and wide
        children: widget.wide
            ? [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 560, maxWidth: 720),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: left),
                    ),
                  ),
                  const SizedBox(width: 24),
                  SizedBox(width: 360, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: right)),
                ]),
                const SizedBox(height: 24),
              ]
            : [
                ...left,
                const SizedBox(height: 8),
                ...right,
                const SizedBox(height: 24), // the card never touches the window's edge at the end of the scroll
              ],
      ),
    );
  }
}

/// The rig's destructive action, explained, at the foot of the Agents tab: the text, then a full-width button. The confirm it
/// opens names what happens and carries the filled red.
class RigDangerZone extends StatelessWidget {
  const RigDangerZone({super.key, required this.rig, required this.action});
  final Rig rig;
  final (String, IconData, VoidCallback) action;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final stopped = rig.status == 'stopped';
    final red = outlinedRed(k);
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(border: Border.all(color: red.withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(kRadius)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Danger zone', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: red)),
          const SizedBox(height: 8),
          Text(
              stopped
                  ? 'Deleting ${rig.name} removes it and its saved state for good. Restore it instead to bring its agents back.'
                  : 'Stopping ${rig.name} ends its agents and their shells. You can save its state first and restore it later; questions waiting for you stay in the Inbox.',
              style: TextStyle(fontSize: 13, color: k.muted, height: 1.4)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: action.$3,
            icon: Icon(action.$2, size: 20),
            label: Text(action.$1),
            style: OutlinedButton.styleFrom(
                foregroundColor: red, side: BorderSide(color: red)).merge(sheetAction),
          ),
        ]),
      ),
    );
  }
}

Tone sliceTone(String status) => statusTone(status);

class _SliceCard extends StatelessWidget {
  const _SliceCard({required this.slice, required this.open, required this.onToggle});
  final SliceDetail slice;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final s = slice.summary;
    final total = slice.checks.length;
    final recent = slice.events.reversed.take(5).toList();
    return Panel(
      onTap: onToggle,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Text(s.displayName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          Pill(s.status, tone: sliceTone(s.status)),
        ]),
        const SizedBox(height: 4),
        Text(
          [
            if (s.missionId != null) s.missionId!,
            '${s.qitemCount} queue item${s.qitemCount == 1 ? '' : 's'}',
            if (s.lastActivityAt != null) ago(s.lastActivityAt),
          ].join(' · '),
          style: TextStyle(fontSize: 12, color: k.muted),
        ),
        if (total > 0) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: Semantics(
                label: '${slice.done} of $total checks done',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: slice.done / total,
                    minHeight: 8,
                    backgroundColor: k.divider,
                    color: k.added,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text('${slice.done}/$total', style: mono(context, size: 12)),
          ]),
        ],
        if (open) ...[
          if (total > 0) ...[
            const SizedBox(height: 12),
            Text('Acceptance', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: k.muted)),
            const SizedBox(height: 4),
            for (final (text, done) in slice.checks) CheckRow(done ? CheckState.ok : CheckState.todo, text, struck: done, word: done ? 'done' : 'to do'),
          ],
          if (recent.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Latest', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: k.muted)),
            const SizedBox(height: 4),
            for (final e in recent)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 40, child: Text(ago(e.at), style: mono(context, size: 12))),
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: [
                        if (e.actor != null)
                          TextSpan(
                              text: '${e.actor!.split('@').first} ',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                        TextSpan(text: e.summary),
                      ]),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ]),
              ),
          ],
        ],
        Align(
          alignment: Alignment.centerRight,
          child: Icon(open ? Icons.expand_less : Icons.expand_more, size: 18, color: k.muted),
        ),
      ]),
    );
  }
}

/// "2 blocked" for a row with blocked steps under it (the rows after it that are nested deeper), else null.
String? _blockedBelow(List<(String, String, int)> rows, int i) {
  var n = 0;
  for (var j = i + 1; j < rows.length && rows[j].$3 > rows[i].$3; j++) {
    if (rows[j].$2 == 'blocked') n++;
  }
  return n == 0 ? null : '$n blocked';
}

/// A checklist line's state: done is passed, blocked a problem, the rest still to do.
CheckState _checkState(String status) => switch (status) {
      'done' => CheckState.ok,
      'blocked' => CheckState.bad,
      _ => CheckState.todo,
    };

/// How a screen reader says a PROGRESS.md row's status: an item under way is not the same as one not started.
String _checkWord(String status) => switch (status) {
      'done' => 'done',
      'blocked' => 'blocked',
      'active' => 'in progress',
      _ => 'to do',
    };
