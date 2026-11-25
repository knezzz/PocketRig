import 'usage_strip.dart' show compactsSoon, contextColor;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/agent_jobs.dart';
import '../data/fleet.dart';
import '../data/git_status.dart';
import '../data/loose_agents.dart' show remoteControlUrl;
import '../data/subagents.dart';
import '../main.dart';
import '../models.dart';
import '../ssh/ssh_exec.dart';
import 'common.dart';
import 'detail_row.dart';
import 'kit.dart';
import 'progress_bar.dart' show ContextBar;
import 'rig/seat_sheet.dart';
import 'theme.dart';

/// What the chat knows about its agent when the details open: the daemon's
/// seat, plus what the chat read from the log and over SSH.
class AgentDetails {
  AgentDetails({
    required this.seat,
    this.model,
    this.contextTokens,
    this.outputTokens,
    this.lastActivityAt,
    this.now,
    this.git,
    this.prs = const [],
    this.files = const {},
    this.jobs = const [],
    this.subagents = const [],
  });
  final Seat seat;

  /// From the log, for agents the daemon has no usage for.
  final String? model;
  final int? contextTokens;
  final int? outputTokens;
  final DateTime? lastActivityAt;

  /// The tool call running right now ("BASH flutter test").
  final String? now;
  final GitStatus? git;

  /// PRs this session opened: (title, url).
  final List<(String, Uri)> prs;

  /// Files this session changed, with lines added and removed.
  final Map<String, (int, int)?> files;
  final List<AgentJob> jobs;
  final List<Subagent> subagents;
}

/// The agent's model and context, usage, code and live activity, in four
/// sections. [onJobs] opens the running processes.
class AgentDetailsSections extends StatefulWidget {
  const AgentDetailsSections(this.details, {super.key, this.onJobs});
  final AgentDetails details;
  final VoidCallback? onJobs;

  @override
  State<AgentDetailsSections> createState() => _AgentDetailsSectionsState();
}

class _AgentDetailsSectionsState extends State<AgentDetailsSections> {
  String? _mode;

  @override
  void initState() {
    super.initState();
    // Only the daemon knows a seat's permission mode.
    if (widget.details.seat.rigId.isNotEmpty && widget.details.seat.isAgent) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          final m = await AppScope.clientOf(context)?.permissionMode(widget.details.seat);
          if (mounted) setState(() => _mode = m);
        } catch (_) {/* the row just stays hidden */}
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final d = widget.details;
    final s = d.seat;
    final model = s.model ?? d.model;
    final pct = s.contextUsedPercent;
    final ctx = d.contextTokens;
    final tokensIn = s.inputTokens, tokensOut = s.outputTokens ?? d.outputTokens;
    final git = d.git;
    final (add, del) = d.files.values.fold((0, 0), (a, e) => e == null ? a : (a.$1 + e.$1, a.$2 + e.$2));
    final last = s.lastActivityAt ?? d.lastActivityAt;
    // Waiting, not idle: on its shells, or on subagents it left running while at its prompt.
    final (:waiting, :idleSubs) = AgentJob.seatWaiting(s, jobs: d.jobs.length, subagents: d.subagents.length);

    Widget row(String label, Widget value, {VoidCallback? onTap}) =>
        DetailRow(label, value, onTap: onTap, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6));

    Widget text(String v, {bool isMono = false, Color? color}) =>
        Text(v, style: isMono ? mono(context, size: 12, color: color ?? k.ink) : TextStyle(fontSize: 13, color: color));
    Widget section(String title, List<Widget> rows) => Section(title, gap: 18, children: rows);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      section('Live activity', [
        row(
            'Status',
            text(
              waiting ? AgentJob.waitingLine(d.jobs, idleSubs) : labelFor(s.state),
              color: s.needsInput ? k.accent : (waiting ? k.shell : null),
            )),
        if (s.needsInput && s.needsInputReason != null) row('Asking', text(s.needsInputReason!, isMono: true)),
        if (d.now != null) row('Now', text(d.now!, isMono: true)),
        if (d.jobs.isNotEmpty)
          row(
            'Shells',
            Text('${AgentJob.counts(d.jobs).join(' · ')}${widget.onJobs == null ? '' : ' ›'}',
                style: TextStyle(
                    fontSize: 13, color: widget.onJobs == null ? k.muted : k.shell, fontWeight: FontWeight.w600)),
            onTap: widget.onJobs,
          ),
        if (d.subagents.isNotEmpty)
          row('Subagents', text('${d.subagents.length} · ${d.subagents.map((a) => a.title).join(', ')}')),
        row('Last active', text(last == null ? '—' : agoPhrase(last))),
      ]),
      section('Model & context', [
        row(
            'Model',
            text([if (model != null) modelLabel(model) else 'default', if (s.effort != null) '${s.effort} effort']
                .join(' · '))),
        if (_mode != null) row('Permissions', text(PermissionMode.fromWire(_mode)?.label ?? _mode!)),
        row(
          'Context',
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            text([
              if (pct != null) '${pct.round()}% used',
              if (ctx != null) '${compactCount(ctx)} tokens',
              if (pct == null && ctx == null) '—',
              if (pct != null && pct >= 80) compactsSoon,
            ].join(' · '), color: pct == null ? null : contextColor(pct, k)),
            if (pct != null) ...[const SizedBox(height: 6), ContextBar(pct)],
          ]),
        ),
      ]),
      section('Usage & cost', [
        row(
            'Tokens',
            text([
              if (tokensIn != null) 'in ${compactCount(tokensIn)}',
              if (tokensOut != null) 'out ${compactCount(tokensOut)}',
              if (tokensIn == null && tokensOut == null) '—',
            ].join(' · '))),
        row('Cost', text(s.costUsd == null ? '—' : '\$${s.costUsd!.toStringAsFixed(2)} (Claude\'s estimate)')),
      ]),
      section('Work & code', [
        row('Worktree', text(s.cwd == null ? '—' : (worktreeName(s.cwd) ?? 'main checkout'), isMono: true)),
        if (s.cwd != null) row('Folder', text(displayPath(s.cwd!), isMono: true)),
        if (git != null && git.isRepo)
          row(
              'Branch',
              text(
                  [
                    git.branch ?? 'detached HEAD',
                    if (git.upstream != null) '↑${git.ahead} ↓${git.behind}' else 'not pushed',
                    '${git.changedFiles} changed',
                  ].join(' · '),
                  isMono: true)),
        if (git?.pr case final pr?)
          row(
            'PR',
            Text('#${pr.number} ${pr.title} · ${prLine(pr)}',
                style: TextStyle(fontSize: 13, color: toneColor(k, statusTone(pr.state)))),
            onTap: pr.url == null ? null : () => launchUrl(Uri.parse(pr.url!), mode: LaunchMode.externalApplication),
          ),
        for (final (title, url) in d.prs.where((p) => p.$2.toString() != git?.pr?.url))
          row(
            'Opened PR',
            Text(title, style: TextStyle(fontSize: 13, color: k.accent)),
            onTap: () => launchUrl(url, mode: LaunchMode.externalApplication),
          ),
        row(
          'This session',
          Text.rich(
              TextSpan(children: [
                TextSpan(text: '${d.files.length} ${d.files.length == 1 ? 'file' : 'files'} changed'),
                if (add + del > 0) ...[
                  const TextSpan(text: '  '),
                  TextSpan(text: '+$add', style: TextStyle(color: k.added, fontWeight: FontWeight.w600)),
                  const TextSpan(text: ' '),
                  TextSpan(text: '−$del', style: TextStyle(color: k.removed, fontWeight: FontWeight.w600)),
                ],
              ]),
              style: const TextStyle(fontSize: 13)),
        ),
      ]),
    ]);
  }
}

/// Ends a rig seat's tmux session after asking; the seat stays in [rigName]
/// to relaunch. True when it's gone.
Future<bool> killSeatSession(BuildContext context, Seat seat, String rigName) async {
  final host = AppScope.read(context).active;
  final session = seat.sessionName;
  final messenger = ScaffoldMessenger.of(context);
  final k = Tokens.of(context);
  if (host == null ||
      session == null ||
      !await confirmSheet(context,
          title: 'Kill ${seat.logicalId}\'s session?',
          body: 'Ends the tmux session $session and any running tool, which can leave that work unfinished. '
              'The seat stays in $rigName; relaunch it from the rig.',
          action: 'Kill session')) {
    return false;
  }
  SshExec? ssh;
  try {
    ssh = await SshExec.connect(host);
    final gone = await ssh.killTmuxSession(session);
    toastOn(messenger, k, gone ? 'Killed $session' : 'tmux couldn\'t end $session. Check it at the host.');
    if (gone) unawaited(fleet.feedFor(host).refresh());
    return gone;
  } catch (e) {
    toastOn(messenger, k, 'Couldn\'t kill it: $e');
    return false;
  } finally {
    ssh?.close();
  }
}

/// Opens [seat]'s session in the Claude app through Remote Control.
Future<void> openInClaude(BuildContext context, Seat seat) async {
  final host = AppScope.read(context).active;
  final id = seat.resumeToken;
  if (host == null || id == null) return;
  try {
    final url = await remoteControlUrl(host, id);
    if (url == null) {
      if (context.mounted) toast(context, 'Remote Control is off for this session. Run /remote-control in it first.');
      return;
    }
    await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (e) {
    if (context.mounted) toast(context, 'Couldn\'t reach ${host.name}: $e');
  }
}

/// Takes [seat] out of [rigName] after asking. True when it's removed.
Future<bool> removeSeatFromRig(BuildContext context, Seat seat, String rigName) async {
  final api = AppScope.clientOf(context);
  final messenger = ScaffoldMessenger.of(context);
  final k = Tokens.of(context);
  if (api == null ||
      !await confirmSheet(context,
          title: 'Remove ${seat.logicalId}?',
          body: 'Takes the seat out of $rigName. Its session is shut down, including any running tool. '
              'Its queued work is not rerouted.',
          action: 'Remove')) {
    return false;
  }
  try {
    await api.removeSeat(seat.rigId, seat.logicalId);
    toastOn(messenger, k, 'Removed ${seat.logicalId}');
    return true;
  } catch (e) {
    toastOn(messenger, k, '$e');
    return false;
  }
}

/// A rig seat's details as a page: the seat sheet's content ([SeatSheetBody])
/// under a header. The sheet ([showSeatSheet]) is the usual way in; this
/// stays for callers that push a page.
class SeatDetailsScreen extends StatelessWidget {
  const SeatDetailsScreen(
      {super.key,
      required this.details,
      required this.rigName,
      this.onJobs,
      this.onTerminal,
      this.onOpenInClaude,
      this.onKilled});
  final AgentDetails details;
  final String rigName;
  final VoidCallback? onJobs;
  final VoidCallback? onTerminal;

  /// Opens the session in the Claude app (Remote Control).
  final VoidCallback? onOpenInClaude;

  /// After its session is killed or the seat removed (the chat closes too).
  final VoidCallback? onKilled;

  @override
  Widget build(BuildContext context) {
    final s = details.seat;
    return Scaffold(
      body: Column(children: [
        PageHeader(
          compact: true,
          title: s.logicalId,
          subtitle: Text(
              [rigName, if (s.podLabel != null) s.podLabel!, if (s.sessionName != null) s.sessionName!].join(' · '),
              style: mono(context),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
        Expanded(
          child: SeatSheetBody(
            rigName: rigName,
            seat: s,
            details: details,
            fromChat: true,
            showHeader: false,
            onJobs: onJobs,
            onTerminal: onTerminal,
            onOpenInClaude: onOpenInClaude,
            onGone: () {
              Navigator.of(context).maybePop();
              onKilled?.call();
            },
          ),
        ),
      ]),
    );
  }
}
