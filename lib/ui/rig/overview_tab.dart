import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/chat_cache.dart';
import '../../data/git_status.dart';
import '../../main.dart';
import '../../models.dart';
import '../../ssh/ssh_exec.dart';
import '../app_icon.dart';
import '../artifact_viewer.dart';
import '../chat/diff_view.dart' show DiffScreen;
import '../chat/git_cards.dart' show ChangesCard;
import '../chat/media_view.dart';
import '../common.dart';
import '../kit.dart';
import '../theme.dart';
import '../status_shape.dart';
import 'seats_tab.dart';
import 'work_queue_screen.dart';

/// Helpers the rig screen's numbers come from.
abstract final class OverviewTab {
  /// The tile counts over [seats]: running, need you, working, idle, on a shell or monitor.
  static (int, int, int, int, int) tally(List<Seat> seats) {
    var running = 0, needs = 0, working = 0, idle = 0, shell = 0;
    for (final s in seats) {
      final st = s.state;
      if (st != SeatState.stopped) running++;
      switch (st) {
        case SeatState.needsYou:
          needs++;
        case SeatState.working:
          working++;
        case SeatState.idle:
          idle++;
        case SeatState.shell:
          shell++;
        case SeatState.stopped:
          break;
      }
    }
    return (running, needs, working, idle, shell);
  }

  /// Summed input tokens, output tokens and cost estimate over [seats].
  static (int, int, double) usage(List<Seat> seats) {
    var tin = 0, tout = 0, cost = 0.0;
    for (final s in seats) {
      tin += s.inputTokens ?? 0;
      tout += s.outputTokens ?? 0;
      cost += s.costUsd ?? 0;
    }
    return (tin, tout, cost);
  }

  /// "15m", "1h", "1h 30m".
  /// "Snapshot 3m ago · auto every 15m".
  static String snapshotLine(Rig rig) => [
        rig.latestSnapshot != null ? 'Snapshot ${rig.latestSnapshot}' : 'No snapshot',
        if (rig.autoSnapshotEvery != null) 'auto every ${OverviewTab.every(rig.autoSnapshotEvery!)}',
      ].join(' · ');

  static String every(Duration d) =>
      d.inMinutes < 60 ? '${d.inMinutes}m' : '${d.inHours}h${d.inMinutes % 60 == 0 ? '' : ' ${d.inMinutes % 60}m'}';
}

/// Which of the rig screen's tabs a [RigBody] draws.
enum RigPart {
  /// A stopped rig's Restore panel, then the agents as a list.
  seats,

  /// The agents as a graph: their links, and each one's model, mode, context and last update.
  graph,

  /// The open work queue.
  work,

  /// The branch and its PR, the snapshot, what the rig made.
  code,
}

/// One tab of the rig screen as a scroll: Agents ([RigPart.seats], with Work, Activity and Usage beside or under them),
/// the Graph, Work or Code.
/// A stopped rig opens on its Restore panel. Every count is over agents only. Progress is its own tab.
class RigBody extends StatelessWidget {
  const RigBody({
    super.key,
    required this.part,
    required this.rig,
    required this.seats,
    required this.queue,
    required this.events,
    this.git,
    this.gitError,
    this.gitLoading = false,
    this.busy = false,
    this.topology,
    this.modes = const {},
    required this.onRefresh,
    required this.onOpenSeat,
    required this.onSeatMore,
    this.onGit,
    this.onWork,
    this.footer,
    this.wide = false,
  });

  final RigPart part;
  final Rig rig;
  final List<Seat> seats;
  final List<QueueItem> queue;
  final List<RigEvent> events;
  final GitStatus? git;
  final String? gitError;
  final bool gitLoading;
  final bool busy;
  final RigTopology? topology;

  /// Permission mode by session name (or logical id), once loaded.
  final Map<String, String?> modes;

  final Future<void> Function() onRefresh;

  /// Restore from the last snapshot; offered on top while the rig is stopped.

  /// A row's tap: its chat (Claude) or terminal.
  final void Function(Seat) onOpenSeat;

  /// A row's ⋯: the seat sheet.
  final void Function(Seat) onSeatMore;

  /// Tapping the branch opens the folder status sheet.
  final VoidCallback? onGit;

  /// "Queue & handoffs"; defaults to pushing that page.
  final VoidCallback? onWork;

  /// At the end of the Agents tab's scroll (the Danger zone).
  final Widget? footer;

  /// The body's pane is 1000dp or more: every tab uses the width (two panes) instead of one column.
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final names = {
      for (final s in seats)
        if (s.nodeId != null) s.nodeId!: s.logicalId
    };
    final agents = seats.where((s) => s.isAgent).toList();
    final (tokensIn, tokensOut, cost) = OverviewTab.usage(agents);
    final stopped = rig.status == 'stopped';
    final open = queue.where((q) => isOpenQueueState(q.state)).toList();
    void push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    final onWork = this.onWork ?? () => push(WorkScreen(rig: rig));

    // Work: the open queue (a few on the Agents tab, all of it on the Work tab), with the link to queue and handoffs.
    List<Widget> workSection({int? take}) => [
          SectionLabel('Work · ${open.length} open', trailing: _Link('Queue & handoffs', onWork)),
          if (open.isEmpty)
            Panel(child: Text('Nothing queued.', style: TextStyle(color: k.muted, fontSize: 13)))
          else
            BorderedList(children: [for (final q in take == null ? open : open.take(take)) QueueRow(q)]),
        ];
    final usage = [
      const SectionLabel('Usage'),
      Panel(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(children: [
          Text('${compactCount(tokensIn + tokensOut)} tokens', style: mono(context, size: 13, color: k.ink)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              [
                'in ${compactCount(tokensIn)}',
                'out ${compactCount(tokensOut)}',
                if (cost > 0) '~\$${cost.toStringAsFixed(2)}',
              ].join(' · '),
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 13, color: k.muted),
            ),
          ),
        ]),
      ),
    ];
    final agentsColumn = [
      if (stopped) ...[
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('This rig is stopped', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            // The one Restore rig button is the green bar under the page.
            Text(
                rig.latestSnapshot == null
                    ? 'Restore rig starts its seats again from its latest snapshot.'
                    : 'Restore rig starts its seats again from the snapshot of ${rig.latestSnapshot}.',
                style: TextStyle(fontSize: 13, color: k.muted)),
          ]),
        ),
        const SizedBox(height: 16),
      ],
      if (agents.any((s) => s.notReady)) ...[StartingCard(agents: agents), const SizedBox(height: 16)],
      SectionLabel('Agents · ${agents.length}'),
      SeatList(seats: seats, modes: modes, onOpen: onOpenSeat, onMore: onSeatMore),
    ];
    // Under the agents on a phone; a right column beside them on a wide page: Work, Activity and Usage.
    final aside = [...workSection(take: 5), _gap, _Activity(events: events, names: names), _gap, ...usage];

    Widget scroll(List<Widget> children) => RefreshIndicator(
          onRefresh: onRefresh,
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 28), children: children),
        );
    return switch (part) {
      RigPart.seats => LayoutBuilder(
          builder: (context, box) => scroll(
            wide
                // The list flexes between 520 and 760 beside a 360 side column (Work, Activity, Usage); the Danger zone is under
                // the list.
                ? [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Flexible(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 520, maxWidth: 760),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...agentsColumn, if (footer != null) footer!]),
                        ),
                      ),
                      const SizedBox(width: 24),
                      SizedBox(width: 360, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [const SizedBox(height: 4), ...aside])),
                    ]),
                  ]
                : box.maxWidth >= 760
                ? [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: agentsColumn)),
                      const SizedBox(width: 24),
                      SizedBox(width: 300, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [const SizedBox(height: 4), ...aside])),
                    ]),
                    if (footer != null) footer!,
                  ]
                : [...agentsColumn, _gap, ...aside, if (footer != null) footer!],
          ),
        ),
      RigPart.graph => scroll([
          SeatMap(seats: seats, topology: topology, modes: modes, onTap: onOpenSeat, onLongPress: onSeatMore),
        ]),
      // A wide pane: the whole queue and its handoffs, the list beside the chosen item's card (the Work screen, embedded).
      RigPart.work => wide ? WorkScreen(key: ValueKey('work-${rig.id}'), rig: rig, embedded: true) : scroll(workSection()),
      // A wide pane: the changed files at the left (with the branch and PR above them), the chosen file's diff beside them.
      RigPart.code when wide => _CodePanes(rig: rig, git: git, error: gitError, loading: gitLoading, onTap: onGit, onRefresh: onRefresh),
      RigPart.code => scroll([
          Text(OverviewTab.snapshotLine(rig), style: TextStyle(fontSize: 12, color: k.muted)),
          const SizedBox(height: 12),
          const SectionLabel('Code'),
          _CodeCard(git: git, error: gitError, loading: gitLoading, onTap: onGit),
          RigMediaSection(rigId: rig.id),
        ]),
    };
  }

  static const _gap = SizedBox(height: 20);
}

/// The underlined link at the end of a section label ("Queue & handoffs").
class _Link extends StatelessWidget {
  const _Link(this.label, this.onTap);
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: Tokens.of(context).ink,
          textStyle: const TextStyle(
              fontFamily: fontSans, fontSize: 12, fontWeight: FontWeight.w600, decoration: TextDecoration.underline)).merge(compactAction),
        child: Text(label),
      );
}

/// Recent activity: the last three events, the rest behind "Show all".
class _Activity extends StatefulWidget {
  const _Activity({required this.events, required this.names});
  final List<RigEvent> events;
  final Map<String, String> names;
  @override
  State<_Activity> createState() => _ActivityState();
}

class _ActivityState extends State<_Activity> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final events = widget.events;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel('Activity',
          trailing: events.length > 3
              ? _Link(_all ? 'Show less' : 'Show all ${events.length}', () => setState(() => _all = !_all))
              : null),
      if (events.isEmpty)
        Panel(child: Text('No events yet.', style: TextStyle(color: k.muted, fontSize: 13)))
      else
        BorderedList(children: [
          for (final e in _all ? events : events.take(3))
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 36, child: Text(ago(e.at), style: mono(context, size: 11))),
                Padding(
                  padding: const EdgeInsets.only(top: 4, right: 8),
                  child: StatusShape(_eventStatus(e), size: 8, semantics: false),
                ),
                Expanded(
                  child: Builder(builder: (context) {
                    final (who, what) = e.describeParts(widget.names);
                    return Text.rich(
                      TextSpan(children: [
                        if (who != null) TextSpan(text: '$who ', style: const TextStyle(fontWeight: FontWeight.w600)),
                        TextSpan(text: what),
                      ]),
                      style: const TextStyle(fontSize: 13),
                    );
                  }),
                ),
              ]),
            ),
        ]),
    ]);
  }
}

/// An event in the status vocabulary: asks are needs-you, starts and running
/// are working, failures and stops failed, the rest idle.
Status _eventStatus(RigEvent e) {
  final t = e.type;
  final activity = e.data['activity'];
  final state = activity is Map ? activity['state'] : null;
  if (t == 'agent.activity') {
    return switch (state) { 'running' => Status.working, 'needs_input' => Status.needsYou, _ => Status.idle };
  }
  if (t.endsWith('failed')) return Status.failed;
  if (t == 'session.stopped' || t == 'rig.stopped') return Status.stopped;
  if (t == 'node.launched' || t == 'node.startup_ready' || t == 'rig.created' || t == 'restore.completed') {
    return Status.working;
  }
  return Status.idle;
}

/// A count over a label, in the state color; tapping goes where the rest is.
class CountTile extends StatelessWidget {
  const CountTile(this.label, this.value,
      {super.key, this.highlight = false, this.color, this.filled = false, this.onTap});
  final String label;
  final String value;
  final bool highlight;

  /// The state's color for the number (green while seats run or work).
  final Color? color;

  /// A light wash of [color] behind the tile.
  final bool filled;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final fg = highlight ? k.onAccent : k.ink;
    final number = highlight ? k.onAccent : (color ?? k.ink);
    return Expanded(
      child: Semantics(
        button: onTap != null,
        label: '$value $label',
        onTap: onTap,
        excludeSemantics: true,
        child: Material(
          color: highlight ? k.accent : (filled && color != null ? color!.withValues(alpha: 0.1) : k.ground),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadius),
            side: BorderSide(
                color: highlight ? k.accent : (filled && color != null ? color!.withValues(alpha: 0.5) : k.border)),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(kRadius),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                FittedBox(
                    child: Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: number))),
                FittedBox(
                    child: Text(label,
                        maxLines: 1, style: TextStyle(fontSize: 11, color: filled && color != null ? color : fg))),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Code card: the branch ("↑2 to push · 4 changed", +added −deleted;
/// tap opens the folder status sheet) and its PR, if any (↗ opens it).
/// The Code tab on a wide pane: 360 of branch, PR and changed files, and the chosen file's diff beside it (the first file is
/// chosen on load). A tap chooses here; on the phone the same rows open the diff screen.
class _CodePanes extends StatefulWidget {
  const _CodePanes({required this.rig, required this.git, required this.error, required this.loading, required this.onTap, required this.onRefresh});
  final Rig rig;
  final GitStatus? git;
  final String? error;
  final bool loading;
  final VoidCallback? onTap;
  final Future<void> Function() onRefresh;
  @override
  State<_CodePanes> createState() => _CodePanesState();
}

class _CodePanesState extends State<_CodePanes> {
  String? _sel;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final g = widget.git;
    final rows = g?.changeRows ?? const [];
    final current = rows.where((r) => r.$2 == _sel).firstOrNull ?? rows.firstOrNull;
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        width: 360,
        child: RefreshIndicator(
          onRefresh: widget.onRefresh,
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 16, 28), children: [
            Text(OverviewTab.snapshotLine(widget.rig), style: TextStyle(fontSize: 12, color: k.muted)),
            const SizedBox(height: 12),
            const SectionLabel('Code'),
            _CodeCard(git: g, error: widget.error, loading: widget.loading, onTap: widget.onTap),
            if (rows.isNotEmpty) ...[
              const SizedBox(height: 20),
              SectionLabel('Changed files · ${rows.length}${g != null && g.changes.isNotEmpty ? ' +${g.added} −${g.deleted}' : ''}'),
              ChangesCard(git: g!, showHeader: false, selected: current?.$2, onPick: (path) => setState(() => _sel = path)),
            ],
            RigMediaSection(rigId: widget.rig.id),
          ]),
        ),
      ),
      VerticalDivider(width: 1, color: k.border),
      Expanded(
        // The same 20 on the right as the other tabs.
        child: Padding(
          padding: const EdgeInsets.only(right: 20),
          child: current == null || g?.root == null
              ? Center(child: Text(rows.isEmpty ? 'No changes' : 'Nothing to show', style: TextStyle(color: k.muted)))
              : DiffScreen(
                  key: ValueKey(current.$2),
                  embedded: true,
                  root: g!.root!,
                  path: current.$2,
                  untracked: g.untracked.contains(current.$2)),
        ),
      ),
    ]);
  }
}

class _CodeCard extends StatelessWidget {
  const _CodeCard({required this.git, required this.error, required this.loading, this.onTap});
  final GitStatus? git;
  final String? error;
  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final g = git;
    final muted = TextStyle(fontSize: 12, color: k.muted);
    if (g == null || !g.isRepo) {
      return Panel(
        child: Text(
          g != null
              ? 'Not a git checkout'
              : (loading ? 'Reading git status over SSH…' : (error ?? 'Git status unavailable')),
          style: muted.copyWith(fontSize: 13),
        ),
      );
    }
    final pr = g.pr;
    Widget row({required Widget lead, required Widget body, Widget? trailing, VoidCallback? onTap}) => RowTile(
          minHeight: 52,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          leading: SizedBox(width: 16, child: Center(child: lead)),
          trailing: trailing,
          onTap: onTap,
          child: body,
        );
    return BorderedList(children: [
      row(
        onTap: onTap,
        lead: AppIcon(AppIconKind.worktree, size: 16, color: k.muted),
        body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(g.branch ?? 'detached HEAD', style: mono(context, size: 13, color: k.ink)),
          Text(
              [
                if (g.upstream == null) 'not pushed' else if (g.ahead > 0) '↑${g.ahead} to push',
                if (g.behind > 0) '↓${g.behind} behind',
                '${g.changedFiles} changed',
              ].join(' · '),
              style: muted),
        ]),
        trailing: g.changes.isEmpty
            ? null
            : Text.rich(
                TextSpan(children: [
                  TextSpan(text: '+${g.added}', style: TextStyle(color: k.added)),
                  const TextSpan(text: ' '),
                  TextSpan(text: '−${g.deleted}', style: TextStyle(color: k.removed)),
                ]),
                style: mono(context, size: 12)),
      ),
      if (pr != null)
        row(
          onTap: pr.url == null ? null : () => launchUrl(Uri.parse(pr.url!), mode: LaunchMode.externalApplication),
          lead: StatusShape(prStatus(pr), size: 9),
          body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('#${pr.number} ${pr.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            Text(prLine(pr), maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
          ]),
          trailing: Text('${pr.state.toLowerCase()} ↗', style: mono(context, size: 11)),
        ),
    ]);
  }
}

/// A PR as a status shape: failing checks failed, open working, merged or closed stopped.
Status prStatus(PullRequest pr) => pr.checks == 'failing'
    ? Status.failed
    : pr.state == 'OPEN'
        ? Status.working
        : Status.stopped;

/// "● PR #42": the small PR pill in the chat's git bar.
class PrChip extends StatelessWidget {
  const PrChip(this.pr, {super.key, this.onTap});
  final PullRequest pr;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return Semantics(
      button: onTap != null,
      label: 'Pull request ${pr.number}, ${prLine(pr)}',
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kRadius),
        child: Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(border: Border.all(color: k.border), borderRadius: BorderRadius.circular(kRadius)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            StatusShape(prStatus(pr), size: 8, semantics: false),
            const SizedBox(width: 6),
            Text('PR #${pr.number}', style: const TextStyle(fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}

/// What this rig's chats made (files, images, videos, artifacts) that is saved on the phone, newest first.
/// Only what was cached: a chat never opened or synced adds nothing. Hidden when there is none.
class RigMediaSection extends StatefulWidget {
  const RigMediaSection({super.key, required this.rigId});
  final String rigId;

  @override
  State<RigMediaSection> createState() => _RigMediaSectionState();
}

class _RigMediaSectionState extends State<RigMediaSection> {
  Stream<List<RigMedia>>? _media;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final cache = chatCache;
      if (!mounted || cache == null) return;
      final host = AppScope.read(context).active;
      if (host != null) {
        _host = host;
        setState(() => _media = cache.watchRigMedia(host.id, widget.rigId));
      }
    });
  }

  Host? _host;

  /// Images and videos are indexed from names in chat text, so some never existed: one batched check hides those
  /// confirmed missing. Everything shows until then, and a failed check leaves everything shown.
  final _checked = <String>{}, _gone = <String>{};
  bool _checking = false;
  DateTime? _failedAt;

  Future<void> _verify(List<RigMedia> all) async {
    final host = _host;
    final todo = [
      for (final m in all)
        if ((m.kind == 'image' || m.kind == 'video') && !_checked.contains(m.ref)) m.ref
    ];
    if (_checking || host == null || todo.isEmpty) return;
    if (_failedAt case final t? when DateTime.now().difference(t) < const Duration(seconds: 30)) return;
    _checking = true;
    SshExec? ssh;
    try {
      ssh = await SshExec.connect(host);
      final ok = await ssh.readable(todo);
      _checked.addAll(todo);
      if (mounted) setState(() => _gone.addAll(todo.where((r) => !ok.contains(r))));
    } catch (_) {
      _failedAt = DateTime.now(); // stays shown; a build after the pause tries again
    } finally {
      ssh?.close();
      _checking = false;
    }
  }

  static const _shown = 5;
  bool _all = false;

  void _open(RigMedia m) {
    switch (m.kind) {
      case 'artifact':
        launchUrl(Uri.parse(m.ref), mode: LaunchMode.externalApplication);
      case 'image' || 'video':
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MediaViewer(paths: [m.ref])));
      default:
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtifactViewer(path: m.ref)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final stream = _media;
    if (stream == null) return const SizedBox.shrink();
    final k = Tokens.of(context);
    return StreamBuilder<List<RigMedia>>(
      stream: stream,
      builder: (context, snap) {
        final all = snap.data ?? const <RigMedia>[];
        if (all.isNotEmpty) scheduleMicrotask(() => _verify(all));
        final media = [
          for (final m in all)
            if (!_gone.contains(m.ref)) m
        ];
        if (media.isEmpty) return const SizedBox.shrink();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 16),
          SectionLabel('Made by the rig · ${media.length}'),
          BorderedList(children: [
            for (final m in _all ? media : media.take(_shown))
              ListTile(
                dense: true,
                minVerticalPadding: 12,
                leading: Icon(
                    switch (m.kind) {
                      'image' => Icons.image_outlined,
                      'video' => Icons.movie_outlined,
                      'artifact' => Icons.web_asset,
                      _ => Icons.description_outlined,
                    },
                    size: 20),
                title: Text(m.name ?? m.ref.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(ago(m.touchedAt), style: TextStyle(color: k.muted, fontSize: 12)),
                onTap: () => _open(m),
              ),
            if (!_all && media.length > _shown)
              ListTile(
                dense: true,
                title: Text('Show more',
                    style: TextStyle(color: k.ink, fontWeight: FontWeight.w600, decoration: TextDecoration.underline)),
                onTap: () => setState(() => _all = true),
              ),
          ]),
        ]);
      },
    );
  }
}

/// A rig that is still starting: a dashed, neutral card (a starting rig does not need you, so nothing in the accent) with an
/// ink STARTING… badge, how many agents are up, and a bar that moves. Its agents below are dimmed, "not ready", and open
/// nothing until they are up.
class StartingCard extends StatefulWidget {
  const StartingCard({super.key, required this.agents});
  final List<Seat> agents;

  @override
  State<StartingCard> createState() => _StartingCardState();
}

class _StartingCardState extends State<StartingCard> with SingleTickerProviderStateMixin {
  late final _stripes = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    _stripes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final agents = widget.agents;
    final up = agents.where((s) => !s.notReady).length;
    final still = MediaQuery.disableAnimationsOf(context) || !animateStatusSpinners;
    if (still && _stripes.isAnimating) _stripes.stop();
    if (!still && !_stripes.isAnimating) _stripes.repeat();
    return CustomPaint(
      foregroundPainter: DashedBorder(k.faint, radius: kRadius),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: k.headerFill, borderRadius: BorderRadius.circular(kRadius)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: k.ink, borderRadius: BorderRadius.circular(kRadius)),
              child: Text('STARTING…',
                  style: mono(context, size: 11, color: k.ground).copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.5)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Setting up the rig · $up of ${agents.length} ${agents.length == 1 ? 'seat' : 'seats'} up · not ready yet',
                  style: TextStyle(fontSize: 13, color: k.ink)),
            ),
          ]),
          const SizedBox(height: 10),
          // The filled part is up/total; moving stripes run over it so a slow start never reads as stuck.
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 4,
              child: AnimatedBuilder(
                animation: _stripes,
                builder: (context, _) => CustomPaint(
                  painter: _StripedBar(agents.isEmpty ? 0 : up / agents.length, k.ink, k.border, still ? 0 : _stripes.value),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text('Rows open a terminal once their seat is ready. Nothing to answer yet.', style: TextStyle(fontSize: 12, color: k.muted)),
        ]),
      ),
    );
  }
}

/// A track with [fraction] of it filled in [fill], and diagonal stripes of the track's colour sliding over the fill by [phase].
class _StripedBar extends CustomPainter {
  _StripedBar(this.fraction, this.fill, this.track, this.phase);
  final double fraction;
  final Color fill;
  final Color track;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = track);
    // Never an empty bar: a starting rig always shows some fill.
    final w = size.width * fraction.clamp(0.12, 1.0);
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, w, size.height));
    canvas.drawRect(Rect.fromLTWH(0, 0, w, size.height), Paint()..color = fill);
    const step = 12.0;
    final stripe = Paint()..color = track.withValues(alpha: .55);
    for (var x = -step + phase * step; x < w + size.height; x += step) {
      canvas.drawPath(
          Path()
            ..moveTo(x, size.height)
            ..lineTo(x + size.height, 0)
            ..lineTo(x + size.height + step / 2, 0)
            ..lineTo(x + step / 2, size.height)
            ..close(),
          stripe);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StripedBar old) =>
      old.fraction != fraction || old.phase != phase || old.fill != fill || old.track != track;
}
