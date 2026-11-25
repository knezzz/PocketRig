import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/agent_jobs.dart';
import '../../data/fleet.dart';
import '../../main.dart';
import '../../ssh/ssh_exec.dart';
import '../kit.dart';
import '../theme.dart';

String _ago(Duration d) => d.inDays > 0
    ? '${d.inDays}d ${d.inHours % 24}h'
    : d.inHours > 0
        ? '${d.inHours}h ${d.inMinutes % 60}m'
        : d.inMinutes > 0
            ? '${d.inMinutes}m ${d.inSeconds % 60}s'
            : '${d.inSeconds}s';

/// Every process the agent started, refreshed every 3 s while open.
/// [onChanged] keeps the chat's shell pill in step.
Future<void> showJobsSheet(
        BuildContext context, List<AgentJob> jobs, String session, ValueChanged<List<AgentJob>> onChanged) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      // Short of full height, so the scrim stays tappable and the handle stays on screen however many jobs there are.
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      builder: (_) => _JobsSheet(jobs: jobs, session: session, onChanged: onChanged),
    );

class _JobsSheet extends StatelessWidget {
  const _JobsSheet({required this.jobs, required this.session, required this.onChanged});
  final List<AgentJob> jobs;
  final String session;
  final ValueChanged<List<AgentJob>> onChanged;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Text('Running processes', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('What $session started on the host. Updates every 3 seconds.', style: TextStyle(fontSize: 13, color: k.muted)),
          const SizedBox(height: 12),
          JobsList(session: session, jobs: jobs, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// The processes [session] started, each shell with its output and a Stop, helpers (MCP servers and others) below.
/// Refreshes every 3 s for as long as it is on screen: the sheet and the Shells pane both show it, so a closed or
/// folded pane (not built) polls nothing. [jobs] is what to show until the first refresh lands.
class JobsList extends StatefulWidget {
  const JobsList({super.key, required this.session, this.jobs = const [], this.onChanged});
  final List<AgentJob> jobs;
  final String session;
  final ValueChanged<List<AgentJob>>? onChanged;

  @override
  State<JobsList> createState() => _JobsListState();
}

class _JobsListState extends State<JobsList> {
  late var _jobs = widget.jobs;
  Future<SshExec>? _ssh;
  Timer? _poll;
  String? _error;

  /// Jobs being stopped, by pid; and how the last stop went (message, ok).
  final Set<int> _stopping = {};
  (String, bool)? _outcome;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
    // The list it opened with has one output line per job; fetch the tails now.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final host = AppScope.read(context).active;
    if (host == null) return;
    try {
      final ssh = await (_ssh ??= SshExec.connect(host));
      final jobs = await ssh.agentJobs(widget.session, lines: 20);
      if (!mounted) return;
      setState(() {
        _jobs = jobs;
        _error = null;
      });
      widget.onChanged?.call(jobs);
    } catch (e) {
      _dropSsh(); // reconnect on the next tick
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _stop(AgentJob j) async {
    final go = await confirmSheet(context,
        title: j.isMonitor ? 'Stop this monitor?' : 'Stop this shell?',
        body: '${j.short}\n\nIt and everything it started are stopped. '
            'The agent sees the command end and can carry on.',
        action: 'Stop');
    if (!go || !mounted) return;
    final host = AppScope.read(context).active;
    if (host == null) return;
    setState(() {
      _stopping.add(j.pid);
      _outcome = null;
    });
    (String, bool) outcome;
    try {
      final left = await (await (_ssh ??= SshExec.connect(host))).stopJob(j.pid);
      outcome = left == 0
          ? ('Stopped ${j.short}', true)
          : ('${j.short} is still running: $left ${left == 1 ? 'process' : 'processes'} didn\'t stop within 5 s.', false);
    } catch (e) {
      _dropSsh();
      outcome = ('Couldn\'t stop ${j.short}: $e', false);
    }
    // The home tab, rig and seat states read the host feed's scan, not this list: rescan it now.
    unawaited(fleet.feedFor(host).refresh());
    await _refresh();
    if (mounted) {
      setState(() {
        _stopping.remove(j.pid);
        _outcome = outcome;
      });
    }
  }

  /// Closes the connection (if it opened) so a failing tick doesn't leak one per retry.
  void _dropSsh() {
    _ssh?.then((s) => s.close(), onError: (_) {});
    _ssh = null;
  }

  @override
  void dispose() {
    _poll?.cancel();
    _dropSsh();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final shells = _jobs.where((j) => j.isShell).toList();
    final helpers = _jobs.where((j) => !j.isShell).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (_outcome case (final msg, final ok)) ...[
        Semantics(
          liveRegion: true,
          child: Row(children: [
            Icon(ok ? Icons.check_circle_outline : Icons.error_outline, size: 16, color: ok ? k.added : k.removed),
            const SizedBox(width: 6),
            Expanded(child: Text(msg, style: TextStyle(fontSize: 13, color: ok ? k.added : k.removed))),
          ]),
        ),
        const SizedBox(height: 8),
      ],
      if (_error != null) ...[
        Text('Couldn\'t refresh: $_error', style: TextStyle(fontSize: 13, color: k.removed)),
        const SizedBox(height: 8),
      ],
      if (shells.isEmpty)
        Text('No shells running. Everything it started has finished.', style: TextStyle(color: k.muted))
      else
        BorderedList(header: const Text('Shells'), children: [
          for (final j in shells) _JobRow(j, stopping: _stopping.contains(j.pid), onStop: () => _stop(j)),
        ]),
      if (helpers.isNotEmpty) ...[
        const SizedBox(height: 12),
        BorderedList(header: const Text('Helpers (MCP servers and others)'), children: [
          for (final j in helpers) _JobRow(j),
        ]),
      ],
    ]);
  }
}

class _JobRow extends StatelessWidget {
  const _JobRow(this.job, {this.onStop, this.stopping = false});
  final AgentJob job;
  final bool stopping;

  /// Shells only: helpers like MCP servers are the agent's own.
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final j = job;
    final bytes = j.outputBytes;
    final started = TimeOfDay.fromDateTime(DateTime.now().subtract(j.elapsed));
    final meta = [
      '${j.cpu.toStringAsFixed(j.cpu < 10 ? 1 : 0)}% CPU',
      if (j.children > 0) '${j.children} under it',
      if (bytes != null) bytes < 1024 ? '$bytes B out' : '${(bytes / 1024).toStringAsFixed(0)} KB out',
      'pid ${j.pid}',
    ].join(' · ');
    final lines = j.output.isNotEmpty ? j.output : [if (j.lastLine != null) j.lastLine!];
    return Semantics(
      container: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text(j.command,
                  maxLines: 3, overflow: TextOverflow.ellipsis, style: mono(context, size: 12, color: k.ink)),
            ),
            if (stopping) ...[
              const SizedBox(width: 8),
              Semantics(
                liveRegion: true,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: k.removed)),
                  const SizedBox(width: 6),
                  Text('Stopping…', style: TextStyle(fontSize: 13, color: k.removed, fontWeight: FontWeight.w600)),
                ]),
              ),
            ] else if (onStop != null) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: onStop,
                icon: const Icon(Icons.stop_circle_outlined, size: 16),
                label: const Text('Stop'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: k.removed,
                  side: BorderSide(color: k.removed),
                  padding: const EdgeInsets.symmetric(horizontal: 10)).merge(compactAction),
              ),
            ],
          ]),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: '${j.state[0].toUpperCase()}${j.state.substring(1)} for ${_ago(j.elapsed)}',
                  style: TextStyle(fontWeight: FontWeight.w600, color: j.state == 'running' ? k.accent : k.ink)),
              TextSpan(text: ' · since ${MaterialLocalizations.of(context).formatTimeOfDay(started)}'),
              if (j.isMonitor) const TextSpan(text: ' · monitor'),
            ]),
            style: TextStyle(fontSize: 13, color: k.muted),
          ),
          const SizedBox(height: 2),
          Text(meta, style: TextStyle(fontSize: 12, color: k.muted)),
          const SizedBox(height: 8),
          if (lines.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: k.fill, borderRadius: BorderRadius.circular(kRadius)),
              // Starts scrolled to the newest line.
              child: SingleChildScrollView(
                reverse: true,
                child: SelectableText(lines.join('\n'), style: mono(context, size: 11, color: k.ink)),
              ),
            )
          else
            Text(
                j.isMonitor
                    ? 'A monitor\'s output goes straight to the agent, so there\'s none to show here.'
                    : bytes == 0
                        ? 'No output yet.'
                        : 'Its output isn\'t written to a file the app can read.',
                style: TextStyle(fontSize: 12, color: k.muted)),
        ]),
      ),
    );
  }
}
