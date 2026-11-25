import 'package:flutter/material.dart';

import '../data/agent_jobs.dart';
import '../data/fleet.dart';
import '../main.dart';
import '../models.dart';
import '../data/subagents.dart';
import 'chat/jobs_view.dart' show JobsList;
import 'common.dart' show agoPhrase;
import 'subagent_open.dart';
import 'theme.dart';

/// The host feed for the active host, or null without one. The panes' counts read it: it is the scan the app already
/// runs, so they add no polling of their own.
HostFeed? panelFeed(BuildContext context) {
  final host = AppScope.read(context).active;
  return host == null ? null : fleet.feedFor(host);
}

/// [seat]'s running subagents, from [feed]'s last scan.
List<Subagent> subagentsIn(HostFeed? feed, Seat seat) => feed?.subagentsOf(seat) ?? const [];

/// How many shells [seat] has running (monitors count, helpers like MCP servers do not), from [feed]'s last scan.
int shellCountIn(HostFeed? feed, Seat seat) =>
    seat.sessionName == null ? 0 : (feed?.jobs[seat.sessionName] ?? const <AgentJob>[]).where((j) => j.isShell).length;

String _since(DateTime? t) => t == null ? 'running' : 'running · started ${agoPhrase(t)}';

/// The Subagents pane: what [parent] has running, each opening its own log as a chat ([onOpen] decides where it goes;
/// the default pushes it on the current navigator).
class SubagentsList extends StatelessWidget {
  const SubagentsList({super.key, required this.parent, required this.subagents, this.onOpen});
  final Seat parent;
  final List<Subagent> subagents;
  final void Function(Subagent)? onOpen;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    if (subagents.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text('No subagents running', style: TextStyle(fontSize: 12, color: k.muted)),
      );
    }
    return Column(children: [
      for (final s in subagents)
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: Icon(Icons.account_tree_outlined, size: 18, color: k.muted),
          title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text([if (s.type != null && s.description != null) s.type!, _since(s.started)].join(' · '),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, color: k.muted)),
          // One without a log yet has nothing to open: the parent is the screen already showing.
          onTap: !canOpenSubagent(s)
              ? null
              : () => (onOpen ?? (sub) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => subagentScreen(parent, sub))))(s),
        ),
    ]);
  }
}

/// The Shells pane: the same list as the chat's processes sheet, polled only while it is on screen.
class ShellsList extends StatelessWidget {
  const ShellsList({super.key, required this.seat, this.padding = const EdgeInsets.all(8)});
  final Seat seat;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final session = seat.sessionName;
    if (session == null) {
      return Padding(padding: padding, child: Text('No session to list shells for', style: TextStyle(fontSize: 12, color: k.muted)));
    }
    return Padding(
      padding: padding,
      child: JobsList(session: session, jobs: panelFeed(context)?.jobs[session] ?? const []),
    );
  }
}
