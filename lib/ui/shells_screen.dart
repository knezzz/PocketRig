import 'package:flutter/material.dart';

import '../data/agent_jobs.dart';
import '../models.dart';
import 'agent_panels_live.dart' show panelFeed;
import 'chat/jobs_view.dart' show JobsList;
import 'kit.dart';
import 'page_column.dart';
import 'theme.dart';

/// An agent's shells on a page of their own: the Shells pane's list (each shell with its live output and a Stop). A shell row
/// in the sidebar or on the Rigs home opens it, since the dock and the phone's panels sheet cannot be opened on a pane from
/// outside. [title] is the agent's name; the breadcrumb under it is host · [project] › [rigName] (as the terminal's header).
///
/// The shell that was tapped ([tapped], from the host scan the rows come from) is shown first, with its command and how long
/// it has run; if the live list (polled from the host) does not have it, that card is what the page says (the scan saw it
/// running: the page never claims it 'finished').
class ShellsScreen extends StatefulWidget {
  const ShellsScreen({super.key, required this.host, required this.seat, required this.title, this.project, this.rigName, this.tapped});
  final Host host;
  final Seat seat;
  final String title;
  final String? project;

  /// Null for an agent outside a rig.
  final String? rigName;
  final AgentJob? tapped;

  @override
  State<ShellsScreen> createState() => _ShellsScreenState();
}

class _ShellsScreenState extends State<ShellsScreen> {
  /// The live list's last answer (null before the first).
  List<AgentJob>? _live;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final session = widget.seat.sessionName;
    final tapped = widget.tapped;
    // The row's shell is missing from what the host answers (or nothing has answered yet): say what the scan saw.
    final showTapped = tapped != null && (_live == null || !_live!.any((j) => j.pid == tapped.pid));
    final liveEmpty = _live != null && _live!.where((j) => j.isShell).isEmpty;
    final crumb = [if (widget.project != null) widget.project!, if (widget.rigName != null) widget.rigName!].join(' › ');
    return Scaffold(
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(title: '${widget.title} · shells', compact: true, inColumn: true, host: widget.host, overline: crumb.isEmpty ? null : crumb),
        Expanded(
          child: PageColumn(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (showTapped) _ScannedShell(tapped),
                if (session == null)
                  Text('No session to list shells for', style: TextStyle(fontSize: 12, color: k.muted))
                else
                  // Kept (offstage when it has nothing) so it keeps polling; its own 'finished' text is not shown over a
                  // shell the scan saw running.
                  Offstage(
                    offstage: showTapped && liveEmpty,
                    child: JobsList(
                      session: session,
                      jobs: panelFeed(context)?.jobs[session] ?? const [],
                      onChanged: (jobs) => mounted ? setState(() => _live = jobs) : null,
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

/// The tapped shell as the host scan saw it: its command and how long it has run.
class _ScannedShell extends StatelessWidget {
  const _ScannedShell(this.job);
  final AgentJob job;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final e = job.elapsed;
    final ran = e.inDays > 0 ? '${e.inDays}d ${e.inHours % 24}h' : e.inHours > 0 ? '${e.inHours}h ${e.inMinutes % 60}m' : '${e.inMinutes}m';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(border: Border.all(color: k.border), borderRadius: BorderRadius.circular(kRadius)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(job.short, style: mono(context, size: 13, color: k.ink).copyWith(fontWeight: FontWeight.w600))),
          Text('up $ran', style: mono(context, size: 12, color: k.muted)),
        ]),
        const SizedBox(height: 4),
        Text(job.isMonitor ? 'monitor · running · pid ${job.pid}' : 'shell · running · pid ${job.pid}',
            style: TextStyle(fontSize: 12, color: k.muted)),
      ]),
    );
  }
}
