import 'dart:async';
import '../action_rows.dart' show showActionRows;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../api/openrig_client.dart';
import '../../data/fleet.dart';
import '../../data/git_status.dart';
import '../../main.dart';
import '../../models.dart';
import '../../ssh/ssh_exec.dart';
import '../../terminal/transport.dart';
import '../chat/diff_view.dart' show DiffScreen;
import '../chat/git_cards.dart' show ChangesCard;
import '../common.dart';
import '../desktop_shell.dart';
import '../kit.dart';
import '../loose_agent_screen.dart';
import '../new_session_sheet.dart';
import '../project_tally.dart';
import '../status_shape.dart';
import '../theme.dart';
import '../tiles_screen.dart' show rigHome;
import '../terminal_screen.dart';
import 'specs.dart';
import 'worktree_delete.dart';
import 'worktree_rows.dart';

/// Pushes [WorktreeScreen] for a worktree of [project] (the main checkout when [name] is null) at once; the
/// screen reads its branch and PR itself.
void openWorktreeScreen(BuildContext context, Host host, Project project, String? name) {
  useHost(context, host);
  detailNavigator(context)
      .push(MaterialPageRoute(builder: (_) => WorktreeScreen.load(host: host, project: project, name: name)));
}

/// One worktree: its branch and push state, its PR, and the rigs and agents
/// running in it. Rigs and agents stay live from the host's feed.
class WorktreeScreen extends StatefulWidget {
  const WorktreeScreen({
    super.key,
    required Worktree this.worktree,
    required this.isMain,
    required this.projectName,
    required this.projectPath,
    required this.pr,
    required bool Function(String cwd) this.contains,
  })  : host = null,
        project = null,
        name = null;

  /// Reads the branch and PR itself, from [host] (not whichever host is active later).
  WorktreeScreen.load({super.key, required Host this.host, required Project this.project, required this.name})
      : worktree = null,
        isMain = name == null,
        projectName = project.name,
        projectPath = project.path,
        pr = null,
        contains = null;

  final Worktree? worktree;
  final bool isMain;
  final String projectName;

  /// The project's folder, where its rig specs are looked for when a rig is started here.
  final String projectPath;
  final PullRequest? pr;

  /// Whether a cwd runs in this worktree (and not a deeper one).
  final bool Function(String cwd)? contains;
  final Host? host;
  final Project? project;
  final String? name;

  @override
  State<WorktreeScreen> createState() => _WorktreeScreenState();
}

class _WorktreeScreenState extends State<WorktreeScreen> {
  late Worktree _w;
  PullRequest? _pr;
  late bool Function(String cwd) _contains;
  bool _loading = false;
  bool _starting = false;
  String? _error;

  /// The folder's uncommitted changes (tracked and new files), read with the worktree; null until then or if git can't say.
  GitStatus? _changes;
  bool _changesLoading = true;

  /// Reads the project's rig specs, then opens the launch sheet for one of them in this worktree.
  Future<void> _startRig() async {
    final host = widget.host ?? AppScope.read(context).active;
    if (host == null) return;
    setState(() => _starting = true);
    try {
      final (worktrees, groups, failed) = await readForStart(host, widget.projectPath);
      if (!mounted) return;
      if (!groups.any((c) => c.any((s) => s.summary.error == null))) {
        toast(context, failed != null ? 'Couldn\'t list specs over SSH: $failed' : 'No rig specs in this project.',
            kind: ToastKind.info);
        return;
      }
      await startRigInWorktree(context,
          w: _w,
          main: widget.isMain,
          projectName: widget.projectName,
          specGroups: groups,
          worktrees: worktrees,
          push: (screen) => _push(context, screen));
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t list specs over SSH: $e', kind: ToastKind.problem);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  void initState() {
    super.initState();
    final project = widget.project;
    if (project == null) {
      _w = widget.worktree!;
      _pr = widget.pr;
      _contains = widget.contains!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadChanges());
      return;
    }
    final name = widget.name;
    _w = Worktree(project.path, null); // only a placeholder; the title comes from [name] until git is read
    // shortcut: until the git read lands, a cwd matches by its place under the project folder.
    _contains = (cwd) => isUnder(cwd, project.path) && worktreeName(cwd) == name;
    _loading = true;
    _load(project, name);
  }

  Future<void> _load(Project project, String? name) async {
    final host = widget.host!;
    SshExec? ssh;
    var timedOut = false;
    try {
      final (all, github) = await (() async {
        ssh = await SshExec.connect(host);
        if (timedOut) {
          ssh!.close();
          throw TimeoutException('late');
        }
        final all = await ssh!.worktrees(project.path);
        return (all, await ssh!.github(project.path).catchError((_) => null));
      })()
          .timeout(const Duration(seconds: 10), onTimeout: () {
        timedOut = true;
        throw TimeoutException('git');
      });
      // The main checkout is git's first; a named one is found by worktreeName, as Home groups it (so a main checkout never matches).
      final w = name == null ? all.firstOrNull : all.where((w) => worktreeName(w.path) == name).firstOrNull;
      if (w == null) throw OpenRigException('Git on ${host.name} doesn\'t list this worktree.');
      Worktree? deepest(String cwd) => all
          .where((w) => cwd == w.path || cwd.startsWith('${w.path}/'))
          .fold<Worktree?>(null, (best, w) => best == null || w.path.length > best.path.length ? w : best);
      if (!mounted) return;
      setState(() {
        _w = w;
        _pr = github?.$2.where((p) => p.headRef != null && p.headRef == w.branch).firstOrNull;
        _contains = (cwd) => identical(deepest(cwd), w);
        _loading = false;
      });
      _loadChanges();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is TimeoutException
            ? 'Timed out reading git on ${host.name}.'
            : (e is OpenRigException ? e.message : '$e');
        _loading = false;
      });
    } finally {
      ssh?.close();
    }
  }

  /// What `git status` and `git diff HEAD --numstat` say about this folder: the changed files with their line counts, and the
  /// new ones. A host that can't be reached just leaves the section saying so.
  Future<void> _loadChanges() async {
    final host = widget.host ?? AppScope.read(context).active;
    if (host == null) return;
    SshExec? ssh;
    try {
      ssh = await SshExec.connect(host);
      final g = await ssh.gitStatus(_w.path).timeout(const Duration(seconds: 10));
      if (mounted) setState(() => _changes = g);
    } catch (_) {
      if (mounted) setState(() => _changes = null);
    } finally {
      ssh?.close();
      if (mounted) setState(() => _changesLoading = false);
    }
  }

  /// A changed file's diff: the existing read-only diff screen.
  void _openChange(GitStatus g, String absolute) {
    final root = g.root;
    if (root == null || !absolute.startsWith('$root/')) return;
    final rel = absolute.substring(root.length + 1);
    _push(context, DiffScreen(root: root, path: rel, untracked: g.untracked.contains(rel)));
  }

  /// Delete worktree (never on the main checkout): the confirm names what is lost and what still runs here; then the page closes.
  Future<void> _delete() async {
    final host = widget.host ?? AppScope.read(context).active;
    if (host == null || widget.isMain) return;
    final feed = fleet.feedFor(host);
    bool here(String? cwd) => cwd != null && _contains(cwd);
    final project = feed.projects.where((p) => p.path == widget.projectPath).firstOrNull;
    final agents = [
      for (final r in feed.rigs)
        if (r.rig.status != 'stopped') for (final s in r.seats) if (s.isAgent && s.state != SeatState.stopped && here(s.cwd)) s.logicalId,
      for (final a in feed.loose) if (here(a.cwd)) a.name,
    ];
    final shells = [for (final sh in project?.shells ?? const <ProjectShell>[]) if (here(sh.cwd)) host.shellLabel(sh.name)];
    final done = await deleteWorktree(context,
        host: host, repo: widget.projectPath, w: _w, name: widget.name ?? _w.name, agents: agents, shells: shells);
    if (done && mounted) Navigator.of(context).maybePop();
  }

  void _push(BuildContext context, Widget w) => detailNavigator(context).push(MaterialPageRoute(builder: (_) => w));

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final w = _w;
    if (!widget.isMain) showsInPanel(context, worktreePanelKey(widget.projectPath, widget.name ?? worktreeName(w.path) ?? w.name));
    final host = widget.host ?? AppScope.of(context).active;
    final feed = host == null ? null : fleet.feedFor(host);
    bool here(String? cwd) => cwd != null && _contains(cwd);
    return Scaffold(
      body: ListenableBuilder(
        listenable: feed ?? const AlwaysStoppedAnimation(0),
        builder: (context, _) {
          final rigs = [
            for (final r in feed?.rigs ?? const <RigWithSeats>[])
              // A rig is where most of its seats run (primaryCwd), as groupByWorktree has it everywhere: one seat of a main-checkout
              // rig in this worktree does not put the rig here.
              if (r.rig.status != 'stopped' && here(r.primaryCwd)) r,
          ];
          final loose = [
            for (final a in feed?.loose ?? const <LooseAgent>[])
              if (here(a.cwd)) a,
          ];
          final pr = _pr;
          return Column(children: [
            PageHeader(
              host: host,
              title: widget.isMain ? 'Main checkout' : (widget.name ?? w.name),
              subtitle: Text('${widget.projectName} · ${middleEllipsis(displayPath(w.path), max: 30)}',
                  style: mono(context), maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                if (!widget.isMain && !_loading && _error == null)
                  IconButton(
                    tooltip: 'Worktree options',
                    icon: const Icon(Icons.more_horiz, size: 22),
                    onPressed: () => showActionRows(context, widget.name ?? w.name,
                        (items: const [], danger: [('Delete worktree…', Icons.delete_outline, _delete)])),
                  ),
              ],
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  _loadChanges();
                  await feed?.refresh();
                },
                child: ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 32), children: [
                  // Branch and PR are unknown until git has been read (or if it couldn't be).
                  if (_loading) const LinearProgressIndicator(minHeight: 2),
                  if (_error != null) Text(_error!, style: TextStyle(color: k.removed)),
                  if (!_loading && _error == null) ...[
                    const SectionLabel('Branch'),
                    BorderedList(children: [
                      RowTile(
                        minHeight: 52,
                        leading: Icon(Icons.call_split, size: 18, color: k.muted),
                        title: w.branch ?? 'detached HEAD',
                        meta: w.upstream == null ? 'no upstream' : 'tracks ${w.upstream}',
                        metaMono: true,
                        // The counts ("2 to push · 3 changed") on a line of their own, so "tracks origin/…" isn't cut.
                        extra: w.pushState,
                      ),
                    ]),
                    const SizedBox(height: 22),
                    const SectionLabel('Pull request'),
                    if (pr == null)
                      Text('No recent PR for this branch.', style: TextStyle(color: k.muted))
                    else
                      BorderedList(children: [
                        RowTile(
                          minHeight: 52,
                          leading: ChecksIcon(pr),
                          title: '#${pr.number} ${pr.title}',
                          meta: [prLine(pr), if (pr.baseRef case final b?) 'into $b'].join(' · '),
                          trailing: Pill(pr.state[0] + pr.state.substring(1).toLowerCase(), tone: statusTone(pr.state)),
                          onTap: pr.url == null
                              ? null
                              : () => launchUrl(Uri.parse(pr.url!), mode: LaunchMode.externalApplication),
                        ),
                      ]),
                    const SizedBox(height: 22),
                    // Uncommitted work in this folder, as the agent's chat lists it: tap a file for its diff.
                    SectionLabel('Changes · ${_changes?.changeRows.length ?? 0}'),
                    if (_changesLoading)
                      Text('Reading changes…', style: TextStyle(color: k.muted))
                    else if (_changes == null)
                      Text('Couldn\'t read changes on ${host?.name ?? 'the host'}.', style: TextStyle(color: k.muted))
                    else if (_changes!.changeRows.isEmpty)
                      Text('No uncommitted changes.', style: TextStyle(color: k.muted))
                    else
                      ChangesCard(git: _changes!, onOpen: (path) => _openChange(_changes!, path)),
                    const SizedBox(height: 22),
                  ],

                  SectionLabel(
                    'Rigs · ${rigs.length}',
                    height: 32,
                    trailing: TextButton(
                      onPressed: _loading || _error != null || _starting ? null : _startRig,
                      style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4)).merge(compactAction),
                      child: Text(_starting ? 'Reading specs…' : '+ Start rig',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ),
                  if (rigs.isEmpty)
                    Text('No rigs running here.', style: TextStyle(color: k.muted))
                  else
                    BorderedList(children: [
                      for (final r in rigs)
                        RowTile(
                          leading: StatusIcon.rig(rigStatus(r, host)),
                          onTap: () {
                            if (host != null) useHost(context, host);
                            _push(context, rigHome(r, widget.projectName));
                          },
                          arrow: true,
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(r.rig.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500)),
                            RigCountLine(host: host, rig: r),
                          ]),
                        ),
                    ]),
                  const SizedBox(height: 22),
                  SectionLabel('Outside a rig · ${loose.length}'),
                  if (loose.isEmpty)
                    Text('No other agents running here.', style: TextStyle(color: k.muted))
                  else
                    LooseAgentList(agents: loose, rigs: feed?.rigs ?? const [], host: host),
                ]),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(color: k.ground, border: Border(top: BorderSide(color: k.divider))),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                  child: Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _push(context, TerminalScreen(target: ProjectShellTarget(w.path))),
                        icon: const Icon(Icons.terminal, size: 18),
                        label: const Text('Shell here'),
                        style: sheetAction,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => startAgentInFolder(context, w.path),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('New agent'),
                        style: sheetAction,
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ]);
        },
      ),
    );
  }
}
