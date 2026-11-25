import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/core_ask.dart';
import 'package:pocket_rig/data/needs_you.dart' show needsYouCount;
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ui/inbox/core_ask_card.dart';
import 'package:pocket_rig/ui/recent_screen.dart';

import 'golden/fixtures.dart';

const _request = {
  'requestId': 'q1',
  'asker': 'planner@conveyor',
  'body': 'Which retry policy?',
  'decisionRevision': 'dr1',
  'episodeKey': null,
  'questions': [
    {
      'id': 'policy',
      'question': 'Which retry policy should the router use?',
      'options': [
        {'id': 'exp', 'label': 'Exponential backoff'},
        {'id': 'fixed', 'label': 'Fixed delay'},
      ]
    }
  ],
  'humanAnswers': {},
  'answer': {'job': 'human-answer', 'forms': ['option', 'typed-reply']},
};

void main() {
  test('CoreAsk reads the daemon\'s request: the first unanswered question is the one an answer binds to', () {
    final a = CoreAsk.fromJson(_request)!;
    expect((a.who, a.revision, a.answerable, a.next?.id), ('planner', 'dr1', true, 'policy'));
    expect(a.next!.options.map((o) => o.label), ['Exponential backoff', 'Fixed delay']);
    final done = CoreAsk.fromJson({..._request, 'humanAnswers': {'policy': 'exp'}})!;
    expect((done.next, done.answerable), (null, false));
    expect(CoreAsk.fromJson({..._request, 'unsupportedReason': 'request_stale', 'answer': null})!.answerable, isFalse);
  });

  final answered = <String>{};

  Future<void> mount(WidgetTester tester, {required int caps, required String? person}) async {
    answered.clear();
    tester.view.physicalSize = const Size(390, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = await installFakes();
    final inner = OpenRigClient.factory;
    OpenRigClient.factory = (h) => OpenRigClient(h,
        httpClient: MockClient((req) async {
          if (req.method == 'POST' && req.url.path.startsWith('/api/apps/v1/answers/')) {
            answered.add('${h.id}|${(jsonDecode(req.body) as Map)['requestId']}');
            return http.Response('{"submission":{"state":"committed","outcome":"answered"}}', 200);
          }
          switch (req.url.path) {
            case '/api/apps/v1/capabilities':
              return http.Response(caps == 200 ? '{"contract":"openrig.core-app","version":1}' : '{}', caps);
            case '/api/gateway/participants':
              return http.Response(
                  jsonEncode({
                    'participants': person == null ? [] : [{'id': 'phone', 'address': person}],
                    'default': {'id': person == null ? null : 'phone'}
                  }),
                  200);
            case '/api/apps/v1/credentials':
              return http.Response('{"credentialId":"c1","token":"orapp_x"}', 201);
            case '/api/apps/v1/needs-me':
              expect(req.headers['authorization'], 'Bearer orapp_x');
              expect(req.url.queryParameters['actor'], 'phone@external');
              return http.Response(
                  jsonEncode({'requests': [for (final r in [_request, {..._request, 'requestId': 'q2'}]) if (!answered.contains('${h.id}|${r['requestId']}')) r]}), 200);
          }
          final copy = http.Request(req.method, req.url)
            ..headers.addAll(req.headers)
            ..bodyBytes = req.bodyBytes;
          return http.Response.fromStream(await fakeDaemon(h).send(copy));
        }),
        eventSource: ({rigId, replay, lastEventId}) => const Stream.empty());
    addTearDown(() => OpenRigClient.factory = inner);
    AppScope.resetClients();
    await tester.pumpWidget(MaterialApp(home: phone(store, const RecentScreen())));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('the Inbox lists a structured question beside the permission cards, in the same frame', (tester) async {
    await mount(tester, caps: 200, person: 'phone@external');
    expect(find.textContaining('planner asks', findRichText: true), findsWidgets, reason: 'one per host');
    expect(find.text('Which retry policy should the router use?'), findsWidgets);
    expect(find.text('Exponential backoff'), findsWidgets, reason: 'an option button');
    expect(find.textContaining('wants to run a command', findRichText: true), findsOneWidget, reason: 'permission cards stay');
    expect(find.textContaining('needs a person'), findsNothing);
    // The tab badge counts them too: the Inbox page says "Inbox N" and the badge says the same N.
    final n = RegExp(r'Inbox (\d+)').firstMatch(tester.widget<Text>(find.textContaining('Inbox ')).data!)!.group(1);
    expect(needsYouCount.value.toString(), n, reason: 'badge and page agree');
    // Two cards: Reply… is an outlined button like the options, 48 tall on touch, and the cards are 12 apart.
    expect(tester.getSize(find.widgetWithText(OutlinedButton, 'Reply…').first).height, 48);
    final cards = find.byType(CoreAskCard);
    expect(tester.getTopLeft(cards.at(1)).dy - tester.getBottomLeft(cards.at(0)).dy, 12);
  });

  testWidgets('an answered card stays as Answered with its choice after a refresh, and the counts drop with the badge', (tester) async {
    await mount(tester, caps: 200, person: 'phone@external');
    int page() => int.parse(RegExp(r'Inbox (\d+)').firstMatch(tester.widget<Text>(find.textContaining('Inbox ')).data!)!.group(1)!);
    final before = page();
    final buttons = find.widgetWithText(OutlinedButton, 'Fixed delay').evaluate().length;
    await tester.tap(find.text('Fixed delay').first);
    await tester.pump(const Duration(milliseconds: 500));
    // The host stops listing it at the next refresh (30 s timer): the card must still be there, answered.
    await tester.pump(const Duration(seconds: 31));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.textContaining('asked · Answered', findRichText: true), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Fixed delay').evaluate().length, buttons - 1, reason: 'its buttons are gone');
    expect(find.text('Fixed delay').evaluate().length, buttons, reason: 'the choice shows as text in their place');
    expect(page(), before - 1, reason: 'the page leaves it out');
    expect(needsYouCount.value, page(), reason: 'badge and page agree');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('no person on the host: one muted line with the exact command and Copy', (tester) async {
    await mount(tester, caps: 200, person: null);
    expect(find.textContaining('Answering questions here needs a person on this host'), findsOneWidget, reason: 'one line, not one per host');
    expect(find.textContaining('rig gateway human add <id> --display-name'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.textContaining(' asks'), findsNothing);
  });

  testWidgets('an older daemon (capabilities 404): nothing new on screen', (tester) async {
    await mount(tester, caps: 404, person: 'phone@external');
    expect(find.textContaining(' asks'), findsNothing);
    expect(find.textContaining('needs a person'), findsNothing);
  });
}
