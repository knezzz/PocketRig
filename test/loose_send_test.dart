import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/send_to_seat.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/terminal/transport.dart';

void main() {
  final host = Host(id: 'h', name: 'work', address: 'a', sshUser: 'u');
  tearDown(() => SshExec.debugConnect = null);

  Seat loose(String session) => Seat(rigId: '', logicalId: 'dev', sessionName: session, runtime: 'claude-code', tmuxPane: '%4');

  test('a send tmux never ran is an error, not a success', () async {
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async => "can't find session: gone\n(sessions here: a b )");
    await expectLater(
      sendToSeat(host, null, loose('gone'), 'hi'),
      throwsA(predicate((e) => '$e'.contains('sessions here: a b'))),
    );
  });

  test('a send that went through', () async {
    String? ran;
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          ran = cmd;
          return 'POCKETRIG_SENT\n';
        });
    await sendToSeat(host, null, loose('dev'), 'hi');
    expect(ran!.replaceAll("'\\''", "'"), allOf(contains("tmux has-session -t '=dev'"), contains("tmux send-keys -t '%4' -l -- 'hi' && sleep 0.3 && tmux send-keys -t '%4' Enter")),
        reason: 'the exact session, typed at the agent\'s own pane, with the pause before Enter');
  });

  test('a missing session lists the ones the host has', () async {
    final dir = await Directory.systemTemp.createTemp('tmux');
    final tmux = File('${dir.path}/tmux')
      ..writeAsStringSync('#!/bin/sh\n'
          'case "\$1" in has-session) echo "can\'t find session: x"; exit 1;; ls) printf "a\\nb@c\\n";; esac\n');
    Process.runSync('chmod', ['+x', tmux.path]);
    final r = Process.runSync('sh', ['-c', tmuxHasSession('x')],
        environment: {'PATH': '${dir.path}:${Platform.environment['PATH']}'});
    expect(r.exitCode, isNot(0));
    expect(r.stdout, contains("can't find session: x"));
    expect(r.stdout, contains('(sessions here: a b@c )'));
    await dir.delete(recursive: true);
  });

  test('a rig seat goes through the daemon; a loose agent never touches it', () async {
    final sent = <String>[];
    final api = OpenRigClient(host, httpClient: MockClient((req) async {
      if (req.url.path == '/api/transport/send') sent.add((jsonDecode(req.body) as Map)['session'] as String);
      return http.Response('{"ok":true}', 200);
    }));
    final rigSeat = Seat(rigId: 'r', logicalId: 'lead', sessionName: 'lead@r', runtime: 'claude-code');
    await sendToSeat(host, api, rigSeat, 'hi');
    expect(sent, ['lead@r']);
    var ssh = false;
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          ssh = true;
          return 'POCKETRIG_SENT\n';
        });
    await sendToSeat(host, api, loose('dev'), 'hi');
    expect(sent, ['lead@r'], reason: 'the loose agent is typed over SSH');
    expect(ssh, isTrue);
  });

  test('nothing is sent when there is no way to send: it throws, so no screen says Sent', () async {
    await expectLater(sendToSeat(host, null, Seat(rigId: 'r', logicalId: 'lead', sessionName: 'lead@r'), 'hi'), throwsA(isA<OpenRigException>()));
    await expectLater(sendToSeat(null, null, loose('dev'), 'hi'), throwsA(isA<OpenRigException>()));
    await expectLater(sendToSeat(host, null, Seat(rigId: 'r', logicalId: 'x'), 'hi'), throwsA(isA<OpenRigException>()));
  });

  test('a send the daemon only recorded (seat gone, OpenRig 0.7.16+) is an error; a held one is not', () async {
    var reply = '{"ok":true,"outcome":"recorded","sent":false,"warning":"Message recorded in the sender outbox, not delivered."}';
    final api = OpenRigClient(host, httpClient: MockClient((req) async => http.Response(reply, 200)));
    final seat = Seat(rigId: 'r', logicalId: 'lead', sessionName: 'lead@r', runtime: 'claude-code');
    await expectLater(sendToSeat(host, api, seat, 'hi'), throwsA(predicate((e) => '$e'.contains('Not delivered: lead@r is gone'))));
    reply = '{"ok":true,"outcome":"retained","sent":false,"reason":"runtime_switch_in_progress"}';
    await sendToSeat(host, api, seat, 'hi'); // typed later by the daemon
  });
}
