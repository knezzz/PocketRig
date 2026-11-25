import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/rig/seats_tab.dart' show SeatRow;
import 'package:pocket_rig/ui/progress_bar.dart' show ContextBar;
import 'package:pocket_rig/ui/status_shape.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

void main() {
  testWidgets('the rig page: a seat that did not launch is red with the daemon\'s reason and a Retry; a healthy one has neither',
      (tester) async {
    final store = await installFakes();
    final posts = <(String, Map)>[];
    OpenRigClient.factory = (h) => OpenRigClient(h,
        eventSource: ({rigId, replay, lastEventId}) => const Stream.empty(),
        httpClient: MockClient((req) async {
          if (req.url.path.startsWith('/api/seat/launch/')) posts.add((req.url.path, jsonDecode(req.body) as Map));
          return http.Response(jsonEncode({'ok': true}), 200);
        }));
    final failed = Seat.fromJson({
      'rigId': 'r1',
      'logicalId': 'core.qa',
      'runtime': 'codex',
      'canonicalSessionName': 'core-qa@crew',
      'startupStatus': 'failed',
      'latestError': 'codex: command not found',
      'contextUsage': {'usedPercentage': 42, 'availability': 'known'},
    });
    final fine = Seat.fromJson({'rigId': 'r1', 'logicalId': 'core.lead', 'runtime': 'claude-code', 'startupStatus': 'ready'});
    expect(failed.launchFailed, isTrue);
    expect(fine.launchFailed, isFalse);
    await tester.pumpWidget(AppScope(
      store: store,
      child: MaterialApp(
        theme: buildTheme(Tokens.light, Brightness.light),
        home: Scaffold(
          body: Column(children: [
            SeatRow(seat: failed, onTap: () {}, onMore: () {}),
            SeatRow(seat: fine, onTap: () {}, onMore: () {}),
          ]),
        ),
      ),
    ));
    expect(find.text('Didn\'t start: codex: command not found'), findsOneWidget);
    expect(tester.widget<Text>(find.text('Didn\'t start: codex: command not found')).style!.color, Tokens.light.removed);
    final icons = tester.widgetList<StatusIcon>(find.byType(StatusIcon)).toList();
    expect([for (final i in icons) i.status], [Status.failed, Status.idle], reason: 'the failed seat\'s icon is red');
    expect(find.byType(ContextBar), findsNothing, reason: 'it never started: no context bar (the healthy seat has no reading either)');
    expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Retry'));
    await tester.pump();
    expect(posts.single.$1, '/api/seat/launch/core-qa%40crew');
    expect(posts.single.$2, containsPair('fresh', true));
    expect(posts.single.$2.containsKey('stop'), isFalse);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Retry')).onPressed, isNull, reason: 'waits for the next poll');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Retry'), warnIfMissed: false);
    await tester.pump();
    expect(posts, hasLength(1), reason: 'a second tap sends nothing');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
