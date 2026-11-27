import 'package:flutter/material.dart';

import '../../data/agent_jobs.dart' show AgentJob, capShells;
import '../../data/fleet.dart' show fleet;
import '../../api/openrig_client.dart' show OpenRigException;
import '../../main.dart' show AppScope;
import '../../models.dart';
import '../common.dart';
import '../kit.dart';
import '../permission_card.dart';
import '../status_shape.dart';
import '../theme.dart';
import '../rigs_home.dart' show homeNow;
import '../subagent_open.dart' show canOpenSubagent, requestSubagent;
import 'graph_layout.dart';
import 'seat_graph.dart';

/// The rig's agents: what the counts, the list and the
/// stop sheet all count. Terminal seats are listed apart and never counted.
List<Seat> agentsOf(List<Seat> seats) => seats.where((s) => s.isAgent).toList();

/// The List view: one card, a grey strip per pod, a row per agent. Tapping a
/// row opens it ([onOpen]: chat or terminal); its ⋯ opens the seat sheet
/// ([onMore]). Terminal seats follow under their own strip.
class SeatList extends StatelessWidget {
  const SeatList({
    super.key,
    required this.seats,
    required this.onOpen,
    required this.onMore,
    this.modes = const {},
    this.onShells,
  });
  final List<Seat> seats;
  final void Function(Seat) onOpen;
  final void Function(Seat) onMore;

  /// A shell row (or '+N more', with a null job) opens the agent's shells list; without it the agent opens.
  final void Function(Seat, AgentJob?)? onShells;

  /// Permission mode by session name (or logical id), once loaded.
  final Map<String, String?> modes;

  /// Rebuilt as the host's feed changes: its subagents come and go.
  @override
  Widget build(BuildContext context) {
    // Without a host scope (a bare list) there are no subagents to show.
    final host = context.dependOnInheritedWidgetOfExactType<AppScope>()?.notifier?.active;
    return host == null ? _list(context, null) : ListenableBuilder(listenable: fleet.feedFor(host), builder: (context, _) => _list(context, host));
  }

  /// The subagents and shells [seat] is running, one step in under it: the same row, their own icons. A subagent opens its
  /// log (its agent when it has none yet); a shell opens its agent.
  List<Widget> _nested(BuildContext context, Host? host, Seat seat) => [
        if (host != null)
          for (final sub in fleet.feedFor(host).subagentsOf(seat))
            AgentRow(
              name: sub.title,
              status: Status.working,
              kind: StatusKind.subagent,
              task: sub.type,
              age: ago(sub.lastWrite ?? sub.started),
              indent: 28,
              moreSlot: true,
              onTap: canOpenSubagent(sub) ? () => requestSubagent(host, seat, sub) : () => onOpen(seat),
              openLabel: '${sub.title}, subagent of ${seat.logicalId}, running',
            ),
        // At most three, then '+N more'; each opens the agent's shells list.
        ...() {
          final (:shown, :more) = capShells(seat.jobs);
          void open(AgentJob? j) => onShells != null ? onShells!(seat, j) : onOpen(seat);
          return [
            for (final j in shown)
              AgentRow(
                name: j.short,
                status: Status.working,
                kind: StatusKind.shell,
                task: j.isMonitor ? 'monitor' : 'shell',
                age: 'up ${ago(homeNow().subtract(j.elapsed))}',
                indent: 28,
                moreSlot: true,
                onTap: () => open(j),
                openLabel: '${j.short}, ${j.isMonitor ? 'monitor' : 'shell'} of ${seat.logicalId}, running',
              ),
            if (more > 0)
              AgentRow(
                name: '+$more more',
                status: Status.working,
                kind: StatusKind.shell,
                indent: 28,
                moreSlot: true,
                onTap: () => open(null),
                openLabel: '$more more shells of ${seat.logicalId}',
              ),
          ];
        }(),
      ];

  Widget _list(BuildContext context, Host? host) {
    final k = Tokens.of(context);
    final agents = agentsOf(seats);
    final terminals = seats.where((s) => !s.isAgent).toList();
    if (agents.isEmpty && terminals.isEmpty) {
      return Panel(
        child: Text('No seats yet.', style: TextStyle(fontSize: 13, color: k.muted)),
      );
    }
    final pods = <String, List<Seat>>{};
    for (final s in agents) {
      (pods[s.podLabel ?? 'seats'] ??= []).add(s);
    }
    Widget strip(String label, {bool first = false}) => Container(
          height: 30,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration:
              BoxDecoration(color: k.headerFill, border: first ? null : Border(top: BorderSide(color: k.divider))),
          child: Text(label.toUpperCase(), style: sectionLabelStyle(context)),
        );
    final children = <Widget>[];
    for (final MapEntry(key: pod, value: list) in pods.entries) {
      children.add(strip(pod, first: children.isEmpty));
      for (final s in list) {
        children.add(SeatRow(
            seat: s, mode: modes[s.sessionName ?? s.logicalId], onTap: () => onOpen(s), onMore: () => onMore(s)));
        children.addAll(_nested(context, host, s));
      }
    }
    if (terminals.isNotEmpty) {
      children.add(strip('terminals', first: children.isEmpty));
      for (final s in terminals) {
        children.add(SeatRow(seat: s, onTap: () => onOpen(s), onMore: () => onMore(s)));
      }
    }
    return Material(
      color: k.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius), side: BorderSide(color: k.border)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}

/// A seat in the List view, as the one [AgentRow]: its icon with the state dot, its name (NEEDS YOU in the accent), what it
/// is doing or asking, its age and context; a ⋯ for the seat sheet. [mode] is kept for callers that pass it.
class SeatRow extends StatelessWidget {
  const SeatRow({super.key, required this.seat, required this.onTap, required this.onMore, this.mode});
  final Seat seat;
  final String? mode;
  final VoidCallback onTap;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final s = seat;
    final ctx = s.contextUsedPercent;
    // A seat still starting: dimmed, no context, nothing to open yet.
    final starting = s.notReady;
    // A seat that did not launch: red, with the daemon's reason, and Retry.
    final failed = s.launchFailed;
    final status = failed ? Status.failed : (starting ? Status.stopped : Status.of(s.state));
    return AgentRow(
      name: s.logicalId,
      status: status,
      kind: s.isAgent ? StatusKind.agent : StatusKind.shell,
      runtime: s.runtime,
      needsYou: s.state == SeatState.needsYou && !starting && !failed,
      extra: seatExtra(s),
      task: failed
          ? 'Didn\'t start${s.latestError == null || s.latestError!.isEmpty ? '' : ': ${s.latestError}'}'
          : s.isAgent ? seatTask(s) : (s.state == SeatState.stopped ? 'stopped' : 'shell'),
      age: starting || failed ? null : ago(s.state == SeatState.needsYou ? s.waitingSince : s.lastActivityAt),
      taskColor: failed ? k.removed : (usageLimitLine(s) == null ? null : limitColor(k)),
      action: failed ? _RetryLaunch(seat: s) : null,
      context: ctx == null || starting || failed ? null : ctx,
      dim: starting,
      tint: starting ? k.surface : statusTint(k, status, k.surface),
      onTap: starting ? null : onTap,
      onMore: onMore,
      moreTooltip: '${s.logicalId} details',
      openLabel:
          '${s.logicalId}, ${seatLabel(s)}${ctx != null ? ', context ${ctx.round()} percent used' : ''}, ${s.isClaude ? 'opens the chat' : 'opens the terminal'}',
    );
  }
}

/// A failed seat's Retry: starts its launch again; the rig page's poll shows it come up.
class _RetryLaunch extends StatefulWidget {
  const _RetryLaunch({required this.seat});
  final Seat seat;

  @override
  State<_RetryLaunch> createState() => _RetryLaunchState();
}

class _RetryLaunchState extends State<_RetryLaunch> {
  bool _busy = false;

  /// The next poll brings a new Seat: until then a second tap would only make the daemon refuse a launch that is running.
  @override
  void didUpdateWidget(_RetryLaunch old) {
    super.didUpdateWidget(old);
    if (!identical(old.seat, widget.seat)) _busy = false;
  }

  Future<void> _retry() async {
    final api = AppScope.clientOf(context);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final k = Tokens.of(context);
    final seat = widget.seat;
    setState(() => _busy = true);
    try {
      await api.retrySeatLaunch(seat);
      toastOn(messenger, k, 'Starting ${seat.logicalId} again');
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      toastOn(messenger, k, 'Couldn\'t retry ${seat.logicalId}: ${e is OpenRigException ? e.message : e}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return OutlinedButton(
      onPressed: _busy ? null : _retry,
      style: compactAction.merge(OutlinedButton.styleFrom(foregroundColor: k.removed, side: BorderSide(color: k.removed))),
      child: const Text('Retry', style: TextStyle(fontWeight: FontWeight.w600)),
    );
  }
}

/// The widest a seat's card gets in the rig's graph (on a phone and on a wide page alike).
const graphCardMax = 280.0;

/// The Map view: the legend (every state, then the link kinds this rig
/// uses) over the seats laid out by pod. Tapping a seat calls [onTap].
class SeatMap extends StatelessWidget {
  const SeatMap(
      {super.key, required this.seats, this.topology, this.modes = const {}, required this.onTap, this.onLongPress});
  final List<Seat> seats;
  final RigTopology? topology;
  final Map<String, String?> modes;

  /// Opens the seat, as its row does elsewhere.
  final void Function(Seat) onTap;

  /// The seat sheet (its details and actions).
  final void Function(Seat)? onLongPress;

  @override
  Widget build(BuildContext context) {
    final byId = {for (final s in seats) s.nodeId ?? s.logicalId: s};
    final input = graphInput(seats, topology);
    final edges = [for (final e in topology?.edges ?? const <TopoEdge>[]) GraphEdgeIn(e.sourceId, e.targetId, e.kind)];
    final kinds = {
      for (final e in edges)
        if (byId.containsKey(e.from) && byId.containsKey(e.to)) e.kind
    }.toList()
      ..sort();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.only(bottom: 12), child: GraphLegend(kinds: kinds)),
      // The links are the old ones: a lane per link in the side gutters, the hierarchy on the left and every other kind on
      // the right, each from one card's edge to the other's (the spec editor's graph draws them the same way). A card is at
      // most [graphCardMax] wide and the whole graph, lanes included, sits in the middle of a wide page.
      LayoutBuilder(
        builder: (context, box) {
          // A wide page: pods as horizontal bands, their cards side by side; where the widest pod does not fit (or on a phone), the column.
          final layout = (box.maxWidth >= 640 ? GraphLayout.swimlanes(input, edges, box.maxWidth) : null) ??
              GraphLayout.column(input, edges, box.maxWidth, cardMax: graphCardMax);
          return Align(
            alignment: Alignment.topCenter,
            child: SeatGraph(
              solidBands: true,
              layout: layout,
              names: {for (final n in input) n.id: n.logicalId},
              byId: byId,
              modes: modes,
              onTap: (id) {
                if (byId[id] case final s?) onTap(s);
              },
              onLongPress: onLongPress == null
                  ? null
                  : (id) {
                      if (byId[id] case final s?) onLongPress!(s);
                    },
            ),
          );
        },
      ),
    ]);
  }
}

/// "opus-4-5 · Accept edits · effort high": model, permission mode, effort. Context used is the row's bar.
String seatSettings(Seat seat, String? mode) => [
      seat.shortModel ?? 'default model',
      if (mode != null) PermissionMode.fromWire(mode)?.label ?? mode,
      if (seat.effort != null) 'effort ${seat.effort}',
    ].join(' · ');

/// What a seat asks, short: "Run npm test?", "Edit lib/a.dart?", "Asked you
/// to pick an option", or "waiting for approval" when the daemon doesn't say which tool.
String askLine(Seat seat) {
  final ask = PermissionAsk.from(seat);
  if (!ask.isPermission) return ask.detail;
  return switch (ask.tool) {
    null => 'waiting for approval',
    'Bash' => 'Run ${ask.detail}?',
    final t => '$t ${ask.detail}?',
  };
}

/// "Run npm test?", "asked a question", "working · 1 queued", "idle · queue empty": what a seat is doing, without its age.
String seatTask(Seat seat) {
  if (seat.notReady) return 'not ready';
  if (usageLimitLine(seat) case final limit?) return limit;
  final queued = seat.activeWorkCount > 0 ? '${seat.activeWorkCount} queued' : null;
  return switch (seat.state) {
    SeatState.needsYou => askLine(seat),
    SeatState.working => ['working', if (queued != null) queued].join(' · '),
    SeatState.shell => [seat.jobsLine, if (queued != null) queued].join(' · '),
    SeatState.idle => ['idle', queued ?? 'queue empty'].join(' · '),
    SeatState.stopped => 'stopped',
  };
}

/// [seatTask], with how long a waiting seat has waited: "Run npm test? · 2m".
String seatLine(Seat seat) =>
    seat.state == SeatState.needsYou && !seat.notReady && seat.waitingSince != null ? '${seatTask(seat)} · ${ago(seat.waitingSince)}' : seatTask(seat);
