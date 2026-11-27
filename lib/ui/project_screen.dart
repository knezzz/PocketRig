import 'dart:async';

import 'action_rows.dart' show showActionRows;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'page_column.dart';
import '../api/openrig_client.dart';
import '../data/fleet.dart';
import '../data/git_status.dart';
import '../data/loose_agents.dart' show answerLooseAgent;
import '../data/needs_you.dart' show attentionTarget;
import '../data/projects.dart' show withListedWorktrees;
import '../main.dart';
import '../models.dart';
import '../ssh/ssh_exec.dart';
import '../terminal/transport.dart';
import 'common.dart';
import 'desktop_shell.dart';
import 'kit.dart';
import 'launch_sheet.dart' show worktreeRigName;
import 'loose_agent_screen.dart';
import 'needs_you_banner.dart';
import 'new_session_sheet.dart';
import 'permission_card.dart';
import 'project_files.dart' show ProjectFilesScreen;
import 'seat_leaf.dart' show SeatLeaf;
import 'rig/overview_tab.dart' show CountTile;
import 'project_actions.dart';
import 'project_tally.dart';
import 'status_shape.dart';
import 'theme.dart';
import 'busy.dart';
import 'rig/rig_actions.dart';
import 'rig/rig_host.dart' show rigRoute;
import 'tiles_screen.dart' show rigHome;
import 'spec_screen.dart';
import 'terminal_screen.dart';
import 'project/specs.dart';
import 'project/worktree_delete.dart';
import 'project/worktree_rows.dart';
import 'project/worktree_screen.dart';

// What used to be defined here keeps its import path.
export 'project/worktree_screen.dart' show WorktreeScreen, openWorktreeScreen;

/// One project folder on one scroll, in the order you act: what needs you, then what runs in each worktree,
/// stopped rigs, the rig specs to start, and the folder's latest pull requests. Shell and New are the page's
/// only actions; the rest sits in ⋯ menus.
class ProjectScreen extends StatefulWidget {
  const ProjectScreen({super.key, required this.path, this.tab = 0});
  final String path;

  /// The view it opens on (the demo's Shells tab).
  final int tab;
  @override
  State<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends State<ProjectScreen> with Polling {
  List<SpecEntry>? _specs;
  String? _specError;
  final Set<String> _busy = {};
  late int _tab = widget.tab;

  /// From `git worktree list`, main checkout first; null until loaded.
  /// What git listed, read with the page.
  List<Worktree>? _gitWorktrees;

  /// The worktrees git did not list that the path rule finds (a stale list, or git not asked yet): kept as one object each so
  /// a group and its rows agree.
  final Map<String, Worktree> _byPath = {};

  /// git's list, plus a worktree for each `.claude/worktrees/<name>` (or `.worktrees`) that something here runs in and git
  /// does not list, so a rig never loses its worktree header to a stale list. Null until git has answered.
  List<Worktree>? get _worktrees {
    final git = _gitWorktrees;
    if (git == null) return null;
    final base = _baseProject;
    if (base == null) return git;
    final cwds = [
      for (final r in base.rigs) for (final s in r.seats) s.cwd,
      for (final a in base.loose) a.cwd,
      for (final sh in base.shells) sh.cwd,
    ];
    final extra = <Worktree>[];
    for (final cwd in cwds) {
      final root = worktreeRoot(cwd);
      if (root == null || git.any((w) => isUnder(cwd!, w.path) && w.path != git.first.path) || extra.any((w) => w.path == root)) continue;
      extra.add(_byPath.putIfAbsent(root, () => Worktree(root, null)));
    }
    return extra.isEmpty ? git : [...git, ...extra];
  }

  /// The GitHub repo URL and its latest PRs, when `gh` knows the folder.
  (String, List<PullRequest>)? _github;

  /// The folder's absolute path on the host, so a pinned `~/…` folder
  /// matches the absolute cwd the daemon reports for its rigs.
  String? _absPath;

  String get _name => folderName(widget.path);

  @override
  void initState() {
    super.initState();
    busyKeys.addListener(_onBusy);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadSpecs();
    });
  }

  /// A rig's action from any trigger: its row shows the spinner.
  void _onBusy() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    busyKeys.removeListener(_onBusy);
    super.dispose();
  }

  /// This folder as the Projects card has it: the feed's own grouping, so a rig or agent belongs here exactly when
  /// the card lists it, with the same seats (and shell marks) and so the same numbers and badge.
  Project? get _baseProject {
    final host = AppScope.read(context).active;
    return host == null ? null : fleet.feedFor(host).projects.where((p) => p.path == widget.path).firstOrNull;
  }

  Project? get _project {
    final project = _baseProject;
    final listed = _gitWorktrees;
    // A worktree outside .claude/worktrees (git worktree add ../x) is a project of its own to the path rule; git's own list,
    // which this page has read, says it is this project's.
    if (project == null || listed == null || listed.length < 2) return project;
    final host = AppScope.read(context).active!;
    return withListedWorktrees(project, fleet.feedFor(host).projects, [for (final w in listed.skip(1)) w.path]);
  }

  List<RigWithSeats> get _rigs => _project?.rigs ?? const [];

  @override
  Future<void> load() async {
    final host = AppScope.read(context).active;
    if (host == null) return;
    await fleet.feedFor(host).refresh();
  }

  /// Specs come from the host's disk, so they need SSH (not the daemon).
  Future<void> _loadSpecs() async {
    final host = AppScope.read(context).active;
    if (host == null) return;
    setState(() {
      _specs = null;
      _specError = null;
    });
    SshExec? ssh;
    try {
      ssh = await SshExec.connect(host);
      if (widget.path.startsWith('~')) {
        final abs = await ssh.resolve(widget.path);
        if (abs.isNotEmpty && mounted) {
          setState(() => _absPath = abs);
          load();
        }
      }
      final worktrees = await ssh.worktrees(widget.path).catchError((_) => <Worktree>[]);
      if (mounted) {
        setState(() => _gitWorktrees = worktrees);
        load(); // rigs in worktrees outside the folder only match once these are known
      }
      final github = await ssh.github(widget.path).catchError((_) => null);
      if (mounted) setState(() => _github = github);
      final (entries, failed) = await readSpecs(ssh, host, widget.path, _absPath);
      if (mounted) {
        setState(() {
          _specs = entries;
          if (failed != null) _specError = 'Couldn\'t list specs over SSH: $failed';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _specError = 'Couldn\'t list specs over SSH: $e');
    } finally {
      ssh?.close();
    }
  }

  /// One group per spec, see [groupSpecs].
  List<List<SpecEntry>> get _specGroups => groupSpecs(_specs ?? const []);

  /// Starts another copy of a running rig in a different worktree, under its
  /// own name, from that worktree's copy of the spec when it has one.
  Future<void> _startInWorktree(RigWithSeats r) async {
    final copies = _specGroups.where((c) => c.first.summary.name == r.rig.name).firstOrNull;
    if (copies == null) {
      toast(context, 'No spec for ${r.rig.name} in this folder.', kind: ToastKind.info);
      return;
    }
    final all = _worktrees ?? const <Worktree>[];
    final current = all.where((w) => _runsIn(w, r.primaryCwd)).firstOrNull;
    final others = [
      for (final w in all)
        if (!identical(w, current)) w
    ];
    if (others.isEmpty) {
      // Nowhere to start it yet: the same sheet as everywhere makes one.
      _newWorktree();
      return;
    }
    String label(Worktree w) => identical(w, all.first) ? 'Main checkout' : w.name;
    final w = await showModalBottomSheet<Worktree>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            SectionLabel('Start ${r.rig.name} in'),
            BorderedList(children: [
              for (final w in others)
                RowTile(
                  title: label(w),
                  meta: w.branch ?? 'detached HEAD',
                  metaMono: true,
                  trailing: const Chevron(),
                  onTap: () => Navigator.pop(ctx, w),
                ),
            ]),
          ]),
        ),
      ),
    );
    if (w == null || !mounted) return;
    final spec = copies.where((c) => c.file.worktree == w.name).firstOrNull ?? copies.first;
    _push(SpecScreen(
      file: spec.file,
      text: spec.text,
      projectName: _name,
      previewNow: true,
      cwd: w.path,
      rigName: worktreeRigName(r.rig.name, identical(w, all.first) ? 'main' : w.name),
      worktrees: all,
    ));
  }

  /// Starts a rig in worktree [w], see [startRigInWorktree].
  Future<void> _startRigIn(Worktree w, {required bool main}) => startRigInWorktree(context,
      w: w,
      main: main,
      projectName: _name,
      specGroups: _specGroups,
      worktrees: _worktrees ?? const [],
      push: _push);

  /// Delete worktree: a confirm that says what is lost (uncommitted files) and what still runs there, then git worktree
  /// remove (--force only after "Delete anyway"). The branch stays; the main checkout never gets this.
  Future<void> _removeWorktree(Worktree w) async {
    final host = AppScope.read(context).active;
    final main = _worktrees?.firstOrNull;
    if (host == null || main == null || identical(w, main)) return;
    final here = _runsIn;
    final agentNames = [
      for (final r in _rigs) for (final s in r.seats) if (s.isAgent && s.state != SeatState.stopped && here(w, s.cwd)) s.logicalId,
      for (final a in _project?.loose ?? const <LooseAgent>[]) if (here(w, a.cwd)) a.name,
    ];
    final shellNames = [for (final sh in _project?.shells ?? const <ProjectShell>[]) if (here(w, sh.cwd)) host.shellLabel(sh.name)];
    final done = await deleteWorktree(context,
        host: host, repo: main.path, w: w, name: w.name, agents: agentNames, shells: shellNames);
    if (done && mounted) await load();
  }

  /// Clears worktrees whose folder is gone from git's list (`git worktree prune` in the repo): the way out for a missing one, which
  /// can't be deleted since there is nothing to delete.
  Future<void> _clearMissing(Worktree w) async {
    final host = AppScope.read(context).active;
    final main = _worktrees?.firstOrNull;
    if (host == null || main == null || identical(w, main)) return;
    setState(() => _busy.add(w.path));
    SshExec? ssh;
    try {
      ssh = await SshExec.connect(host);
      await ssh.pruneWorktrees(main.path);
      if (mounted) await load();
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t clear ${w.name}: ${e is OpenRigException ? e.message : e}', kind: ToastKind.problem);
    } finally {
      ssh?.close();
      if (mounted) setState(() => _busy.remove(w.path));
    }
  }

  /// Deny or Allow once on a waiting seat, without opening it.
  Future<void> _answerSeat(Seat s, {required bool allow}) async {
    final host = AppScope.read(context).active;
    final api = AppScope.clientOf(context);
    if (host == null || api == null) return;
    final key = 'answer:${s.rigId}/${s.logicalId}';
    setState(() => _busy.add(key));
    try {
      await answerSeat(host, s, allow ? SeatAnswer.allowOnce : SeatAnswer.deny);
      if (mounted) {
        toast(context, allow ? 'Allowed ${s.logicalId} once' : 'Denied ${s.logicalId}', kind: ToastKind.done);
      }
      await load();
    } catch (e) {
      if (mounted) {
        toast(context, 'Couldn\'t answer ${s.logicalId}: ${e is OpenRigException ? e.message : e}',
            kind: ToastKind.problem);
      }
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  /// Deny or Allow once on a waiting agent outside a rig, at its tmux pane.
  Future<void> _answerLoose(LooseAgent a, {required bool allow}) async {
    final host = AppScope.read(context).active;
    if (host == null) return;
    final key = 'answer:${a.id}';
    setState(() => _busy.add(key));
    try {
      await answerLooseAgent(host, a, allow: allow);
      if (mounted) toast(context, allow ? 'Allowed ${a.name} once' : 'Denied ${a.name}', kind: ToastKind.done);
      unawaited(fleet.feedFor(host).refresh(scan: true));
    } catch (e) {
      if (mounted) {
        toast(context, 'Couldn\'t answer ${a.name}: ${e is OpenRigException ? e.message : e}', kind: ToastKind.problem);
      }
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  void _launch(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  void _push(Widget w) => detailNavigator(context).push(MaterialPageRoute(builder: (_) => w));

  /// shortcut: only the latest PRs are fetched, so an older branch's PR isn't shown.
  PullRequest? _prOf(Worktree w) => _github?.$2.where((p) => p.headRef != null && p.headRef == w.branch).firstOrNull;

  void _openWorktree(Worktree w) => _push(WorktreeScreen(
        worktree: w,
        isMain: identical(w, _worktrees?.first),
        projectName: _name,
        projectPath: widget.path,
        pr: _prOf(w),
        contains: (cwd) => _runsIn(w, cwd),
      ));

  /// Whether [cwd] runs in [w]: in the deepest worktree git lists for this project that holds it (so one outside
  /// `.claude/worktrees` counts), else in the main checkout when it is in the folder and is not a worktree by its path.
  bool _runsIn(Worktree w, String? cwd) {
    final all = _worktrees;
    if (cwd == null || all == null) return false;
    Worktree? inner;
    for (final x in all.skip(1)) {
      if (isUnder(cwd, x.path) && (inner == null || x.path.length > inner.path.length)) inner = x;
    }
    if (inner != null) return identical(inner, w);
    return identical(w, all.firstOrNull) && isUnder(cwd, widget.path) && worktreeName(cwd) == null;
  }

  /// [r] when it belongs where [there] says: the folder most of its seats run in. A rig is in one place with all its seats
  /// (a seat elsewhere gets a chip), so it is never cut to the seats that happen to be here.
  RigWithSeats? _rigHere(RigWithSeats r, bool Function(String? cwd) there) => there(r.primaryCwd) ? r : null;

  void _openLoose(LooseAgent a, HostFeed? feed) {
    if (feed != null) useHost(context, feed.host);
    openLooseAgent(detailNavigator(context), a, feed?.rigs ?? const []);
  }

  /// The New worktree sheet, on this project's host; the worktree list reloads and the new one's page opens.
  void _newWorktree() {
    final host = AppScope.read(context).active;
    if (host == null) return;
    newWorktree(context, host, widget.path, () {
      if (mounted) _loadSpecs();
    });
  }

  void _projectMenu() => showProjectActions(context, widget.path, onChanged: () {
        if (mounted) _loadSpecs();
      });

  void _rigMenu(RigWithSeats r, String label) => showRigActions(context, r.rig, r.seats,
      title: label,
      projectName: _name,
      onOpen: () => _push(rigRoute(r.rig, _name, seats: r.seats)),
      onWorktree: () => _startInWorktree(r));

  void _worktreeMenu(Worktree w, bool main, int agents) => showActionRows(context, main ? 'Main checkout' : w.name, (items: [
        (
          Icons.hub_outlined,
          'Start a rig here…',
          _specGroups.isEmpty ? 'No specs in this project' : 'From one of this project\'s specs',
          _specGroups.isEmpty ? null : () => _startRigIn(w, main: main)
        ),
        (Icons.add_comment_outlined, 'New agent here', null, () => startAgentInFolder(context, w.path)),
        (Icons.terminal_outlined, 'Shell here', null, () => _push(TerminalScreen(target: ProjectShellTarget(w.path)))),
        (Icons.folder_open_outlined, 'Open worktree', w.branch, () => _openWorktree(w)),
      ], danger: [
        if (!main) ('Delete worktree…', Icons.delete_outline, () => _removeWorktree(w)),
      ]));

  /// A section label with a link that jumps to another tab ("All agents ›").
  Widget _labelWithJump(String text, String link, int tab) => Row(children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(text.toUpperCase(), style: sectionLabelStyle(context)),
          ),
        ),
        TextButton(
          onPressed: () => setState(() => _tab = tab),
          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4)),
          child: Text('$link ›'),
        ),
      ]);

  /// A daemon action item addressed to the person. It opens the seat that asked, as the Inbox card does; with no
  /// asker there is nobody to open, so the row has no Answer and no tap.
  Widget _actionRow(AttentionItem i, HostFeed? feed) {
    final target = attentionTarget(feed?.rigs ?? const [], i);
    return NeedsRow(
      title: i.asker ?? 'OpenRig',
      detail: i.summary,
      code: false,
      onOpen: target == null ? null : () => openSeatFromAlert(target.$1, target.$2),
      permission: false,
      busy: false,
      onAllow: () {},
      onDeny: () {},
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final host = AppScope.of(context).active;
    showsInPanel(context, 'project:${widget.path}');
    final feed = host == null ? null : fleet.feedFor(host);

    return Scaffold(
      body: ListenableBuilder(
        // The fleet too: a rig row folds through it.
        listenable: Listenable.merge([fleet, if (feed != null) feed]),
        builder: (context, _) {
          final running = _rigs.where((r) => r.rig.status != 'stopped').toList();
          final stopped = _rigs.where((r) => r.rig.status == 'stopped').toList();
          final loose = _project?.loose ?? const <LooseAgent>[];
          final worktrees = _worktrees ?? const <Worktree>[];
          final t = Theme.of(context).textTheme;

          // What waits on the person here: the same list as the tab badge, by membership. A permission is answered
          // right here.
          final asks = [
            if (feed != null && _project != null) ...feed.needsYouItems.where((i) => i.inProject(_project!)),
          ];
          final waiting = <Widget>[
            for (final item in asks)
              if (item.seat case final s?)
                Builder(builder: (context) {
                  final r = item.rig!;
                  final ask = PermissionAsk.from(s);
                  return NeedsRow(
                    title: '${s.logicalId} · ${r.rig.name}',
                    detail: [if (ask.tool != null) ask.tool!, ask.detail].join(' · '),
                    code: ask.isPermission,
                    onOpen: () => openSeatFromAlert(r.rig.name, s),
                    permission: ask.isPermission && s.sessionName != null,
                    busy: _busy.contains('answer:${s.rigId}/${s.logicalId}'),
                    onAllow: () => _answerSeat(s, allow: true),
                    onDeny: () => _answerSeat(s, allow: false),
                  );
                })
              else if (item.loose case final a?)
                NeedsRow(
                  title: [a.name, if (worktreeName(a.cwd) case final w?) w].join(' · '),
                  detail: a.message ?? a.detail ?? 'Waiting for your input',
                  code: a.isPermission,
                  onOpen: () => _openLoose(a, feed),
                  permission: a.isPermission && (a.tmuxPane ?? a.tmuxSession) != null,
                  busy: _busy.contains('answer:${a.id}'),
                  onAllow: () => _answerLoose(a, allow: true),
                  onDeny: () => _answerLoose(a, allow: false),
                )
              else
                _actionRow(item.action!, feed),
          ];

          Widget rigRow(RigWithSeats r, {bool withSeats = true}) {
            final label = host?.rigLabel(r.rig.name) ?? r.rig.name;
            // Folds like the Projects rows: its working seats show until the person unfolds or folds it.
            final seats = r.seats.where((s) => s.isAgent || s.state != SeatState.stopped).toList();
            final key = host == null ? null : Fleet.rigKey(host, r);
            final shown = key == null ? const <Seat>[] : fleet.rigSeatsShown(key, seats);
            final all = shown.length == seats.length;
            final row = RowTile(
              minHeight: 56,
              padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
              fold: key == null || seats.isEmpty || !withSeats
                  ? null
                  : (name: label, open: all, onTap: () => fleet.toggleRig(key, allShown: all)),
              reserveFold: key == null || seats.isEmpty || !withSeats,
              leading: StatusIcon.rig(rigStatus(r, host)),
              onTap: () => _push(rigHome(r, _name)),
              onLongPress: busyKeys.value.contains(r.rig.id) ? null : () => _rigMenu(r, label),
              trailing: busyKeys.value.contains(r.rig.id)
                  // The IconButton's box, so the row doesn't jump when it swaps in.
                  ? const SizedBox(
                      width: 48,
                      height: 48,
                      child: Center(
                          child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))))
                  : IconButton(
                      tooltip: 'Rig actions',
                      icon: const Icon(Icons.more_horiz, size: 20),
                      onPressed: () => _rigMenu(r, label),
                    ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                RigName(label),
                const SizedBox(height: 3),
                RigCountLine(host: host, rig: r),
              ]),
            );
            if (shown.isEmpty || !withSeats) return row;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              row,
              Padding(
                // Seat rows line up with the rig row, as on Projects.
                padding: const EdgeInsets.fromLTRB(tileFoldMax + 6, 0, 0, 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final s in shown) SeatLeaf(host: host!, rigName: r.rig.name, seat: s, rigBadge: false, branch: seatPlaceChip(s, r.primaryCwd)),
                ]),
              ),
            ]);
          }

          Widget looseRow(LooseAgent a, {bool withWorktree = false}) {
            final jobs = jobsOfLoose(host, a);
            final subs = subagentsWaitingOf(host, a);
            return RowTile(
              minHeight: 56,
              padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
              // In the flat Agents list it has no fold slot, so its robot is at the rig agents' x.
              reserveFold: !withWorktree,
              // In the flat Agents list it has the chevron the other agent rows have, so the worktree tags line up.
              arrow: withWorktree,
              leading: StatusIcon.agent(Status.of(looseState(host, a)), runtime: a.runtime),
              onTap: () => _openLoose(a, feed),
              onLongPress: () => showLooseActions(context, a,
                  onChat: () => _openLoose(a, feed),
                  onTerminal: () => _push(TerminalScreen(target: SeatTarget('no rig', a.toSeat())))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Expanded(
                    child: Row(children: [
                      Flexible(
                        child: Text(a.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      ),
                      Text('  no rig', style: mono(context, size: 11)),
                    ]),
                  ),
                  if (withWorktree && a.cwd != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 96),
                      child: Text(worktreeName(a.cwd) ?? 'main',
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 11, color: k.muted)),
                    ),
                ]),
                Text(
                  [
                    a.runtimeLabel,
                    looseStatus(a, null, jobs, subs),
                    if (!a.inTmux) 'read only',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: k.muted),
                ),
              ]),
            );
          }

          // One card per worktree (main checkout first), each with what runs in it; a cwd outside every
          // worktree goes last. Outside git: one card for the folder.
          final groups = <Widget>[];
          if (worktrees.isEmpty) {
            if (running.isNotEmpty || loose.isNotEmpty) {
              groups.add(BorderedList(children: [for (final r in running) rigRow(r), for (final a in loose) looseRow(a)]));
            } else {
              groups.add(Text(_worktrees == null ? 'Reading git…' : 'Nothing running here.',
                  style: TextStyle(color: k.muted)));
            }
          } else {
            for (final (i, w) in [...worktrees.indexed, (-1, null)]) {
              bool there(String? cwd) => w != null ? _runsIn(w, cwd) : !worktrees.any((x) => _runsIn(x, cwd));
              final rigsHere = [for (final r in running) if (_rigHere(r, there) case final here?) here];
              final looseHere = loose.where((a) => there(a.cwd)).toList();
              if (w == null) {
                if (rigsHere.isEmpty && looseHere.isEmpty) continue;
                groups.add(BorderedList(stripHeader: false, header: const WorktreeHead(title: 'Elsewhere', main: false), children: [
                  for (final r in rigsHere) rigRow(r),
                  for (final a in looseHere) looseRow(a),
                ]));
                continue;
              }
              final agents =
                  _rigs.expand((r) => r.seats).where((s) => s.cwd != null && there(s.cwd)).length + looseHere.length;
              groups.add(BorderedList(
                stripHeader: false,
                header: WorktreeHead(
                  title: i == 0 ? 'Main checkout' : w.name,
                  main: i == 0,
                  worktree: w,
                  pr: _prOf(w),
                  busy: _busy.contains(w.path),
                  onOpen: () => _openWorktree(w),
                  onMenu: () => _worktreeMenu(w, i == 0, agents),
                  onRemove: w.missing && i != 0 ? () => _clearMissing(w) : null,
                ),
                children: [
                  for (final r in rigsHere) rigRow(r),
                  for (final a in looseHere) looseRow(a),
                  if (rigsHere.isEmpty && looseHere.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                      child: Text('Nothing running here.', style: TextStyle(fontSize: 13, color: k.muted)),
                    ),
                ],
              ));
            }
          }

          final linkedSpecs = host?.specFolders[widget.path];
          final specGroups = _specGroups;
          final prs = _github?.$2 ?? const <PullRequest>[];

          final err = [
            if (feed?.error case final e?) ErrorBanner(e, margin: const EdgeInsets.only(bottom: 16)),
          ];
          // The project's shells (tmux rp-*): only these, each with Close shell (one shared, confirmed call).
          final shells = _project?.shells ?? const <ProjectShell>[];
          final shellsTab = <Widget>[
            ...err,
            SectionLabel('Shells · ${shells.length}', height: 32),
            if (shells.isEmpty)
              Text('No shells running here.', style: TextStyle(color: k.muted))
            else
              BorderedList(children: [
                for (final sh in shells)
                  RowTile(
                    minHeight: 56,
                    padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
                    leading: const StatusIcon.shell(Status.idle),
                    title: host?.shellLabel(sh.name) ?? sh.name,
                    meta: displayPath(sh.cwd),
                    metaMono: true,
                    onTap: () => openShell(context, sh),
                    onLongPress: host == null ? null : () => showShellActions(context, host, sh),
                    trailing: host == null
                        ? null
                        : IconButton(
                            tooltip: 'Close ${host.shellLabel(sh.name)}',
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: () => confirmCloseShell(context, host, sh)),
                  ),
              ]),
          ];
          final overview = <Widget>[
            ...err,
            if (waiting.isNotEmpty) ...[
              SectionLabel('Needs you · ${waiting.length}',
                  height: 32, leading: const StatusShape(Status.needsYou, size: 8, semantics: false)),
              BorderedList(borderColor: k.accent, children: waiting),
              const SizedBox(height: 22),
            ],
            _labelWithJump('Running', 'All agents', 1),
            Builder(builder: (_) {
              final tally = SeatTally(host, _rigs, loose, project: _project);
              void toAgents() => setState(() => _tab = 1);
              return Row(children: [
                CountTile('rigs', '${running.length}', color: running.isNotEmpty ? k.added : null, onTap: toAgents),
                const SizedBox(width: 8),
                CountTile('agents', '${tally.up}', color: tally.up > 0 ? k.added : null, onTap: toAgents),
                const SizedBox(width: 8),
                CountTile('need you', '${tally.needs}', highlight: tally.needs > 0, onTap: toAgents),
                const SizedBox(width: 8),
                CountTile('working', '${tally.working}',
                    color: tally.working > 0 ? k.added : null, filled: tally.working > 0, onTap: toAgents),
              ]);
            }),
            if (worktrees.isNotEmpty) ...[
              const SizedBox(height: 22),
              _labelWithJump('Code', 'Worktrees', 2),
              BorderedList(children: [
                for (final (i, w) in worktrees.indexed)
                  RowTile(
                    minHeight: 52,
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                    title: i == 0 ? 'Main checkout' : w.name,
                    meta: w.branch ?? 'detached HEAD',
                    metaMono: true,
                    trailing: Text(w.pushState, style: mono(context, color: w.pushState == 'pushed' ? k.added : null)),
                    onTap: () => _openWorktree(w),
                    arrow: true,
                  ),
              ]),
            ],
            if (prs.isNotEmpty) ...[
              const SizedBox(height: 22),
              SectionLabel('Pull requests · latest ${prs.length}', height: 32),
              BorderedList(children: [
                for (final pr in prs)
                  RowTile(
                    minHeight: 52,
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                    leading: ChecksIcon(pr),
                    title: '#${pr.number} ${pr.title}',
                    meta: prLine(pr),
                    trailing: pr.url == null ? null : Icon(Icons.north_east, size: 16, color: k.muted),
                    onTap: pr.url == null ? null : () => _launch(pr.url!),
                  ),
              ]),
            ],
            const SizedBox(height: 22),
            const SectionLabel('Project', height: 32),
            BorderedList(children: [
              RowTile(
                minHeight: 52,
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                leading: Icon(Icons.folder_outlined, size: 20, color: k.muted),
                title: 'Files',
                meta: 'Changes and the file tree',
                onTap: () => _push(ProjectFilesScreen(path: widget.path, name: _name)),
              ),
            ]),
          ];
          // Agents: one flat list, the ones waiting on you first, each with its worktree as a muted tag. The rigs
          // themselves are on the Worktrees tab.
          int rank(SeatState s) => switch (s) {
                SeatState.needsYou => 0,
                SeatState.working => 1,
                SeatState.shell => 2,
                SeatState.idle => 3,
                SeatState.stopped => 4,
              };
          final flat = <(int, Widget)>[
            if (host != null)
              for (final r in running)
                for (final s in r.seats.where((s) => s.isAgent || s.state != SeatState.stopped))
                  (
                    rank(s.state),
                    SeatLeaf(
                        host: host,
                        rigName: r.rig.name,
                        seat: s,
                        flat: true,
                        tag: s.cwd == null ? null : (worktreeName(s.cwd) ?? 'main'))
                  ),
            for (final a in loose) (rank(looseState(host, a)), looseRow(a, withWorktree: true)),
          ];
          final order = [for (final (i, e) in flat.indexed) (e.$1, i, e.$2)]
            ..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
          final agents = <Widget>[
            ...err,
            if (order.isNotEmpty) ...[
              SectionLabel('Agents · ${order.length}', height: 32),
              Padding(
                padding: const EdgeInsets.only(bottom: 22),
                child: BorderedList(children: [for (final e in order) e.$3]),
              ),
            ],
            if (running.isNotEmpty) ...[
              SectionLabel('Rigs · ${running.length}', height: 32),
              Padding(
                padding: const EdgeInsets.only(bottom: 22),
                child: BorderedList(children: [for (final r in running) rigRow(r, withSeats: false)]),
              ),
            ],
            if (order.isEmpty && running.isEmpty && stopped.isEmpty)
              Text('Nothing running here.', style: TextStyle(color: k.muted)),
            if (stopped.isNotEmpty) ...[
              SectionLabel('Stopped · ${stopped.length}', height: 32),
              BorderedList(children: [
                for (final r in stopped)
                  RowTile(
                    minHeight: 56,
                    padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
                    leading: const StatusShape(Status.stopped),
                    title: r.rig.name,
                    meta: r.rig.latestSnapshot != null ? 'snapshot ${r.rig.latestSnapshot}' : 'no snapshot',
                    trailing: busyKeys.value.contains(r.rig.id)
                        ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                        : Row(mainAxisSize: MainAxisSize.min, children: [
                            PillButton('Restore', height: 32, onPressed: () => restoreRigOnce(context, r.rig)),
                            IconButton(
                              tooltip: 'Rig actions',
                              icon: const Icon(Icons.more_horiz, size: 20),
                              onPressed: () => _rigMenu(r, r.rig.name),
                            ),
                          ]),
                    onTap: () => _push(rigRoute(r.rig, _name, seats: r.seats)),
                    onLongPress: busyKeys.value.contains(r.rig.id) ? null : () => _rigMenu(r, r.rig.name),
                  ),
              ]),
            ],
          ];
          final worktreeTab = <Widget>[
            ...err,
            const SectionLabel('By worktree', height: 32),
            for (final g in groups) Padding(padding: const EdgeInsets.only(bottom: 14), child: g),
            // The one New worktree button: a dashed row at the end of the list, as Add project folder is in the sidebar.
            // NavRow keeps the sidebar's side inset; here its dashed edges are the cards' edges above.
            LayoutBuilder(
              builder: (context, box) => SizedBox(
                height: navRowHeight(),
                child: OverflowBox(
                minWidth: box.maxWidth + 2 * navSideInset(),
                maxWidth: box.maxWidth + 2 * navSideInset(),
                child: NavRow(
                  leading: Icon(Icons.add, size: 16, color: Tokens.of(context).ink),
                  label: 'New worktree',
                  dashed: true,
                  onTap: _newWorktree,
                ),
                ),
              ),
            ),
          ];
          final specs = <Widget>[
            ...err,
            SectionLabel('Rig specs${_specs == null ? '' : ' · ${specGroups.length}'}', height: 32),
            if (_specError != null) ErrorBanner(_specError!, margin: const EdgeInsets.only(bottom: 8)),
            if (_specs == null && _specError == null)
              const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
            if (_specs != null && _specs!.isEmpty)
              Text(
                  'No rig.yaml files found in ${[
                    displayPath(_absPath ?? widget.path),
                    if (linkedSpecs != null) linkedSpecs,
                  ].join(' or ')} (looked 5 folders deep).',
                  style: TextStyle(color: k.muted)),
            if (specGroups.isNotEmpty)
              BorderedList(children: [
                for (final copies in specGroups)
                  Builder(builder: (_) {
                    final s = copies.first;
                    final elsewhere = copies.where((c) => c.file.worktree != null).length;
                    final live = running.where((r) => r.rig.name == s.summary.name).firstOrNull;
                    void open() => _push(
                        SpecScreen(file: s.file, text: s.text, projectName: _name, worktrees: _worktrees ?? const []));
                    return RowTile(
                      minHeight: 60,
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                      leading: Icon(Icons.description_outlined, size: 18, color: k.muted),
                      onTap: open,
                      arrow: true, // the whole row opens
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(s.summary.name ?? s.file.checkoutPath,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: mono(context, size: 13, color: k.ink).copyWith(fontWeight: FontWeight.w600)),
                            Text([if (s.summary.summary case final sum?) sum, s.summary.oneLine].join(' · '),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: t.bodySmall?.copyWith(color: s.summary.error != null ? k.removed : k.muted)),
                            Text(
                                [
                                  s.file.checkoutPath,
                                  if (elsewhere > 0) 'also in ${countOf(elsewhere, 'worktree')}',
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: mono(context, size: 11)),
                            if (live != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Pill('running as ${live.rig.name}', tone: Tone.done),
                              ),
                          ]),
                    );
                  }),
              ]),
          ];

          return Column(children: [
            PageHeader(
              inColumn: true,
              host: host,
              title: _name,
              subtitle: Text(
                  [
                    displayPath(widget.path),
                    if (worktrees.isNotEmpty) countOf(worktrees.length, 'worktree'),
                  ].join(' · '),
                  style: mono(context),
                  overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  tooltip: 'Project options',
                  icon: const Icon(Icons.more_horiz, size: 22),
                  onPressed: _projectMenu,
                ),
              ],
              bottom: Segmented<int>(
                values: [0, 1, 2, 3, if (shells.isNotEmpty) 4],
                labels: ['Overview', 'Agents', 'Worktrees', 'Specs', if (shells.isNotEmpty) 'Shells ${shells.length}'],
                selected: _tab == 4 && shells.isEmpty ? 0 : _tab,
                onChanged: (i) => setState(() => _tab = i),
                semanticLabel: 'Project views',
              ),
            ),
            Expanded(
              child: PageColumn(child: SafeArea(
                top: false,
                child: RefreshIndicator(
                onRefresh: () async {
                  await Future.wait([
                    load(),
                    _loadSpecs(),
                    if (feed != null) feed.refresh(),
                  ]);
                },
                child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                    children: [overview, agents, worktreeTab, specs, shellsTab][_tab == 4 && shells.isEmpty ? 0 : _tab]),
              ),
              )),
            ),
          ]);
        },
      ),
    );
  }
}
