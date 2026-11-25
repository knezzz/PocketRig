import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ui/rig/rig_chat.dart' show HandoffDetail;
import 'package:pocket_rig/ui/rig_screen.dart';

import 'golden/fixtures.dart';

void main() {
  late List<(String, Map)> writes;
  Object? refuse;

  Future<void> open(WidgetTester tester) async {
    final store = await installFakes();
    writes = [];
    refuse = null;
    final inner = OpenRigClient.factory;
    OpenRigClient.factory = (h) => OpenRigClient(h,
        httpClient: MockClient((req) async {
          final p = req.url.path;
          if (req.method == 'POST' && (p.endsWith('/handoff') || p.endsWith('/update'))) {
            writes.add((p, jsonDecode(req.body) as Map));
            return refuse != null
                ? http.Response(jsonEncode({'error': 'queue_item_not_found', 'message': refuse}), 409)
                : http.Response(jsonEncode({'ok': true}), p.endsWith('/handoff') ? 201 : 200);
          }
          final copy = http.Request(req.method, req.url)
            ..headers.addAll(req.headers)
            ..bodyBytes = req.bodyBytes;
          return http.Response.fromStream(await fakeDaemon(h).send(copy));
        }),
        eventSource: ({rigId, replay, lastEventId}) => const Stream.empty());
    addTearDown(() => OpenRigClient.factory = inner);
    AppScope.resetClients();
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await fleet.feedFor(homelab).refresh();
    final rig = fleet.feedFor(homelab).rigs.map((r) => r.rig).firstWhere((r) => r.name == 'conveyor');
    await tester.pumpWidget(MaterialApp(home: phone(store, RigScreen(rig: rig, projectName: 'app'))));
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.descendant(of: find.byType(RigScreen), matching: find.textContaining('Work')).first);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  }

  testWidgets('Reassign picks another seat, confirms, and writes a handoff (not a state change); the daemon\'s refusal is shown', (tester) async {
    await open(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Reassign…'));
    await tester.pumpAndSettle();
    expect(find.text('lead'), findsNothing, reason: 'the item\'s own seat is not offered (it is on lead)');
    await tester.tap(find.text('impl'));
    await tester.pumpAndSettle();
    expect(find.text('Hand this to impl?'), findsOneWidget);
    expect(writes, isEmpty, reason: 'nothing before the confirm');
    await tester.tap(find.text('Reassign'));
    await tester.pumpAndSettle();
    expect(writes, hasLength(1));
    expect(writes.single.$1, endsWith('/handoff'));
    expect(writes.single.$2, containsPair('toSession', 'impl@conveyor'));
    expect(writes.single.$2, containsPair('fromSession', 'pocketrig'));
    expect(find.text('Handed to impl'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    refuse = 'not yours to hand off';
    await tester.tap(find.widgetWithText(OutlinedButton, 'Reassign…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('review'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reassign'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not yours to hand off'), findsOneWidget, reason: 'the daemon\'s own message');
    await close(tester);
  });

  testWidgets('Reassign re-reads the item before the handoff and stops if it moved since the confirm', (tester) async {
    await open(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Reassign…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('impl'));
    await tester.pumpAndSettle();
    queueOverrides[tester.widget<HandoffDetail>(find.byType(HandoffDetail)).item.id] = {'state': 'done'}; // someone closed it meanwhile
    await tester.tap(find.text('Reassign'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty, reason: 'nothing was sent');
    expect(find.textContaining('This item changed since you opened it (done)'), findsOneWidget);
    await close(tester);
  });

  testWidgets('Mark done asks for a closure reason, then confirms, then writes state done with it', (tester) async {
    await open(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Mark done…'));
    await tester.pumpAndSettle();
    expect(find.text('Canceled'), findsOneWidget);
    await tester.tap(find.text('Canceled'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty, reason: 'nothing before the confirm');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty, reason: 'Cancel writes nothing');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Mark done…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark done'));
    await tester.pumpAndSettle();
    expect(writes, hasLength(1));
    expect(writes.single.$1, endsWith('/update'));
    expect(writes.single.$2, containsPair('state', 'done'));
    expect(writes.single.$2, containsPair('closureReason', 'no-follow-on'));
    expect(writes.single.$2, containsPair('actorSession', 'pocketrig'));
    await close(tester);
  });

  testWidgets('a closed item has neither button', (tester) async {
    await open(tester);
    await tester.tap(find.textContaining('Closed ').first);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(OutlinedButton, 'Reassign…'), findsNothing);
    await close(tester);
  });

  test('the fake daemon (and so the demo) applies a handoff and a close to the next list', () async {
    await installFakes();
    final c = fakeDaemon(homelab);
    Future<List> list() async => jsonDecode((await http.Response.fromStream(await c.send(http.Request('GET', Uri.parse('http://x/api/queue/list?rig=conveyor'))))).body) as List;
    Future<void> post(String path, Map b) async =>
        c.send(http.Request('POST', Uri.parse('http://x$path'))..body = jsonEncode(b)..headers['content-type'] = 'application/json');
    final before = await list();
    final first = before.first as Map;
    await post('/api/queue/${first['qitemId']}/handoff', {'toSession': 'tests@conveyor'});
    var now = await list();
    expect(now, hasLength(before.length + 1), reason: 'the successor');
    expect(now.firstWhere((q) => q['qitemId'] == first['qitemId'])['state'], 'handed-off');
    expect(now.last['destinationSession'], 'tests@conveyor');
    final second = before[1] as Map;
    await post('/api/queue/${second['qitemId']}/update', {'state': 'done', 'closureReason': 'canceled'});
    now = await list();
    expect(now.firstWhere((q) => q['qitemId'] == second['qitemId']), containsPair('closureReason', 'canceled'));
    await installFakes();
    expect(await list(), hasLength(before.length), reason: 'installFakes starts clean');
  });
}
