import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/chat/session_log.dart';
import 'package:pocket_rig/data/host_store.dart' show isDesktop;
import 'package:pocket_rig/data/new_session.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/new_session_sheet.dart';
import 'package:pocket_rig/ui/project_screen.dart';
import 'package:pocket_rig/ui/terminal_screen.dart' show TerminalScreen;

import 'golden/fixtures.dart';

void main() {
  test('session ids are version 4 UUIDs, and differ', () {
    final v4 = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
    expect(newSessionId(), matches(v4));
    expect(newSessionId(Random(1)), matches(v4));
    expect(newSessionId(), isNot(newSessionId()));
  });

  test('a new session is named like a restarted one', () {
    expect(newSessionName(AgentRuntime.claude, '/w/My.App', '5091364c-8453'), 'claude-my-app-5091');
    expect(newSessionName(AgentRuntime.codex, '~/code/x', 'ab'), 'codex-x-ab');
  });

  test('the command line carries only what was chosen', () {
    final plain = NewSessionSpec(runtime: AgentRuntime.claude, cwd: '/w', name: 'n', sessionId: 'id-1');
    expect(plain.args, ['--session-id', 'id-1']);
    final full = NewSessionSpec(
      runtime: AgentRuntime.claude,
      cwd: '/w',
      name: 'n',
      sessionId: 'id-1',
      model: ' opus ',
      permissionMode: ClaudePermissionMode.plan,
      prompt: 'Fix it\n',
    );
    expect(full.args, ['--session-id', 'id-1', '--permission-mode', 'plan', '--model', 'opus', 'Fix it']);
    final codex = NewSessionSpec(runtime: AgentRuntime.codex, cwd: '/w', name: 'n', model: 'gpt-5', prompt: 'go');
    expect(codex.args, ['-m', 'gpt-5', 'go'], reason: 'Codex has no session id to pin');
    final a = codex.agent('/abs/w');
    expect(a.claudeSessionId, isNull);
    expect(a.tmuxSession, 'n');
    expect(a.runtime, 'codex');
    expect(a.cwd, '/abs/w');
    expect(full.agent('/w').claudeSessionId, 'id-1');
    expect(full.agent('/w').toSeat().resumeToken, 'id-1', reason: 'the chat follows <id>.jsonl');
  });

  test('a just-started session never borrows the newest log in its folder', () {
    final seat = Seat(rigId: '', logicalId: 'n', runtime: 'claude-code', cwd: '/w/app', resumeToken: 'id-1');
    final exact = locateLogScript(seat, exactOnly: true);
    expect(exact, contains('/id-1.jsonl'));
    expect(exact, isNot(contains('ls -t')));
    expect(locateLogScript(seat), contains('ls -t'));
  });

  group('the start script on a real shell', () {
    late Directory home;
    late File tmuxLog;

    /// A host with tmux and [bins] in PATH; tmux logs its calls, and
    /// `new-session` marks the session running unless [stillborn].
    void host({List<String> bins = const ['claude'], bool stillborn = false}) {
      Directory('${home.path}/bin').createSync();
      for (final b in bins) {
        final f = File('${home.path}/bin/$b')..writeAsStringSync('#!/bin/sh\n');
        Process.runSync('chmod', ['+x', f.path]);
      }
      tmuxLog = File('${home.path}/tmux.log');
      final tmux = File('${home.path}/bin/tmux')
        ..writeAsStringSync('''#!/bin/sh
printf '%s\\n' "\$*" >> "${tmuxLog.path}"
case "\$1" in
  has-session) [ -f "${home.path}/running" ] ;;
  new-session) ${stillborn ? ':' : 'touch "${home.path}/running"'} ;;
esac
''');
      Process.runSync('chmod', ['+x', tmux.path]);
    }

    Future<String> run(NewSessionSpec spec, {String? path}) async => (await Process.run(
          '/bin/sh',
          ['-c', newSessionScript(spec, settleSeconds: 0)],
          environment: {'HOME': home.path, 'PATH': path ?? '${home.path}/bin:/usr/bin:/bin'},
        ))
            .stdout
            .toString();

    NewSessionSpec claude({String? prompt, String? model, String cwd = '~/My App'}) => NewSessionSpec(
          runtime: AgentRuntime.claude,
          cwd: cwd,
          name: 'n1',
          sessionId: '1234abcd-0000-4000-8000-000000000000',
          model: model,
          prompt: prompt,
        );

    setUp(() {
      home = Directory.systemTemp.createTempSync('pocketrig-new');
      Directory('${home.path}/My App').createSync();
    });

    tearDown(() => home.deleteSync(recursive: true));

    test('starts claude detached in the folder, with the id and the prompt intact', () async {
      host();
      final out = await run(claude(prompt: 'it\'s "quoted" \$HOME `x`', model: 'opus'));
      expect(out, 'pocketrig-new-ok ${home.path}/My App\n', reason: '~/ expands to the absolute folder');
      final log = tmuxLog.readAsStringSync();
      expect(log, contains('has-session -t =n1'));
      expect(
          log,
          contains('new-session -d -s n1 -c ${home.path}/My App exec \'${home.path}/bin/claude\' '
              "'--session-id' '1234abcd-0000-4000-8000-000000000000' '--model' 'opus' "
              "'it'\\''s \"quoted\" \$HOME `x`'"),
          reason: 'quoted for the shell tmux starts, so nothing expands twice');
    });

    test('finds claude in its install folder when PATH misses it', () async {
      host(bins: const []);
      final installed = File('${home.path}/.local/bin/claude')
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\n');
      Process.runSync('chmod', ['+x', installed.path]);
      expect(await run(claude()), startsWith('pocketrig-new-ok'));
      expect(tmuxLog.readAsStringSync(), contains("exec '${installed.path}'"));
    });

    test('codex starts the same way', () async {
      host(bins: const ['codex']);
      final spec = NewSessionSpec(runtime: AgentRuntime.codex, cwd: '~/My App', name: 'c1', model: 'gpt-5');
      expect(await run(spec), startsWith('pocketrig-new-ok'));
      expect(tmuxLog.readAsStringSync(), contains("exec '${home.path}/bin/codex' '-m' 'gpt-5'"));
    });

    test('nothing starts without tmux, the binary, or the folder, or when the name is taken', () async {
      host();
      // A PATH with claude but no tmux (the machine's own tmux must stay out of it).
      Directory('${home.path}/notmux').createSync();
      File('${home.path}/bin/claude').copySync('${home.path}/notmux/claude');
      expect(await run(claude(), path: '${home.path}/notmux'), contains('pocketrig-new-error no-tmux'));
      expect(await run(claude(cwd: '~/Nope')), contains('pocketrig-new-error no-folder'));
      File('${home.path}/running').createSync();
      expect(await run(claude()), contains('pocketrig-new-error name-taken'));
      expect(tmuxLog.readAsStringSync(), isNot(contains('new-session')));
      File('${home.path}/running').deleteSync();
      File('${home.path}/bin/claude').deleteSync();
      expect(await run(claude()), contains('pocketrig-new-error no-claude'));
    });

    test('a session that quits at once is reported', () async {
      host(stillborn: true);
      expect(await run(claude()), contains('pocketrig-new-error exited'));
    });
  });

  test('startNewSession turns the script\'s result into an agent, or a sentence', () async {
    var reply = 'pocketrig-new-ok /Users/me/code/app\n';
    final commands = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          commands.add(cmd);
          return reply;
        });
    addTearDown(() => SshExec.debugConnect = null);
    final spec = NewSessionSpec(runtime: AgentRuntime.claude, cwd: '~/code/app', name: 'claude-app-1234');
    final a = await startNewSession(homelab, spec);
    expect(a.cwd, '/Users/me/code/app', reason: 'the host\'s absolute folder, so it groups with the daemon\'s rows');
    expect(a.tmuxSession, 'claude-app-1234');
    expect(commands.single, allOf(contains('exec "\${SHELL:-/bin/sh}" -lc'), contains('pocketrig-new-ok')));

    reply = 'pocketrig-new-error no-claude\n';
    await expectLater(
        startNewSession(homelab, spec), throwsA(predicate((e) => '$e'.contains('Couldn\'t find claude'))));
    reply = '';
    await expectLater(startNewSession(homelab, spec), throwsA(predicate((e) => '$e'.contains('gave no result'))));
    await expectLater(startNewSession(homelab, NewSessionSpec(runtime: AgentRuntime.claude, cwd: '/w', name: 'a b')),
        throwsA(predicate((e) => '$e'.contains('tmux session name'))));
  });

  testWidgets('New agent on a project starts it over SSH and opens a chat that waits for the log', (tester) async {
    final store = await installFakes();
    final commands = <String>[];
    var logReady = false;
    String? sessionId;
    // The script travels through two layers of shell quoting; read it bare.
    String bare(String cmd) => cmd.replaceAll(RegExp(r"['\\]"), '');
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          commands.add(cmd);
          if (cmd.contains('pocketrig-new-ok')) {
            sessionId = RegExp(r'--session-id ([0-9a-f-]+)').firstMatch(bare(cmd))?.group(1);
            return 'pocketrig-new-ok $app\n';
          }
          if (cmd.contains('.jsonl')) {
            return logReady ? '/Users/me/.claude/projects/-Users-me-code-app/$sessionId.jsonl\n' : '';
          }
          return fakeShell(cmd);
        });
    await tester.pumpWidget(MaterialApp(home: phone(store, const ProjectScreen(path: app))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byTooltip('Project options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New agent'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Start in app'), findsOneWidget);
    expect(find.textContaining('claude-app-'), findsOneWidget, reason: 'the tmux name is filled in');
    await tester.tap(find.text('opus'));
    await tester.pump();
    await tester.enterText(
        find.ancestor(of: find.text('First message · optional'), matching: find.byType(TextField)), 'Fix the 409 retry');
    await tester.ensureVisible(find.text('Start and open chat'));
    await tester.pump();
    await tester.tap(find.text('Start and open chat'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final start = bare(commands.where((c) => c.contains('pocketrig-new-ok')).single);
    expect(start, allOf(contains('--model opus'), contains('Fix the 409 retry'), contains('name=claude-app-')));
    expect(sessionId, isNotNull);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.textContaining('Starting claude-app-'), findsOneWidget);
    expect(find.text('Fix the 409 retry'), findsOneWidget, reason: 'the first message shows as pending');
    expect(find.textContaining('No Claude Code session log'), findsNothing);
    final looked = commands.where((c) => c.contains('$sessionId.jsonl')).length;
    expect(commands.where((c) => c.contains('$sessionId.jsonl')).single, isNot(contains('ls -t')),
        reason: 'only the exact log, never the folder\'s newest');

    // It asks again a few seconds later, and the chat fills in once the log exists.
    logReady = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(commands.where((c) => c.contains('$sessionId.jsonl')).length, greaterThan(looked));
    expect(find.textContaining('Starting claude-app-'), findsNothing);
    expect(find.textContaining('retry flow I implemented'), findsOneWidget, reason: 'the replayed log is on screen');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the new-agent sheet is the agent form only: a rig starts from its spec, a shell from Shell here', (tester) async {
    final store = await installFakes();
    await tester.binding.setSurfaceSize(const Size(390, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: phone(
          store,
          Builder(
            builder: (context) => Scaffold(
                body: Center(child: TextButton(onPressed: () => startAgentInFolder(context, app), child: const Text('+')))),
          ),
          root: true),
    ));
    await tester.tap(find.text('+'));
    await tester.pumpAndSettle();
    expect(find.text('Start and open chat'), findsOneWidget);
    for (final gone in ['Rig from spec', 'Shell', 'Open shell']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('desktop: New agent skips the sheet, starts default claude and opens its terminal, never the chat',
      (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    final started = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          if (cmd.contains('pocketrig-new-ok')) {
            started.add(cmd.replaceAll(RegExp(r"['\\]"), ''));
            return 'pocketrig-new-ok $app\n';
          }
          return fakeShell(cmd);
        });
    await tester.pumpWidget(MaterialApp(home: phone(store, const ProjectScreen(path: app))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Project options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New agent'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Start in app'), findsNothing, reason: 'no sheet');
    expect(started.single, allOf(contains('name=claude-app-'), contains('--session-id'), isNot(contains('--model'))));
    expect(find.byType(TerminalScreen), findsOneWidget);
    expect(find.byType(ChatScreen), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
