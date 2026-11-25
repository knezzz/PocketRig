import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/api/openrig_client.dart' show OpenRigException;
import 'package:pocket_rig/data/registry_hosts.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/registry_hosts_screen.dart';

void main() {
  // Captured from this Mac: `rig host list --json` with nothing registered.
  test('empty registry as the CLI prints it', () => expect(parseRegistryHosts('[]\n'), isEmpty));

  // Captured from this Mac: GET /api/hosts on the daemon.
  test('empty registry as the daemon sends it',
      () => expect(parseRegistryHosts('{"ownName":"localhost","selected":"local","hosts":[]}'), isEmpty));

  // Entry fields follow the daemon's host registry (hosts-registry-reader); no
  // real entries exist on this Mac, so these rows are written to that shape.
  test('ssh and http entries, pointers only', () {
    final hosts = parseRegistryHosts('''
[
  {"id":"vps","transport":"ssh","target":"vps.example.com","user":"ops","notes":"build box","selected":true,"status":"reachable"},
  {"id":"lab","transport":"http","url":"http://lab:7433","bearer_file":"/home/u/.openrig/secrets/host-lab.token","status":"unreachable"},
  {"id":"api","transport":"http","url":"https://api:7433","bearer_env":"LAB_TOKEN"},
  {"transport":"ssh","target":"no-id"}
]''');
    expect(hosts.map((h) => h.id), ['vps', 'lab', 'api']);
    expect(hosts[0].isSsh, isTrue);
    expect(hosts[0].where, 'ops@vps.example.com');
    expect(hosts[0].selected, isTrue);
    expect(hosts[1].where, 'http://lab:7433');
    expect(hosts[1].bearerFile, endsWith('host-lab.token'));
    expect(hosts[1].selected, isFalse);
    expect(hosts[2].bearerEnv, 'LAB_TOKEN');
  });

  test('doctor returns every line even when rig exits 1', () async {
    final host = Host(id: 'h', name: 'mini', address: 'mini', sshUser: 'me', privateKeyPem: 'k');
    final cmds = <String>[];
    SshExec.debugConnect = (_) async => SshExec.fake((cmd) async {
          cmds.add(cmd);
          return 'ok 1\nok 2\nok 3\nok 4\nFAIL 5\n  fix: open the port\npocketrig-host-ok\n';
        });
    addTearDown(() => SshExec.debugConnect = null);
    final out = await RegistryClient(host).doctor('lab');
    expect(out, contains('fix: open the port'));
    expect(out, isNot(contains('pocketrig-host-ok')));
    expect(cmds.single, contains('doctor'));
    expect(cmds.single, contains('2>&1 ; echo pocketrig-host-ok'));
  });

  test('output that is not JSON throws with what rig said', () {
    expect(() => parseRegistryHosts('command not found: rig'), throwsA(isA<OpenRigException>()));
  });

  test('a doctor run reads as ok, or as its first problem', () {
    expect(doctorVerdict('ok reachable\nok version 0.7.6\n'), (true, 'ok'));
    expect(doctorVerdict('ok 1\nFAIL bearer token missing\n  fix: set LAB_TOKEN\n'), (false, 'bearer token missing'));
    expect(doctorVerdict('ok ssh\nconnection refused by lab:7433\n'), (false, 'connection refused by lab:7433'));
  });

  testWidgets('rows show the doctor inline; pairing runs in the background and toasts the outcome', (tester) async {
    final host = Host(id: 'h-pair', name: 'homelab', address: 'homelab', sshUser: 'me', privateKeyPem: 'k');
    final approval = Completer<String>();
    SshExec.debugConnect = (_) async => SshExec.fake((cmd) async {
          if (cmd.contains('list')) {
            return '[{"id":"local","transport":"ssh","target":"localhost","selected":true},'
                '{"id":"mini","transport":"ssh","target":"mini.ts.net","user":"me"},'
                '{"id":"gpu","transport":"http","url":"http://gpu:7433"}]\npocketrig-host-ok\n';
          }
          if (cmd.contains('doctor') && cmd.contains('mini')) return 'ok reachable\npocketrig-host-ok\n';
          if (cmd.contains('doctor') && cmd.contains('gpu')) return 'FAIL bearer token missing\npocketrig-host-ok\n';
          if (cmd.contains('pair')) return approval.future;
          return 'pocketrig-host-ok\n';
        });
    addTearDown(() => SshExec.debugConnect = null);
    await tester.pumpWidget(MaterialApp(home: RegistryHostsScreen(host: host)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.textContaining('These are not the hosts PocketRig connects to'), findsOneWidget);
    expect(find.text('Machines on homelab'), findsOneWidget, reason: 'not "hosts": Settings keeps that word');
    expect(find.text('OpenRig hosts'), findsNothing);
    expect(find.text('doctor ok · just now'), findsOneWidget);
    expect(find.text('doctor: bearer token missing'), findsOneWidget);

    await tester.tap(find.text('Pair a machine…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Address'), 'studio:7433');
    await tester.pump(); // Pair turns on once there's an address
    await tester.tap(find.text('Pair'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Waiting for approval on studio:7433…'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '+ Add')).onPressed, isNotNull,
        reason: 'the screen stays usable while it waits');

    approval.complete('paired\npocketrig-host-ok\n');
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('Paired with studio:7433'), findsOneWidget);
    expect(find.text('Waiting for approval on studio:7433…'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a registry row\'s ⋯ is the shared action sheet: Make current, doctor, edit, and Remove… in red', (tester) async {
    final host = Host(id: 'h-acts', name: 'homelab', address: 'homelab', sshUser: 'me', privateKeyPem: 'k');
    SshExec.debugConnect = (_) async => SshExec.fake((cmd) async => cmd.contains('list')
        ? '[{"id":"local","transport":"ssh","target":"localhost","selected":true},'
            '{"id":"mini","transport":"ssh","target":"mini.ts.net","user":"me"}]\npocketrig-host-ok\n'
        : 'ok 1\npocketrig-host-ok\n');
    addTearDown(() => SshExec.debugConnect = null);
    await tester.pumpWidget(MaterialApp(home: RegistryHostsScreen(host: host)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(find.byTooltip('mini actions'));
    await tester.pumpAndSettle();
    for (final l in ['Make current', 'Run doctor', 'Edit', 'Remove…']) {
      expect(find.text(l), findsOneWidget, reason: l);
    }
    await tester.tapAt(const Offset(200, 20)); // the scrim
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 10));
  });
}
