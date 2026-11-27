// The demo build: the app on the golden-test fixtures, for checking a design live. It is a separate entrypoint, built only
// by scripts/demo-build.sh (`flutter build -t tool/demo/main_demo.dart`); it lives outside lib/, and the shipped app (lib/main.dart) never imports it.
// No network, no SSH, no keychain (the secure storage is the in-memory mock), no real hosts. It reaches into the test
// fixtures on purpose: one set of invented rigs, seats and asks serves the boards and this app.
//
//   --dart-define=POCKETRIG_THEME=light|dark   forces the theme (default: the system's)
//   --dart-define=POCKETRIG_DEMO_VARIANT=empty|stopped  This Mac only: nothing at all, or just a stopped rig
//   New sheet › Location › Type a path…: the fake host answers ~/code/app (a git repository with a worktree), /srv/x (a folder, not
//   git), ~/code/missing (no such folder), ~/afile.txt (a file); any other path is a folder. (fakeShell in test/golden/fixtures.dart.)
//   --dart-define=POCKETRIG_DEMO_SCREEN=rig|rig-graph|rig-work|rig-code|rig-progress|rig-stopped|rig-failed|terminal|glyphs|chat|chat-worktree|artifact-html|artifact-html-styled|panels|drawer|settings|host-editor|seat|rig-menu|stop-rig|inbox|new|new-path-ok|new-path-missing|new-path-file|new-path-nogit  opens that screen at launch;
//   afterwards scripts/demo-screen.sh <screen> opens another in the running app (it polls /tmp/pocketrig-demo-screen-<pid>)
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/host_store.dart';
import 'package:pocket_rig/data/usage_rings.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/appearance.dart';
import 'package:pocket_rig/ui/debug_overlay_setting.dart' show debugOverlay;
import 'package:pocket_rig/terminal/transport.dart' show SeatTarget, debugOpenTerminal;
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell, shownDetailPane;
import 'package:pocket_rig/ui/kit.dart' show AgentRow, BorderedList, panelRouteName;
import 'package:pocket_rig/ui/status_shape.dart' show Status;
import 'package:pocket_rig/ui/usage_strip.dart' show debugUsageClock;
import 'package:pocket_rig/ui/needs_you_banner.dart' show inboxRequests;
import 'package:pocket_rig/ui/new_sheet.dart' show showNew;
import 'package:pocket_rig/ui/terminal_screen.dart' show TerminalScreen;
import 'package:drift/native.dart' show NativeDatabase;
import 'package:pocket_rig/data/chat_cache.dart' show ChatCache, RigMedia, chatCache, chatKey;
import 'package:pocket_rig/ui/agent_panels_sheet.dart' show showPanelsSheet;
import 'package:pocket_rig/ui/rig/rig_host.dart' show rigRoute;
import 'package:pocket_rig/ui/artifact_viewer.dart' show ArtifactViewer;
import 'package:pocket_rig/ui/chat_screen.dart' show ChatScreen;
import 'package:pocket_rig/data/git_status.dart' show Worktree;
import 'package:pocket_rig/models.dart' show Project, Seat;
import 'package:pocket_rig/ui/project/worktree_delete.dart' show deleteWorktree;
import 'package:pocket_rig/ui/project/worktree_screen.dart' show WorktreeScreen;
import 'package:pocket_rig/ui/project_actions.dart' show newWorktree;
import 'package:pocket_rig/ui/hosts/host_editor.dart' show HostEditor;
import 'package:pocket_rig/ui/hosts_screen.dart' show HostsScreen;
import 'package:pocket_rig/ui/project_screen.dart' show ProjectScreen;
import 'package:pocket_rig/ui/rig/rig_actions.dart' show showRigActions;
import 'package:pocket_rig/ui/rig/seat_sheet.dart' show showSeatSheet;
import 'package:pocket_rig/ui/stop_rig.dart' show confirmStopRig;

import '../../test/golden/fixtures.dart';

/// True only in a build made with `--dart-define=POCKETRIG_DEMO=true`; the shipped app is built without it.
const bool kDemoBuild = bool.fromEnvironment('POCKETRIG_DEMO');

const _theme = String.fromEnvironment('POCKETRIG_THEME');
const _variant = String.fromEnvironment('POCKETRIG_DEMO_VARIANT');
const _screen = String.fromEnvironment('POCKETRIG_DEMO_SCREEN');

/// The theme the build forces, or null for the system's.
ThemeMode? get demoThemeMode => switch (_theme) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => null,
    };

String _ago(Duration d) => DateTime.now().toUtc().subtract(d).toIso8601String();

/// What the fixtures lack for the demo (and only for it, so no board changes): two more idle agents in the running conveyor
/// rig (last active 3 and 25 minutes ago), and a rig whose seats are all idle in a project of its own.
void _moreFixtures() {
  Map<String, Object?> idle(String rig, String rigId, String id, String cwd, Duration ago) => {
        ...nodes['r-conveyor']!.last, // the idle 'tests' seat
        'nodeId': 'n-$rig-$id',
        'rigId': rigId,
        'rigName': rig,
        'logicalId': id,
        'canonicalSessionName': '$id@$rig',
        'resumeToken': 'sess-$id',
        'cwd': cwd,
        'runtime': 'claude-code',
        'lastActivityAt': _ago(ago),
      };
  nodes['r-conveyor']!
    ..add(idle('conveyor', 'r-conveyor', 'docs', app, const Duration(minutes: 3)))
    ..add(idle('conveyor', 'r-conveyor', 'archivist', app, const Duration(minutes: 25)));
  rigs[0]['nodeCount'] = 6;
  // impl stops working and waits on a shell it started (see _demoScan): an agent in the 'on shell' state.
  final i = nodes['r-conveyor']!.indexWhere((n) => n['logicalId'] == 'impl');
  nodes['r-conveyor']![i] = {
    ...nodes['r-conveyor']![i],
    'activityState': {'activity': 'idle-at-prompt', 'display': 'idle', 'needsInput': {'count': 0, 'reason': null}},
    'pendingWorkCount': 0,
  };
  const notes = '/Users/me/code/notes';
  rigs.add({'rigId': 'r-docs', 'name': 'docs-sync', 'nodeCount': 2, 'runningCount': 2, 'attentionCount': 0, 'status': 'running', 'uptime': '3h 40m'});
  nodes['r-docs'] = [
    idle('docs-sync', 'r-docs', 'writer', notes, const Duration(minutes: 40)),
    idle('docs-sync', 'r-docs', 'linker', notes, const Duration(hours: 2)),
  ];
  // A rig with a seat that failed to launch (O3): 'qa' is red with the reason and a Retry.
  rigs.add({'rigId': 'r-pilot', 'name': 'pilot-crew', 'nodeCount': 2, 'runningCount': 1, 'attentionCount': 1, 'status': 'partial', 'uptime': '4m'});
  nodes['r-pilot'] = [
    {...idle('pilot-crew', 'r-pilot', 'lead', app, const Duration(minutes: 1)), 'startupStatus': 'ready'},
    {
      ...idle('pilot-crew', 'r-pilot', 'qa', app, const Duration(minutes: 4)),
      'runtime': 'codex',
      'startupStatus': 'failed',
      'latestError': 'codex: command not found',
      'sessionStatus': null,
    },
  ];
}

/// The five shells conveyor's 'impl' waits on, the first its 'dev server' (which the Shells page's output tail belongs to).
String _implJobs(String snap) => [
      for (final (i, (age, cmd)) in [
        ('00:41:00', 'dev server'),
        ('00:38:00', 'storybook'),
        ('00:25:00', 'test --watch'),
        ('00:19:00', 'docker compose up db'),
        ('00:03:00', 'tail -f logs/app.log'),
      ].indexed)
        "J\t${4201 + i * 10}\tS\t$age\t0.0\t0\t$snap '$cmd' < /dev/null && pwd -P >| /tmp/pwd\n",
    ].join();

/// The host scan with what a real one finds besides the loose agents: a running subagent under the working Claude agent
/// 'attacker' and a shell it started (flutter run), conveyor's idle 'impl' waiting on five shells (a list capped at three and
/// '+2 more'), the loose
/// 'codex-fix' waiting on 'npm run dev', and a project shell in each of two projects.
Future<String> _demoScan(String cmd) async {
  // The Shells page and pane ask for one agent's processes (AgentJob.script: `set -- '<session>' <lines>; …`): the same shells the
  // host scan lists, with an output tail, so the page can be checked live.
  // (runLogin wraps it in `$SHELL -lc '…'`, so the quotes around the session are escaped as '\'' there.)
  final asked = RegExp(r"set -- (?:'\\''|')([^'\\]+)(?:'\\''|') \d+;").firstMatch(cmd);
  if (asked != null) {
    const snap = 'zsh -c source /Users/me/.claude/shell-snapshots/snapshot.sh && eval';
    return switch (asked.group(1)) {
      'impl@conveyor' => "${_implJobs(snap)}"
          'O\t4201\t2048\tlistening on http://localhost:8080\n'
          'L\t4201\tcompiled 212 modules in 3.1s\nL\t4201\tlistening on http://localhost:8080\n',
      'codex-fix' => "J\t4301\tS\t00:12:00\t0.0\t0\t$snap 'npm run dev' < /dev/null && pwd -P >| /tmp/pwd\n"
          'O\t4301\t512\tready in 412 ms\nL\t4301\tvite v5 dev server running\nL\t4301\tready in 412 ms\n',
      'attacker@adversarial-review' => "J\t4101\tS\t02:10:00\t0.0\t0\t$snap 'flutter run -d macos' < /dev/null && pwd -P >| /tmp/pwd\n"
          'O\t4101\t8192\tSyncing files to device macOS\nL\t4101\tLaunching lib/main.dart on macOS\nL\t4101\tSyncing files to device macOS\n',
      _ => '',
    };
  }
  final base = await fakeShell(cmd);
  if (!cmd.contains('@@pocketrig-subagents') && !cmd.contains('@@pocketrig-jobs')) return base;
  final now = DateTime.now();
  final subs = '@@sub\tsess-attacker\ta1\t${_ago(const Duration(minutes: 2))}\t${now.millisecondsSinceEpoch ~/ 1000}\t'
      '/h/.claude/projects/p/sess-attacker/subagents/agent-a1.jsonl\n'
      '{"agentType":"general-purpose","description":"Check the diff for races"}';
  final jobs = "@@jobs\tattacker@adversarial-review:$app\n"
      "J\t4101\tS\t02:10:00\t0.0\t0\tzsh -c source /Users/me/.claude/shell-snapshots/snapshot.sh && eval 'flutter run -d macos' < /dev/null && pwd -P >| /tmp/pwd\n"
      '@@jobs\timpl@conveyor:$app\n'
      "${_implJobs('zsh -c source /Users/me/.claude/shell-snapshots/snapshot.sh && eval')}"
      '@@jobs\tcodex-fix:$app\n'
      "J\t4301\tS\t00:12:00\t0.0\t0\tzsh -c source /Users/me/.claude/shell-snapshots/snapshot.sh && eval 'npm run dev' < /dev/null && pwd -P >| /tmp/pwd\n"
      '@@jobs\trp-app:$app\n'
      '@@jobs\trp-site:$site\n';
  return '$base\n@@pocketrig-subagents\n$subs\n@@pocketrig-jobs\n$jobs';
}

/// The fixtures installed and the app's switches set so the Rigs home shows everything at once: two hosts (the second
/// offline), needs-you asks, working, idle, a stopped rig, a rig in another worktree, loose agents and shells.
///
/// [variant] 'empty': This Mac only, with no rigs and no agents at all (the "Nothing is running" screen); 'stopped': This
/// Mac only, whose one rig is stopped (which must read "Nothing is running" too).
/// The demo's own keychain service: whatever reads the keychain in the demo (the secure storage is the in-memory mock) can
/// never reach the real app's items, which is what makes macOS ask the person for permission.
const demoKeychainService = 'flutter_secure_storage_service_demo';

Future<HostStore> demoSetup({String variant = ''}) async {
  HostStore.keychainService = demoKeychainService;
  final store = await installFakes();
  AppShell.debugStartOnInbox = false; // the app's own first screen
  if (variant.isEmpty) {
    _moreFixtures();
    // The Mac dock of conveyor's lead has something to open (a file edit, a page, a note, an image): click one to see it in the main area.
    chatCache = _DemoMedia(chatKey(seatFromFixture('r-conveyor', 'lead')));
    SshExec.debugConnect = (h) async => SshExec.fake(_demoScan);
    // conveyor's graph with every link kind: the two the fixtures have (hands off to, reviewed by) and the five that have
    // their own look (delegates, collaborates, observes, escalates, spawned).
    OpenRigClient.factory = (h) => OpenRigClient(
          h,
          httpClient: MockClient((req) async {
            if (h.id == homelab.id && req.url.path == '/api/rigs/r-conveyor') {
              final topo = conveyorTopology;
              final edges = [
                ...(topo['edges']! as List),
                {'sourceId': 'n-conveyor-docs', 'targetId': 'n-conveyor-archivist', 'kind': 'collaborates_with'},
                {'sourceId': 'n-conveyor-tests', 'targetId': 'n-conveyor-impl', 'kind': 'can_observe'},
                {'sourceId': 'n-conveyor-review', 'targetId': 'n-conveyor-lead', 'kind': 'escalates_to'},
                {'sourceId': 'n-conveyor-archivist', 'targetId': 'n-conveyor-lead', 'kind': 'spawned_by'},
              ];
              return http.Response(jsonEncode({...topo, 'edges': edges}), 200, headers: {'content-type': 'application/json'});
            }
            if (h.id == homelab.id && (req.url.path.startsWith('/api/apps/v1/') || req.url.path == '/api/gateway/participants')) {
              return _coreApp(req);
            }
            // Everything else is the fixtures' daemon. A request can be sent once, so this one is copied for it.
            final copy = http.Request(req.method, req.url)
              ..headers.addAll(req.headers)
              ..bodyBytes = req.bodyBytes;
            return http.Response.fromStream(await fakeDaemon(h).send(copy));
          }),
          eventSource: ({rigId, replay, lastEventId}) =>
              rigId == 'r-conveyor' && lastEventId == null ? Stream.fromIterable(conveyorEvents).asBroadcastStream() : const Stream.empty(),
        );
    showLoose = true;
    showWorktrees = true;
    showBarRigs = true;
    showUsageLimit = true; // conveyor's tests seat is at its usage limit (resets in 2h)
    return store;
  }
  showLoose = false;
  showWorktrees = false;
  showBarRigs = false;
  await store.remove(homelab.id);
  await store.remove(macbook.id); // This Mac stays: it is the one host
  final stopped = variant == 'stopped';
  OpenRigClient.factory = (h) => OpenRigClient(
        h,
        httpClient: MockClient((req) async {
          final p = req.url.path;
          Object body = <Object>[];
          if (p == '/healthz') {
            body = {'status': 'ok', 'semver': '0.7.6'};
          } else if (stopped && p == '/api/ps') {
            body = [rigs.firstWhere((r) => r['name'] == 'research-team')];
          } else if (stopped && p.startsWith('/api/rigs/') && p.endsWith('/nodes')) {
            body = nodes['r-research'] ?? <Object>[];
          }
          return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
        }),
        eventSource: ({rigId, replay, lastEventId}) => const Stream.empty(),
      );
  return store;
}

/// A usage reading for the two demo hosts (the Rigs home's host header shows it: bars on a Mac, '5h 71% · week 34%' on a phone),
/// refreshed every minute so it never goes stale while the demo runs. Demo only: no board and no shipped build sees it.
void _demoUsage() {
  // The fixtures pin the usage clock to a day in the past (for the goldens): the demo's readings are relative to now, so read them at now.
  debugUsageClock = null;
  HostUsage claude(String host, int five, int week) {
    final now = DateTime.now().toUtc();
    return HostUsage(host: host, provider: 'claude', windows: [
      UsageWindow(window: 'five_hour', usedPercent: five, resetsAt: now.add(const Duration(hours: 2)), asOf: now),
      UsageWindow(window: 'weekly', usedPercent: week, resetsAt: now.add(const Duration(days: 4)), asOf: now),
    ]);
  }

  void set() => usageNow.set([
        // homelab: 5h over pace (red), week under (green); macbook: both on pace (grey).
        (homelab, [claude('local', 71, 34)]),
        (macbook, [claude('local', 61, 43)]),
      ]);
  set();
  Timer.periodic(const Duration(minutes: 1), (_) => set());
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await demoSetup(variant: _variant);
  if (_variant.isEmpty) _demoUsage();
  if (demoThemeMode case final mode?) appearance.value = mode;
  // No deep links and so no push registration (no notification permission dialog), and no debug-panel bug button.
  debugOverlay.value = false;
  runApp(PocketRigApp(store: store, deepLinks: false));
  if (_screen.isNotEmpty) Future<void>.delayed(const Duration(seconds: 3), () => _open(_screen));
  // scripts/demo-screen.sh writes a screen name here; the running demo opens it (no rebuild, no clicking).
  var last = '';
  Timer.periodic(const Duration(milliseconds: 700), (_) {
    final f = File(demoScreenFile);
    final want = f.existsSync() ? f.readAsStringSync().trim() : '';
    if (want.isNotEmpty && want != last) {
      last = want;
      _open(want);
    }
  });
}

/// The demo daemon's Core app job (OpenRig 0.7.22): a registered person (phone), capabilities v1 and two structured asks,
/// one with options and one for typed text. An answer is recorded and the ask leaves needs-me, as on a real daemon.
final _coreAnswers = <String, Object?>{};
http.Response _coreApp(http.Request req) {
  http.Response ok(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
  Map<String, Object?> ask(String id, String asker, String question, List<(String, String)> options) => {
        'requestId': id,
        'asker': asker,
        'body': question,
        'decisionRevision': 'dr-$id',
        'episodeKey': null,
        'questions': [
          {'id': 'q', 'question': question, 'options': [for (final (i, l) in options) {'id': i, 'label': l}]}
        ],
        'humanAnswers': _coreAnswers[id] == null ? {} : {'q': _coreAnswers[id]},
        'answer': {'job': 'human-answer', 'forms': options.isEmpty ? ['typed-reply'] : ['option', 'typed-reply']},
      };
  final asks = [
    ask('demo-q1', 'lead@conveyor', 'Which retry policy should the router use?', [('exp', 'Exponential backoff'), ('fixed', 'Fixed delay'), ('none', 'No retries')]),
    ask('demo-q2', 'review@conveyor', 'What should the release be called?', []),
  ];
  final p = req.url.path;
  if (p == '/api/gateway/participants') {
    return ok({'participants': [{'id': 'phone', 'address': 'phone@external', 'kind': 'person'}], 'default': {'id': 'phone'}});
  }
  if (p.endsWith('/capabilities')) return ok({'contract': 'openrig.core-app', 'version': 1, 'answerForms': ['option', 'typed-reply']});
  if (p.endsWith('/credentials')) return ok({'credentialId': 'demo-cred', 'token': 'orapp_demo'}, 201);
  if (p.endsWith('/needs-me')) return ok({'requests': [for (final a in asks) if (_coreAnswers[a['requestId']] == null) a]});
  if (req.method == 'POST' && p.contains('/answers/')) {
    final b = jsonDecode(req.body) as Map;
    final a = b['answer'] as Map;
    _coreAnswers[b['requestId'] as String] = a['kind'] == 'option' ? a['optionId'] : {'kind': 'typed-reply', 'text': a['text']};
    return ok({'replayed': false, 'submission': {'state': 'committed', 'outcome': 'answered'}});
  }
  if (p.contains('/answers/')) return ok({'submission': {'state': 'committed', 'outcome': 'answered'}});
  return ok({'revoked': true});
}

/// The file the running demo polls for a screen to open.
final demoScreenFile = '/tmp/pocketrig-demo-screen-$pid';

/// Opens [screen] where a tap on it would: in the content panel when the shell has one, else over everything.
void _open(String screen) {
  if (screen == 'inbox') {
    inboxRequests.value++;
    return;
  }
  // The New sheet in each state, so a capture needs no clicking: new, and the typed path checked (a git folder, no such
  // folder, a file, a folder that is not git).
  final typed = switch (screen) {
    'new-path-ok' => '~/code/app',
    'new-path-missing' => '~/code/missing',
    'new-path-file' => '~/afile.txt',
    'new-path-nogit' => '/srv/x',
    _ => null,
  };
  if (screen == 'new' || typed != null) {
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
    if (navigatorKey.currentContext case final c?) showNew(c, typed: typed);
    return;
  }
  // The phone drawer, opened as the lip would (the shell's Scaffold is private, so find the one that has a drawer).
  if (screen == 'drawer') {
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
    void visit(Element e) {
      if (e is StatefulElement && e.state is ScaffoldState && (e.widget as Scaffold).drawer != null) {
        (e.state as ScaffoldState).openDrawer();
        return;
      }
      e.visitChildren(visit);
    }
    navigatorKey.currentContext?.visitChildElements(visit);
    return;
  }
  // Sheets on conveyor and its lead, so their option rows and buttons can be checked without a tap.
  final seats = nodes['r-conveyor']!.map(Seat.fromJson).toList();
  final sheet = switch (screen) {
    'panels' => (BuildContext c) => showPanelsSheet(c, seats.first, const []),
    'seat' => (BuildContext c) => showSeatSheet(c, 'conveyor', seats.first),
    'rig-menu' => (BuildContext c) => showRigActions(c, rigFromFixture('r-conveyor'), seats),
    'stop-rig' => (BuildContext c) => confirmStopRig(c, rigFromFixture('r-conveyor'), seats),
    // The New worktree sheet with a name typed that collides: app has the worktree flaky-ci, so flaky/ci makes its folder.
    'new-worktree' => (BuildContext c) => newWorktree(c, homelab, app, null, 'flaky/ci'),
    // The dirty Delete dialog for app's flaky-ci worktree (the demo shell lists two changed files there).
    'delete-worktree' => (BuildContext c) => deleteWorktree(c,
        host: homelab,
        repo: app,
        w: Worktree('$app/.claude/worktrees/flaky-ci', 'fix/flaky-ci'),
        name: 'flaky-ci'),
    _ => null,
  };
  if (sheet != null) {
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
    if (navigatorKey.currentContext case final c?) sheet(c);
    return;
  }
  // The terminal shows board 3b's text, or (glyphs) every glyph Claude Code's and Codex's TUIs draw, to find the ones the
  // terminal font can't: compare it with the same text in Terminal.app (the file /tmp/pocketrig-glyphs.txt, written here).
  if (screen == 'terminal' || screen == 'glyphs') {
    final lines = screen == 'glyphs' ? _glyphLines : null;
    if (lines != null) File('/tmp/pocketrig-glyphs.txt').writeAsStringSync('${lines.join('\n')}\n');
    debugOpenTerminal = (h, t) async => FakeTerminal('ssh homelab · tmux attach -t conveyor-lead', lines: lines);
  }
  Widget rigPage(String id, {int initialTab = 0, int tab = 0}) =>
      // As the app builds one: a host on the Mac (Rig details toggles to the tiles in one click), the plain page on a phone.
      rigRoute(rigFromFixture(id), 'app', initialTab: initialTab, tab: tab);
  final page = switch (screen) {
    'rig' => rigPage('r-conveyor'),
    'rig-graph' => rigPage('r-conveyor', initialTab: 1),
    'rig-work' => rigPage('r-conveyor', tab: 1),
    'rig-code' => rigPage('r-conveyor', tab: 3),
    'rig-progress' => rigPage('r-conveyor', tab: 2),
    'rig-stopped' => rigPage('r-research'),
    // pilot-crew's qa seat failed to launch: red, the reason, Retry.
    'rig-failed' => rigPage('r-pilot'),
    'terminal' || 'glyphs' => TerminalScreen(target: SeatTarget('conveyor', seatFromFixture('r-conveyor', 'lead'))),
    // conveyor's lead waits on a Bash permission, so its chat shows a pending permission card.
    'chat' => ChatScreen(rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'lead'), asChat: true),
    // retry-pair's lead runs in the api-retry worktree: AgentHeader shows the branch with the worktree's name under it ('chat' is the main checkout: the branch only).
    // An agent's HTML page as the dock opens it: with no colours of its own it follows the theme (dark in dark); with its own it keeps them.
    'artifact-html' => const ArtifactViewer(path: '$app/reports/plain-report.html'),
    'artifact-html-styled' => const ArtifactViewer(path: '$app/reports/styled-report.html'),
    'chat-worktree' => ChatScreen(rigName: 'retry-pair', seat: seatFromFixture('r-wa', 'lead'), asChat: true),
    // app has a project shell in the demo scan: its page on the Shells tab.
    'project-shells' => const ProjectScreen(path: app, tab: 4),
    // The Worktrees tab (ending in the dashed New worktree row), and a worktree's page (its Changes, and the ⋯ with Delete worktree…).
    'project-worktrees' => const ProjectScreen(path: app, tab: 2),
    'worktree' => WorktreeScreen.load(host: homelab, project: Project(path: app), name: 'flaky-ci'),
    // The runtime icons in the three state colours (Z1): a working Claude, a waiting Codex, an idle runtime with no logo.
    'runtime-icons' => Scaffold(
        appBar: AppBar(title: const Text('Agent icons')),
        body: ListView(padding: const EdgeInsets.all(20), children: const [
          BorderedList(children: [
            AgentRow(name: 'lead', status: Status.working, runtime: 'claude-code', task: 'Claude · working', age: '2m', context: 44),
            AgentRow(name: 'review', status: Status.needsYou, runtime: 'codex', needsYou: true, task: 'Codex · Run npm test?', age: '5m', context: 71),
            AgentRow(name: 'scribe', status: Status.idle, runtime: 'kimi', task: 'Kimi (no logo) · idle', age: '1h'),
          ]),
        ])),
    'settings' => const HostsScreen(),
    'host-editor' => const HostEditor(),
    _ => null,
  };
  if (page == null) return;
  final nav = shownDetailPane() ?? navigatorKey.currentState;
  nav?.popUntil((r) => r.isFirst);
  // Named like the shell's own pushes, so a page opened in the content panel shows no back arrow, as from the sidebar.
  nav?.push(MaterialPageRoute<void>(settings: const RouteSettings(name: panelRouteName), builder: (_) => page));
}

/// One line per family, then a box-drawn table whose right edge shows a glyph drawn at the wrong width.
const _glyphLines = [
  'claude:  ⏺ ✻ ✶ ✳ ✢ · ⎿ ❯ ⏵⏵ ⏸ ⏴ ● ○ ◯ ◐ ◆ ◇ ▶ ▸ ✓ ✗ ✔ ✘ ⚠ ⧉ ↯ ⎯',
  'codex:   › • ◦ ▌ ▎ ⋮ ↳ ⇡ ⇣ └ ├ ✨ ⌘ ⌥ ⇧ ⏎ ↵ ⌫ ⎋',
  'braille: ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏ ⣾ ⣽ ⣻ ⢿ ⡿ ⣟ ⣯ ⣷',
  'blocks:  ░ ▒ ▓ █ ▀ ▄ ▏ ▕ ▁ ▂ ▃ ▅ ▆ ▇',
  'arrows:  ← ↑ → ↓ ↔ ↕ ⇐ ⇒ ⟶ ↩ ↪ ↻',
  'misc:    … — – ≈ ≠ ≤ ≥ ± × ÷ ° € £ ¥ © ® ™ ✉ ☐ ☑ ☒',
  '╭──────┬──────╮',
  '│ ab   │ ⏺ ✻  │',
  '├──────┼──────┤',
  '│ ⎿ ❯  │ ⠋ ✓  │',
  '╰──────┴──────╯',
  '┌──────┐ ┏━━━━┓ ╔════╗',
  '└──────┘ ┗━━━━┛ ╚════╝',
];

/// The dock's lists for conveyor's lead, as a plain stream (no database behind it).
class _DemoMedia extends ChatCache {
  _DemoMedia(this.key) : super(NativeDatabase.memory());
  final String key;
  @override
  Stream<List<RigMedia>> watchChatMedia(String hostId, String chatKey) {
    final now = DateTime.now();
    return Stream.value([
      RigMedia('file', '$app/src/rig/router.ts', null, now, key),
      RigMedia('file', '$app/docs/retry-design.md', null, now, key),
      RigMedia('file', '$app/reports/plain-report.html', null, now, key),
      RigMedia('file', '$app/reports/styled-report.html', null, now, key),
      RigMedia('image', '$app/docs/retry-flow.png', null, now, key),
    ]);
  }
}
