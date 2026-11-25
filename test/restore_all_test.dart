import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/restore_all.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ui/restore_all.dart';

import 'golden/fixtures.dart';

void main() {
  test('runPool runs at most the limit at once and every item', () async {
    var running = 0, peak = 0;
    final done = <int>[];
    await runPool(List.generate(7, (i) => i), 3, (i) async {
      running++;
      if (running > peak) peak = running;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      running--;
      done.add(i);
    });
    expect(peak, 3);
    expect(done.toSet(), {0, 1, 2, 3, 4, 5, 6});
  });

  testWidgets('Restore all stopped rigs: lists them, asks, restores 3 at a time, names the one that failed, the others carry on', (tester) async {
    final store = await installFakes();
    final stopped = [
      for (var i = 1; i <= 4; i++)
        {'rigId': 'r-s$i', 'name': 'stopped-$i', 'nodeCount': 1, 'runningCount': 0, 'attentionCount': 0, 'status': 'stopped', 'latestSnapshot': '1d ago'}
    ];
    final gates = <String, Completer<void>>{};
    var running = 0, peak = 0;
    final upped = <String>[];
    final inner = OpenRigClient.factory;
    OpenRigClient.factory = (h) => OpenRigClient(h,
        httpClient: MockClient((req) async {
          if (req.url.path == '/api/ps') return http.Response(jsonEncode(stopped), 200);
          if (req.url.path == '/api/up') {
            final name = (jsonDecode(req.body) as Map)['sourceRef'] as String;
            upped.add(name);
            peak = ++running > peak ? running : peak;
            await (gates[name] = Completer<void>()).future;
            running--;
            return name == 'stopped-2'
                ? http.Response(jsonEncode({'status': 'failed', 'errors': ['no snapshot']}), 200)
                : http.Response(jsonEncode({'status': 'restored'}), 200);
          }
          return http.Response('[]', 200);
        }),
        eventSource: ({rigId, replay, lastEventId}) => const Stream.empty());
    addTearDown(() => OpenRigClient.factory = inner);
    AppScope.resetClients();
    await fleet.feedFor(homelab).refresh();
    expect(stoppedRigs(homelab), hasLength(4));
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(AppScope(
        store: store,
        child: MaterialApp(home: Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => restoreAllStopped(c, homelab), child: const Text('go')))))));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Restore 4 stopped rigs on'), findsOneWidget);
    expect(upped, isEmpty, reason: 'nothing before the confirm');
    await tester.tap(find.text('Restore 4'));
    await tester.pump();
    await tester.pump();
    expect(upped, ['stopped-1', 'stopped-2', 'stopped-3'], reason: 'three at once, the fourth waits');
    gates['stopped-1']!.complete();
    await tester.pump();
    await tester.pump();
    expect(upped, hasLength(4), reason: 'a finished one starts the waiting one');
    for (final g in gates.values) {
      if (!g.isCompleted) g.complete();
    }
    await tester.pumpAndSettle();
    expect(peak, 3);
    expect(find.text('Restored 3 of 4'), findsOneWidget);
    expect(find.textContaining('Couldn\'t restore:'), findsOneWidget, reason: 'only stopped-2');
    expect(find.textContaining('no snapshot'), findsOneWidget, reason: 'with the daemon\'s reason');
    expect(find.text('Restored'), findsNWidgets(3));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
