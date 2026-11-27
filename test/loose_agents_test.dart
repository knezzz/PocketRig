import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/deep_link.dart';
import 'package:pocket_rig/data/fleet.dart' show fleet;
import 'package:pocket_rig/data/agent_jobs.dart' show AgentJob;
import 'package:pocket_rig/data/loose_agents.dart';
import 'package:pocket_rig/data/projects.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/terminal/transport.dart' show seatAttachCommand;
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/hosts_screen.dart';
import 'package:pocket_rig/ui/loose_agent_screen.dart';

import 'golden/fixtures.dart';

void main() {
  test('the scan keeps agents, not shells, and the hook adds waiting state', () {
    final scanned = discovered.map(LooseAgent.fromDiscovery).whereType<LooseAgent>().toList();
    expect(scanned.map((a) => a.name), ['scratch', 'codex-fix'], reason: 'the plain zsh pane is not an agent');
    final all = mergeLooseAgents(scanned, parseHookFile(looseHookFile), {'lead@conveyor'});
    // Waiting first; the rig seat's own hook is dropped.
    expect(all.map((a) => a.name), ['scratch', 'claude', 'codex-fix']);
    final s = all.first;
    expect(s.discoveryId, 'd-scratch', reason: 'scan facts kept: it can be adopted');
    expect(s.claudeSessionId, 'sess-scratch');
    expect(s.isPermission, isTrue);
    expect(s.meta, 'tmux scratch · needs you');
    final tab = all[1];
    expect(tab.inTmux, isFalse);
    expect(tab.canAdopt, isFalse);
    expect(tab.meta, 'Terminal tab, no tmux · chat only');
    expect(parseHookFile('not json'), isEmpty);
    expect(parseHookFile(''), isEmpty);
  });

  test('names given in the app replace the default and survive a host save', () {
    final scanned = discovered.map(LooseAgent.fromDiscovery).whereType<LooseAgent>().toList();
    final tabId = mergeLooseAgents(scanned, parseHookFile(looseHookFile), {})
        .firstWhere((a) => !a.inTmux)
        .id;
    final host = Host.fromJson(Host(id: 'h', name: 'h', address: 'a', sshUser: 'u', agentNames: {tabId: 'Billing fix'}, specFolders: {'~/app': '~/.openrig/specs'}, rigNames: {'conveyor': 'Billing'})
        .toJson()
        .map((k, v) => MapEntry(k, jsonDecode(jsonEncode(v)))));
    final all = mergeLooseAgents(scanned, parseHookFile(looseHookFile), {}, labels: host.agentNames);
    expect(all.firstWhere((a) => a.id == tabId).name, 'Billing fix');
    expect(all.where((a) => a.label != null), hasLength(1), reason: 'others keep their tmux or runtime name');
    expect(host.specFolders, {'~/app': '~/.openrig/specs'});
    expect([host.rigLabel('conveyor'), host.rigLabel('release')], ['Billing', 'release']);
  });

  test('a loose agent opens like a seat with no rig', () {
    final s = scratchAgent().toSeat();
    expect(s.rigId, '');
    expect(s.sessionName, 'scratch');
    expect(seatAttachCommand(s), "exec tmux -u attach -t '=scratch'", reason: 'the seat rebuilds its attach line');
    expect(s.needsInput, isTrue);
    expect(s.needsInputReason, 'Bash: rm -rf dist && npm run build');
    expect(s.transcriptPath, endsWith('sess-scratch.jsonl'));
    final tab = LooseAgent(id: 'x', claudeSessionId: 'x', waiting: true, waitingKind: 'permission');
    expect(tab.toSeat().needsInput, isFalse, reason: 'no tmux, nothing to press the key into');
  });

  test('the daemon\'s agents are handed over before the slow SSH read finishes, so a first load does not wait on it', () async {
    final store = await installFakes();
    showLoose = true;
    addTearDown(() => showLoose = false);
    final gate = Completer<void>();
    SshExec.debugConnect = (h) async {
      await gate.future;
      return SshExec.fake(fakeShell);
    };
    addTearDown(() => SshExec.debugConnect = null);
    final host = store.active!;
    final early = <String>[];
    final done = loadLooseAgents(host, OpenRigClient.factory(host), const [], onDiscovered: (l) => early.addAll(l.map((a) => a.name)));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(early, unorderedEquals(['scratch', 'codex-fix']), reason: 'the scan\'s agents, while SSH is still pending');
    var finished = false;
    unawaited(done.then((_) => finished = true));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(finished, isFalse, reason: 'the full list waits for SSH');
    gate.complete();
    final all = await done;
    expect(all.map((a) => a.name), containsAll(['scratch', 'codex-fix']));
  });

  test('a loose agent in a subfolder, a worktree or behind a trailing slash files under its project, in one rule for rigs and agents', () {
    final rigs = rigsWithSeatsFromFixture();
    final root = groupIntoProjects(rigs, const []).firstWhere((p) => p.rigs.isNotEmpty).path;
    final agents = [
      for (final (id, cwd) in [
        ('sub', '$root/lib/src'),
        ('wt', '$root/.claude/worktrees/feat-x'),
        ('wt-sub', '$root/.claude/worktrees/feat-x/lib'),
        ('slash', '$root/'),
        ('same', root),
      ])
        LooseAgent(id: id, cwd: cwd),
    ];
    final projects = groupIntoProjects(rigs, const [], agents);
    final p = projects.firstWhere((p) => p.path == root);
    expect(p.loose.map((a) => a.id), unorderedEquals(['sub', 'wt', 'wt-sub', 'slash', 'same']));
    expect(projects.where((q) => q.loose.isNotEmpty), [p], reason: 'no project of its own for any of them');
    expect(byWorktree(p).map((g) => g.$1), containsAll([null, 'feat-x']), reason: 'the worktree one is told apart, under the same project');
  });

  test('a session the daemon calls unknown is still an agent when its process title is a Claude Code version, hook or no hook', () {
    Map<String, Object?> row(String hint, String cmd) => {
          'id': 'd-x', 'tmuxSession': 'claude-home-1a2b', 'status': 'active', 'cwd': '/Users/me', 'runtimeHint': hint, 'activeCommand': cmd,
        };
    expect(LooseAgent.fromDiscovery(row('unknown', '2.1.332'))?.runtime, 'claude-code', reason: 'a version title is Claude Code');
    expect(LooseAgent.fromDiscovery(row('unknown', 'zsh')), isNull, reason: 'a shell is not an agent');
    expect(LooseAgent.fromDiscovery(row('unknown', 'node')), isNull);
    expect(LooseAgent.fromDiscovery(row('shell', '2.1.332')), isNull, reason: 'only an unknown one is reclassified');
    // Without the hook file it still joins the folder it runs in (a home folder takes only its own agents).
    final a = LooseAgent.fromDiscovery(row('unknown', '2.1.332'))!;
    final projects = groupIntoProjects(const [], const [], [a, LooseAgent(id: 'b', cwd: '/Users/me/code/app')]);
    expect(projects.map((p) => p.path).toSet(), {'/Users/me', '/Users/me/code/app'});
    expect(projects.firstWhere((p) => p.path == '/Users/me').loose.single.id, 'claude-home-1a2b');
  });

  test('loose agents join the project of their folder', () {
    final agents = mergeLooseAgents(
        discovered.map(LooseAgent.fromDiscovery).whereType<LooseAgent>().toList(), parseHookFile(looseHookFile), {});
    final projects = groupIntoProjects(rigsWithSeatsFromFixture(), const [], agents);
    final c = projects.firstWhere((p) => p.path == app);
    expect(c.loose.map((a) => a.name), containsAll(['scratch', 'codex-fix']));
    expect(projects.firstWhere((p) => p.path == site).loose.single.name, 'claude');
    // A folder with only a hand-started agent still shows up.
    final only = groupIntoProjects(const [], const [], [LooseAgent(id: 'a', cwd: '/x/solo')]);
    expect(only.single.name, 'solo');
    expect(only.single.attention, 0);
  });

  test('agent links from notifications', () {
    final l = AgentLink.parse(Uri.parse('pocketrig://agent/sess-9?host=homelab&tmux=scratch&cwd=%2FUsers%2Fme%2Fcode%2Fapp'))!;
    expect(l.id, 'sess-9');
    expect(l.host, 'homelab');
    expect(l.tmux, 'scratch');
    expect(l.cwd, app);
    expect(AgentLink.parse(Uri.parse('pocketrig://seat/lead@conveyor')), isNull);
    expect(AgentLink.parse(Uri.parse('pocketrig://agent/sess-9?tmux='))!.tmux, isNull);
  });

  test('discovery and adopt hit the daemon', () async {
    final calls = <String>[];
    final api = OpenRigClient(
      homelab,
      httpClient: MockClient((req) async {
        calls.add('${req.method} ${req.url.path} ${req.body}');
        if (req.url.path == '/api/discovery') return http.Response(jsonEncode(discovered), 200);
        if (req.url.path.endsWith('/adopt')) {
          return http.Response(jsonEncode({'ok': true, 'action': 'create_and_bind', 'logicalId': 'orchestration.scratch'}), 201);
        }
        return http.Response('{}', 200);
      }),
    );
    expect((await api.discovered(scan: true)).length, 2);
    expect(calls.first, startsWith('POST /api/discovery/scan'));
    final id = await api.adopt('d-scratch', rigId: 'r-conveyor', podId: 'orchestration', podNamespace: 'orchestration', memberName: 'scratch');
    expect(id, 'orchestration.scratch');
    expect(jsonDecode(calls.last.split(' ').skip(2).join(' ')), {
      'rigId': 'r-conveyor',
      'target': {'kind': 'pod', 'podId': 'orchestration', 'podNamespace': 'orchestration', 'memberName': 'scratch'},
    });
  });

  testWidgets('Allow once presses 1 in the pane; adopting joins the chosen rig', (tester) async {
    final store = await installFakes();
    showLoose = true;
    final commands = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          commands.add(cmd);
          return fakeShell(cmd);
        });
    final adopts = <String>[];
    OpenRigClient.factory = (h) => OpenRigClient(h, httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/adopt')) {
            adopts.add(req.body);
            return http.Response(jsonEncode({'ok': true, 'logicalId': 'orchestration.scratch'}), 201);
          }
          return fakeDaemon(h).send(req).then(http.Response.fromStream);
        }));
    await tester.binding.setSurfaceSize(const Size(390, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(AppScope(
      store: store,
      child: MaterialApp(home: LooseAgentScreen(agent: scratchAgent(), rigs: rigsWithSeatsFromFixture())),
    ));
    await tester.pump();

    expect(find.text('scratch needs approval'), findsNothing, reason: 'the heading says needs you: the card has no second title');
    expect(find.text('Needs you'), findsOneWidget);
    expect(find.text('Claude Code'), findsOneWidget, reason: 'the runtime mark is named');
    expect(find.text('not in a rig'), findsOneWidget);
    expect(find.text('app › homelab'), findsOneWidget);
    await tester.tap(find.text('Allow once'));
    await tester.pump();
    await tester.pump();
    final keys = commands.where((c) => c.contains('send-keys')).single;
    expect(keys.replaceAll("'\\''", "'"), allOf(contains("tmux send-keys -t '%7' '1'"), contains('POCKETRIG_SENT')), reason: 'at its own pane, checked');
    expect(find.textContaining('✓ Allowed once · scratch'), findsOneWidget);

    await tester.ensureVisible(find.text('Adopt into a rig'));
    await tester.tap(find.text('Adopt into a rig'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Adopt as scratch in conveyor'));
    await tester.tap(find.text('Adopt as scratch in conveyor'));
    await tester.pump();
    await tester.pump();
    expect(jsonDecode(adopts.single), {
      'rigId': 'r-conveyor',
      'target': {'kind': 'pod', 'podId': 'orchestration', 'podNamespace': 'orchestration', 'memberName': 'scratch'},
    });
    expect(find.textContaining('scratch is now orchestration.scratch in conveyor'), findsOneWidget);
  });

  testWidgets('Restart in tmux confirms, runs the script, and opens a chat that can send', (tester) async {
    final store = await installFakes();
    final commands = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          commands.add(cmd);
          if (cmd.contains('"status"')) return 'idle\n';
          if (cmd.contains('pocketrig-restart-ok')) return 'pocketrig-restart-ok\n';
          return fakeShell(cmd);
        });
    final tab = LooseAgent(id: 'abcd-1', claudeSessionId: 'abcd-1', runtime: 'claude-code', cwd: '/w/My App');
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: LooseAgentScreen(agent: tab))));
    await tester.pump();

    await tester.ensureVisible(find.text('Restart in tmux'));
    await tester.tap(find.text('Restart in tmux'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Restart in tmux?'), findsOneWidget);
    expect(commands.where((c) => c.contains('pocketrig-restart-ok')), isEmpty, reason: 'nothing runs before confirm');

    await tester.tap(find.text('Restart'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(commands.where((c) => c.contains('pocketrig-restart-ok')), hasLength(1));
    expect(find.textContaining('Reply to claude-my-app-abcd'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  group('Restart in tmux progress', () {
    final tab = LooseAgent(id: 'abcd-1', claudeSessionId: 'abcd-1', runtime: 'claude-code', cwd: '/w/My App');

    Future<void> open(WidgetTester tester, Future<SshExec> Function(Host) connect) async {
      final store = await installFakes();
      SshExec.debugConnect = connect;
      await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: LooseAgentScreen(agent: tab))));
      await tester.pump();
      await tester.ensureVisible(find.text('Restart in tmux'));
      await tester.tap(find.text('Restart in tmux'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    Finder dialogText(String text) => find.descendant(of: find.byType(BottomSheet), matching: find.textContaining(text));

    testWidgets('shows a step at once, and Cancel drops the check', (tester) async {
      final store = await installFakes();
      final check = Completer<String>();
      SshExec.debugConnect = (h) async => SshExec.fake((cmd) => check.future);
      await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: LooseAgentScreen(agent: tab))));
      await tester.pump();
      await tester.ensureVisible(find.text('Restart in tmux'));
      await tester.tap(find.text('Restart in tmux'));
      await tester.pump();
      expect(dialogText('Connecting to homelab'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 300)); // the sheet slides in
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 300));
      check.complete('idle\n');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Restart in tmux?'), findsNothing);
      expect(find.byType(LooseAgentScreen), findsOneWidget, reason: 'the screen behind the dialog stays');
    });

    testWidgets('a host it can\'t reach links to its settings', (tester) async {
      await open(tester, (h) async => throw Exception('connection refused'));
      expect(find.text('Couldn\'t reach homelab'), findsOneWidget);
      expect(dialogText('connection refused'), findsOneWidget);
      expect(find.text('Restart in tmux?'), findsNothing, reason: 'no confirm for a restart that can\'t work');

      await tester.tap(find.text('Host settings'));
      await tester.pumpAndSettle();
      expect(find.byType(HostEditor), findsOneWidget);
    });

    testWidgets('follows the script and says where a failure stopped', (tester) async {
      final script = Completer<String>();
      await open(
          tester,
          (h) async => SshExec.fake((cmd) async {
                if (cmd.contains('"status"')) return 'idle\n';
                if (cmd.contains('pocketrig-restart-ok')) return script.future;
                return fakeShell(cmd);
              }));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Restart'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(dialogText('Connecting to homelab'), findsOneWidget);

      script.complete('pocketrig-restart-step stopping\npocketrig-restart-error still-running\n');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Restart didn\'t finish'), findsOneWidget);
      expect(find.textContaining('Stopped at: Stopping the agent…'), findsOneWidget);
      expect(dialogText('left running'), findsOneWidget);
      expect(find.text('Host settings'), findsNothing, reason: 'settings can\'t fix this one');
    });
  });

  testWidgets('the agent screen\'s ⋯ is the same list the chat has: Open chat, Open terminal, Rename, red Kill agent…',
      (tester) async {
    final store = await installFakes();
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: LooseAgentScreen(agent: scratchAgent()))));
    await tester.pump();
    await tester.tap(find.byTooltip('Agent options'));
    await tester.pumpAndSettle();
    Finder inSheet(String t) => find.descendant(of: find.byType(BottomSheet), matching: find.text(t));
    expect(inSheet('Rename'), findsOneWidget);
    expect(inSheet('Kill agent…'), findsOneWidget, reason: 'red, pinned under the rows');
  });

  testWidgets('a row whose tmux session is gone offers Remove from list, which only clears the record and never runs the kill', (tester) async {
    final store = await installFakes();
    final agent = scratchAgent();
    fleet.feedFor(store.active!).jobs = <String, List<AgentJob>>{'some-other-session': const []};
    final commands = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          commands.add(cmd);
          return cmd.contains('SessionEnd') ? 'pocketrig-kill-ok\n' : fakeShell(cmd);
        });
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: LooseAgentScreen(agent: agent))));
    await tester.pump();
    expect(find.text('Kill agent…'), findsNothing);
    await tester.tap(find.text('Remove from list…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Remove scratch from the list?'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(commands.where((c) => c.contains('kill-session') || c.contains('kill -TERM')), isEmpty, reason: 'nothing is killed');
  });

  testWidgets('Kill agent, pinned at the bottom, confirms, runs the script, and reports failure', (tester) async {
    final store = await installFakes();
    final commands = <String>[];
    var reply = 'pocketrig-kill-error still-running\n';
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          commands.add(cmd);
          if (cmd.contains('pocketrig-kill-ok')) return reply;
          return fakeShell(cmd);
        });
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: LooseAgentScreen(agent: scratchAgent()))));
    await tester.pump();

    Future<void> kill() async {
      // Pinned under the list: tappable without scrolling.
      await tester.tap(find.text('Kill agent…'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Kill scratch?'), findsOneWidget);
    }

    await kill();
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(commands.where((c) => c.contains('pocketrig-kill-ok')), isEmpty, reason: 'nothing runs before confirm');

    await kill();
    await tester.tap(find.text('Kill'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(commands.where((c) => c.contains('pocketrig-kill-ok')), hasLength(1));
    expect(find.textContaining('even after a force kill'), findsOneWidget);
    expect(find.text('Kill agent…'), findsOneWidget, reason: 'a failed kill stays on the screen');
  });

  group('restart script on a real shell', () {
    late Directory home;
    late File tmuxLog;
    late String bash;
    final procs = <Process>[];

    // The defaults are generous because CI on a loaded Mac can't schedule even a stub within 1s; both return as soon as
    // the step finishes. Only tests that must hit a timeout pass a short one.
    Future<ProcessResult> run(String id, {int wait = 10, String path = '', int attach = 30}) => Process.run(
          '/bin/sh',
          ['-c', restartInTmuxScript(sessionId: id, cwd: home.path, name: 'n1', waitSeconds: wait, settleSeconds: 0, attachSeconds: attach)],
          environment: {'HOME': home.path, 'PATH': '${home.path}/bin:/usr/bin:/bin'},
        );

    /// A live process with claude in its command line (bash's \$0), registered
    /// like Claude Code does.
    var agents = 0;
    Future<Process> agent(String id, String body) async {
      // A script named claude: `ps` shows `/bin/sh …/claude`, the way an installed claude shows its name first.
      final script = File('${home.path}/a${agents++}/claude')..createSync(recursive: true);
      script.writeAsStringSync('#!/bin/sh\n$body\n');
      Process.runSync('chmod', ['+x', script.path]);
      final p = await Process.start(script.path, []);
      procs.add(p);
      File('${home.path}/.claude/sessions/${p.pid}.json').writeAsStringSync('{"pid":${p.pid},"sessionId":"$id"}');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(Process.killPid(p.pid, ProcessSignal.sigcont), isTrue, reason: 'the fake agent must be alive to start with');
      return p;
    }

    setUp(() {
      home = Directory.systemTemp.createTempSync('pocketrig-restart');
      Directory('${home.path}/bin').createSync();
      Directory('${home.path}/.claude/sessions').createSync(recursive: true);
      bash = Process.runSync('sh', ['-c', 'command -v bash']).stdout.toString().trim();
      final claude = File('${home.path}/bin/claude')..writeAsStringSync('#!/bin/sh\n');
      Process.runSync('chmod', ['+x', claude.path]);
      tmuxLog = File('${home.path}/tmux.log');
      final tmux = File('${home.path}/bin/tmux')
        ..writeAsStringSync('''#!/bin/sh
echo "\$*" >> "${tmuxLog.path}"
case "\$1" in
  has-session) [ -f "${home.path}/running" ] && [ "\$3" = "=n1" ] ;;
  display-message) cat "${home.path}/created" 2>/dev/null ;;
  new-session) touch "${home.path}/running" ;;
  list-panes) case "\$*" in *pane_pid*) cat "${home.path}/panepid" 2>/dev/null ;; *) echo %7 ;; esac ;;
esac
''');
      Process.runSync('chmod', ['+x', tmux.path]);
    });

    tearDown(() {
      for (final p in procs) {
        p.kill(ProcessSignal.sigkill);
      }
      procs.clear();
      home.deleteSync(recursive: true);
    });

    test('stops the process, then resumes in tmux', () async {
      final p = await agent('abc', 'sleep 60 & wait');
      final r = await run('abc');
      expect(r.stdout, contains('pocketrig-restart-ok'));
      expect(await p.exitCode.timeout(const Duration(seconds: 30)), isNot(0));
      expect(tmuxLog.readAsStringSync(), allOf(contains('new-session -d -s n1'), contains("/bin/claude' --resume abc")));
    });

    test('finds claude in its install folder when PATH misses it', () async {
      File('${home.path}/bin/claude').deleteSync();
      final installed = File('${home.path}/.local/bin/claude')
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\n');
      Process.runSync('chmod', ['+x', installed.path]);
      await agent('abc', 'sleep 60 & wait');
      expect((await run('abc')).stdout, contains('pocketrig-restart-ok'));
      expect(tmuxLog.readAsStringSync(), contains("'${installed.path}' --resume abc"));
    });

    test('a process that ignores the stop is left alone and tmux never starts', () async {
      final p = await agent('abc', 'trap "" TERM; while :; do sleep 1; done');
      final r = await run('abc', wait: 1);
      expect(r.stdout, contains('pocketrig-restart-error still-running'));
      expect(tmuxLog.readAsStringSync(), isNot(contains('new-session')));
      expect(Process.killPid(p.pid, ProcessSignal.sigcont), isTrue, reason: 'still alive');
    });

    test('nothing is stopped when the session is unknown or the name is taken', () async {
      final p = await agent('abc', 'sleep 60 & wait');
      expect((await run('other')).stdout, contains('pocketrig-restart-error not-found'));
      File('${home.path}/running').createSync();
      expect((await run('abc')).stdout, contains('pocketrig-restart-error name-taken'));
      expect(tmuxLog.readAsStringSync(), isNot(contains('new-session')));
      expect(Process.killPid(p.pid, ProcessSignal.sigcont), isTrue, reason: 'still alive');
    });

    test('a pid reused by something else is not killed', () async {
      final p = await Process.start(bash, ['-c', 'sleep 60 & wait']);
      procs.add(p);
      File('${home.path}/.claude/sessions/${p.pid}.json').writeAsStringSync('{"sessionId":"abc"}');
      expect((await run('abc')).stdout, contains('pocketrig-restart-error not-claude'));
      expect(Process.killPid(p.pid, ProcessSignal.sigcont), isTrue, reason: 'still alive');
    });

    group('kill', () {
      late File curlLog;

      Future<String> kill({String? id, String? name, String? pane, int? since}) async => (await Process.run(
            '/bin/sh',
            ['-c', killAgentScript(sessionId: id, name: name, pane: pane, since: since, waitSeconds: 1)],
            environment: {'HOME': home.path, 'PATH': '${home.path}/bin:/usr/bin:/bin'},
          ))
              .stdout
              .toString();

      setUp(() {
        curlLog = File('${home.path}/curl.log');
        final curl = File('${home.path}/bin/curl')..writeAsStringSync('#!/bin/sh\necho "\$*" >> "${curlLog.path}"\n');
        Process.runSync('chmod', ['+x', curl.path]);
      });

      test('a terminal tab agent is stopped and dropped from the watcher', () async {
        final p = await agent('abc', 'sleep 60 & wait');
        expect(await kill(id: 'abc'), contains('pocketrig-kill-ok'));
        expect(await p.exitCode.timeout(const Duration(seconds: 3)), isNot(0));
        expect(curlLog.readAsStringSync(), contains('"session_id":"abc","hook_event_name":"SessionEnd"'));
      });

      test('a process that ignores TERM gets KILL', () async {
        final p = await agent('abc', 'trap "" TERM; while :; do sleep 1; done');
        expect(await kill(id: 'abc'), contains('pocketrig-kill-ok'));
        expect(await p.exitCode.timeout(const Duration(seconds: 3)), -9);
      });

      test('in tmux it closes only the pane', () async {
        File('${home.path}/running').createSync();
        expect(await kill(name: 'n1', pane: '%7'), contains('pocketrig-kill-ok'));
        expect(tmuxLog.readAsStringSync(), allOf(contains('kill-pane -t %7'), isNot(contains('kill-session'))));
      });

      test('without a pane it closes the session', () async {
        File('${home.path}/running').createSync();
        expect(await kill(name: 'n1', since: 1000), contains('pocketrig-kill-ok'));
        expect(tmuxLog.readAsStringSync(), contains('kill-session -t =n1'));
      });

      test('with no process and no age to compare, a live session of that name is not closed', () async {
        File('${home.path}/running').createSync();
        expect(await kill(name: 'n1'), contains('pocketrig-kill-error session-unknown'));
        expect(tmuxLog.readAsStringSync(), isNot(contains('kill-')));
      });

      test('a pane no longer in the session is left alone', () async {
        File('${home.path}/running').createSync();
        expect(await kill(name: 'n1', pane: '%9'), contains('pocketrig-kill-error pane-moved'));
        expect(tmuxLog.readAsStringSync(), isNot(contains('kill-')));
      });

      test('a tmux session already gone counts as killed', () async {
        expect(await kill(name: 'n1', pane: '%7'), contains('pocketrig-kill-ok'));
        expect(tmuxLog.readAsStringSync(), isNot(contains('kill-')));
      });

      test('a gone session kills nothing, even when a live process holds its conversation id', () async {
        // The conversation was resumed in another session (or the pid reused): that process is not this agent's.
        final p = await agent('abc', 'sleep 60 & wait');
        expect(await kill(id: 'abc', name: 'n1', pane: '%7'), contains('pocketrig-kill-ok'));
        expect(tmuxLog.readAsStringSync(), isNot(contains('kill-')));
        expect(Process.killPid(p.pid, ProcessSignal.sigcont), isTrue, reason: 'still alive');
      });

      test('a live session of that name is not closed when its Claude runs elsewhere (a reused name like 0)', () async {
        File('${home.path}/running').createSync();
        File('${home.path}/panepid').writeAsStringSync('1\n');
        final p = await agent('abc', 'sleep 60 & wait');
        expect(await kill(id: 'abc', name: 'n1'), contains('pocketrig-kill-error session-reused'));
        expect(tmuxLog.readAsStringSync(), isNot(contains('kill-')), reason: 'the new session survives');
        expect(Process.killPid(p.pid, ProcessSignal.sigcont), isTrue, reason: 'and so does the other conversation');
      });

      test('with no process alive, a session made after the row was first seen is not closed', () async {
        File('${home.path}/running').createSync();
        File('${home.path}/created').writeAsStringSync('2000\n');
        expect(await kill(name: 'n1', since: 1000), contains('pocketrig-kill-error session-reused'));
        expect(tmuxLog.readAsStringSync(), isNot(contains('kill-')));
        File('${home.path}/created').writeAsStringSync('900\n');
        expect(await kill(name: 'n1', since: 1000), contains('pocketrig-kill-ok'));
        expect(tmuxLog.readAsStringSync(), contains('kill-session -t =n1'), reason: 'an older session is the same one');
      });

      test('two live processes holding the id: nothing is killed', () async {
        final a = await agent('abc', 'sleep 60 & wait');
        final b = await agent('abc', 'sleep 60 & wait');
        expect(await kill(id: 'abc'), contains('pocketrig-kill-error ambiguous'));
        expect(Process.killPid(a.pid, ProcessSignal.sigcont), isTrue);
        expect(Process.killPid(b.pid, ProcessSignal.sigcont), isTrue);
      });

      test('a terminal tab row does not kill a Claude that runs in a tmux pane', () async {
        final p = await agent('abc', 'sleep 60 & wait');
        File('${home.path}/panepid').writeAsStringSync('${p.pid}\n');
        expect(await kill(id: 'abc'), contains('pocketrig-kill-error in-tmux'));
        expect(Process.killPid(p.pid, ProcessSignal.sigcont), isTrue);
      });

      test('only a process whose executable is claude counts, not one with claude in an argument', () async {
        final q = await Process.start('/bin/sh', ['-c', 'sleep 60', '/home/me/.claude/x']);
        procs.add(q);
        File('${home.path}/.claude/sessions/${q.pid}.json').writeAsStringSync('{"sessionId":"zzz"}');
        expect(await kill(id: 'zzz'), contains('pocketrig-kill-error not-claude'));
        expect(Process.killPid(q.pid, ProcessSignal.sigcont), isTrue);
      });

      test('removing a gone row clears its record and kills nothing, whatever holds its id', () async {
        final p = await agent('abc', 'sleep 60 & wait');
        final out = (await Process.run('/bin/sh', ['-c', forgetAgentScript('abc')],
                environment: {'HOME': home.path, 'PATH': '${home.path}/bin:/usr/bin:/bin'}))
            .stdout
            .toString();
        expect(out, contains('pocketrig-kill-ok'));
        expect(curlLog.readAsStringSync(), contains('"session_id":"abc","hook_event_name":"SessionEnd"'));
        expect(Process.killPid(p.pid, ProcessSignal.sigcont), isTrue);
      });

      test('Remove on a gone row passes a real session id and clears it (forgetLooseAgent itself)', () async {
        final commands = <String>[];
        SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
              commands.add(cmd);
              return 'pocketrig-kill-ok\n';
            });
        addTearDown(() => SshExec.debugConnect = null);
        final host = Host(id: 'h', name: 'mini', address: 'mini', sshUser: 'me');
        final a = LooseAgent(id: 'x', claudeSessionId: '5091364c-8453-4a0e-b1c5-0123456789ab', tmuxSession: 'gone-one');
        await forgetLooseAgent(host, a);
        expect(commands.single, contains('SessionEnd'));
        expect(commands.single, isNot(contains('kill -TERM')));
        await expectLater(forgetLooseAgent(host, LooseAgent(id: 'y', claudeSessionId: 'a b;rm')), throwsA(isA<OpenRigException>()));
      });

      test('a job Stop in a session signals nothing when the pid is no longer under one of its panes', () async {
        File('${home.path}/running').createSync();
        final j = await Process.start('sleep', ['60']);
        procs.add(j);
        Future<String> stop() async => (await Process.run('/bin/sh', ['-c', AgentJob.stopScript(j.pid, session: 'n1')],
                environment: {'HOME': home.path, 'PATH': '${home.path}/bin:/usr/bin:/bin'}))
            .stdout
            .toString();
        File('${home.path}/panepid').writeAsStringSync('1\n');
        expect(await stop(), contains('pocketrig-stop-moved'));
        expect(Process.killPid(j.pid, ProcessSignal.sigcont), isTrue, reason: 'not under a pane: left alone');
        File('${home.path}/panepid').writeAsStringSync('${j.pid}\n');
        await stop();
        expect(await j.exitCode.timeout(const Duration(seconds: 5)), isNot(0), reason: 'under the pane: stopped');
      });

      test('the agent in a pane of its session is stopped with it', () async {
        File('${home.path}/running').createSync();
        final p = await agent('abc', 'sleep 60 & wait');
        File('${home.path}/panepid').writeAsStringSync('${p.pid}\n');
        expect(await kill(id: 'abc', name: 'n1'), contains('pocketrig-kill-ok'));
        expect(await p.exitCode.timeout(const Duration(seconds: 3)), isNot(0));
      });

      test('a name that is a prefix of another session\'s closes nothing', () async {
        File('${home.path}/running').createSync();
        expect(await kill(name: 'n'), contains('pocketrig-kill-ok'));
        expect(tmuxLog.readAsStringSync(), allOf(contains('has-session -t =n'), isNot(contains('kill-'))), reason: 'n1 is not n');
      });

      test('nothing is killed when the session is unknown or its pid was reused', () async {
        final p = await Process.start(bash, ['-c', 'sleep 60 & wait']);
        procs.add(p);
        expect(await kill(id: 'abc'), contains('pocketrig-kill-error not-found'));
        File('${home.path}/.claude/sessions/${p.pid}.json').writeAsStringSync('{"sessionId":"abc"}');
        expect(await kill(id: 'abc'), contains('pocketrig-kill-error not-claude'));
        expect(Process.killPid(p.pid, ProcessSignal.sigcont), isTrue, reason: 'still alive');
      });
    });

    group('the terminal tab', () {
      late File osaLog;

      void fake(String name, String body) {
        final f = File('${home.path}/bin/$name')..writeAsStringSync('#!/bin/sh\n$body\n');
        Process.runSync('chmod', ['+x', f.path]);
      }

      /// A Mac where the agent runs on ttys9, with [foreground] at the front of
      /// that tab after the stop and osascript running [osa].
      void mac({String foreground = '-zsh', String osa = 'exit 0', String running = 'Terminal'}) {
        osaLog = File('${home.path}/osa.log');
        fake('ps', '''
case "\$*" in
  '-o tty= -p '*) echo ' ttys9' ;;
  '-t ttys9 -o stat=,comm=') printf 'Ss /usr/bin/login\\nS+ $foreground\\n' ;;
  *) exec /bin/ps "\$@" ;;
esac''');
        fake('pgrep', '[ "\$2" = "$running" ]');
        fake('osascript', 'echo "\$3 | \$4" >> "${osaLog.path}"\n$osa');
      }

      test('attaches at the shell prompt it came from', () async {
        mac();
        await agent('abc', 'sleep 60 & wait');
        expect((await run('abc')).stdout, contains('pocketrig-restart-ok attached'));
        expect(osaLog.readAsStringSync(), "/dev/ttys9 | tmux attach -t '=n1'\n");
      });

      test('reports each step as it reaches it', () async {
        mac();
        await agent('abc', 'sleep 60 & wait');
        final out = (await run('abc')).stdout.toString();
        final steps = RegExp(r'pocketrig-restart-step (\w+)').allMatches(out).map((m) => m.group(1)!).toList();
        expect(steps, ['stopping', 'starting', 'attaching']);
        expect(steps.map(RestartStep.values.byName), hasLength(3), reason: 'every step is one the app knows');
      });

      test('falls through to iTerm', () async {
        mac(running: 'iTerm2');
        await agent('abc', 'sleep 60 & wait');
        expect((await run('abc')).stdout, contains('pocketrig-restart-ok attached'));
      });

      test('never types into something other than a shell', () async {
        mac(foreground: 'vim');
        await agent('abc', 'sleep 60 & wait');
        expect((await run('abc')).stdout, contains('pocketrig-restart-ok attach-failed'));
        expect(osaLog.existsSync(), isFalse);
      });

      test('a terminal it cannot script still restarts', () async {
        mac(running: 'Ghostty');
        await agent('abc', 'sleep 60 & wait');
        expect((await run('abc')).stdout, contains('pocketrig-restart-ok attach-failed'));
        expect(tmuxLog.readAsStringSync(), contains('new-session'));
      });

      test('an unanswered Automation prompt does not hang the restart', () async {
        mac(osa: 'exec sleep 30');
        await agent('abc', 'sleep 60 & wait');
        final clock = Stopwatch()..start();
        expect((await run('abc', attach: 1)).stdout, contains('pocketrig-restart-ok attach-failed'));
        // The stub sleeps 30 s; a loaded machine may take a while, but it must not wait that out.
        expect(clock.elapsed, lessThan(const Duration(seconds: 25)));
      });
    });

    test('a dead process just resumes', () async {
      File('${home.path}/.claude/sessions/999999.json').writeAsStringSync('{"sessionId":"abc"}');
      expect((await run('abc')).stdout, contains('pocketrig-restart-ok'));
    });
  });

  test('Open in Claude reads the bridge id from the session file', () async {
    final host = Host(id: 'h', name: 'mini', address: 'mini', sshUser: 'me');
    var answer = 'session_01ABC\n';
    final commands = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          commands.add(cmd);
          return answer;
        });
    addTearDown(() => SshExec.debugConnect = null);
    expect(await remoteControlUrl(host, 'abc'), Uri.parse('https://claude.ai/code/session_01ABC'));
    expect(commands.single, contains('"bridgeSessionId"'));
    answer = '';
    expect(await remoteControlUrl(host, 'abc'), isNull);
  });

  test('session names are tmux safe', () {
    expect(restartSessionName('/w/My.App', '5091364c-8453'), 'claude-my-app-5091');
  });
}
