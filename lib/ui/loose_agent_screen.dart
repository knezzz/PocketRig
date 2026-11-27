import 'package:flutter/material.dart';

import '../api/openrig_client.dart';
import '../data/agent_jobs.dart';
import '../data/loose_agents.dart';
import '../data/projects.dart';
import '../data/fleet.dart';
import '../main.dart';
import '../models.dart';
import '../terminal/transport.dart';
import 'action_rows.dart';
import 'agent_details.dart';
import 'chat_screen.dart';
import 'answer_bar.dart';
import 'permission_card.dart' show PermissionCode;
import 'common.dart';
import 'project_tally.dart' show looseState;
import 'status_shape.dart';
import 'desktop_shell.dart';
import 'detail_row.dart';
import 'agent_view_switch.dart' show AgentView;
import 'kit.dart';
import 'open_agents_on.dart';
import 'rig/rig_host.dart' show rigRoute;
import 'terminal_screen.dart';
import 'theme.dart';

/// Agents a project has outside any rig, in a dashed card (board 7).
class LooseAgentList extends StatelessWidget {
  const LooseAgentList({super.key, required this.agents, this.rigs = const [], this.host});
  final List<LooseAgent> agents;

  /// The host the agents run on; made active before one opens.
  final Host? host;

  /// Rigs on the host, offered as adoption targets.
  final List<RigWithSeats> rigs;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return CustomPaint(
      foregroundPainter: DashedBorder(k.faint, radius: kRadius, width: 1),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(kRadius),
        child: Material(
          color: k.ground,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < agents.length; i++) ...[
              if (i > 0) Divider(color: k.divider),
              NeedsYouTint(on: agents[i].waiting, child: _LooseRow(agent: agents[i], rigs: rigs, host: host)),
            ],
          ]),
        ),
      ),
    );
  }
}

/// The line under an agent's name: what it's doing, not where it runs.
String looseStatus(LooseAgent a, [DateTime? at, List<AgentJob> jobs = const [], int subagents = 0]) {
  final now = at ?? DateTime.now();
  if (a.waiting) return 'needs you';
  // Working wins over on-shell, as in looseState: the text is the icon's state.
  if (a.isWorking(now)) return 'working';
  if (jobs.isNotEmpty || subagents > 0) return AgentJob.waitingLine(jobs, subagents);
  final since = a.activeAt ?? a.heardAt;
  if (since != null) return 'idle · ${ago(since, now)}';
  return a.meta;
}

class _LooseRow extends StatelessWidget {
  const _LooseRow({required this.agent, required this.rigs, this.host});
  final LooseAgent agent;
  final List<RigWithSeats> rigs;
  final Host? host;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final a = agent;
    final jobs = jobsOfLoose(host ?? AppScope.of(context).active, a);
    final subs = subagentsWaitingOf(host ?? AppScope.of(context).active, a);
    final k = Tokens.of(context);
    return RowTile(
      minHeight: 60,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      arrow: true,
      openLabel:
          '${a.name}, ${a.runtimeLabel}, not in a rig${a.inTmux ? '' : ', read only'}, ${looseStatus(a, null, jobs, subs)}',
      onTap: () {
        if (host != null) useHost(context, host!);
        openLooseAgent(detailNavigator(context), a, rigs);
      },
      leading: StatusIcon.agent(Status.of(looseState(host ?? AppScope.of(context).active, a)), runtime: a.runtime),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        // Not in tmux, so the app can't send it anything.
        if (!a.inTmux) ...[
          Tooltip(message: 'Read only: not in tmux', child: Icon(Icons.edit_off_outlined, size: 16, color: k.muted)),
          const SizedBox(width: 6),
        ],
        if (a.waiting) ...[const Pill('1', tone: Tone.hot, semanticsLabel: '1 need you'), const SizedBox(width: 6)],
        Text(agoOrDash(a.lastActivityAt), style: mono(context)),
      ]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Flexible(
              child: Text(a.name,
                  maxLines: 1,
                  style: t.bodyLarge?.copyWith(fontWeight: FontWeight.w500, height: 1.3),
                  overflow: TextOverflow.ellipsis)),
          if (worktreeName(a.cwd) case final worktree?) ...[
            const SizedBox(width: 6),
            Flexible(child: Pill(worktree, height: 18, bold: false, tone: Tone.outline)),
          ],
        ]),
        const SizedBox(height: 2),
        Text(
            [
              looseStatus(a, null, jobs, subs),
              if (subagentsOn(host ?? AppScope.of(context).active, a.toSeat()) case final s?) s
            ].join(' · '),
            style: t.bodySmall?.copyWith(color: a.waiting ? k.accent : (jobs.isNotEmpty || subs > 0 ? k.shell : null))),
      ]),
    );
  }
}

/// Opens an agent outside a rig as 'Open agents on' says (a Claude Code agent: its chat or terminal). One with no
/// chat opens its terminal when that is the setting and it runs in tmux, else its details screen. [chat] is the
/// explicit 'Chat' of a menu or link: the chat, whatever the setting.
void openLooseAgent(NavigatorState nav, LooseAgent a, List<RigWithSeats> rigs, {bool chat = false}) {
  final seat = a.toSeat();
  nav.push(MaterialPageRoute(
    builder: (_) => seat.isClaude
        ? ChatScreen(rigName: 'no rig', seat: seat, loose: a, rigs: rigs, asChat: chat)
        : a.inTmux && !chat && openAgentsOn.value == AgentView.terminal
            ? TerminalScreen(target: SeatTarget('no rig', seat))
            : LooseAgentScreen(agent: a, rigs: rigs),
  ));
}

/// One agent outside a rig: answer it, open it, or adopt it (board 7a).
class LooseAgentScreen extends StatefulWidget {
  const LooseAgentScreen(
      {super.key,
      required this.agent,
      this.rigs = const [],
      this.fromChat = false,
      this.details,
      this.onJobs,
      this.onOpenInClaude});
  final LooseAgent agent;
  final List<RigWithSeats> rigs;

  /// From its chat: model, context, usage, code and live activity.
  final AgentDetails? details;
  final VoidCallback? onJobs;

  /// Opens the session in the Claude app (Remote Control), from its chat.
  final VoidCallback? onOpenInClaude;

  /// Opened from the agent's chat menu: Open chat goes back to it.
  final bool fromChat;

  @override
  State<LooseAgentScreen> createState() => _LooseAgentScreenState();
}

class _LooseAgentScreenState extends State<LooseAgentScreen> {
  String? _answer;
  bool _busy = false;
  RigWithSeats? _rig;
  (String, String)? _pod; // podId, namespace
  late final _role = TextEditingController(text: tmuxSafe(widget.agent.name));
  String? _adopted;

  LooseAgent get a => widget.agent;

  /// Running rigs with a pod to join, in the agent's own worktree; failing that its project; failing that all.
  List<RigWithSeats> get _targets {
    final joinable = widget.rigs.where((r) => r.rig.status != 'stopped' && _pods(r).isNotEmpty).toList();
    // The agent's own folder first, as before the scoping.
    return [...adoptCandidates(joinable, a, AppScope.read(context).active?.pinnedFolders ?? const [])]
      ..sort((x, y) => (y.primaryCwd == a.cwd ? 1 : 0) - (x.primaryCwd == a.cwd ? 1 : 0));
  }

  static List<(String, String)> _pods(RigWithSeats r) => {
        for (final s in r.seats)
          if (s.podId != null && s.podNamespace != null) (s.podId!, s.podNamespace!),
      }.toList();

  @override
  void initState() {
    super.initState();
    final t = _targets;
    if (t.isNotEmpty) _pick(t.first);
  }

  @override
  void dispose() {
    _role.dispose();
    super.dispose();
  }

  void _pick(RigWithSeats r) {
    _rig = r;
    _pod = _pods(r).first;
  }

  Future<void> _reply(bool allow) async {
    final host = AppScope.read(context).active;
    if (host == null) return;
    setState(() => _busy = true);
    try {
      await answerLooseAgent(host, a, allow: allow);
      if (mounted) {
        setState(() => _answer = allow
            ? '✓ Allowed once · ${a.name} is running ${a.detail ?? 'it'}'
            : '✕ Denied · ${a.name} is waiting for instructions');
      }
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t answer: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _adopt() async {
    final api = AppScope.clientOf(context);
    final rig = _rig, pod = _pod, id = a.discoveryId;
    final role = tmuxSafe(_role.text);
    if (api == null || rig == null || pod == null || id == null || role.isEmpty) return;
    setState(() => _busy = true);
    try {
      final logicalId = await api.adopt(id, rigId: rig.rig.id, podId: pod.$1, podNamespace: pod.$2, memberName: role);
      if (mounted) setState(() => _adopted = logicalId);
    } on OpenRigException catch (e) {
      if (mounted) toast(context, e.message);
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t adopt: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _kill() async {
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    try {
      if (await killLooseAgent(context, a)) await nav.maybePop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openChat() => widget.fromChat
      ? Navigator.of(context).pop()
      : Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ChatScreen(rigName: 'no rig', seat: a.toSeat(), loose: a, rigs: widget.rigs, asChat: true)));

  void _openTerminal() => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TerminalScreen(target: SeatTarget('no rig', a.toSeat()))));

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final t = Theme.of(context).textTheme;
    final host = AppScope.of(context).active;
    final path = [a.project, host?.name].whereType<String>().join(' › ');
    final jobs = jobsOfLoose(host, a);
    final subs = subagentsWaitingOf(host, a);
    final status = looseStatus(a, null, jobs, subs);
    final what = a.tool != null ? '${a.tool} · ${a.detail ?? ''}' : (a.message ?? 'Waiting for your approval');

    Widget detail(String label, String value, {bool isMono = false}) => DetailRow(label,
        Text(value, style: isMono ? mono(context, size: 12, color: k.ink) : const TextStyle(fontSize: 13)),
        padding: const EdgeInsets.symmetric(vertical: 4));

    final targets = _targets;
    return Scaffold(
      body: Column(children: [
        PageHeader(
          host: AppScope.of(context).active,
          title: [a.name, if (worktreeName(a.cwd) != null) worktreeName(a.cwd)!].join(' · '),
          compact: true,
          // The pill sits with the folder, not against the ⋯ button.
          subtitle: Row(children: [
            Flexible(child: Text(path, style: mono(context), maxLines: 1, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            const Pill('not in a rig', tone: Tone.dashed),
          ]),
          actions: [
            IconButton(
              tooltip: 'Agent options',
              icon: const Icon(Icons.more_horiz),
              onPressed: () => showLooseActions(context, a,
                  onChat: _openChat,
                  onTerminal: _openTerminal,
                  onOpenInClaude: widget.onOpenInClaude,
                  onRenamed: () => setState(() {}),
                  onKilled: () => Navigator.of(context).maybePop()),
            ),
          ],
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 32), children: [
            Row(children: [
              StatusShape(Status.of(looseState(host, a))),
              const SizedBox(width: 10),
              Expanded(
                child: Text('${status[0].toUpperCase()}${status.substring(1)}${a.inTmux ? '' : ' · read only'}',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: a.waiting ? k.accent : (jobs.isNotEmpty || subs > 0 ? k.shell : null))),
              ),
              // The runtime's mark, named: it was an unexplained sunburst.
              Text(RuntimeGlyph.label(a.runtime), style: TextStyle(fontSize: 12, color: k.muted)),
              const SizedBox(width: 6),
              RuntimeGlyph(a.runtime),
            ]),
            const SizedBox(height: 14),
            if (a.waiting && _answer == null) ...[
              Panel(
                borderColor: k.accent,
                child: Semantics(
                  container: true,
                  label: 'Permission request',
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    // The heading above already says it needs you: no second title on the card.
                    PermissionCode(what),
                    const SizedBox(height: 8),
                    if (a.isPermission && a.inTmux) ...[
                      // The one answer bar: Deny on the left, Allow once on the right, as everywhere else.
                      AnswerBar(onAllow: () => _reply(true), onDeny: () => _reply(false), busy: _busy),
                      const SizedBox(height: 6),
                      Text('Sent as a keypress through tmux, like a rig seat.', style: t.bodySmall),
                    ] else
                      Text(
                          a.inTmux
                              ? 'Reply in the chat or the terminal.'
                              : 'Not in tmux, so answer it at the Mac. The chat shows what it is doing.',
                          style: t.bodySmall),
                  ]),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (_answer != null) ...[
              Panel(child: Text(_answer!, style: const TextStyle(fontSize: 13))),
              const SizedBox(height: 16),
            ],
            if (widget.details case final d?)
              AgentDetailsSections(d, onJobs: widget.onJobs)
            else ...[
              detail('Last active', a.lastActivityAt == null ? '—' : agoPhrase(a.lastActivityAt!)),
              if (jobs.isNotEmpty)
                detail('Running', AgentJob.describe(jobs), isMono: true)
              else if (a.activeCommand != null)
                detail('Running', a.activeCommand!, isMono: true),
              if (a.cwd != null) detail('Folder', displayPath(a.cwd!), isMono: true),
            ],
            const SizedBox(height: 8),
            Row(children: [
              if (a.runtime == 'claude-code')
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _openChat,
                    icon: const Icon(Icons.chat_bubble_outline, size: 18),
                    label: const Text('Chat'),
                    style: sheetAction,
                  ),
                ),
              if (a.runtime == 'claude-code' && a.inTmux) const SizedBox(width: 8),
              if (a.inTmux)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _openTerminal,
                    icon: const Icon(Icons.terminal, size: 18),
                    label: const Text('Terminal'),
                    style: sheetAction,
                  ),
                ),
            ]),
            if (widget.onOpenInClaude case final open?) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: open,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open in Claude'),
                style: sheetAction,
              ),
            ],
            if (canRestartInTmux(a.toSeat())) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => confirmRestartInTmux(context, a.toSeat()),
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Restart in tmux'),
                style: sheetAction,
              ),
              const SizedBox(height: 4),
              Text('Lets you message it from here. It restarts in tmux, in the same terminal tab.', style: t.bodySmall),
            ],
            const SizedBox(height: 12),
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: Column(children: [
                Divider(color: k.border, height: 1),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                  title: Semantics(header: true, child: const Text('Adopt into a rig')),
                  subtitle: Text('Becomes a seat: graph, queue, permission modes, snapshots.', style: t.bodySmall),
                  children: [
                    if (_adopted != null)
                      Panel(
                        borderColor: k.ink,
                        onTap: () => Navigator.of(context).pushReplacement(
                            MaterialPageRoute(builder: (_) => rigRoute(_rig!.rig, a.project ?? ''))),
                        child: Text('✓ ${a.name} is now $_adopted in ${_rig!.rig.name} · Open rig ›',
                            style: const TextStyle(fontSize: 14)),
                      )
                    else if (!a.canAdopt)
                      Text(
                          a.inTmux
                              ? 'The daemon hasn\'t seen this tmux session yet. Pull to refresh Projects to scan again.'
                              : 'Only agents running in tmux can join a rig. Start it inside tmux, then rescan.',
                          style: TextStyle(fontSize: 13, color: k.muted))
                    else if (targets.isEmpty)
                      Text('No running rig to join. Start a rig in ${a.project ?? 'this folder'} first.',
                          style: TextStyle(fontSize: 13, color: k.muted))
                    else ...[
                      for (final r in targets)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _Choice(
                            selected: _rig == r,
                            title: r.rig.name,
                            meta: [
                              '${r.rig.runningCount} of ${r.rig.nodeCount} seats running',
                              if (r.primaryCwd == a.cwd) 'same folder',
                            ].join(' · '),
                            onTap: () => setState(() => _pick(r)),
                          ),
                        ),
                      if (_rig != null && _pods(_rig!).length > 1) ...[
                        const SizedBox(height: 4),
                        Segmented<(String, String)?>(
                          values: _pods(_rig!),
                          labels: [for (final p in _pods(_rig!)) 'pod ${p.$2}'],
                          selected: _pod,
                          onChanged: (p) => setState(() => _pod = p),
                          semanticLabel: 'Pod',
                        ),
                        const SizedBox(height: 8),
                      ],
                      TextField(
                        controller: _role,
                        autocorrect: false,
                        enableSuggestions: false,
                        style: const TextStyle(fontFamily: fontMono, fontSize: 13),
                        decoration: InputDecoration(
                          labelText: 'Role',
                          prefixText: _pod != null ? '${_pod!.$2}.' : null,
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 10),
                      FilledButton(
                        onPressed: _busy || tmuxSafe(_role.text).isEmpty ? null : _adopt,
                        style: sheetAction,
                        child: Text('Adopt as ${tmuxSafe(_role.text)} in ${_rig?.rig.name ?? 'rig'}'),
                      ),
                    ],
                  ],
                ),
                Divider(color: k.border, height: 1),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Technical details'),
                  children: [
                    detail('Runtime',
                        switch (a.runtime) { 'claude-code' => 'Claude Code', 'codex' => 'Codex', _ => a.runtimeLabel }),
                    detail(
                        'Where',
                        a.inTmux
                            ? 'tmux ${a.tmuxSession}${a.tmuxPane != null ? ' (${a.tmuxPane})' : ''}'
                            : 'A terminal tab, not tmux',
                        isMono: a.inTmux),
                    detail(
                        'Seen',
                        [
                          if (a.since != null) 'started ${agoPhrase(a.since!)}',
                          [if (a.discoveryId != null) 'daemon scan', if (a.claudeSessionId != null) 'Claude hook']
                              .join(' + '),
                        ].where((s) => s.isNotEmpty).join(' · ')),
                  ],
                ),
                Divider(color: k.border, height: 1),
              ]),
            ),
          ]),
        ),
        // Once adopted it's a rig seat, and those stop with their rig.
        if (_adopted == null) KillBar([(looseGone(host ?? AppScope.read(context).active, a) ? 'Remove from list…' : 'Kill agent…', Icons.dangerous_outlined, _busy ? null : _kill)]),
      ]),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({required this.selected, required this.title, required this.meta, required this.onTap});
  final bool selected;
  final String title;
  final String meta;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? k.headerFill : k.ground,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadius),
          side: BorderSide(color: selected ? k.ink : k.border, width: selected ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadius),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    Text(meta, style: TextStyle(fontSize: 12, color: k.muted)),
                  ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks, then ends [a] (see [killAgent]). True when it was killed.
/// A name for the agent in the app only; empty clears it. True when it changed.
Future<bool> renameLooseAgent(BuildContext context, LooseAgent a) async {
  final store = AppScope.read(context);
  final host = store.active;
  if (host == null) return false;
  final name = await inputSheet(context,
      title: 'Rename',
      initial: a.label ?? '',
      hint: a.tmuxSession ?? a.runtimeLabel,
      helper: 'Only shown in this app',
      capitalization: TextCapitalization.sentences);
  if (name == null) return false;
  final clean = name.trim();
  a.label = clean.isEmpty ? null : clean;
  if (clean.isEmpty) {
    host.agentNames.remove(a.id);
  } else {
    host.agentNames[a.id] = clean;
  }
  await store.save();
  return true;
}

/// The one ⋯ list for an agent outside a rig, from its chat and from its screen. A callback is null on the screen
/// that already is that view.
Future<void> showLooseActions(BuildContext context, LooseAgent a,
        {VoidCallback? onChat,
        VoidCallback? onTerminal,
        VoidCallback? onDetails,
        VoidCallback? onOpenInClaude,
        VoidCallback? onRenamed,
        VoidCallback? onKilled}) =>
    showActionRows(
        context,
        a.name,
        looseActionRows(context, a,
            onChat: onChat,
            onTerminal: onTerminal,
            onDetails: onDetails,
            onOpenInClaude: onOpenInClaude,
            onRenamed: onRenamed,
            onKilled: onKilled));

/// The rows of [showLooseActions], for the command palette too.
ActionRows looseActionRows(BuildContext context, LooseAgent a,
        {VoidCallback? onChat,
        VoidCallback? onTerminal,
        VoidCallback? onDetails,
        VoidCallback? onOpenInClaude,
        VoidCallback? onRenamed,
        VoidCallback? onKilled}) =>
    (items: [
      if (onChat != null && a.runtime == 'claude-code') (Icons.chat_bubble_outline, 'Open chat', null, onChat),
      if (onTerminal != null && a.inTmux)
        (Icons.terminal_outlined, 'Open terminal', 'The agent\'s live pane, for anything the chat can\'t do', onTerminal),
      if (onDetails != null)
        (Icons.info_outline, 'Agent details', 'Model, context, usage, code and what it\'s doing', onDetails),
      if (onOpenInClaude != null) (Icons.open_in_new, 'Open in Claude', null, onOpenInClaude),
      if (canRestartInTmux(a.toSeat()))
        (Icons.restart_alt, 'Restart in tmux', 'Lets you message it from here', () => confirmRestartInTmux(context, a.toSeat())),
      (
        Icons.edit_outlined,
        'Rename',
        'Only shown in this app',
        () async {
          if (await renameLooseAgent(context, a)) onRenamed?.call();
        }
      ),
    ], danger: [
      (
        looseGone(AppScope.read(context).active, a) ? 'Remove from list…' : 'Kill agent…',
        Icons.dangerous_outlined,
        () async {
          if (await killLooseAgent(context, a)) onKilled?.call();
        }
      ),
    ]);

Future<bool> killLooseAgent(BuildContext context, LooseAgent a) async {
  final host = AppScope.read(context).active;
  final messenger = ScaffoldMessenger.of(context);
  final k = Tokens.of(context);
  // Its tmux session is gone: nothing runs to kill (the script stops nothing), the record is only cleared.
  final gone = looseGone(host, a);
  if (host == null ||
      !await confirmSheet(context,
          title: gone ? 'Remove ${a.name} from the list?' : 'Kill ${a.name}?',
          body: gone
              ? 'Its tmux session ${a.tmuxSession} is gone, so nothing is running. This only clears it from the list.'
              : 'This ends the agent and any running tool, which can leave that work unfinished. ${switch (a) {
            LooseAgent(inTmux: false) => 'Its terminal tab stays open.',
            LooseAgent(tmuxPane: null) => 'It closes the tmux session ${a.tmuxSession} and everything in it.',
            _ => 'It closes the agent\'s tmux pane.',
          }}',
          action: gone ? 'Remove' : 'Kill')) {
    return false;
  }
  try {
    await killAgent(host, a);
    toastOn(messenger, k, gone ? 'Removed ${a.name}' : 'Killed ${a.name}');
    // The daemon keeps listing a dead tmux session until its next scan.
    fleet.feedFor(host).refresh(scan: true).ignore();
    return true;
  } catch (e) {
    toastOn(messenger, k, '$e');
    return false;
  }
}
