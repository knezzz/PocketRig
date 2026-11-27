import 'dart:async';

import '../data/projects.dart' show projectGroup;
import 'package:flutter/material.dart';

import '../data/agent_jobs.dart' show AgentJob, capShells;
import '../data/chat_cache.dart' show chatKey;
import '../data/fleet.dart';
import '../data/home_order.dart';
import '../data/usage_rings.dart' show usageNow;
import '../main.dart';
import '../models.dart';
import 'app_icon.dart';
import 'common.dart';
import 'desktop_shell.dart';
import 'host_color.dart';
import 'hosts/host_editor.dart' show HostEditor;
import 'kit.dart';
import 'loose_agent_screen.dart';
import 'new_sheet.dart' show NewKind, showNew;
import 'needs_you_banner.dart' show inboxRequests;
import 'page_column.dart';
import 'host_actions.dart' show showHostActions;
import 'usage_strip.dart' show HostUsageBar, HostUsageLine;
import 'project_actions.dart' show openShell, showProjectActions;
import 'project_screen.dart' show ProjectScreen;
import 'project_tally.dart';
import 'recent_screen.dart' show RecentScreen;
import 'rig/seats_tab.dart' show seatTask;
import 'chat_screen.dart' show seatScreen;
import 'shells_screen.dart';
import 'status_shape.dart';
import 'theme.dart';
import 'worktree_chip.dart';
import 'tiles_screen.dart' show rigHome;

/// A path as the host's person writes it: `/Users/me/code/app` and `/home/me/code/app` are `~/code/app`.
/// shortcut: the home is read from the path's first two parts (macOS and Linux), not asked of the host; a root user's
/// `/root` is left as it is.
String tildePath(String path) => path.replaceFirst(RegExp(r'^/(Users|home)/[^/]+'), '~');

/// A project's heading: its name and path, as the sidebar lists it (every folder an agent runs in is a project there, pinned
/// or not). Only agents with no folder at all ('(no folder)') are in no known project: named for what they are, with the
/// note 'not a known project'.
({String title, String sub, bool unknown}) projectHeading(Project p) => p.path == '(no folder)'
    ? (title: 'No folder', sub: 'not a known project', unknown: true)
    : (title: p.name, sub: tildePath(p.path), unknown: false);

/// A host's Claude usage as text, '5h 71% · week 34%' (empty with no reading): the phone's host header.
String usageText(Host host) => [
      for (final r in HostUsageBar.claudeReadings(host, HostUsageBar.clock()))
        '${r.label} ${r.usedPercent}%'
    ].join(' · ');

/// A folded host's number of active agents (needs you, working or on a shell, and structured questions) at the right of its
/// header, in the accent when any needs you: the sidebar's host header and the Rigs home's, one count ([hostActiveCounts]).
class HostActiveCount extends StatelessWidget {
  const HostActiveCount(this.host, {super.key, this.padded = true});
  final Host host;

  /// 6 before it (the Rigs home); the sidebar's NavRow adds its own.
  final bool padded;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final (:needs, :active) = hostActiveCounts(host);
    return Padding(
      padding: EdgeInsets.only(left: padded ? 6 : 0),
      child: Semantics(
        label: '$active active agents${needs > 0 ? ', $needs need you' : ''}',
        excludeSemantics: true,
        child: Text('$active',
            style: mono(context, size: 12, color: needs > 0 ? k.accent : k.muted, weight: needs > 0 ? FontWeight.w700 : FontWeight.w500)),
      ),
    );
  }
}

/// The moment the home measures recency against (the idle window, the loose agents' recency): the wall clock, or the one a
/// test pins for [ago], so a slow run cannot tip a fixture's 9-minute-old agent over the 10-minute line.
DateTime homeNow() => debugAgoClock ?? DateTime.now();

/// How urgent a seat is on the Rigs home: 0 needs you, 1 working, 2 on a shell, 3 idle (or stopped).
int seatTier(Seat s) => switch (s.state) {
      SeatState.needsYou => 0,
      SeatState.working => 1,
      SeatState.shell => 2,
      SeatState.idle || SeatState.stopped => 3,
    };

/// A rig's tier: its most urgent agent's (0 needs you, 1 working, 2 on a shell, 3 idle); the Rigs home and the sidebar order by it.
int rigTier(RigWithSeats r) {
  final tiers = [for (final s in r.seats) if (s.isAgent && s.state != SeatState.stopped) seatTier(s)];
  return tiers.isEmpty ? 3 : tiers.reduce((a, b) => a < b ? a : b);
}

/// A loose agent's tier, as [seatTier].
int looseTier(Host host, LooseAgent a) => switch (looseState(host, a)) {
      SeatState.needsYou => 0,
      SeatState.working => 1,
      SeatState.shell => 2,
      _ => 3,
    };

/// An agent's row is shown on its card when it needs you, works or is on a shell, or is idle but did something in the last
/// [idleWindow] (its last reply or hook event, never the pane's redraw); stopped agents and older idle ones fold into '+N idle'.
bool seatVisible(Seat s, DateTime now) =>
    s.isAgent &&
    s.state != SeatState.stopped &&
    (seatTier(s) < 3 || (s.lastActivityAt != null && now.difference(s.lastActivityAt!) <= idleWindow));

/// The Rigs home shows the Inbox as a column beside its cards from this content width, [inboxColumnWidth] wide.
const inboxColumnMinWidth = 900.0, inboxColumnWidth = 380.0;

/// The Rigs home: every enabled host at once (a host header, its usage and projects), each project's rigs as cards of
/// agent rows (needs you first), then the agents and shells running in that project outside a rig. The filter narrows to
/// the agents that need you or work; the host picker is a filter, All hosts by default. An unreachable host says so and
/// the others still load.
/// What a screen reader says for an agent's row on the home: its name and state, its context, and 'read only' when there is
/// no session to type into.
String seatRowLabel(Seat s) =>
    '${s.logicalId}, ${seatLabel(s)}${s.contextUsedPercent != null ? ', context ${s.contextUsedPercent!.round()} percent used' : ''}${s.sessionName == null ? ', read only' : ''}';

class RigsHome extends StatefulWidget {
  const RigsHome({super.key});
  @override
  State<RigsHome> createState() => _RigsHomeState();
}

class _RigsHomeState extends State<RigsHome> {
  Timer? _messages;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // The agents' last lines: read now and every 30s while the home is open (a feed reads at most every 45s).
    _messages = Timer.periodic(const Duration(seconds: 30), (_) => _loadMessages());
    // A held change of tier takes effect after 5 minutes without anything else changing: look again every 30s.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => mounted ? setState(() {}) : null);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMessages());
  }

  @override
  void dispose() {
    _messages?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  void _loadMessages() {
    if (!mounted) return;
    for (final h in AppScope.read(context).hosts) {
      fleet.feedFor(h).refreshMessages();
    }
  }

  /// One host's id, or null for All hosts.
  String? _host;

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context);
    final k = Tokens.of(context);
    // Live hosts first, offline ones after them (each group in the host list's order).
    final picked = [for (final h in store.hosts) if (_host == null || h.id == _host) h];
    fleet.sync(store.hosts);
    return Scaffold(
      body: ListenableBuilder(
        listenable: Listenable.merge([fleet, for (final h in picked) fleet.feedFor(h)]),
        builder: (context, _) {
          // Looked at on every change: a host going offline moves behind the live ones.
          final hosts = liveHostsFirst(picked);
          var needs = 0;
          for (final h in hosts) {
            needs += hostActiveCounts(h).needs; // agents, action items and structured questions: the badge's and the Inbox's number
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // The same page header as every other page: the title, the host picker and the + on its line; nothing is pinned under it.
            PageHeader(
              key: const ValueKey('rigs-bar'),
              title: 'Rigs',
              actions: [
                if (store.hosts.length > 1)
                  PopupMenuButton<String?>(
                    tooltip: 'Show rigs of',
                    initialValue: _host,
                    onSelected: (v) => setState(() => _host = v),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: null, child: Text('All hosts')),
                      for (final h in store.hosts) PopupMenuItem(value: h.id, child: Text(h.name)),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(border: Border.all(color: k.border), borderRadius: BorderRadius.circular(kRadius)),
                      child: Text(
                          '${_host == null ? 'All hosts' : store.hosts.firstWhere((h) => h.id == _host, orElse: () => store.hosts.first).name} ▾',
                          style: mono(context, size: 12, color: k.muted)),
                    ),
                  ),
                IconButton(tooltip: 'New…', onPressed: () => showNew(context), icon: const Icon(Icons.add)),
              ],
            ),
            Expanded(
              child: LayoutBuilder(builder: (context, box) {
                // A wide window: the cards in a column and the Inbox in its own column beside them (the strip is then not needed).
                final wide = box.maxWidth >= inboxColumnMinWidth;
                final list = RefreshIndicator(
                  key: const ValueKey('rigs-cards'),
                  onRefresh: () => Future.wait([for (final h in hosts) fleet.feedFor(h).refresh(scan: true)]),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    children: [
                      if (needs > 0 && !wide) _needsStrip(k, needs),
                      for (final h in hosts) ..._hostSection(context, h, many: store.hosts.length > 1, compact: !wide && box.maxWidth < 560),
                      if (_nothingListed(hosts)) _empty(context),
                    ],
                  ),
                );
                if (!wide) return PageColumn(child: list);
                return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  // The cards in a column of at most 640, the Inbox in its own column of 380 at the right edge.
                  Expanded(child: Align(alignment: Alignment.topLeft, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: list))),
                  VerticalDivider(width: 1, color: k.border),
                  const SizedBox(width: inboxColumnWidth, child: RecentScreen(column: true)),
                ]);
              }),
            ),
          ]);
        },
      ),
    );
  }

  /// "2 agents need you · Answer ›": the way into the Inbox, where they are answered.
  Widget _needsStrip(Tokens k, int n) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Semantics(
          button: true,
          label: '$n ${n == 1 ? 'agent needs' : 'agents need'} you, Answer',
          excludeSemantics: true,
          onTap: () => inboxRequests.value++,
          child: Material(
            color: k.accent.withValues(alpha: 0.10),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(kRadius), side: BorderSide(color: k.accent.withValues(alpha: 0.7))),
            child: InkWell(
              onTap: () => inboxRequests.value++,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(children: [
                  Icon(Icons.inbox_outlined, size: 18, color: k.accent),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text('$n ${n == 1 ? 'agent needs' : 'agents need'} you',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: k.ink))),
                  Text('Answer ›', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: k.accent)),
                ]),
              ),
            ),
          ),
        ),
      );

  /// The rigs of [p] that are running (a stopped rig is on the sidebar and the project page, not here).
  List<RigWithSeats> _runningRigs(Project p) => [for (final r in p.rigs) if (r.rig.status != 'stopped') r];

  /// The agents of [p] outside a rig, split into those worth a row (needs you, working, on a shell, or active in the last 10
  /// minutes) and the idle ones that fold into the project's '+N idle agents'. An agent's tier settles over 5 minutes like
  /// everything else on the home, so a flicker does not move it between the two.
  (List<LooseAgent> shown, List<LooseAgent> folded) _looseSplit(Host host, Project p) {
    final now = homeNow();
    final shown = <LooseAgent>[], folded = <LooseAgent>[];
    for (final a in p.loose) {
      final settled = homeOrder.tier('a:${host.id}|${a.id}', looseTier(host, a));
      (settled < 3 || looseRecent(host, a, now) ? shown : folded).add(a);
    }
    return (shown, folded);
  }

  List<LooseAgent> _looseShown(Host host, Project p) => _looseSplit(host, p).$1;

  /// A project's tier: its most urgent visible item. Null when it has none (only stopped rigs): it is not listed.
  int? _projectTier(Host host, Project p) {
    final tiers = [
      for (final r in _runningRigs(p)) rigTier(r),
      for (final a in _looseShown(host, p)) looseTier(host, a),
      if (_looseSplit(host, p).$2.isNotEmpty) 3,
      if (p.shells.isNotEmpty) 2,
    ];
    return tiers.isEmpty ? null : tiers.reduce((a, b) => a < b ? a : b);
  }

  /// When the longest-waiting ask of the project began (the order inside Needs you).
  DateTime? _askedSince(Project p) {
    final times = [
      for (final r in _runningRigs(p))
        for (final s in r.seats)
          if (s.state == SeatState.needsYou && s.waitingSince != null) s.waitingSince!
    ]..sort();
    return times.firstOrNull;
  }

  bool _nothingListed(List<Host> hosts) =>
      hosts.isNotEmpty &&
      hosts.every((h) {
        final f = fleet.feedFor(h);
        return f.loaded && f.error == null && !f.projects.any((p) => _projectTier(h, p) != null);
      });

  /// Nothing is running: a quiet note, with the ways to start something.
  Widget _empty(BuildContext context) {
    final k = Tokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 48),
      child: Column(children: [
        AppIcon(AppIconKind.rig, size: 36, color: k.faint),
        const SizedBox(height: 12),
        const Text('Nothing is running', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text('Stopped rigs and idle projects are under their host in the sidebar.',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: k.muted)),
        const SizedBox(height: 16),
        Wrap(spacing: 12, children: [
          FilledButton(onPressed: () => showNew(context, kind: NewKind.rig), child: const Text('New rig')),
          OutlinedButton(onPressed: () => showNew(context), child: const Text('New agent')),
        ]),
      ]),
    );
  }

  List<Widget> _hostSection(BuildContext context, Host host, {required bool many, bool compact = false}) {
    final k = Tokens.of(context);
    final feed = fleet.feedFor(host);
    final hc = hostTextColor(host, k);
    final headed = many || HostUsageBar.labelsFor(host).isNotEmpty;
    // A host folds only where it has a header to unfold it from.
    final folded = headed && fleet.hostFolded(host.id);
    final listed = [
      for (final p in feed.projects)
        if (_projectTier(host, p) != null) p
    ];
    // Tier, then name; the longest wait first among those needing you; a change of tier held 5 minutes (StableTiers).
    final now = homeNow();
    final projects = homeOrder.sorted<Project>(listed,
        key: (p) => 'p:${host.id}|${p.path}',
        raw: (p) => _projectTier(host, p)!,
        name: (p) => projectHeading(p).title,
        asked: (p) => _askedSince(p) ?? now);
    // Known projects, then other folders where something runs, the home folder last; the activity order is kept inside each.
    final ordered = [for (final g in [0, 1, 2]) ...projects.where((p) => projectGroup(p) == g)];
    return [
      if (many || HostUsageBar.labelsFor(host).isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 4),
          // The host's settings (its editor), in the content panel.
          child: InkWell(
            onTap: () => detailNavigator(context).push(MaterialPageRoute<void>(builder: (_) => HostEditor(host: host))),
            // The host's list (Rescan, Restore all stopped rigs): the ⋯, or a long press.
            onLongPress: () => showHostActions(context, host),
            child: Row(children: [
              Container(width: 10, height: 10, color: hostColor(host, Tokens.of(context))),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(host.name.toUpperCase(),
                      style: mono(context, size: 12, color: hc).copyWith(fontWeight: FontWeight.w700, letterSpacing: 1))),
              // Wide: the compact line the sidebar has (they lay out in a width of their own). On a phone: the text, '5h 71% · week 34%', at the right.
              if (compact)
                ValueListenableBuilder(
                  valueListenable: usageNow,
                  builder: (context, _, __) => Text(usageText(host), style: mono(context, size: 12, color: k.muted)),
                )
              else
                SizedBox(width: 190, child: HostUsageLine(host: host)),
              // Folded: the active agents on the host (needs you in the accent); the usage stays. One fold state per host, the
              // sidebar's too (fleet.hostFolded).
              if (folded && feed.error == null) Padding(padding: const EdgeInsets.only(right: 8), child: HostActiveCount(host)),
              IconButton(
                tooltip: 'Actions for ${host.name}',
                visualDensity: VisualDensity.compact,
                splashRadius: 16,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                onPressed: () => showHostActions(context, host),
                icon: Icon(Icons.more_horiz, size: 18, color: k.muted),
              ),
              IconButton(
                tooltip: folded ? 'Unfold ${host.name}' : 'Fold ${host.name}',
                visualDensity: VisualDensity.compact,
                splashRadius: 16, // the hover circle stays on the chevron, off the count
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                onPressed: () => fleet.toggleHost(host.id),
                icon: AnimatedRotation(
                    turns: folded ? 0 : 0.25,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(Icons.chevron_right, size: 18, color: k.muted)),
              ),
            ]),
          ),
        ),
      if (feed.error != null && !folded)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            Expanded(
                child: Text('${host.name} is offline · ${host.address}:${host.daemonPort}',
                    style: TextStyle(fontSize: 13, color: k.muted))),
            TextButton(onPressed: feed.refresh, child: const Text('Retry')),
          ]),
        ),
      if (!folded)
        for (final p in ordered) ..._project(context, host, p),
    ];
  }

  List<Widget> _project(BuildContext context, Host host, Project p) {
    final k = Tokens.of(context);
    final t = SeatTally(host, p.rigs, p.loose, project: p);
    final heading = projectHeading(p);
    final now = homeNow();
    final rigs = homeOrder.sorted<RigWithSeats>(_runningRigs(p),
        key: (r) => Fleet.rigKey(host, r),
        raw: rigTier,
        name: (r) => host.rigLabel(r.rig.name),
        asked: (r) => [for (final s in r.seats) if (s.state == SeatState.needsYou && s.waitingSince != null) s.waitingSince!].firstOrNull ?? now);
    final split = _looseSplit(host, p);
    final loose = homeOrder.sorted<LooseAgent>(split.$1,
        key: (a) => 'a:${host.id}|${a.id}', raw: (a) => looseTier(host, a), name: (a) => a.name);
    void more() {
      useHost(context, host);
      showProjectActions(context, p.path);
    }

    return [
      Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: InkWell(
          onTap: () {
            useHost(context, host);
            detailNavigator(context).push(MaterialPageRoute<void>(builder: (_) => ProjectScreen(path: p.path)));
          },
          onLongPress: more,
          child: Row(children: [
            // Orange when an agent needs you, green when some work, grey when it is empty or idle.
            AppIcon(AppIconKind.folder, size: 18, color: folderColor(k, needs: t.needs, working: t.working)),
            const SizedBox(width: 8),
            Flexible(child: Text(heading.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
            const SizedBox(width: 8),
            Expanded(
                child: Text(heading.sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 12, color: k.muted))),
            if (t.needs > 0) Text('${t.needs}', style: mono(context, size: 12, color: k.accent, weight: FontWeight.w700)),
            IconButton(
                tooltip: 'Actions for ${p.name}',
                visualDensity: VisualDensity.compact,
                onPressed: more,
                icon: Icon(Icons.more_horiz, size: 18, color: k.muted)),
          ]),
        ),
      ),
      for (final r in rigs) _rigCard(context, host, p, r),
      if (loose.isNotEmpty || p.shells.isNotEmpty || split.$2.isNotEmpty) _outsideRig(context, host, p, loose, split.$2),
    ];
  }

  Widget _rigCard(BuildContext context, Host host, Project p, RigWithSeats r) {
    final k = Tokens.of(context);
    // The card's tally, tint and icon come from its agents only: an ask in the queue is in the Inbox, and a header that says
    // 'needs you' over rows none of which does would contradict them.
    final counts = <Status, int>{};
    for (final s in r.seats) {
      if (s.isAgent && s.state != SeatState.stopped) counts[Status.of(s.state)] = (counts[Status.of(s.state)] ?? 0) + 1;
    }
    final needsYou = (counts[Status.needsYou] ?? 0) > 0;
    final now = homeNow();
    final key = Fleet.rigKey(host, r);
    // The agents of the card in tier then name order; the idle (not recent) and stopped ones fold into '+N idle'.
    List<Seat> ordered(Iterable<Seat> seats) => homeOrder.sorted<Seat>(seats,
        key: (s) => '$key/${s.logicalId}', raw: seatTier, name: (s) => s.logicalId, asked: (s) => s.waitingSince ?? now);
    final seats = ordered([for (final s in r.seats) if (seatVisible(s, now)) s]);
    final folded = ordered([for (final s in r.seats) if (s.isAgent && !seatVisible(s, now)) s]);
    final open = homeIdleOpen.contains(key);
    final allIdle = rigTier(r) == 3;
    final label = host.rigLabel(r.rig.name);
    Widget rows(List<Seat> list, {bool dim = false}) => ListenableBuilder(
          listenable: minuteTick,
          builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final s in list)
              AgentRow(
                name: s.logicalId,
                status: Status.of(s.state),
                runtime: s.runtime,
                needsYou: s.state == SeatState.needsYou,
                // Only when it runs in another worktree than its rig.
                extra: seatPlaceChip(s, r.primaryCwd),
                task: _said(host, s) ?? seatTask(s),
                age: s.lastActivityAt == null ? null : ago(s.lastActivityAt),
                context: s.contextUsedPercent,
                dim: dim,
                openLabel: seatRowLabel(s),
                onTap: () {
                  useHost(context, host);
                  detailNavigator(context).push(MaterialPageRoute(builder: (_) => seatScreen(r.rig.name, s)));
                },
              ),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      // A Container, not a DecoratedBox: it insets its child by the border, so the rows' own fills don't paint over it.
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: k.surface,
          border: Border.all(color: needsYou ? k.accent.withValues(alpha: 0.6) : k.border),
          borderRadius: BorderRadius.circular(kRadius),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Only the header takes the needs-you tint: each row below keeps the plain ground, so its own state reads.
          Material(
            color: needsYou ? k.accent.withValues(alpha: 0.08) : Colors.transparent,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(kRadius)),
            child: InkWell(
              borderRadius: BorderRadius.circular(kRadius),
              onTap: () {
                useHost(context, host);
                detailNavigator(context).push(MaterialPageRoute<void>(builder: (_) => rigHome(r, p.name)));
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Row(children: [
                  // The rig's state colours its icon (one rule, rigIconColor; with no host, its agents only, as the card's tally).
                  AppIcon(AppIconKind.rig, size: 22, color: rigIconColor(k, r, null)),
                  const SizedBox(width: 10),
                  // The name is what is scanned: it never gives way to the chip. On a narrow card the chip drops under it (same
                  // left edge); the name ellipsizes only when wider than the whole row.
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, box) => Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: box.maxWidth),
                            child: Text(label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: k.ink)),
                          ),
                          // Always on a rig card: the worktree it runs in.
                          if (r.primaryCwd != null) WorktreeChip(worktreeName(r.primaryCwd) ?? 'main'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (allIdle) Text('all idle', style: mono(context, size: 12, color: k.muted)) else StatusTally(counts),
                ]),
              ),
            ),
          ),
          rows(seats),
          if (folded.isNotEmpty) ...[
            if (open) rows(folded, dim: true),
            _foldLine(context, key, folded.length, 'idle', label),
          ],
        ]),
      ),
    );
  }

  /// What an agent last did or said, one line: its newest tool call ("EDIT lib/ui/kit.dart"), else its last reply's first
  /// line, from the chat logs the Inbox already reads. Null without a cached log (the row then says its state).
  String? _said(Host host, Seat s) {
    // An agent on a shell says what it waits on (the nested row below it), in the muted text.
    if (s.state == SeatState.shell) {
      final job = s.jobs.where((j) => j.isShell).firstOrNull;
      if (job != null) return 'waiting on ${job.short}';
      if (s.waitingSubagents > 0) return 'waiting on ${s.waitingSubagents == 1 ? 'a subagent' : '${s.waitingSubagents} subagents'}';
    }
    final m = fleet.feedFor(host).lastMessages[chatKey(s)];
    if (m == null) return null;
    if (m.tool != null && m.tool!.isNotEmpty) return m.tool;
    if (m.fromUser) return null;
    final line = m.text.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
    return line.isEmpty ? null : line;
  }

  void _openShells(BuildContext context, Host host, LooseAgent a, String project, AgentJob? tapped) {
    useHost(context, host);
    detailNavigator(context).push(MaterialPageRoute<void>(builder: (_) => ShellsScreen(host: host, seat: a.toSeat(), title: a.name, project: project, tapped: tapped)));
  }

  /// The agents running in the project outside a rig, with their subagents and shells nested, then the project's shells.
  Widget _outsideRig(BuildContext context, Host host, Project p, List<LooseAgent> loose, List<LooseAgent> folded) {
    final k = Tokens.of(context);
    final foldKey = 'a:${host.id}|${p.path}';
    final open = homeIdleOpen.contains(foldKey);
    Widget row(Status status, StatusKind kind, String title, String meta, {double indent = 0, String? age, VoidCallback? onTap, String? branch, String? runtime}) =>
        AgentRow(name: title, status: status, kind: kind, runtime: runtime, extra: branch, task: meta, age: age, indent: indent, onTap: onTap);
    // The idle agents (older than 10 minutes), dimmed, when the fold is open.
    List<Widget> idleRows() => [
          for (final a in folded)
            Opacity(
              opacity: 0.6,
              child: row(Status.of(looseState(host, a)), StatusKind.agent, a.name, looseStatus(a, null, jobsOfLoose(host, a), subagentsWaitingOf(host, a)),
                  age: a.lastActivityAt == null ? null : ago(a.lastActivityAt), runtime: a.runtime, branch: worktreeName(a.cwd), onTap: () {
                useHost(context, host);
                openLooseAgent(detailNavigator(context), a, p.rigs);
              }),
            ),
        ];
    // At most three shells under an agent, then '+N more'; each opens the agent's shells (live output and a Stop).
    List<Widget> shellRows(LooseAgent a) {
      final (:shown, :more) = capShells(jobsOfLoose(host, a));
      return [
        for (final j in shown)
          row(Status.working, StatusKind.shell, j.short, j.isMonitor ? 'monitor' : 'shell', indent: 32, age: ago(homeNow().subtract(j.elapsed)),
              onTap: () => _openShells(context, host, a, p.name, j)),
        if (more > 0) row(Status.working, StatusKind.shell, '+$more more', '', indent: 32, onTap: () => _openShells(context, host, a, p.name, null)),
      ];
    }

    final rows = <Widget>[
      for (final a in loose) ...[
        row(Status.of(looseState(host, a)), StatusKind.agent, a.name,
            looseStatus(a, null, jobsOfLoose(host, a), subagentsWaitingOf(host, a)),
            age: a.lastActivityAt == null ? null : ago(a.lastActivityAt),
            // Outside a rig the project's main checkout is the default: only another worktree is named.
            runtime: a.runtime, branch: worktreeName(a.cwd), onTap: () {
          useHost(context, host);
          openLooseAgent(detailNavigator(context), a, p.rigs);
        }),
        for (final sub in fleet.feedFor(host).subagentsOf(a.toSeat()))
          row(Status.working, StatusKind.subagent, sub.title, 'subagent',
              indent: 32, age: (sub.lastWrite ?? sub.started) == null ? null : ago(sub.lastWrite ?? sub.started)),
        ...shellRows(a),
      ],
      for (final sh in p.shells)
          row(Status.idle, StatusKind.shell, host.shellLabel(sh.name), 'shell in this project', onTap: () {
            useHost(context, host);
            openShell(context, sh);
          }),
      if (open) ...idleRows(),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: k.surface, border: Border.all(color: k.border), borderRadius: BorderRadius.circular(kRadius)),
        child: Column(children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, color: k.border),
            rows[i],
          ],
          if (folded.isNotEmpty) _foldLine(context, foldKey, folded.length, 'idle agents', p.name, divider: rows.isNotEmpty),
        ]),
      ),
    );
  }

  /// The '+N idle  show ▾' line at the foot of a card: the same for a rig's agents and a project's loose agents. The whole
  /// line taps; open it reads 'fewer ▴', and the state is remembered for the session under [key].
  Widget _foldLine(BuildContext context, String key, int count, String noun, String of, {bool divider = true}) {
    final k = Tokens.of(context);
    final open = homeIdleOpen.contains(key);
    void toggle() => setState(() => open ? homeIdleOpen.remove(key) : homeIdleOpen.add(key));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (divider) Divider(height: 1, color: k.border),
      Semantics(
        button: true,
        expanded: open,
        label: open ? 'Show fewer $noun of $of' : 'Show $count $noun of $of',
        excludeSemantics: true,
        onTap: toggle,
        child: InkWell(
          onTap: toggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: [
              Text(open ? '$count $noun' : '+$count $noun', style: mono(context, size: 11.5, color: k.muted)),
              const Spacer(),
              Text(open ? 'fewer ▴' : 'show ▾', style: mono(context, size: 11.5, color: k.muted)),
            ]),
          ),
        ),
      ),
    ]);
  }
}
