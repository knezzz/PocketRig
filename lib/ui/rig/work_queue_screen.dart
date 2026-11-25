import 'package:flutter/material.dart';

import '../../main.dart';
import '../../models.dart';
import '../common.dart';
import '../kit.dart';
import '../page_column.dart';
import '../status_shape.dart';
import '../theme.dart';
import '../../data/fleet.dart' show fleet;
import '../../terminal/transport.dart' show SeatTarget;
import '../chat_screen.dart' show ChatScreen;
import '../desktop_shell.dart' show detailNavigator;
import '../terminal_screen.dart' show TerminalScreen;
import 'add_to_queue_sheet.dart';
import 'queue_actions.dart';
import 'rig_chat.dart' show HandoffDetail, RigChatMessage, showHandoff;

/// States an item can still move out of.
bool isOpenQueueState(String state) => const {'pending', 'in-progress', 'blocked'}.contains(state);

/// A queue item's state as a status shape: in progress is working, blocked or
/// failed is failed, pending is idle, anything closed is stopped.
Status queueStatus(String state) => switch (state) {
      'in-progress' => Status.working,
      'blocked' || 'failed' => Status.failed,
      'pending' => Status.idle,
      _ => Status.stopped,
    };

String _who(String? session) => session?.split('@').first ?? 'someone';

/// One queue item: its state's shape, the summary, and "from → to · state ·
/// urgent · 40m". Tap opens its full text and history.
class QueueRow extends StatelessWidget {
  const QueueRow(this.q, {super.key, this.onTap, this.selected = false});
  final QueueItem q;

  /// A wide Work page selects the item for its detail pane; by default a tap opens the sheet.
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final state = q.state.replaceAll('-', ' ');
    final bad = queueStatus(q.state) == Status.failed;
    // Opens a sheet, not a screen: no ›.
    final row = RowTile(
      minHeight: 52,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      openLabel: '${q.summary.isEmpty ? q.id : q.summary}, $state',
      onTap: onTap ?? () => showHandoff(context, q),
      leading: StatusShape(queueStatus(q.state), size: 10, semantics: false),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(q.summary.isEmpty ? q.id : q.summary,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.3)),
        Text.rich(
          TextSpan(children: [
            TextSpan(
                text: [
              if (q.sourceSession != null)
                '${_who(q.sourceSession)} → ${_who(q.destinationSession)}'
              else if (q.ownerLogicalId != null)
                q.ownerLogicalId!,
              '',
            ].join(' · ')),
            TextSpan(text: state, style: bad ? TextStyle(color: k.removed) : null),
            TextSpan(
                text: [
              '',
              if (q.priority == 'urgent' || q.priority == 'critical') q.priority!,
              if (q.updated != null) ago(q.updated),
            ].join(' · ')),
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: k.muted),
        ),
      ]),
    );
    return selected ? ColoredBox(color: k.fill, child: row) : row;
  }
}

enum _Filter { open, closed, all }

/// The rig's work: Queue (every item, closed ones included since OpenRig keeps
/// them, most recently updated first) and Handoffs (the same items read as
/// the seats' conversation, newest at the bottom, every item). Open/Closed/All is a light text filter above the
/// Queue only; tapping an item opens its full text and history. Read-only.
class WorkScreen extends StatefulWidget {
  const WorkScreen({super.key, required this.rig, this.initialTab = 0, this.embedded = false});
  final Rig rig;

  /// In the rig page's Work tab on a wide pane: no page header of its own (its Queue | Handoffs switch and + sit in a bar).
  final bool embedded;

  /// 0 Queue, 1 Handoffs.
  final int initialTab;
  @override
  State<WorkScreen> createState() => _WorkScreenState();
}

class _WorkScreenState extends State<WorkScreen> with Polling {
  List<QueueItem>? _items;
  String? _error;
  _Filter _filter = _Filter.open;
  late int _tab = widget.initialTab;

  /// The item the wide page shows in its detail pane (the first one until another is chosen).
  String? _sel;

  @override
  Duration get every => const Duration(seconds: 30);
  @override
  Duration get slowEvery => const Duration(seconds: 60);
  @override
  bool wants(RigEvent e) => e.rigId == widget.rig.id && e.type.startsWith('queue.');

  @override
  Future<void> load() async {
    final api = AppScope.clientOf(context);
    if (api == null) return;
    try {
      final items = await api.queueHistory(widget.rig.name, limit: 500);
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _add() async {
    final api = AppScope.clientOf(context);
    if (api == null) return;
    try {
      final seats = (await api.seats(widget.rig.id)).where(canQueue).toList();
      if (!mounted) return;
      if (seats.isEmpty) return toast(context, 'No agent in ${widget.rig.name} can take queued work.');
      final agent = await showAddToQueue(context, seats: seats);
      if (agent == null || !mounted) return;
      toast(context, 'Added to $agent\'s queue');
      await load();
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final all = _items ?? const <QueueItem>[];
    final open = all.where((q) => isOpenQueueState(q.state)).toList();
    final closed = all.where((q) => !isOpenQueueState(q.state)).toList();
    final handoffs = _tab == 1;
    final shown = handoffs ? [...all] : switch (_filter) { _Filter.open => open, _Filter.closed => closed, _Filter.all => [...all] };
    if (handoffs) {
      shown.sort((a, b) => (b.created ?? DateTime(0)).compareTo(a.created ?? DateTime(0)));
    } else {
      shown.sort((a, b) => (b.updated ?? DateTime(0)).compareTo(a.updated ?? DateTime(0)));
    }
    final empty = _items != null && shown.isEmpty;
    // Light text, not a second segmented strip: which queue items to list.
    final filterRow = Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        for (final (f, label) in [
          (_Filter.open, 'Open ${open.length}'),
          (_Filter.closed, 'Closed ${closed.length}'),
          (_Filter.all, 'All ${all.length}'),
        ])
          Semantics(
            button: true,
            selected: _filter == f,
            onTap: () => setState(() => _filter = f),
            excludeSemantics: true,
            label: label,
            child: InkWell(
              onTap: () => setState(() => _filter = f),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
                child: Padding(
                  padding: const EdgeInsets.only(right: 18),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    widthFactor: 1,
                    child: Text(label,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: _filter == f ? FontWeight.w600 : FontWeight.w400,
                            color: _filter == f ? k.ink : k.muted)),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
    final switcher = Segmented<int>(
      values: const [0, 1],
      labels: const ['Queue', 'Handoffs'],
      selected: _tab,
      onChanged: (t) => setState(() => _tab = t),
      semanticLabel: 'Work view',
    );
    final addButton = TextButton(
      onPressed: _add,
      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)).merge(compactAction),
      child: const Text('+ Add to queue', style: TextStyle(fontWeight: FontWeight.w600)),
    );
    // One column below 1000dp (the phone and a narrow pane); from 1000 the list at the left and the chosen item's card beside it.
    final body = LayoutBuilder(builder: (context, box) {
      if (box.maxWidth >= 1000) return _wide(context, box, shown, handoffs, empty, filterRow);
      return PageColumn(child: RefreshIndicator(
            onRefresh: load,
            child: _items == null || empty
                ? ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(20), children: [
                    if (!handoffs && _items != null) filterRow,
                    if (_error != null) ErrorBanner(_error!, margin: const EdgeInsets.only(bottom: 16)),
                    if (_items == null && _error == null)
                      const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
                    if (empty)
                      Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                            handoffs
                                ? 'No handoffs in ${widget.rig.name} yet. Work its seats send each other shows up here.'
                                : _filter == _Filter.open
                                    ? 'Nothing open.'
                                    : 'Nothing here yet.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: k.muted)),
                      ),
                  ])
                : handoffs
                    // Newest first in the list, drawn from the bottom: opens on the latest message.
                    ? ListView.builder(
                        reverse: true,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                        itemCount: shown.length + (_error != null ? 1 : 0),
                        itemBuilder: (context, i) => i == shown.length
                            ? ErrorBanner(_error!, margin: const EdgeInsets.only(bottom: 12))
                            : Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: RigChatMessage(item: shown[i], onTap: () => showHandoff(context, shown[i])),
                              ),
                      )
                    : ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(16, 16, 16, 28), children: [
                        filterRow,
                        if (_error != null) ErrorBanner(_error!, margin: const EdgeInsets.only(bottom: 16)),
                        BorderedList(children: [for (final q in shown) QueueRow(q)]),
                      ]),
          ));
    });
    if (widget.embedded) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
          child: Row(children: [SizedBox(width: 280, child: switcher), const Spacer(), addButton]),
        ),
        Expanded(child: body),
      ]);
    }
    return Scaffold(
      body: Column(children: [
        PageHeader(
          inColumn: true,
          overline: widget.rig.name,
          title: 'Work',
          actions: [addButton],
          bottom: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [switcher]),
        ),
        Expanded(child: body),
      ]),
    );
  }

  /// Reassign and Mark done for an item that is still open: queue writes, so each asks first and a refusal shows the daemon's message.
  Widget? _actionsFor(QueueItem item) {
    if (!isOpenQueueState(item.state)) return null;
    return Wrap(spacing: 8, runSpacing: 8, children: [
      OutlinedButton(onPressed: () => reassignItem(context, widget.rig, item, onDone: load), style: compactAction, child: const Text('Reassign…')),
      OutlinedButton(onPressed: () => markItemDone(context, item, onDone: load), style: compactAction, child: const Text('Mark done…')),
    ]);
  }

  /// "Open <seat>" for an item: its destination seat in this rig, opened as tapping it elsewhere does (the chat for Claude, the
  /// terminal otherwise). Null when the rig has no such seat: no button.
  ({String label, VoidCallback open})? _openSeatFor(QueueItem item) {
    final host = AppScope.read(context).active;
    final session = item.destinationSession;
    if (host == null || session == null) return null;
    final rig = fleet.feedFor(host).rigs.where((r) => r.rig.id == widget.rig.id).firstOrNull;
    final seat = rig?.seats.where((s) => s.sessionName == session && s.isAgent).firstOrNull;
    if (seat == null) return null;
    final name = widget.rig.name;
    return (
      label: 'Open ${seat.logicalId}',
      open: () => detailNavigator(context).push(MaterialPageRoute<void>(
          builder: (_) => seat.isClaude
              ? ChatScreen(rigName: name, seat: seat, asChat: true)
              : TerminalScreen(target: SeatTarget(name, seat)))),
    );
  }

  /// The wide page: the list (420-480) with its filter above, and the chosen item's card (at most 640) beside it; the first
  /// item is chosen on load, and 'Nothing open' stands in the middle when there is none.
  Widget _wide(BuildContext context, BoxConstraints box, List<QueueItem> shown, bool handoffs, bool empty, Widget filterRow) {
    final k = Tokens.of(context);
    final current = shown.where((q) => q.id == _sel).firstOrNull ?? shown.firstOrNull;
    // The list's own width is about 420-480 inside its padding (20 left, 16 right).
    final listW = (box.maxWidth * 0.4).clamp(456.0, 516.0);
    final list = _items == null
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: load,
            child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(20, 12, 16, 28), children: [
              if (!handoffs) filterRow,
              if (_error != null) ErrorBanner(_error!, margin: const EdgeInsets.only(bottom: 16)),
              if (empty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(handoffs ? 'No handoffs in ${widget.rig.name} yet.' : 'Nothing here yet.', textAlign: TextAlign.center, style: TextStyle(color: k.muted)),
                )
              else if (handoffs)
                for (final q in shown)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: DecoratedBox(
                      decoration: BoxDecoration(border: Border(left: BorderSide(width: 3, color: identical(q, current) ? k.accent : Colors.transparent))),
                      child: RigChatMessage(item: q, onTap: () => setState(() => _sel = q.id)),
                    ),
                  )
              else
                BorderedList(children: [for (final q in shown) QueueRow(q, selected: identical(q, current), onTap: () => setState(() => _sel = q.id))]),
            ]),
          );
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(width: listW, child: list),
      VerticalDivider(width: 1, color: k.border),
      Expanded(
        child: current == null
            ? Center(child: Text('Nothing open', style: TextStyle(color: k.muted)))
            : Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: k.surface, border: Border.all(color: k.border), borderRadius: BorderRadius.circular(kRadius)),
                      child: HandoffDetail(key: ValueKey(current.id), item: current, padding: const EdgeInsets.all(16), openSeat: _openSeatFor(current), actions: _actionsFor(current)),
                    ),
                  ),
                ),
              ),
      ),
    ]);
  }
}
