import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/loose_agents.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/terminal/transport.dart';

void main() {
  final host = Host(id: 'h', name: 'work', address: 'a', sshUser: 'u');
  tearDown(() => SshExec.debugConnect = null);

  LooseAgent agent({String? session = 'dev', String? pane = '%3'}) =>
      LooseAgent(id: 'a', claudeSessionId: 'a', runtime: 'claude-code', tmuxSession: session, tmuxPane: pane);

  test('the one target rule: the exact pane when known, else =session: (exact name, its active pane)', () {
    expect(tmuxTarget('dev'), "'=dev:'");
    expect(tmuxTarget('dev', pane: '%3'), "'%3'");
    expect(tmuxTarget("it's"), "'=it'\\''s:'");
  });

  test('every key in a press command carries that target, for a pane and for a session', () {
    expect(tmuxPressCommand('dev', ['1']), "tmux send-keys -t '=dev:' '1'");
    expect(tmuxPressCommand('dev', ['1'], pane: '%3'), "tmux send-keys -t '%3' '1'");
    expect(tmuxPressCommand('dev', [const TypedAnswer('hi')], pane: '%3'),
        "tmux send-keys -t '%3' -l -- 'hi' && sleep 0.3 && tmux send-keys -t '%3' Enter");
  });

  test('a loose agent keeps its pane when it opens as a seat, so the chat answers it where the Allow button does', () {
    final s = agent().toSeat();
    expect((s.sessionName, s.tmuxPane), ('dev', '%3'));
    expect(agent(pane: null).toSeat().tmuxPane, isNull);
  });

  test('answering a loose agent checks the session exactly, types at its pane, and says so only when it was sent', () async {
    String? ran;
    // runLogin wraps the line in `exec $SHELL -lc '…'`: take the quoting back off to read it.
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          ran = cmd.replaceAll("'\\''", "'");
          return 'POCKETRIG_SENT\n';
        });
    await answerLooseAgent(host, agent(), allow: true);
    expect(ran, contains("tmux has-session -t '=dev'"));
    expect(ran, contains("tmux send-keys -t '%3' '1'"));
    expect(ran, contains('echo POCKETRIG_SENT'));
    await answerLooseAgent(host, agent(), allow: false);
    expect(ran, contains("tmux send-keys -t '%3' 'Escape'"));
    await answerLooseAgent(host, agent(pane: null), allow: true);
    expect(ran, contains("tmux send-keys -t '=dev:' '1'"), reason: 'no pane known: the session\'s active pane, exactly named');
  });

  test('a gone session is an error, not an "Allowed once"', () async {
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async => "can't find session: dev\n(sessions here: dev2 )");
    await expectLater(answerLooseAgent(host, agent(), allow: true), throwsA(predicate((e) => '$e'.contains('No tmux session dev'))));
  });

  test('an agent outside tmux is told to answer at the Mac, nothing is sent', () async {
    var ran = false;
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          ran = true;
          return '';
        });
    await expectLater(answerLooseAgent(host, agent(session: null, pane: null), allow: true), throwsA(predicate((e) => '$e'.contains('isn\'t in tmux'))));
    expect(ran, isFalse);
  });

  test('a seat attaches to its exact session name: a gone dev must not attach dev2', () {
    final seat = Seat.fromJson({'rigId': 'r', 'logicalId': 'x', 'canonicalSessionName': 'dev', 'runtime': 'claude-code', 'sessionStatus': 'running'});
    expect(seatAttachCommand(seat), "exec tmux -u attach -t '=dev'");
  });

  test('before pressing at a %pane the host confirms it is still in that session (a stale %N after a tmux restart)', () async {
    final dir = await Directory.systemTemp.createTemp('tmuxpane');
    addTearDown(() => dir.delete(recursive: true));
    Future<ProcessResult> check(String sessionOfPane) async {
      File('${dir.path}/tmux').writeAsStringSync('#!/bin/sh\n[ "\$1" = display-message ] && echo $sessionOfPane\n');
      Process.runSync('chmod', ['+x', '${dir.path}/tmux']);
      return Process.run('sh', ['-c', tmuxPaneInSession('dev', '%3')], environment: {'PATH': '${dir.path}:${Platform.environment['PATH']}'});
    }

    expect((await check('dev')).exitCode, 0);
    final stale = await check('other');
    expect(stale.exitCode, isNot(0));
    expect(stale.stdout, contains('pane %3 is no longer in session dev'));
  });

  test('a loose answer runs that check before it types; a rig seat has no pane, so none', () async {
    final ran = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          ran.add(cmd.replaceAll("'\\''", "'"));
          return 'POCKETRIG_SENT\n';
        });
    await answerLooseAgent(host, agent(), allow: true);
    expect(ran.last, contains("tmux display-message -p -t '%3' '#{session_name}'"));
    expect(ran.last.indexOf('display-message'), lessThan(ran.last.indexOf('send-keys')));
    await answerLooseAgent(host, agent(pane: null), allow: true);
    expect(ran.last, isNot(contains('display-message')));
  });

  test('a two-line message goes in as one bracketed paste in a buffer of its own, then Enter; one line stays send-keys -l', () {
    final cmd = tmuxPressCommand('dev', [const TypedAnswer('one\ntwo')], pane: '%3');
    final m = RegExp(r"^printf %s 'one\ntwo' \| tmux load-buffer -b (pocketrig-send-[A-Za-z0-9_-]{12}) - && "
            r"\{ tmux paste-buffer -p -d -b (\S+) -t '%3' \|\| \{ tmux delete-buffer -b (\S+) 2>/dev/null; false; \}; \} "
            r"&& sleep 0.3 && tmux send-keys -t '%3' Enter$")
        .firstMatch(cmd);
    expect(m, isNotNull, reason: cmd);
    expect({m!.group(1), m.group(2), m.group(3)}, hasLength(1), reason: 'load, paste and delete use the same buffer');
    expect(tmuxPressCommand('dev', [const TypedAnswer('one')]), startsWith("tmux send-keys -t '=dev:' -l -- 'one'"));
    expect(tmuxPressCommand('dev', [const TypedAnswer("it's\nme")]), contains("printf %s 'it'\\''s\nme'"), reason: 'quotes survive');
  });

  test('two sends at once never share a buffer name', () {
    final names = {
      for (var i = 0; i < 50; i++)
        RegExp(r'-b (pocketrig-send-\S+) -').firstMatch(tmuxPressCommand('dev', [const TypedAnswer('a\nb')]))!.group(1)
    };
    expect(names, hasLength(50));
  });

  group('when the keys may have been typed but the marker never came back, the send is not retried by itself', () {
    Future<Object?> send(Future<String> Function(String cmd) run) async {
      SshExec.debugConnect = (h) async => SshExec.fake(run);
      try {
        await answerLooseAgent(host, agent(), allow: true);
        return null;
      } catch (e) {
        return e;
      }
    }

    test('the session check passed (READY) and no SENT: maybeSent', () async {
      final e = await send((cmd) async => 'POCKETRIG_READY\n');
      expect(e, isA<OpenRigException>().having((x) => x.maybeSent, 'maybeSent', isTrue));
    });

    test('the channel never opened: nothing ran, so the error stands and a retry is safe (not maybeSent)', () async {
      SshExec.debugConnect = (h) async => SshExec.fake((cmd) async => throw StateError('channel open failed'), neverOpens: true);
      Object? e;
      try {
        await answerLooseAgent(host, agent(), allow: true);
      } catch (x) {
        e = x;
      }
      expect(e, isA<StateError>(), reason: 'passed through, not wrapped as maybeSent');
    });

    test('the connection drops while the script runs: maybeSent', () async {
      final e = await send((cmd) async => throw StateError('socket closed'));
      expect(e, isA<OpenRigException>().having((x) => x.maybeSent, 'maybeSent', isTrue));
    });

    test('the session was not found: nothing was typed, so a retry is safe (not maybeSent)', () async {
      final e = await send((cmd) async => "can't find session: dev\n(sessions here: dev2 )");
      expect(e, isA<OpenRigException>().having((x) => x.maybeSent, 'maybeSent', isFalse));
    });

    test('confirmed: no error', () async {
      expect(await send((cmd) async => 'POCKETRIG_READY\nPOCKETRIG_SENT\n'), isNull);
    });
  });
}
