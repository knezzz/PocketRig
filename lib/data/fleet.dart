import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState;
import 'package:loggy/loggy.dart';

import '../api/client_cache.dart';
import '../api/openrig_client.dart';
import '../chat/session_log.dart';
import '../chat/transcript.dart';
import '../models.dart';
import 'agent_jobs.dart';
import 'git_status.dart';
import '../ssh/ssh_exec.dart';
import 'chat_cache.dart';
import 'chat_sync.dart';
import 'loose_agents.dart';
import 'needs_you.dart';
import 'projects.dart';
import 'prompt_screen.dart';
import 'subagents.dart';

/// The newest thing said in one agent's chat, read from its session log.
class LastMessage {
  LastMessage({required this.text, required this.fromUser, this.at, this.tool});

  /// The message, or what the agent is doing when its newest entry is a tool call.
  final String text;
  final bool fromUser;
  final DateTime? at;

  /// "EDIT src/router.ts" when the agent's newest entry is a tool call.
  final String? tool;

  /// Picks the newest message out of [lines] (session log JSONL), or null.
  static LastMessage? fromLog(List<String> lines) {
    final t = ChatTranscript()..addAll(lines);
    String? tool;
    DateTime? toolAt;
    for (final item in t.items.reversed) {
      switch (item) {
        case ToolCall():
          if (tool == null) {
            tool = [item.verb, item.target].where((s) => s.isNotEmpty).join(' ');
            toolAt = item.at;
          }
        case AssistantMessage(:final text):
          return LastMessage(text: text, fromUser: false, at: toolAt ?? item.at, tool: tool);
        case UserMessage(:final text):
          return LastMessage(text: text, fromUser: true, at: toolAt ?? item.at, tool: tool);
        case NoteItem():
          break;
      }
    }
    return tool == null ? null : LastMessage(text: '', fromUser: false, at: toolAt, tool: tool);
  }
}

/// [hosts] with the unreachable ones after the live ones, each group in its own order: the Rigs home and the sidebar list
/// them this way.
List<Host> liveHostsFirst(Iterable<Host> hosts) => [
      ...hosts.where((h) => fleet.feedFor(h).error == null),
      ...hosts.where((h) => fleet.feedFor(h).error != null),
    ];

/// One script for every seat's log: `@@pr-seat <i>` and then its newest
/// chat lines. Tool results are left out: they're big and say nothing new.
@visibleForTesting
String lastMessagesScript(List<Seat> seats) {
  final b = StringBuffer();
  for (var i = 0; i < seats.length; i++) {
    b.write('echo "@@pr-seat $i"; ');
    b.write('f=\$( ( ${locateLogScript(seats[i], exactOnly: true)} ) ); ');
    b.write('[ -n "\$f" ] && tail -c 262144 "\$f" | grep -v \'"tool_result"\' '
        '| grep -E \'"type": ?"(assistant|user)"\' | tail -n 6; ');
  }
  b.write('true');
  return b.toString();
}

/// Splits [lastMessagesScript]'s output back into one message per seat.
@visibleForTesting
Map<int, LastMessage> parseLastMessages(String out) {
  final bySeat = <int, List<String>>{};
  List<String>? cur;
  for (final line in const LineSplitter().convert(out)) {
    if (line.startsWith('@@pr-seat ')) {
      cur = bySeat[int.tryParse(line.substring(10).trim()) ?? -1] = [];
    } else {
      cur?.add(line);
    }
  }
  return {
    for (final e in bySeat.entries)
      if (LastMessage.fromLog(e.value) case final m?) e.key: m,
  };
}

/// What one host is running, kept fresh while anything listens: rigs and
/// their seats, agents outside a rig, the daemon's attention feed, and (on
/// request) each agent's newest chat message. Reloads when the daemon's
/// event stream reports something, and polls as the fallback.
class HostFeed extends ChangeNotifier {
  HostFeed(this._host);

  Host _host;
  Host get host => _host;

  List<RigWithSeats> rigs = const [];
  List<LooseAgent> loose = const [];

  /// Every tmux session's processes, by session: what [Seat.jobs] comes from.
  Map<String, List<AgentJob>> jobs = const {};

  /// The project shells (tmux `rp-*`) from the same scan.
  List<ProjectShell> shells = const [];

  /// Running subagents by parent Claude session.
  Map<String, List<Subagent>> subagents = const {};

  /// [seat]'s running subagents, oldest first.
  List<Subagent> subagentsOf(Seat seat) => subagents[claudeSessionOf(seat)] ?? const [];
  List<AttentionItem> attention = const [];
  String? error;
  bool loaded = false;
  DateTime? scannedAt;

  /// Newest chat message per agent, by [chatKey].
  Map<String, LastMessage> lastMessages = const {};
  DateTime? messagesAt;
  bool loadingMessages = false;

  /// Each folder's pull request (null: none), from [refreshPrs] or a chat's git bar. Allowed to go stale.
  final Map<String, PullRequest?> prs = {};
  DateTime? _prsAt;
  bool _loadingPrs = false;

  OpenRigClient get api => cachedClient(_host);

  /// Rigs a screen has open: their seats load on every poll. The others load
  /// when their counts change, when the host reports an event, or [seatsEvery].
  final _focus = <String, int>{};
  final _seatsAt = <String, ({DateTime at, String sig})>{};

  /// Each rig's seat levels (Seat.level), by rig id: fetched once per rig, as a rig's hierarchy rarely changes.
  final _levels = <String, Map<String, int>>{};

  void _applyLevels() {
    for (final r in rigs) {
      for (final s in r.seats) {
        s.level = _levels[r.rig.id]?[s.logicalId];
      }
    }
  }

  Future<void> _loadLevels(OpenRigClient client, bool Function() current) async {
    var got = false;
    for (final r in rigs.where((r) => !_levels.containsKey(r.rig.id))) {
      try {
        _levels[r.rig.id] = (await client.topology(r.rig.id)).levels;
        got = true;
      } catch (_) {/* no levels: the seat keeps the middle window */}
      if (!current()) return;
    }
    if (got) {
      _applyLevels();
      _notify();
    }
  }
  bool _all = true; // the next load fetches every rig (first load, a host event, pull-to-refresh)
  static const seatsEvery = Duration(seconds: 60);

  /// Agents outside a rig: the daemon's tmux scan is its slowest call.
  static const scanEvery = Duration(minutes: 10);

  /// Keeps [rigId] polled while a screen shows it; call the result when it closes.
  VoidCallback focus(String rigId) {
    _focus[rigId] = (_focus[rigId] ?? 0) + 1;
    return () {
      if ((_focus[rigId] ?? 0) <= 1) {
        _focus.remove(rigId);
      } else {
        _focus[rigId] = _focus[rigId]! - 1;
      }
    };
  }

  static String _sig(Rig r) => '${r.nodeCount}/${r.runningCount}/${r.attentionCount}/${r.status}';

  bool _fresh(Rig r) {
    if (_all || _focus.containsKey(r.id)) return false;
    final seen = _seatsAt[r.id];
    return seen != null && seen.sig == _sig(r) && DateTime.now().difference(seen.at) < seatsEvery;
  }

  int _listeners = 0;
  Timer? _timer;
  Timer? _soon;
  StreamSubscription<RigEvent>? _events;
  ValueNotifier<bool>? _connected;
  OpenRigClient? _listeningTo;
  bool _forceScan = false;
  bool _disposed = false;

  /// What waits on you here (the Inbox's Needs you list); [needsYou] is its length.
  List<NeedsYouItem> get needsYouItems => needsYouList(rigs, loose, attention);
  int get needsYou => needsYouItems.length + coreAsks;

  /// Structured questions (the Core app job) waiting on the person here: counted with the asks above, in the tab badge and
  /// the Inbox's own number. Set by the Inbox when it reads them.
  int coreAsks = 0;
  void setCoreAsks(int n) {
    if (n == coreAsks) return;
    coreAsks = n;
    needsYouCount.value = fleet._feeds.values.fold(0, (a, f) => a + f.needsYou);
    notifyListeners();
  }

  int get runningRigs => rigs.where((r) => r.rig.status != 'stopped').length;

  /// The host's projects, needs-you first.
  List<Project> get projects => groupIntoProjects(rigs, _host.pinnedFolders, loose, attention, shells);

  /// The host's settings changed (name, pins, notify kinds).
  void updateHost(Host h) {
    if (identical(h, _host)) return;
    final moved = h.address != _host.address || h.daemonPort != _host.daemonPort;
    _host = h;
    if (_listeners > 0) _sync?.start(); // a changed host key is trusted again
    if (moved) {
      rigs = const [];
      loose = const [];
      subagents = const {};
      attention = const [];
      lastMessages = const {};
      loaded = false;
      error = null;
      if (_listeners > 0) {
        _listen();
        _inFlight = null; // the old client's load is discarded by current(); don't wait on it
        refresh();
      }
    }
    _notify();
  }

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (_listeners++ == 0) _start();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (--_listeners == 0) _stop();
  }

  void _start() {
    _listen();
    _schedule();
    scheduleMicrotask(refresh);
    // The chats are pulled in the background; refreshMessages is the fallback without a cache.
    if (chatCache != null) {
      _sync ??= ChatSync(
        host: () => _host,
        seats: () => [for (final (s, _) in chatAgents) s],
        onLines: _syncedLines,
      )..start();
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _soon?.cancel();
    _soon = null;
    _sync?.stop();
    _sync = null;
    _unlisten();
  }

  ChatSync? _sync;
  bool _paused = false;

  void pause() {
    if (_paused || _listeners == 0) return;
    _paused = true;
    _stop();
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    if (_listeners > 0) _start();
  }

  /// The newest message of a chat the background pull just saved to, for its preview.
  void _syncedLines(String key, List<String> lines) {
    final m = LastMessage.fromLog(lines.length > 60 ? lines.sublist(lines.length - 60) : lines);
    if (m == null || _disposed) return;
    lastMessages = {...lastMessages, key: m};
    messagesAt = DateTime.now();
    _notify();
  }

  void _listen() {
    final client = api;
    if (identical(client, _listeningTo)) return;
    _unlisten();
    _listeningTo = client;
    _connected = client.live.connected..addListener(_schedule);
    _events = client.live.stream.listen((_) {
      _sync?.poke();
      // Coalesce bursts into one reload.
      _soon ??= Timer(const Duration(milliseconds: 400), () {
        _soon = null;
        _all = true;
        refresh();
      });
    });
  }

  void _unlisten() {
    _events?.cancel();
    _events = null;
    _connected?.removeListener(_schedule);
    _connected = null;
    _listeningTo = null;
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed || _listeners == 0) return;
    final every = _connected?.value == true ? const Duration(seconds: 30) : const Duration(seconds: 5);
    _timer = Timer.periodic(every, (_) => refresh());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void>? _inFlight;

  /// Reloads now; [scan] also asks the daemon to look for agents outside a rig.
  Future<void> refresh({bool scan = false}) {
    if (scan) _forceScan = _all = true;
    if (_inFlight case final f?) return f;
    late final Future<void> mine;
    // Only clear our own load: updateHost may have started a newer one meanwhile.
    mine = _load().whenComplete(() {
      if (identical(_inFlight, mine)) _inFlight = null;
    });
    return _inFlight = mine;
  }

  Future<void> _load() async {
    final host = _host;
    final client = api;
    bool current() => !_disposed && identical(client, api);
    try {
      final results = await Future.wait([
        client.rigsWithSeats(known: {for (final r in rigs) r.rig.id: r.seats}, reuse: _fresh),
        client.attention().catchError((_) => <AttentionItem>[]),
      ]);
      if (!current()) return;
      final previous = {for (final r in rigs) r.rig.id: r.seats};
      rigs = results[0] as List<RigWithSeats>;
      for (final r in rigs) {
        if (identical(previous[r.rig.id], r.seats)) continue; // reused, not fetched: keeps its age
        _seatsAt[r.rig.id] = (at: DateTime.now(), sig: _sig(r.rig));
      }
      _all = false;
      // The last scan's shells until this round's arrives, so states don't flicker.
      applyShells([for (final r in rigs) ...r.seats]);
      _applyLevels();
      _loadLevels(client, current);
      attention = results[1] as List<AttentionItem>;
      error = null;
      loaded = true;
      _notify();
      fleet._reported(this);

      // Agents outside a rig: the daemon only scans tmux when asked, so ask
      // on pull-to-refresh and at most once a minute otherwise.
      final now = DateTime.now();
      final scan = _forceScan || scannedAt == null || now.difference(scannedAt!) > scanEvery;
      _forceScan = false;
      var complete = true;
      var subs = subagents;
      var jobsNow = jobs;
      var shellsNow = shells;
      final found = await loadLooseAgents(host, client, rigs,
          scan: scan,
          onPartial: () => complete = false,
          onSubagents: (l) => subs = Subagent.bySession(l),
          onJobs: (j) => jobsNow = j,
          onShells: (l) => shellsNow = l,
          // The first load shows the daemon's agents at once; the hook file and tmux's answer follow and replace them.
          onDiscovered: (l) {
            if (!current() || loose.isNotEmpty || l.isEmpty) return;
            loose = l;
            _notify();
          });
      chatCache?.prune(host.id, rigs, complete ? found : null).catchError((Object e) {
        logWarning('chat cache: $e');
      });
      if (!current()) return;
      loose = found;
      subagents = subs;
      jobs = jobsNow;
      shells = shellsNow;
      await _checkScreens();
      if (!current()) return;
      applyShells([for (final r in rigs) ...r.seats]);
      if (scan) scannedAt = now;
      _notify();
      fleet._reported(this);
    } catch (e) {
      if (!current()) return;
      error = e.toString();
      loaded = true;
      _notify();
    }
  }

  /// Marks each of [seats] with the shell it's waiting on, from the last scan.
  void applyShells(List<Seat> seats) {
    for (final s in seats) {
      final j = jobs[s.sessionName];
      s.jobs = j == null ? const [] : AgentJob.waitingOn(j, working: s.activity == 'working');
      s.waitingSubagents = s.activity == 'working' ? 0 : subagentsOf(s).length;
      s.screenClear = _noDialog.contains(s.sessionName);
    }
  }

  /// Sessions whose daemon ask the last [_checkScreens] found without a dialog on screen.
  Set<String> _noDialog = const {};

  /// Reads the screen of each Claude seat the daemon says is asking; one SSH call, and only when one is. Any
  /// failure leaves the daemon's word standing.
  Future<void> _checkScreens() async {
    final host = _host;
    final asking = [
      for (final r in rigs)
        for (final s in r.seats)
          if (asksWithDialog(s)) s.sessionName!
    ];
    var clear = <String>{};
    if (asking.isNotEmpty && (host.isLocal || host.privateKeyPem != null)) {
      try {
        clear = sessionsWithoutDialog(await SshExec.use(host, (ssh) => ssh.runLogin(screensScript(asking))));
      } catch (e) {
        logInfo('screen check: $e');
      }
    }
    if (_disposed || !identical(host, _host)) return;
    _noDialog = clear;
  }

  /// Every agent that has a chat log: rig seats and agents outside a rig.
  List<(Seat, RigWithSeats?)> get chatAgents => [
        for (final r in rigs)
          for (final s in r.seats)
            if (s.isAgent && s.state != SeatState.stopped) (s, r),
        for (final a in loose) (a.toSeat(), null),
      ];

  /// Reads each Claude agent's newest message over SSH, at most every [every].
  Future<void> refreshMessages({Duration every = const Duration(seconds: 45), bool force = false}) async {
    if (_sync != null) return _sync!.poke(); // the background pull keeps lastMessages current
    if (loadingMessages) return;
    if (!force && messagesAt != null && DateTime.now().difference(messagesAt!) < every) return;
    final host = _host;
    if (host.privateKeyPem == null) return;
    final seats = [
      for (final (s, _) in chatAgents)
        if (s.isClaude) s
    ];
    if (seats.isEmpty) return;
    loadingMessages = true;
    _notify();
    try {
      await SshExec.use(host, (ssh) async {
        final found = parseLastMessages(await ssh.run(lastMessagesScript(seats)));
        if (_disposed || !identical(host, _host)) return;
        lastMessages = {for (final e in found.entries) chatKey(seats[e.key]): e.value};
        messagesAt = DateTime.now();
      });
    } catch (e) {
      logWarning('last messages on ${host.name}: $e');
      messagesAt = DateTime.now();
    } finally {
      loadingMessages = false;
      _notify();
    }
  }

  /// Looks up [folders]' pull requests over SSH: all of them at most every
  /// [every], folders not seen before right away.
  Future<void> refreshPrs(Iterable<String> folders, {Duration every = const Duration(minutes: 5)}) async {
    final host = _host;
    if (_loadingPrs || host.privateKeyPem == null) return;
    final stale = _prsAt == null || DateTime.now().difference(_prsAt!) >= every;
    final todo = {for (final d in folders) if (stale || !prs.containsKey(d)) d};
    if (todo.isEmpty) return;
    if (stale) _prsAt = DateTime.now();
    _loadingPrs = true;
    try {
      await SshExec.use(host, (ssh) async {
        for (final d in todo) {
          try {
            prs[d] = (await ssh.gitStatus(d)).pr;
          } catch (_) {
            prs.putIfAbsent(d, () => null); // Not asked again until the next full pass.
          }
          if (_disposed || !identical(host, _host)) return;
        }
      });
    } catch (e) {
      logWarning('pull requests on ${host.name}: $e');
    } finally {
      _loadingPrs = false;
      _notify();
    }
  }

  /// Stops for good: the host is gone. Screens may still be holding it.
  void retire() {
    _disposed = true;
    _stop();
  }

  @override
  void dispose() {
    retire();
    super.dispose();
  }
}

/// What a rig row lists: nothing, the seats that work or need you, or every seat. See [Fleet.rigView].
enum RigView { collapsed, active, all }

/// A feed per stored host. Screens ask for the feeds of the hosts they show
/// and listen to them; a feed polls only while something listens.
class Fleet extends ChangeNotifier {
  final Map<String, HostFeed> _feeds = {};

  /// Hosts and worktree groups folded shut (they start open); kept while the app runs.
  final Set<String> _flipped = {};

  /// Whether the node [key] is open (they start open).
  bool isOpen(String key) => !_flipped.contains(key);

  void toggle(String key) {
    if (!_flipped.remove(key)) _flipped.add(key);
    notifyListeners();
  }

  /// What a rig or folder row lists under it: nothing, only what is active, or everything. The person's pick per row.
  final Map<String, RigView> _view = {};

  /// One key per rig, so Projects, a project's Agents tab and the desktop sidebar fold it together.
  static String rigKey(Host host, RigWithSeats r) => 'r:${host.id}|${r.rig.id}';

  /// Hosts whose sidebar section is folded to its header, remembered for the session like the projects' and rigs' folds.
  final Set<String> _hostsFolded = {};
  bool hostFolded(String hostId) => _hostsFolded.contains(hostId);
  void toggleHost(String hostId) {
    if (!_hostsFolded.remove(hostId)) _hostsFolded.add(hostId);
    notifyListeners();
  }

  /// One key per project folder in the sidebar.
  static String folderKey(Host host, String path) => 'p:${host.id}|$path';

  /// Working, waiting on you, waiting on a shell or monitor, or idle while its subagents run. Idle ones are not active:
  /// an agent waiting on a shell is never folded away.
  static bool seatActive(Seat s) => stateActive(s.state) || s.waitingSubagents > 0;

  /// The one rule for 'active': needs you, working, or waiting on a shell (an agent on a shell is not folded away). Every
  /// active-only view and every active count (host, project, rig) goes through it; the structured questions add to the counts.
  static bool stateActive(SeatState s) => s == SeatState.needsYou || s == SeatState.working || s == SeatState.shell;

  /// The view of row [key] whose children are [anyActive] or not: an active view with nothing active shows as
  /// collapsed. A rig starts on active, a folder on all.
  RigView viewOf(String key, bool anyActive, {RigView start = RigView.active}) {
    final v = _view[key];
    if (v != null) return v; // a view that was chosen stays, active only included, even when nothing is active
    // Unchosen: a row that starts at active only opens folded when nothing in it is active.
    return start == RigView.active && !anyActive ? RigView.collapsed : start;
  }

  /// The next view in the cycle collapsed > active > all > collapsed. Active is never skipped: with nothing active the row says
  /// 'No active agents', so the middle state is still seen and reached ([anyActive] only decides the unchosen default).
  void cycle(String key, bool anyActive, {RigView start = RigView.active}) {
    _view[key] = switch (viewOf(key, anyActive, start: start)) {
      RigView.collapsed => RigView.active,
      RigView.active => RigView.all,
      RigView.all => RigView.collapsed,
    };
    notifyListeners();
  }

  RigView rigView(String key, List<Seat> seats) => viewOf(key, seats.any(seatActive));

  /// The seats a rig row lists under it.
  List<Seat> rigSeatsShown(String key, List<Seat> seats) => switch (rigView(key, seats)) {
        RigView.all => seats,
        RigView.collapsed => const [],
        RigView.active => seats.where(seatActive).toList(),
      };

  void cycleRig(String key, List<Seat> seats) => cycle(key, seats.any(seatActive));

  /// Sets a row's view directly (the sidebar's long-press list).
  void setView(String key, RigView v) {
    _view[key] = v;
    notifyListeners();
  }

  /// Folds a rig row that lists every seat ([allShown]); otherwise unfolds it to every seat.
  void toggleRig(String key, {required bool allShown}) {
    _view[key] = allShown ? RigView.collapsed : RigView.all;
    notifyListeners();
  }

  AppLifecycleListener? _life;

  /// In the background nothing polls, listens or holds a connection; coming back reloads.
  void _watchLifecycle() {
    try {
      _life ??= AppLifecycleListener(onStateChange: (s) {
        if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) {
          for (final f in _feeds.values) {
            f.pause();
          }
          sshPool.closeIdle();
        } else if (s == AppLifecycleState.resumed) {
          sshPool.checkAll();
          for (final f in _feeds.values) {
            f.resume();
          }
        }
      });
    } catch (_) {
      // No binding (a plain unit test).
    }
  }

  HostFeed feedFor(Host host) {
    _watchLifecycle();
    final f = _feeds[host.id];
    if (f != null) {
      f.updateHost(host);
      return f;
    }
    return _feeds[host.id] = HostFeed(host);
  }

  /// The feeds of [hosts], in order; feeds of removed hosts are dropped.
  List<HostFeed> sync(List<Host> hosts) {
    final keep = {for (final h in hosts) h.id};
    final dropped = _feeds.keys.where((id) => !keep.contains(id)).toList();
    for (final id in dropped) {
      final gone = _feeds.remove(id)!;
      // Screens may still hold it this frame: stop it rather than dispose it.
      gone.retire();
      needsYouAlerts.forgetHost(id);
    }
    // Its asks leave the count now, not at the next report from another host (which may never come).
    if (dropped.isNotEmpty) needsYouCount.value = _feeds.values.fold(0, (n, f) => n + f.needsYou);
    return [for (final h in hosts) feedFor(h)];
  }

  /// Every known host's open asks, for the tab label and the banner.
  void _reported(HostFeed feed) {
    needsYouCount.value = _feeds.values.fold(0, (n, f) => n + f.needsYou);
    final host = feed.host;
    needsYouAlerts.report(host, [
      for (final r in feed.rigs)
        for (final s in r.seats)
          if (s.needsInput)
            SeatAlert(
              host: host,
              rig: r.rig,
              seat: s,
              project: r.primaryCwd == null
                  ? null
                  : mainCheckout(r.primaryCwd!).split('/').where((p) => p.isNotEmpty).lastOrNull,
            ),
    ]);
    notifyListeners();
  }

  @visibleForTesting
  void reset() {
    for (final f in _feeds.values) {
      f.retire();
    }
    _feeds.clear();
    _flipped.clear();
    _view.clear();
    needsYouCount.value = 0;
  }
}

final fleet = Fleet();

/// The shells and monitors [a] (outside a rig) is waiting on, from [host]'s last process scan.
List<AgentJob> jobsOfLoose(Host? host, LooseAgent a) {
  final jobs = host == null ? null : fleet.feedFor(host).jobs[a.tmuxSession];
  return jobs == null ? const [] : AgentJob.waitingOn(jobs, working: a.isWorking(DateTime.now()));
}

/// Subagents [a] (outside a rig) waits on: running while it's idle at its prompt.
int subagentsWaitingOf(Host? host, LooseAgent a) =>
    host == null || a.isWorking(DateTime.now()) ? 0 : fleet.feedFor(host).subagentsOf(a.toSeat()).length;

/// "2 subagents" for [seat] on [host], or null when none run (or no host).
String? subagentsOn(Host? host, Seat seat) => host == null ? null : subagentsLabel(fleet.feedFor(host).subagentsOf(seat));
