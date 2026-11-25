import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/host_actions.dart';

import 'golden/fixtures.dart';

void main() {
  testWidgets('the host list has a Rescan row that closes the sheet (the scan itself is fleet\'s, tested there)', (tester) async {
    final store = await installFakes();
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
    addTearDown(() => SshExec.debugConnect = null);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () => showHostActions(context, store.hosts.first), child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Rescan'), findsOneWidget);
    await tester.tap(find.text('Rescan'));
    await tester.pumpAndSettle();
    expect(find.text('Rescan'), findsNothing, reason: 'the sheet closed');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the host list (the sidebar ⋯ and ⌘K) offers Restore all stopped rigs, with the count, only when some are stopped', (tester) async {
    final store = await installFakes();
    final host = store.hosts.first;
    await fleet.feedFor(host).refresh();
    final rows = hostActionRows(host).items;
    expect(rows.map((r) => r.$2), contains('Restore all stopped rigs…'));
    expect(rows.firstWhere((r) => r.$2.startsWith('Restore all')).$3, '1 stopped on ${host.name}');
    final empty = Host(id: 'e', name: 'e', address: 'a', sshUser: 'u');
    expect(hostActionRows(empty).items.map((r) => r.$2), isNot(contains('Restore all stopped rigs…')));
  });
}
