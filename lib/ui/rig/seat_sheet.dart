import '../usage_strip.dart' show contextColor, compactsSoon, contextWeight;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../desktop_shell.dart' show DetailPane, detailNavigator;
import '../../data/agent_jobs.dart';
import '../../data/fleet.dart';
import '../../data/git_status.dart';
import '../../data/subagents.dart';
import '../../main.dart';
import '../../models.dart';
import '../../ssh/ssh_exec.dart';
import '../../terminal/transport.dart';
import '../agent_details.dart';
import '../answer_bar.dart';
import '../chat/jobs_view.dart' show showJobsSheet;
import '../chat_screen.dart' show ChatScreen, showGitSheet;
import '../common.dart';
import '../detail_row.dart';
import '../kit.dart';
import '../needs_you_banner.dart' show needsYouAlerts;
import '../permission_card.dart';
import '../permission_sheet.dart';
import '../recent_screen.dart' show askReply;
import '../status_shape.dart';
import '../terminal_screen.dart';
import '../theme.dart';
import 'add_to_queue_sheet.dart' show canQueue, showAddToQueue;
import '../progress_bar.dart' show ContextBar;
import 'rig_chat.dart' show showHandoff;
import 'seat_actions.dart' show editSeatInSpec, runSeatAction;
import 'seats_tab.dart' show askLine, seatLine;

/// The one seat sheet: who the seat is, the ways into it (Chat · Terminal ·
/// Open in Claude), its question with the answer buttons when it asks, then
/// Now, Model & context and Code, the spec link, and Kill session… /
/// Remove from rig… last, each behind a confirmation. Opened from the rig's
/// List ⋯, the Map's Details, and the chat's ⋯.
///
/// [rigName] is the rig's real name (session addresses use it). [queue] gives
/// the current task. [details] carries what a chat read for the seat (its
/// log's model and tokens, the running tool, git, files, PRs, shells and
/// subagents); without it the sheet reads git over SSH and the shells and
/// subagents from the host feed. [mode] is the permission mode when the
/// caller already has it; the sheet asks the daemon otherwise.
///
/// Callbacks default to what the rig screen does: [onChat] opens the chat,
/// [onTerminal] the terminal, [onJobs] the shells sheet, [onSubagents] a list
/// of them, [onEditSpec] the spec editor on this member. Set [fromChat] when
/// the chat opens it: the Chat button goes. [onGone] runs after the session
/// is killed or the seat removed (the chat closes itself there);
/// [onRefresh] after anything that changes the seat.
Future<void> showSeatSheet(
  BuildContext context,
  String rigName,
  Seat seat, {
  List<QueueItem> queue = const [],
  AgentDetails? details,
  String? mode,
  bool fromChat = false,
  bool fromTerminal = false,
  List<(IconData, String, VoidCallback)> extraActions = const [],
  VoidCallback? onChat,
  VoidCallback? onTerminal,
  VoidCallback? onJobs,
  VoidCallback? onSubagents,
  VoidCallback? onEditSpec,
  VoidCallback? onGone,
  Future<void> Function()? onRefresh,
}) {
  // The sheet is a route of the root navigator, outside the desktop shell's detail pane: without this its Chat and
  // Terminal (detailNavigator) opened a full-window page, the sidebar gone, not in the main area as a click does.
  final pane = context.getInheritedWidgetOfExactType<DetailPane>();
  return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) {
        final sheet = DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, scroll) => SeatSheetBody(
          rigName: rigName,
          seat: seat,
          queue: queue,
          details: details,
          mode: mode,
          fromChat: fromChat,
          fromTerminal: fromTerminal,
          extraActions: extraActions,
          onChat: onChat,
          onTerminal: onTerminal,
          onJobs: onJobs,
          onSubagents: onSubagents,
          onEditSpec: onEditSpec,
          onGone: onGone,
          onRefresh: onRefresh,
          controller: scroll,
          inSheet: true,
        ),
      );
        return pane == null ? sheet : DetailPane(nav: pane.nav, child: sheet);
      },
    );
}

/// The running subagents, as the shells sheet is: scrollable and short of full height, so the scrim and handle stay
/// reachable however many there are. [onOpen] runs after the sheet closes.
Future<void> showSubagentsSheet(BuildContext context, List<Subagent> subs, ValueChanged<Subagent> onOpen) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: EdgeInsets.only(bottom: 8 + MediaQuery.viewPaddingOf(ctx).bottom),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Subagents · ${subs.length} running', style: Theme.of(ctx).textTheme.titleMedium),
          ),
          for (final a in subs)
            OptionRow(
              leading: const StatusShape(Status.working, size: 10, semantics: false),
              title: Text(a.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle:
                  Text([if (a.type != null) a.type!, if (a.started != null) 'started ${ago(a.started)}'].join(' · ')),
              trailing: a.path == null ? null : const Chevron(),
              onTap: a.path == null
                  ? null
                  : () {
                      Navigator.of(ctx).pop();
                      onOpen(a);
                    },
            ),
        ],
      ),
    );

/// The seat's current task: its in-progress queue item, else the oldest
/// pending one.
QueueItem? currentTaskFor(Seat seat, List<QueueItem> queue) {
  final mine = queue.where((q) => q.destinationSession != null && q.destinationSession == seat.sessionName).toList();
  return mine.where((q) => q.state == 'in-progress').firstOrNull ?? mine.where((q) => q.state == 'pending').lastOrNull;
}

/// The seat sheet's content, in a sheet ([inSheet]) or under a page header
/// ([SeatDetailsScreen]).
class SeatSheetBody extends StatefulWidget {
  const SeatSheetBody({
    super.key,
    required this.rigName,
    required this.seat,
    this.queue = const [],
    this.details,
    this.mode,
    this.fromChat = false,
    this.fromTerminal = false,
    this.extraActions = const [],
    this.onChat,
    this.onTerminal,
    this.onJobs,
    this.onSubagents,
    this.onEditSpec,
    this.onOpenInClaude,
    this.onGone,
    this.onRefresh,
    this.controller,
    this.inSheet = false,
    this.showHeader = true,
  });
  final String rigName;
  final Seat seat;
  final List<QueueItem> queue;
  final AgentDetails? details;
  final String? mode;
  final bool fromChat;

  /// Opened from the seat's terminal: no Terminal button, and the terminal's own [extraActions] (Reflow, Reconnect).
  final bool fromTerminal;
  final List<(IconData, String, VoidCallback)> extraActions;
  final VoidCallback? onChat;
  final VoidCallback? onTerminal;
  final VoidCallback? onJobs;
  final VoidCallback? onSubagents;
  final VoidCallback? onEditSpec;

  /// Overrides opening the session in the Claude app.
  final VoidCallback? onOpenInClaude;
  final VoidCallback? onGone;
  final Future<void> Function()? onRefresh;
  final ScrollController? controller;

  /// Leaving for the chat, terminal or spec closes the sheet first.
  final bool inSheet;

  /// Off under a page header that already names the seat.
  final bool showHeader;

  @override
  State<SeatSheetBody> createState() => _SeatSheetBodyState();
}

class _SeatSheetBodyState extends State<SeatSheetBody> {
  late String? _mode = widget.mode ?? widget.seat.permissionMode;
  GitStatus? _git;
  bool _gitTried = false;

  Seat get _s => widget.seat;

  /// A durable queue item for this seat (not typed text).
  Future<void> _addToQueue() async {
    final agent = await showAddToQueue(context, seat: _s);
    if (agent != null && mounted) toast(context, 'Added to $agent\'s queue');
    await _refresh();
  }
  AgentDetails? get _d => widget.details;

  @override
  void initState() {
    super.initState();
    _git = _d?.git;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadMode();
      if (_git == null) _loadGit();
    });
  }

  Future<void> _loadMode() async {
    // Only the daemon knows a seat's permission mode.
    if (_s.rigId.isEmpty || !_s.isAgent) return;
    try {
      final m = await AppScope.clientOf(context)?.permissionMode(_s);
      if (mounted && m != null) setState(() => _mode = m);
    } catch (_) {/* the row says — */}
  }

  Future<void> _loadGit() async {
    final host = AppScope.read(context).active;
    final cwd = _s.cwd;
    if (host == null || cwd == null) return;
    SshExec? ssh;
    try {
      ssh = await SshExec.connect(host);
      final g = await ssh.gitStatus(cwd);
      if (mounted) setState(() => _git = g);
    } catch (_) {/* the Code section shows the folder only */} finally {
      ssh?.close();
      if (mounted) setState(() => _gitTried = true);
    }
  }

  Future<void> _refresh() async => widget.onRefresh?.call();

  /// Closes the sheet (when it is one), then [f] on the page underneath.
  void _leave(VoidCallback f) {
    if (widget.inSheet) Navigator.of(context).pop();
    f();
  }

  NavigatorState get _nav => Navigator.of(context);

  void _chat() => widget.onChat != null
      ? _leave(widget.onChat!)
      : _leaveWith((nav) => nav.push(MaterialPageRoute(builder: (_) => ChatScreen(rigName: widget.rigName, seat: _s, asChat: true))));

  void _terminal() => widget.onTerminal != null
      ? _leave(widget.onTerminal!)
      : _leaveWith(
          (nav) => nav.push(MaterialPageRoute(builder: (_) => TerminalScreen(target: SeatTarget(widget.rigName, _s)))));

  /// Pops the sheet and pushes on the navigator underneath it.
  void _leaveWith(void Function(NavigatorState nav) push) {
    final target = detailNavigator(context);
    if (widget.inSheet) _nav.pop();
    push(target);
  }

  void _jobs() {
    if (widget.onJobs != null) return widget.onJobs!();
    final session = _s.sessionName;
    if (session == null) return;
    showJobsSheet(context, _jobsList, session, (_) {});
  }

  List<AgentJob> get _jobsList => _d?.jobs.isNotEmpty == true ? _d!.jobs : _s.jobs;

  List<Subagent> get _subagents {
    if (_d case final d? when d.subagents.isNotEmpty) return d.subagents;
    final host = AppScope.read(context).active;
    return host == null ? const [] : fleet.feedFor(host).subagentsOf(_s);
  }

  void _showSubagents(List<Subagent> subs) {
    if (widget.onSubagents != null) return widget.onSubagents!();
    showSubagentsSheet(
        context,
        subs,
        (a) => detailNavigator(context)
            .push(MaterialPageRoute(builder: (_) => ChatScreen(rigName: _s.logicalId, seat: a.toSeat(cwd: _s.cwd)))));
  }

  Future<void> _permissions() async {
    await showPermissionSheet(context, _s);
    if (!mounted) return;
    await _loadMode();
    await _refresh();
  }

  Future<void> _contextAction(String what) async {
    await runSeatAction(context, what, _s, onRefresh: _refresh);
  }

  /// The member in the spec this rig was launched from.
  Future<void> _editSpec() async {
    if (widget.onEditSpec != null) return _leave(widget.onEditSpec!);
    final outer = widget.inSheet ? _nav.context : context;
    await editSeatInSpec(outer, _s, widget.rigName, beforeOpen: () {
      if (!mounted) return false; // dismissed while the rig was being read
      if (widget.inSheet) _nav.pop();
      return true;
    });
  }

  Future<void> _kill() async {
    final nav = _nav;
    if (await killSeatSession(context, _s, widget.rigName)) {
      if (widget.inSheet && nav.mounted) nav.pop();
      widget.onGone?.call();
      await _refresh();
    }
  }

  Future<void> _remove() async {
    final nav = _nav;
    if (await removeSeatFromRig(context, _s, widget.rigName)) {
      if (widget.inSheet && nav.mounted) nav.pop();
      widget.onGone?.call();
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final s = _s;
    final d = _d;
    final live = s.sessionName != null && s.state != SeatState.stopped;
    final buttons = <(String, IconData, VoidCallback)>[
      if (s.isClaude && !widget.fromChat) ('Chat', Icons.chat_bubble_outline, _chat),
      if (s.sessionName != null && !widget.fromTerminal) ('Terminal', Icons.terminal, _terminal),
      if (s.isClaude && s.resumeToken != null)
        ('Open in Claude', Icons.open_in_new, widget.onOpenInClaude ?? () => openInClaude(context, s)),
    ];
    return ListView(
      controller: widget.controller,
      // The bottom inset too: useSafeArea on the sheet covers the top and sides only, and the red actions at the end
      // sit above the home indicator.
      padding: EdgeInsets.fromLTRB(20, widget.showHeader ? 0 : 16, 20, 24 + MediaQuery.viewPaddingOf(context).bottom),
      children: [
        if (widget.showHeader) ...[SeatHeader(rigName: widget.rigName, seat: s), const SizedBox(height: 14)],
        if (buttons.isNotEmpty) ...[
          Row(children: [
            for (final (i, (label, icon, onTap)) in buttons.indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                // Each button takes room for its caption: 'Open in Claude' is cut to 'Open in C…' at 390 wide if the
                // three share equally.
                flex: label.length + 6,
                child: OutlinedButton.icon(
                  onPressed: onTap,
                  icon: Icon(icon, size: 18),
                  label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8)).merge(sheetAction),
                ),
              ),
            ],
          ]),
          const SizedBox(height: 16),
        ],
        if (s.needsInput && s.sessionName != null) ...[
          SeatAskPanel(
              seat: s,
              onAnswered: () {
                if (widget.inSheet && mounted) Navigator.of(context).pop();
                _refresh();
              }),
          const SizedBox(height: 16),
        ],
        ..._now(k, s, d),
        if (s.isAgent) ..._model(k, s, d, live),
        ..._code(k, s, d),
        if (canQueue(s) || (s.nodeId != null && s.rigId.isNotEmpty) || widget.extraActions.isNotEmpty) ...[
          BorderedList(children: [
            for (final (icon, label, run) in widget.extraActions) DetailRow(label, null, icon: icon, onTap: () => _leave(run)),
            if (canQueue(s)) DetailRow('Add to queue…', null, icon: Icons.playlist_add, onTap: _addToQueue),
            if (s.nodeId != null && s.rigId.isNotEmpty) DetailRow('Edit this seat in the spec', null, icon: Icons.edit_outlined, onTap: _editSpec),
          ]),
        ],
        if (s.nodeId != null) ...[
          const SizedBox(height: 8),
          Row(children: [
            if (live) ...[
              Expanded(child: _danger('Kill session…', Icons.dangerous_outlined, _kill)),
              const SizedBox(width: 8),
            ],
            Expanded(child: _danger('Remove from rig…', Icons.delete_outline, _remove)),
          ]),
        ],
      ],
    );
  }

  Widget _danger(String label, IconData icon, VoidCallback onTap) => OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        style: OutlinedButton.styleFrom(
          foregroundColor: outlinedRed(Tokens.of(context)),
          side: BorderSide(color: outlinedRed(Tokens.of(context))),
          padding: const EdgeInsets.symmetric(horizontal: 8)).merge(sheetAction),
      );

  List<Widget> _now(Tokens k, Seat s, AgentDetails? d) {
    final jobs = _jobsList;
    final subs = _subagents;
    // Waiting, not idle: on its shells, or on subagents it left running at its prompt.
    final (:waiting, :idleSubs) = AgentJob.seatWaiting(s, jobs: jobs.length, subagents: subs.length);
    final task = currentTaskFor(s, widget.queue);
    final last = s.lastActivityAt ?? d?.lastActivityAt;
    // Asking: the card above says what for; this says only the state.
    final status = waiting
        ? AgentJob.waitingLine(jobs, idleSubs)
        : s.isAgent && !s.needsInput
            ? seatLine(s)
            : labelFor(s.state);
    final running = subs.where((a) => a.lastWrite == null || DateTime.now().difference(a.lastWrite!).inMinutes < 2);
    return [
      Section('Now', children: [
        DetailRow('Status', Text(status, style: TextStyle(fontSize: 13, color: waiting ? k.shell : _statusColor(k, s)))),
        if (d?.now != null) DetailRow('Running', Text(d!.now!, style: mono(context, size: 12, color: k.ink))),
        if (task != null || s.activeWorkCount > 0)
          DetailRow(
            'Task',
            Text.rich(
                TextSpan(children: [
                  TextSpan(text: task?.summary ?? 'none in progress', style: TextStyle(color: k.ink)),
                  if (s.activeWorkCount > (task == null ? 0 : 1))
                    TextSpan(
                        text: ' · ${s.activeWorkCount - (task == null ? 0 : 1)} queued',
                        style: TextStyle(color: k.muted)),
                ]),
                style: const TextStyle(fontSize: 13)),
            onTap: task == null ? null : () => showHandoff(context, task),
          ),
        if (jobs.isNotEmpty)
          DetailRow('Shells', Text(AgentJob.counts(jobs).join(' · '), style: TextStyle(fontSize: 13, color: k.shell)),
              onTap: s.sessionName == null && widget.onJobs == null ? null : _jobs),
        if (subs.isNotEmpty)
          DetailRow(
            'Subagents',
            Text('${subs.length}${running.isNotEmpty ? ' · ${running.length} running' : ''}',
                style: const TextStyle(fontSize: 13)),
            onTap: () => _showSubagents(subs),
          ),
        DetailRow('Last active', Text(last == null ? '—' : agoPhrase(last), style: TextStyle(fontSize: 13, color: k.muted))),
      ]),
    ];
  }

  Color _statusColor(Tokens k, Seat s) => Status.of(s.state).textColor(k);

  List<Widget> _model(Tokens k, Seat s, AgentDetails? d, bool live) {
    final model = s.model ?? d?.model;
    final pct = s.contextUsedPercent;
    final ctxTokens = d?.contextTokens;
    final tin = s.inputTokens, tout = s.outputTokens ?? d?.outputTokens;
    final mode = PermissionMode.fromWire(_mode);
    final canClear = s.isClaude && live;
    return [
      const SizedBox(height: 16),
      Section('Model & context', children: [
        DetailRow(
            'Model',
            Text(
                [if (model != null) modelLabel(model) else 'default', if (s.effort != null) 'effort ${s.effort}']
                    .join(' · '),
                style: const TextStyle(fontSize: 13))),
        DetailRow(
          'Permissions',
          Text.rich(
              TextSpan(children: [
                TextSpan(text: mode?.label ?? _mode ?? '—'),
                if (s.isClaude && live)
                  TextSpan(text: ' · only Auto switches live', style: TextStyle(color: k.muted, fontSize: 12)),
              ]),
              style: const TextStyle(fontSize: 13)),
          onTap: s.rigId.isEmpty ? null : _permissions,
        ),
        // A row like the others, its value on the right; the bar sits under it, in the same list item (no divider between).
        Column(mainAxisSize: MainAxisSize.min, children: [
        DetailRow(
          'Context',
          Text(
              [
                if (pct != null) '${pct.round()}%',
                if (ctxTokens != null) compactCount(ctxTokens),
                if (pct == null && ctxTokens == null) '—',
                if (pct != null && pct >= 80) compactsSoon,
              ].join(' · '),
              style: TextStyle(
                  fontSize: 13,
                  color: pct == null ? null : contextColor(pct, k),
                  fontWeight: pct == null ? null : contextWeight(pct))),
        ),
        if (pct != null) Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 8), child: ContextBar(pct)),
        ]),
        DetailRow(
            'Usage',
            Text(
                [
                  if (tin != null) 'in ${compactCount(tin)}',
                  if (tout != null) 'out ${compactCount(tout)}',
                  if (s.costUsd != null) '~\$${s.costUsd!.toStringAsFixed(2)}',
                  if (tin == null && tout == null && s.costUsd == null) '—',
                ].join(' · '),
                style: const TextStyle(fontSize: 13))),
        if (canClear)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _contextAction('compact'),
                  style: sheetAction,
                  child: const Text('Compact'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _contextAction('clear'),
                  style: sheetAction,
                  child: const Text('Clear context…'),
                ),
              ),
            ]),
          ),
      ]),
    ];
  }

  List<Widget> _code(Tokens k, Seat s, AgentDetails? d) {
    final git = _git;
    final files = d?.files ?? const <String, (int, int)?>{};
    final (add, del) = files.values.fold((0, 0), (a, e) => e == null ? a : (a.$1 + e.$1, a.$2 + e.$2));
    final prs = [
      for (final p in d?.prs ?? const <(String, Uri)>[])
        if (p.$2.toString() != git?.pr?.url) p
    ];
    final rows = <Widget>[
      DetailRow(
          'Worktree',
          Text(s.cwd == null ? '—' : (worktreeName(s.cwd) ?? 'main checkout'),
              style: mono(context, size: 12, color: k.ink))),
      if (git != null && git.isRepo)
        DetailRow(
          'Branch',
          Text(
              [
                git.branch ?? 'detached HEAD',
                if (git.upstream != null) '↑${git.ahead} ↓${git.behind}' else 'not pushed',
                '${git.changedFiles} changed',
              ].join(' · '),
              style: mono(context, size: 12, color: k.ink)),
          onTap: () => showGitSheet(context, git),
        )
      else if (s.cwd != null && !_gitTried && d == null)
        DetailRow('Branch', Text('Reading over SSH…', style: TextStyle(fontSize: 13, color: k.muted))),
      if (d != null)
        DetailRow(
          'This session',
          Text.rich(
              TextSpan(children: [
                TextSpan(text: '${files.length} ${files.length == 1 ? 'file' : 'files'}'),
                if (add + del > 0) ...[
                  const TextSpan(text: '  '),
                  TextSpan(text: '+$add', style: TextStyle(color: k.added, fontWeight: FontWeight.w600)),
                  const TextSpan(text: ' '),
                  TextSpan(text: '−$del', style: TextStyle(color: k.removed, fontWeight: FontWeight.w600)),
                ],
              ]),
              style: const TextStyle(fontSize: 13)),
        ),
      if (git?.pr case final pr?)
        DetailRow(
          'PR',
          Text('#${pr.number} ${pr.title} · ${prLine(pr)}', style: const TextStyle(fontSize: 13)),
          onTap: pr.url == null ? null : () => launchUrl(Uri.parse(pr.url!), mode: LaunchMode.externalApplication),
          external: true,
        ),
      for (final (title, url) in prs)
        DetailRow('Opened PR', Text(title, style: const TextStyle(fontSize: 13)),
            onTap: () => launchUrl(url, mode: LaunchMode.externalApplication), external: true),
      if (s.cwd != null) DetailRow('Folder', Text(displayPath(s.cwd!), style: mono(context, size: 12, color: k.muted))),
    ];
    return [
      const SizedBox(height: 16),
      Section('Code', children: rows),
      const SizedBox(height: 12),
    ];
  }
}

/// The seat's shape and name, and "rig · pod · runtime · worktree" under it.
class SeatHeader extends StatelessWidget {
  const SeatHeader({super.key, required this.rigName, required this.seat, this.trailing = const []});
  final String rigName;
  final Seat seat;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final s = seat;
    return Row(children: [
      StatusShape(Status.of(s.state), size: 12),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.logicalId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          Text(
            [
              rigName,
              if (s.podLabel != null) s.podLabel!,
              if (s.runtime != null) RuntimeGlyph.label(s.runtime).toLowerCase(),
              if (worktreeName(s.cwd) case final w?) 'worktree $w' else if (s.cwd != null) 'main checkout',
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontFamily: fontMono, fontSize: 11, color: k.muted),
          ),
        ]),
      ),
      ...trailing,
    ]);
  }
}

/// What a waiting seat asks and the answer buttons: the [AnswerBar] for a
/// permission, Reply… for a question. [onAnswered] after an answer goes out.
class SeatAskPanel extends StatefulWidget {
  const SeatAskPanel({super.key, required this.seat, this.onAnswered, this.onOpen});
  final Seat seat;
  final VoidCallback? onAnswered;

  /// Opens the seat where the whole question is (its chat or terminal).
  final VoidCallback? onOpen;
  @override
  State<SeatAskPanel> createState() => _SeatAskPanelState();
}

class _SeatAskPanelState extends State<SeatAskPanel> {
  bool _busy = false;

  Seat get _s => widget.seat;

  Future<bool> _press(SeatAnswer a) async {
    final host = AppScope.read(context).active;
    final api = AppScope.clientOf(context);
    if (host == null || api == null) return false;
    try {
      await answerSeat(host, _s, a);
      needsYouAlerts.answered(_s);
      return true;
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t reach the seat: $e');
      return false;
    }
  }

  Future<void> _run(Future<String?> Function() f) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final k = Tokens.of(context);
    try {
      final done = await f();
      if (done == null) return;
      toastOn(messenger, k, done);
      widget.onAnswered?.call();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _answer(SeatAnswer a, String done) async => await _press(a) ? done : null;

  Future<String?> _denyWithNote() async {
    final session = _s.sessionName!;
    final api = AppScope.clientOf(context);
    final note = await askReply(context, session);
    if (note == null || note.trim().isEmpty || !mounted) return null;
    if (!await _press(SeatAnswer.deny)) return null;
    await Future<void>.delayed(const Duration(milliseconds: 400)); // let the menu close
    try {
      await api?.send(session, note.trim());
      return 'Denied · told ${_s.logicalId}';
    } catch (e) {
      return 'Denied · couldn\'t send the note: $e';
    }
  }

  Future<String?> _allowAuto() async {
    final host = AppScope.read(context).active;
    final api = AppScope.clientOf(context);
    if (host == null || api == null || !await _press(SeatAnswer.allowOnce)) return null;
    await Future<void>.delayed(const Duration(milliseconds: 500)); // let the menu close
    try {
      await switchSeatToAuto(host, _s);
      await api.setPermissionMode(_s, PermissionMode.auto);
      return 'Allowed once · now in Auto';
    } catch (e) {
      return 'Allowed once · couldn\'t switch to Auto: $e';
    }
  }

  Future<String?> _reply() async {
    final session = _s.sessionName!;
    final text = await askReply(context, session);
    if (text == null || text.trim().isEmpty || !mounted) return null;
    try {
      await AppScope.clientOf(context)?.send(session, text.trim());
      return 'Sent to ${_s.logicalId}';
    } catch (e) {
      return 'Couldn\'t send: $e';
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final ask = PermissionAsk.from(_s);
    final since = _s.waitingSince == null ? '' : ' · ${ago(_s.waitingSince)}';
    if (ask.isPermission) {
      return PermissionCard(
        compact: true,
        who: _s.logicalId,
        ask: ask,
        trailing: since.isEmpty ? null : Text(since.substring(3), style: mono(context, size: 11)),
        answer: AnswerBar(
          busy: _busy,
          onDeny: () => _run(() => _answer(SeatAnswer.deny, 'Denied')),
          onAlways: () => _run(() => _answer(SeatAnswer.allowAlways, 'Always allowed')),
          alwaysScope: ask.alwaysScope,
          onAllow: () => _run(() => _answer(SeatAnswer.allowOnce, 'Allowed once')),
          onDenyWithNote: () => _run(_denyWithNote),
          onAllowAuto: _s.isClaude ? () => _run(_allowAuto) : null,
        ),
      );
    }
    final title = askLine(_s);
    return Panel(
      borderColor: k.accent,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('$title$since', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: k.accent)),
        ...[
          const SizedBox(height: 10),
          Row(children: [
            if (widget.onOpen != null) ...[
              Expanded(
                child: OutlinedButton(
                  onPressed: widget.onOpen,
                  style: sheetAction,
                  child: Text(_s.isClaude ? 'Open chat' : 'Open terminal'),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : () => _run(_reply),
                style: sheetAction,
                child: const Text('Reply…'),
              ),
            ),
          ]),
        ],
      ]),
    );
  }
}

