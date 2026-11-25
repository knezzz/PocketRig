import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/rig/add_to_queue_sheet.dart';

import 'golden/fixtures.dart';

Seat _seat(String id, String session) =>
    Seat(rigId: 'r1', logicalId: id, nodeId: 'n-$id', sessionName: session, runtime: 'claude-code');

/// Opens the sheet from a button; the result of the sheet lands in [result].
Future<List<Map>> _open(WidgetTester tester, {Seat? seat, List<Seat> seats = const [], List<int> statuses = const [200]}) async {
  final store = await installFakes();
  final posts = <Map>[];
  OpenRigClient.factory = (h) => OpenRigClient(h,
      eventSource: ({rigId, replay, lastEventId}) => const Stream.empty(),
      httpClient: MockClient((req) async {
        if (req.url.path != '/api/queue/create') return http.Response('[]', 200);
        posts.add(jsonDecode(req.body) as Map);
        final status = statuses[(posts.length - 1).clamp(0, statuses.length - 1)];
        return http.Response(jsonEncode(status == 200 ? {'qitemId': posts.last['qitemId']} : {'error': 'daemon says no'}), status);
      }));
  await tester.pumpWidget(AppScope(
    store: store,
    child: MaterialApp(
      home: Builder(
        builder: (context) => TextButton(onPressed: () => showAddToQueue(context, seat: seat, seats: seats), child: const Text('open')),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return posts;
}

void main() {
  testWidgets('a preselected agent asks only for the message and sends the queue item', (tester) async {
    final posts = await _open(tester, seat: _seat('dev.impl', 'dev-impl@crew'));
    expect(find.text('Add to dev.impl\'s queue'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<Seat>), findsNothing, reason: 'no agent picker');
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull, reason: 'needs a message');

    await tester.enterText(find.byType(TextField), 'Fix the flaky test\nthen run the suite');
    await tester.tap(find.text('urgent'));
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(posts, hasLength(1));
    final p = posts.single;
    expect(p['destinationSession'], 'dev-impl@crew');
    expect(p['sourceSession'], 'pocketrig');
    expect(p['body'], 'Fix the flaky test\nthen run the suite');
    expect(p['summary'], 'Fix the flaky test');
    expect(p['priority'], 'urgent');
    expect(p['qitemId'], matches(RegExp(r'^qitem-\d{14}-[0-9a-f]{16}$')));
    expect(find.text('Add to dev.impl\'s queue'), findsNothing, reason: 'the sheet closes');
  });

  testWidgets('without an agent it asks which one, and routine is the default', (tester) async {
    final posts = await _open(tester, seats: [_seat('dev.impl', 'dev-impl@crew'), _seat('dev.qa', 'dev-qa@crew')]);
    await tester.enterText(find.byType(TextField), 'Look at the queue');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull, reason: 'no agent yet');

    await tester.tap(find.byType(DropdownButtonFormField<Seat>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('dev.qa').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(posts.single['destinationSession'], 'dev-qa@crew');
    expect(posts.single['priority'], 'routine');
  });

  testWidgets('a failure keeps the sheet and text; retrying reuses the id, editing mints a new one', (tester) async {
    final posts = await _open(tester, seat: _seat('dev.impl', 'dev-impl@crew'), statuses: [500, 500, 200]);
    await tester.enterText(find.byType(TextField), 'Do the thing');
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.textContaining('daemon says no'), findsOneWidget);
    expect(find.text('Do the thing'), findsOneWidget, reason: 'nothing typed is lost');

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(posts[1]['qitemId'], posts[0]['qitemId'], reason: 'a retry never creates a second row');

    await tester.enterText(find.byType(TextField), 'Do the other thing');
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(posts[2]['qitemId'], isNot(posts[0]['qitemId']), reason: 'a different message is different work');
    expect(find.text('Add to dev.impl\'s queue'), findsNothing);
  });

  testWidgets('the summary is the first line, cut to 80 characters', (tester) async {
    final posts = await _open(tester, seat: _seat('dev.impl', 'dev-impl@crew'));
    await tester.enterText(find.byType(TextField), '${'x' * 100}\nsecond line');
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(posts.single['summary'], '${'x' * 79}…');
  });
}
