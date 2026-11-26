import 'dart:async';

import 'package:flutter/material.dart';

import 'page_column.dart';
import '../data/fleet.dart';
import '../data/git_status.dart';
import '../data/host_store.dart' show isDesktop;
import '../data/rig_spec_source.dart';
import '../main.dart';
import '../models.dart';
import '../ssh/ssh_exec.dart';
import '../terminal/transport.dart';
import 'app_icon.dart';
import 'busy.dart';
import 'worktree_chip.dart';
import 'chat_screen.dart';
import 'common.dart';
import 'host_color.dart' show hostOverline;
import 'kit.dart';
import 'new_session_sheet.dart' show startAgentInFolder;
import 'project_tally.dart' show rigIconColor;
import 'rig/overview_tab.dart';
import 'rig/progress_tab.dart' show ProgressBody, RigDangerZone;
import 'rig/rig_actions.dart';
import 'rig/rig_header.dart';
import 'rig/rig_room.dart' show RigRoomScreen, RemindersScreen, broadcastToRig;
import 'rig/work_queue_screen.dart' show isOpenQueueState;
import 'rig/seat_sheet.dart';
import 'spec_editor_screen.dart';
import 'desktop_shell.dart' show dropPanelRoutes, showsInPanel;
import 'needs_you_banner.dart' show inboxRequests;
import 'tab_strip.dart';
import 'theme.dart';
import 'terminal_screen.dart';

/// A rig in three tabs, Seats | Overview | Progress: a header with the rig's status and its options (⋯); Seats
/// (a List or a Map, opening on the Map), then Work, Code, Activity, what it made, Usage and its tools
/// ([RigBody]), then Progress.
///
/// Seats and the /api/ps row are polled every 5 s; the rig's event stream
/// fills Activity and triggers an early refresh when something happens.
class RigScreen extends StatefulWidget {
  const RigScreen({super.key, required this.rig, required this.projectName, this.initialTab = 0, this.tab = 0, this.tiles = false});
  final Rig rig;
  final String projectName;

  /// 1 opens a running rig on its Graph tab; the default opens on Agents.
  final int initialTab;

  /// Opened from the tiles' List side: the Mac's header keeps a List | Tiles switch with List selected.
  final bool tiles;

  /// The open tab: 0 Agents (the default), 1 Work, 2 Progress, 3 Code.
  final int tab;
  @override
  State<RigScreen> createState() => _RigScreenState();
}

class _RigScreenState extends State<RigScreen> with Polling {
  late Rig _rig = widget.rig;
  List<Seat> _seats = [];
  List<QueueItem> _queue = [];
  RigTopology? _topology;
  GitStatus? _git;
  String? _gitError;
  bool _gitLoading = false;
  int _gitTries = 0;
  final List<RigEvent> _events = [];
  String? _error;
  /// Any action on this rig, from any trigger (its ⋯, a project row, the sidebar), or the spec editor.
  bool get _working => busyKeys.value.contains(_rig.id);

  /// Permission mode per seat, from seat status (the node row doesn't carry it).
  final Map<String, String?> _modes = {};

  /// The open tab. Graph only exists on a running rig: a stopped rig falls back to Agents.
  late _RigTab _tab = switch (widget.tab) {
    1 => _RigTab.work,
    2 => _RigTab.progress,
    3 => _RigTab.code,
    _ => widget.initialTab == 1 && widget.rig.status != 'stopped' ? _RigTab.graph : _RigTab.agents,
  };

  StreamSubscription<RigEvent>? _eventSub;
  Timer? _reconnect;
  String? _lastEventId;
  VoidCallback? _unfocus; // keeps this rig's seats polled by the feed while open

  @override
  void initState() {
    super.initState();
    busyKeys.addListener(_onBusy);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (AppScope.read(context).active case final host?) _unfocus = fleet.feedFor(host).focus(_rig.id);
      _listen(replay: 20);
      _loadTopology();
      _loadGit();
    });
  }

  /// Its rig's work from any trigger started or finished: the bar follows. The status is read again by the feed
  /// refresh the action ends with (see the test).
  void _onBusy() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    busyKeys.removeListener(_onBusy);
    _unfocus?.call();
    _eventSub?.cancel();
    _reconnect?.cancel();
    super.dispose();
  }

  @override
  Future<void> load() async {
    final api = AppScope.clientOf(context);
    if (api == null) return;
    try {
      final results = await Future.wait([
        api.seats(_rig.id),
        api.rig(_rig.id).catchError((_) => null),
        api.queue(rigName: _rig.name).catchError((_) => <QueueItem>[]),
      ]);
      if (!mounted) return;
      final seats = results[0] as List<Seat>;
      // The shells come from the host feed's last process scan.
      if (AppScope.read(context).active case final host?) fleet.feedFor(host).applyShells(seats);
      final changedShape = seats.length != _seats.length;
      setState(() {
        _seats = seats;
        _rig = (results[1] as Rig?) ?? _rig;
        _queue = results[2] as List<QueueItem>;
        _error = null;
      });
      if (changedShape) _loadTopology();
      _loadModes();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _loadModes() {
    final api = AppScope.clientOf(context);
    if (api == null) return;
    for (final s in _seats) {
      final key = _modeKey(s);
      if (!s.isAgent || _modes.containsKey(key)) continue;
      _modes[key] = null;
      api.permissionMode(s).then((m) {
        if (mounted) setState(() => _modes[key] = m);
      }, onError: (_) {});
    }
  }

  static String _modeKey(Seat s) => s.sessionName ?? s.logicalId;

  Future<void> _loadTopology() async {
    final api = AppScope.clientOf(context);
    if (api == null) return;
    try {
      final t = await api.topology(_rig.id);
      if (mounted) setState(() => _topology = t);
    } catch (_) {/* graph falls back to seats without edges */}
  }

  Future<void> _loadGit() async {
    final host = AppScope.read(context).active;
    final cwd = RigWithSeats(_rig, _seats).primaryCwd;
    if (host == null) return;
    if (cwd == null) {
      // Seats haven't loaded yet: try again once they have.
      if (_seats.isEmpty && _gitTries++ < 10) {
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted && _git == null) _loadGit();
        });
      }
      return;
    }
    setState(() => _gitLoading = true);
    SshExec? ssh;
    try {
      ssh = await SshExec.connect(host);
      final g = await ssh.gitStatus(cwd);
      if (mounted) {
        setState(() {
          _git = g;
          _gitError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _gitError = 'Git status needs SSH: $e');
    } finally {
      ssh?.close();
      if (mounted) setState(() => _gitLoading = false);
    }
  }

  void _listen({int? replay}) {
    final api = AppScope.clientOf(context);
    if (api == null) return;
    _eventSub?.cancel();
    _eventSub = api.events(rigId: _rig.id, replay: replay, lastEventId: _lastEventId).listen(
      (e) {
        if (!mounted) return;
        _lastEventId = '${e.seq}';
        setState(() {
          _events.insert(0, e);
          if (_events.length > 20) _events.removeLast();
        });
        if (e.type == 'node.added' || e.type == 'node.removed') _loadTopology();
      },
      onError: (_) => _retryListen(),
      onDone: _retryListen,
    );
  }

  void _retryListen() {
    _reconnect?.cancel();
    _reconnect = Timer(const Duration(seconds: 5), () {
      // Last-Event-ID resumes; without one, ask for a short replay (an
      // absent replay would send the whole event log).
      if (mounted) _listen(replay: _lastEventId == null ? 20 : null);
    });
  }

  /// The global stream (from [Polling]) carries seat.activity_changed,
  /// which the rig stream never does, so it drives the reloads.
  @override
  bool wants(RigEvent e) =>
      e.rigId == _rig.id || e.type == 'seat.activity_changed' && _seats.any((s) => s.sessionName == e.sessionName);

  Future<void> _refreshAll() => Future.wait([load(), _loadTopology(), _loadGit()]);

  void _push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));

  void _openTerminal(Seat s) => _push(TerminalScreen(target: SeatTarget(_rig.name, s)));
  void _openChat(Seat s) => _push(ChatScreen(rigName: _rig.name, seat: s, asChat: true));

  /// Claude Code seats open as a chat; everything else as a terminal. Both
  /// screens switch to the other.
  // The chat on a phone; on desktop ChatScreen opens the terminal.
  void _openSeat(Seat s) => _push(seatScreen(_rig.name, s));

  /// A seat's ⋯ (and a long press on the Map): the seat sheet.
  Future<void> _seatSheet(Seat s) async {
    await showSeatSheet(context, _rig.name, s,
        queue: _queue,
        mode: _modes[_modeKey(s)],
        onChat: () => _openChat(s),
        onTerminal: () => _openTerminal(s),
        onEditSpec: () => _editSpec(s),
        onRefresh: load);
    // Its mode may have changed in there.
    if (!mounted) return;
    _modes.remove(_modeKey(s));
    _loadModes();
  }

  /// Opens the visual editor on the spec this rig was launched from (see
  /// [locateRigSpec]), on [s]'s member when given.
  Future<void> _editSpec([Seat? s]) async {
    await exclusive(_rig.id, () => editRigSpec(context, _rig, _seats, projectName: widget.projectName, member: s?.logicalId));
  }

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, box) => _page(context, box.maxWidth >= 760));

  /// [wide]: the page has room for the Mac's header buttons; narrower, the actions are tiles under the subtitle.
  Widget _page(BuildContext context, bool wide) {
    showsInPanel(context, 'rig:${_rig.id}');
    final host = AppScope.of(context).active;
    final renamed = host?.rigNames[_rig.name] != null;
    final withSeats = RigWithSeats(_rig, _seats);
    final cwd = withSeats.primaryCwd;
    final stopped = _rig.status == 'stopped';
    final actions = RigActionSet(
      onNew: cwd == null ? null : () => startAgentInFolder(context, cwd),
      onMessageAll: stopped ? null : () => broadcastToRig(context, _rig),
      onRoom: () => _push(RigRoomScreen(rig: _rig)),
      onReminders: () => _push(RemindersScreen(rig: _rig, seats: _seats)),
    );
    final k = Tokens.of(context);
    final agents = _seats.where((s) => s.isAgent).length;
    final open = _queue.where((q) => isOpenQueueState(q.state)).length;
    final tabs = [_RigTab.agents, if (!stopped) _RigTab.graph, _RigTab.work, _RigTab.code, _RigTab.progress];
    final tab = tabs.contains(_tab) ? _tab : _RigTab.agents;
    final header = PageHeader(
      // The rig, in the colour of its worst state.
      titleIcon: AppIcon(AppIconKind.rig, size: 22, color: rigIconColor(k, withSeats, host)),
      title: host?.rigLabel(_rig.name) ?? _rig.name,
      actions: [
        if (wide) ...rigHeaderButtons(context, actions),
        // The Mac only: every running agent of the rig as a live terminal.
        if (isDesktop && !stopped)
          ...[
            RigTilesButton(rig: RigWithSeats(_rig, _seats), projectName: widget.projectName),
            RigDetailsButton(rig: _rig, projectName: widget.projectName, selected: true),
          ],
        IconButton(
          tooltip: 'Rig options',
          icon: const Icon(Icons.more_horiz),
          onPressed: () => showRigActions(context, _rig, _seats,
              projectName: widget.projectName,
              onDeleted: () => _leaveRig(context, _rig.id)),
        ),
      ],
      // Under the title row, across the whole width: project · host · worktree · N agents (the real name too when this app
      // renamed the rig); then, on a phone, the four actions as tiles; then the tabs. The Mac has the actions in the bar.
      bottom: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 0, 12),
          child: Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text([widget.projectName, if (renamed) _rig.name].join(' · '), style: mono(context, size: 12, color: k.muted)),
            if (host != null) hostOverline(host, mono(context, size: 12, color: k.muted)),
            if (cwd != null) WorktreeChip(worktreeName(cwd) ?? 'main'),
            Text('$agents ${agents == 1 ? 'agent' : 'agents'}', style: mono(context, size: 12, color: k.muted)),
            if (_rig.status != 'running') RigStatusLine(_rig),
          ]),
        ),
        if (!wide) ...[RigActionTiles(actions), const SizedBox(height: 12)],
        TabStrip<_RigTab>(
          values: tabs,
          labels: [for (final t in tabs) t == _RigTab.work && open > 0 ? 'Work $open' : t.label],
          selected: tab,
          onChanged: (t) => setState(() => _tab = t),
          semanticLabel: 'Rig views',
        ),
      ]),
    );
    return Scaffold(
      body: Column(children: [
        header,
        if (_working) const LinearProgressIndicator(minHeight: 2),
        // One banner for all three tabs; it sits under the header, so the header never moves.
        if (_error != null) ErrorBanner(_error!, margin: const EdgeInsets.fromLTRB(16, 12, 16, 0)),
        Expanded(
          // Wide is the body's own pane (not the window): 1000dp and up, every tab is two panes and uncapped; below it, the column.
          child: LayoutBuilder(builder: (context, box) {
            final wide = box.maxWidth >= 1000;
            return SafeArea(
            top: false,
            bottom: false, // the bar under it takes the inset
            // The graph uses the window's width (up to 1600), the other tabs the usual column.
            child: PageColumn(alignment: Alignment.topLeft, maxWidth: wide ? double.infinity : (tab == _RigTab.graph ? 1600 : pageColumnWidth), child: IndexedStack(index: tabs.indexOf(tab), children: [
            for (final t in tabs)
              if (t == _RigTab.progress)
                ProgressBody(rig: _rig, active: tab == _RigTab.progress, wide: wide)
              else
                RigBody(
                  part: switch (t) {
                    _RigTab.agents => RigPart.seats,
                    _RigTab.graph => RigPart.graph,
                    _RigTab.work => RigPart.work,
                    _ => RigPart.code,
                  },
                  rig: _rig,
                  seats: _seats,
                  queue: _queue,
                  events: _events,
                  git: _git,
                  gitError: _gitError,
                  gitLoading: _gitLoading,
                  busy: _working,
                  topology: _topology,
                  modes: _modes,
                  onRefresh: _refreshAll,
                  wide: wide,
                  onOpenSeat: (s) => s.isAgent ? _openSeat(s) : _openTerminal(s),
                  onSeatMore: _seatSheet,
                  onGit: _git == null ? null : () => showGitSheet(context, _git!),
                  // Stop (or Delete once stopped) ends the Agents tab, as well as the header's ⋯.
                  footer: t == _RigTab.agents
                      ? RigDangerZone(
                          rig: _rig,
                          action: _rig.status == 'stopped'
                              ? ('Delete rig…', Icons.delete_outline, () => deleteRig(context, _rig, onDeleted: () => _leaveRig(context, _rig.id)))
                              : ('Stop rig…', Icons.stop_circle_outlined, () => stopRig(context, _rig, _seats)))
                      : null,
                ),
          ])),
          );
          }),
        ),
        // A stopped rig keeps its green Restore in view; Stop and Delete are in the header's ⋯ and the Agents tab's Danger zone.
        if (_rig.status == 'stopped')
          PageColumn(alignment: Alignment.topLeft, child: KillBar(outlined: true, primary: ('Restore rig', Icons.play_arrow_rounded, _working ? null : () => restoreRigOnce(context, _rig)), const [])),
      ]),
    );
  }
}

/// Leaves the page of a rig that is gone: back one screen, or, when this is the root of the content panel (nothing
/// to go back to), the screen the panel shows with nothing selected, which the shell opens on request.
void _leaveRig(BuildContext context, String rigId) {
  if (!context.mounted) return;
  dropPanelRoutes(rigId);
  final nav = Navigator.of(context);
  if (nav.canPop()) {
    nav.pop();
  } else {
    inboxRequests.value++;
  }
}

/// Opens the visual editor on the spec [rig] was launched from (see
/// [locateRigSpec]), on [member] when given; says why when there's none.
Future<void> editRigSpec(BuildContext context, Rig rig, List<Seat> seats,
    {required String projectName, String? member}) async {
  final host = AppScope.read(context).active;
  final api = AppScope.clientOf(context);
  final cwd = RigWithSeats(rig, seats).primaryCwd;
  if (host == null || api == null) return;
  SshExec? ssh;
  try {
    ssh = await SshExec.connect(host);
    final spec = await locateRigSpec(ssh, api, rig, cwd);
    final why = spec == null ? specNotFound(rig, await api.rigSpecSource(rig.id).catchError((_) => null), cwd) : null;
    if (!context.mounted) return;
    if (spec != null) {
      Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) =>
              SpecEditorScreen(file: spec.file, text: spec.text, projectName: projectName, member: member)));
    } else {
      toast(context, why!);
    }
  } catch (e) {
    if (context.mounted) toast(context, 'Couldn\'t read the spec over SSH: $e');
  } finally {
    ssh?.close();
  }
}

/// "Running · up 2h 5m": the status word in its status color, the rest muted. The snapshot details are on Overview
/// ([OverviewTab.snapshotLine]), so the header stays one line.
class RigStatusLine extends StatelessWidget {
  const RigStatusLine(this.rig, {super.key});
  final Rig rig;


  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final status = rig.status.isEmpty ? rig.status : '${rig.status[0].toUpperCase()}${rig.status.substring(1)}';
    return Text.rich(
        TextSpan(children: [
          TextSpan(
              text: status, style: TextStyle(color: toneColor(k, statusTone(rig.status)), fontWeight: FontWeight.w600)),
          TextSpan(
            text: [
              '',
              if (rig.uptime != null) 'up ${rig.uptime}',
            ].join(' · '),
          ),
        ]),
        style: TextStyle(fontSize: 12, color: k.muted),
    );
  }
}


/// The rig page's tabs; Graph only while the rig runs.
enum _RigTab {
  agents('Agents'),
  graph('Graph'),
  work('Work'),
  code('Code'),
  progress('Progress');

  const _RigTab(this.label);
  final String label;
}
