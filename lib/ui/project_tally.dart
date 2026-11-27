import 'package:flutter/material.dart';

import '../data/fleet.dart';
import '../data/needs_you.dart';
import '../models.dart';
import 'common.dart';
import 'status_shape.dart';
import 'theme.dart';

/// "3 rigs", "1 rig".
String countOf(int n, String one) => '$n ${n == 1 ? one : '${one}s'}';

/// A hand-started agent's state, as its row shows it.
SeatState looseState(Host? host, LooseAgent a) {
  if (looseGone(host, a)) return SeatState.stopped; // its tmux session is gone: greyed, not a live agent
  if (a.waiting) return SeatState.needsYou;
  // Working wins: on a shell means the agent itself is idle.
  if (a.isWorking(DateTime.now())) return SeatState.working;
  if (jobsOfLoose(host, a).isNotEmpty || subagentsWaitingOf(host, a) > 0) return SeatState.shell;
  return SeatState.idle;
}

/// Whether a hand-started agent is active (the same rule as a seat's: [Fleet.stateActive] over its row's state).
bool looseActive(Host? host, LooseAgent a) => Fleet.stateActive(looseState(host, a));

/// A host's needs-you count (agents and the daemon's action items, plus its structured questions) and its active count (those plus
/// working and on a shell): the number on a folded host's header, the sidebar's and the Rigs home's alike.
({int needs, int active}) hostActiveCounts(Host host) {
  final feed = fleet.feedFor(host);
  final t = SeatTally(host, [for (final r in feed.rigs) r], [for (final p in feed.projects) ...p.loose], wholeHost: true);
  final needs = t.needs + feed.coreAsks;
  return (needs: needs, active: needs + t.working + t.shell);
}

/// How long an idle agent stays listed after it last did something: 10 minutes, for rig seats and agents outside a rig alike (the
/// sidebar and the Rigs home). Older idle ones fold into '+N idle'.
const idleWindow = Duration(minutes: 10);

/// An agent outside a rig that is busy, or was active within [idleWindow].
bool looseRecent(Host? host, LooseAgent a, DateTime now) =>
    looseState(host, a) != SeatState.idle ||
    (a.lastActivityAt != null && now.difference(a.lastActivityAt!) <= idleWindow);

/// The agents that are up, by seat state: the one source for every tally on the Projects and Project screens,
/// so a host is the sum of its cards and a card the sum of its rig rows. With a [host], the daemon's action items
/// in scope add to [needs] (not to [up], they are not agents): those of the given [rigs], of the [project] (also
/// those naming only its folder), or of the [wholeHost].
/// A project folder's colour on the sidebar and the Rigs home: the accent (orange, which means "needs you") when any agent
/// there needs you, the working green when some work and none need you, grey otherwise.
Color folderColor(Tokens k, {required int needs, required int working}) =>
    needs > 0 ? k.accent : (working > 0 ? k.added : k.muted);

class SeatTally {
  SeatTally(Host? host, Iterable<RigWithSeats> rigs, Iterable<LooseAgent> loose,
      {Project? project, bool wholeHost = false}) {
    final asks = host == null
        ? const <NeedsYouItem>[]
        : fleet.feedFor(host).needsYouItems.where((i) =>
            i.action != null &&
            (wholeHost || (project != null ? i.inProject(project) : rigs.any(i.inRig))));
    final states = [
      for (final r in rigs)
        for (final s in r.seats)
          if (s.isAgent) s.state,
      for (final a in loose) looseState(host, a),
    ];
    int n(SeatState s) => states.where((x) => x == s).length;
    needs = n(SeatState.needsYou) + asks.length;
    _agentNeeds = n(SeatState.needsYou);
    working = n(SeatState.working);
    // Waiting on a shell or monitor: running, not needing the person, but not mid-turn either.
    shell = n(SeatState.shell);
    idle = n(SeatState.idle);
  }
  late final int needs, working, shell, idle, _agentNeeds;

  /// Agents up in any state.
  int get up => _agentNeeds + working + shell + idle;

  /// Per state, for [StatusTally] (zeros are hidden there).
  Map<Status, int> get counts =>
      {Status.needsYou: needs, Status.working: working, Status.shell: shell, Status.idle: idle};

  /// "2 need you · 3 working · 1 waiting on shell · 1 idle", zeros left out: what a screen reader hears.
  String words([String plain = '']) => [
        if (needs > 0) '$needs ${needs == 1 ? 'needs' : 'need'} you',
        if (working > 0) '$working working',
        if (shell > 0) '$shell waiting on shell',
        if (idle > 0) '$idle idle',
        if (plain.isNotEmpty) plain,
      ].join(' · ');
}

/// A rig's one shape: stopped, needs you (a waiting seat or an action item from it), working, only on shells, or idle.
Status rigStatus(RigWithSeats r, Host? host) {
  if (r.rig.status == 'stopped') return Status.stopped;
  final t = SeatTally(host, [r], const []);
  if (t.needs > 0) return Status.needsYou;
  if (t.working > 0) return Status.working;
  if (t.shell > 0) return Status.shell;
  return Status.idle;
}

/// The rig icon's colour, one rule on the sidebar, the Rigs home card and the rig page: a seat that failed to launch is red; else its
/// state's (needs you accent, working green, only on shells cyan); idle and stopped read muted (stopped's faint grey is under 3:1). With no [host] the daemon's action items
/// are not counted (the Rigs home card, whose tally is its agents only).
Color rigIconColor(Tokens k, RigWithSeats r, Host? host) {
  if (r.rig.status != 'stopped' && r.seats.any((s) => s.launchFailed)) return k.removed;
  final status = rigStatus(r, host);
  return status == Status.needsYou || status == Status.working || status == Status.shell ? status.color(k) : k.muted;
}

/// What a screen reader hears for a running rig's [RigCountLine].
String rigCountWords(Host? host, RigWithSeats r) {
  final t = SeatTally(host, [r], const []);
  return t.words([
    if (t.up == 0) 'no agents running',
    if (r.lastActivityAt case final at?) agoPhrase(at),
  ].join(' · '));
}

/// A running rig's tally (shapes with counts, zeros hidden), then how long since its last activity.
class RigCountLine extends StatelessWidget {
  const RigCountLine({super.key, required this.host, required this.rig, this.ago = true});
  final Host? host;
  final RigWithSeats rig;

  /// Ends with "· 3m ago".
  final bool ago;

  // Rebuilt by the minute tick, so its "Nm ago" ages on a quiet screen.
  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: minuteTick, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final k = Tokens.of(context);
    final t = SeatTally(host, [rig], const []);
    final at = rig.lastActivityAt;
    return Semantics(
      label: rigCountWords(host, rig),
      excludeSemantics: true,
      child: Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (t.up > 0)
          StatusTally(t.counts)
        else
          Text('no agents running', style: TextStyle(fontSize: 12, color: k.muted)),
        if (ago && at != null) Text(agoPhrase(at), style: TextStyle(fontSize: 12, color: k.faint)),
      ]),
    );
  }
}

/// A rig's name in mono, bold; cut with an ellipsis when it doesn't fit.
class RigName extends StatelessWidget {
  const RigName(this.name, {super.key});
  final String name;
  @override
  Widget build(BuildContext context) => Text(name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: mono(context, size: 13, color: Tokens.of(context).ink).copyWith(fontWeight: FontWeight.w600));
}
