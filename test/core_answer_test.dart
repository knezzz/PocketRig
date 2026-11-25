import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/core_answer.dart';
import 'package:pocket_rig/data/core_app.dart';
import 'package:pocket_rig/data/core_ask.dart';
import 'package:pocket_rig/data/host_store.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/inbox/core_ask_card.dart';

final _askJson = <String, Object?>{
  'requestId': 'q1',
  'asker': 'planner@conveyor',
  'body': 'Which?',
  'decisionRevision': 'dr1',
  'episodeKey': null,
  'questions': [
    {'id': 'policy', 'question': 'Which retry policy?', 'options': [{'id': 'exp', 'label': 'Exponential'}, {'id': 'fixed', 'label': 'Fixed'}]}
  ],
  'humanAnswers': {},
  'answer': {'job': 'human-answer', 'forms': ['option', 'typed-reply']},
};
final _ask = CoreAsk.fromJson(_askJson)!;

void main() {
  final host = Host(id: 'h1', name: 'lab', address: '10.0.0.5', sshUser: 'u');
  late HostStore store;
  late List<(String, Map<String, Object?>?)> posts;
  late List<int> script;
  late List<String> revokes;
  late bool capsOk;
  final inner = OpenRigClient.factory;
  var receipt = false;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    store = HostStore();
    resetCoreAppSession();
    revokes = [];
    capsOk = true;
    posts = [];
    script = [];
    receipt = false;
    OpenRigClient.factory = (h) => OpenRigClient(h, httpClient: MockClient((req) async {
          final path = req.url.path;
          if (path == '/api/apps/v1/capabilities') return capsOk ? http.Response('{"contract":"openrig.core-app","version":1}', 200) : http.Response('{}', 404);
          if (path == '/api/gateway/participants') {
            return http.Response('{"participants":[{"id":"phone","address":"phone@external"}],"default":{"id":"phone"}}', 200);
          }
          if (path == '/api/apps/v1/credentials') return http.Response('{"credentialId":"c1","token":"orapp_x"}', 201);
          if (req.method == 'DELETE') {
            revokes.add(path);
            return http.Response('{"revoked":true}', 200);
          }
          if (req.method == 'POST') {
            posts.add((path, (jsonDecode(req.body) as Map).cast<String, Object?>()));
            final st = script.isEmpty ? 200 : script.removeAt(0);
            return http.Response(
                st == 200
                    ? jsonEncode({'submission': {'state': 'committed', 'outcome': 'answered'}})
                    : st == 409
                        ? '{"code":"answer_already_finalized"}'
                        : '{"error":"submission_incomplete"}',
                st);
          }
          if (path.startsWith('/api/apps/v1/requests/')) {
            return http.Response(jsonEncode({..._askJson, 'humanAnswers': {'policy': 'fixed'}}), 200);
          }
          // GET /answers/:id
          return http.Response(jsonEncode({'submission': {'state': receipt ? 'committed' : 'incomplete', 'outcome': 'answered'}}), 200);
        }));
  });
  tearDown(() => OpenRigClient.factory = inner);

  test('an answer carries its binding: the first unanswered question, the revision, the actor and one option', () async {
    final r = await submitCoreAnswer(store, host, _ask, optionAnswer('exp'));
    expect(r.outcome, AnswerOutcome.recorded);
    final (path, body) = posts.single;
    expect(RegExp(r'^/api/apps/v1/answers/[A-Za-z0-9_-]{24}$').hasMatch(path), isTrue);
    expect(body, {
      'job': 'human-answer',
      'actor': 'phone@external',
      'requestId': 'q1',
      'questionId': 'policy',
      'episodeKey': null,
      'expectedRevision': 'dr1',
      'answer': {'kind': 'option', 'optionId': 'exp'},
    });
    expect(await store.pendingAnswer('h1', 'q1'), isNull, reason: 'nothing left to retry');
  });

  test('a 503 retries the same id and the same bytes, reading the receipt first, and ends recorded', () async {
    script = [503, 503, 200];
    final r = await submitCoreAnswer(store, host, _ask, typedAnswer('  ship it  '), backoff: const [Duration.zero, Duration.zero, Duration.zero]);
    expect(r.outcome, AnswerOutcome.recorded);
    expect(posts.length, 3);
    expect(posts.map((p) => p.$1).toSet().length, 1, reason: 'one answer id for every attempt');
    expect(posts.map((p) => jsonEncode(p.$2)).toSet().length, 1, reason: 'the same payload');
    expect(posts.first.$2!['answer'], {'kind': 'typed-reply', 'text': 'ship it'});
  });

  test('a 503 that lasts is saved as pending; sending again reuses the saved id even for another choice', () async {
    script = [503, 503];
    final r = await submitCoreAnswer(store, host, _ask, optionAnswer('exp'), backoff: const [Duration.zero]);
    expect(r.outcome, AnswerOutcome.pending);
    final saved = await store.pendingAnswer('h1', 'q1');
    expect(saved?['answerId'], isNotNull);
    posts.clear();
    await submitCoreAnswer(store, host, _ask, optionAnswer('fixed'));
    expect(posts.single.$1, endsWith(saved!['answerId'] as String));
    expect((posts.single.$2!['answer'] as Map)['optionId'], 'exp', reason: 'the decision already sent is the one retried');
  });

  test('a receipt already committed ends the retry without sending again', () async {
    script = [503];
    receipt = true;
    final r = await submitCoreAnswer(store, host, _ask, optionAnswer('exp'));
    expect(r.outcome, AnswerOutcome.recorded);
    expect(posts.length, 1);
  });

  test('409 says already answered and never retries with a new id', () async {
    script = [409];
    final r = await submitCoreAnswer(store, host, _ask, optionAnswer('exp'));
    expect(r.outcome, AnswerOutcome.alreadyAnswered);
    expect(posts.length, 1);
    expect(await store.pendingAnswer('h1', 'q1'), isNull);
  });

  testWidgets('the card: tapping an option sends it and the card then reads Answered with the choice', (tester) async {
    Map<String, Object?>? sent;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CoreAskCard(
                ask: _ask,
                onSubmit: (a) async {
                  sent = a;
                  return AnswerResult(AnswerOutcome.recorded, sent: a, questionId: 'policy');
                }))));
    expect(find.text('Exponential'), findsOneWidget);
    expect(find.text('Reply…'), findsOneWidget);
    await tester.tap(find.text('Fixed'));
    await tester.pumpAndSettle();
    expect(sent, {'kind': 'option', 'optionId': 'fixed'});
    expect(find.textContaining('Answered', findRichText: true), findsOneWidget);
    expect(find.text('Fixed'), findsOneWidget, reason: 'the recorded answer, not the buttons');
    expect(find.text('Exponential'), findsNothing);
  });

  testWidgets('the card: Reply… opens a text field; empty text sends nothing', (tester) async {
    final sent = <Map<String, Object?>>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: CoreAskCard(ask: _ask, onSubmit: (a) async {
          sent.add(a);
          return const AnswerResult(AnswerOutcome.recorded);
        }))));
    await tester.tap(find.text('Reply…'));
    await tester.pump();
    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(sent, isEmpty);
    await tester.enterText(find.byType(TextField), 'use jitter');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(sent, [{'kind': 'typed-reply', 'text': 'use jitter'}]);
  });

  testWidgets('after a not-confirmed answer the card shows the saved answer and only Send again, which resends that one', (tester) async {
    final calls = <Map<String, Object?>>[];
    var n = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CoreAskCard(
                ask: _ask,
                onSubmit: (a) async {
                  calls.add(a);
                  final saved = optionAnswer('exp'); // the saved payload wins, whatever was tapped
                  return n++ == 0
                      ? AnswerResult(AnswerOutcome.pending, reason: 'busy', sent: saved, questionId: 'policy')
                      : AnswerResult(AnswerOutcome.recorded, sent: saved, questionId: 'policy');
                }))));
    await tester.tap(find.text('Exponential'));
    await tester.pumpAndSettle();
    expect(find.text('Saved answer: Exponential'), findsOneWidget);
    expect(find.text('Fixed'), findsNothing, reason: 'no other option can be tapped now');
    expect(find.text('Reply…'), findsNothing);
    await tester.tap(find.text('Send again'));
    await tester.pumpAndSettle();
    expect(calls.last, {'kind': 'option', 'optionId': 'exp'});
    expect(find.textContaining('Exponential'), findsOneWidget, reason: 'recorded: the label of what was sent');
  });

  test('the result names what was sent: a tap on another option after a pending one still sends the saved payload', () async {
    script = [503, 503];
    final first = await submitCoreAnswer(store, host, _ask, optionAnswer('exp'), backoff: const [Duration.zero]);
    final second = await submitCoreAnswer(store, host, _ask, optionAnswer('fixed'));
    expect(first.sent, {'kind': 'option', 'optionId': 'exp'});
    expect(second.sent, {'kind': 'option', 'optionId': 'exp'});
    expect(second.outcome, AnswerOutcome.recorded);
  });

  test('two answers saved at once both survive (one key each)', () async {
    await Future.wait([
      store.setPendingAnswer('h1', 'a', {'answerId': '1'}),
      store.setPendingAnswer('h1', 'b', {'answerId': '2'}),
    ]);
    expect((await store.pendingAnswer('h1', 'a'))?['answerId'], '1');
    expect((await store.pendingAnswer('h1', 'b'))?['answerId'], '2');
  });

  test('409 re-reads the request and shows the answer the daemon holds', () async {
    script = [409];
    final r = await submitCoreAnswer(store, host, _ask, optionAnswer('exp'));
    expect((r.outcome, r.shown), (AnswerOutcome.alreadyAnswered, 'Fixed'));
  });

  test('loading the asks leaves no token in what the screen keeps', () async {
    final (app, _) = await loadCoreAsks(store, host);
    expect((app.state, app.actor, app.token), (CoreAppState.ready, 'phone@external', null));
  });

  test('a forced re-issue revokes the old credential first and happens once per session, not on every refresh', () async {
    await coreAppFor(store, host);
    final a = await coreAppFor(store, host, forceNew: true);
    expect(a.state, CoreAppState.ready);
    final b = await coreAppFor(store, host, forceNew: true);
    expect(b.state, CoreAppState.failed);
    expect(revokes, ['/api/apps/v1/credentials/c1']);
  });

  test('turning a host off revokes its credential; removing it deletes its pending answers', () async {
    await store.upsert(host);
    await coreAppFor(store, host);
    await store.setPendingAnswer('h1', 'q9', {'answerId': 'z'});
    await store.setEnabled(host, false);
    await Future<void>.delayed(Duration.zero);
    expect(revokes, ['/api/apps/v1/credentials/c1']);
    expect(await store.appCredential('h1'), isNull);
    await store.remove('h1');
    expect(await store.pendingAnswer('h1', 'q9'), isNull);
  });

  test('no credential just now: nothing sent or saved, reported as not sent', () async {
    capsOk = false;
    final r = await submitCoreAnswer(store, host, _ask, optionAnswer('exp'));
    expect((r.outcome, r.sent), (AnswerOutcome.notSent, null));
    expect(posts, isEmpty);
    expect(await store.pendingAnswer('h1', 'q1'), isNull);
  });

  testWidgets('a not-sent result keeps the options enabled and says to try again', (tester) async {
    var n = 0;
    final sent = <Map<String, Object?>>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CoreAskCard(
                ask: _ask,
                onSubmit: (a) async {
                  sent.add(a);
                  return n++ == 0 ? const AnswerResult(AnswerOutcome.notSent, reason: 'No credential.') : AnswerResult(AnswerOutcome.recorded, sent: a, questionId: 'policy');
                }))));
    await tester.tap(find.text('Exponential'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Not sent, try again'), findsOneWidget);
    expect(find.textContaining('Saved answer'), findsNothing);
    await tester.tap(find.text('Fixed'));
    await tester.pumpAndSettle();
    expect(sent.last, {'kind': 'option', 'optionId': 'fixed'});
  });

  testWidgets('a card built with a saved, unconfirmed answer offers Send again for it instead of the options', (tester) async {
    await store.setPendingAnswer('h1', 'q1', {
      'answerId': 'a',
      'payload': {'questionId': 'policy', 'answer': optionAnswer('exp')}
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: CoreAskCard(ask: _ask, onSubmit: (a) async => const AnswerResult(AnswerOutcome.refused), loadSaved: () => savedCoreAnswer(store, host, _ask)))));
    await tester.pumpAndSettle();
    expect(find.text('Saved answer: Exponential'), findsOneWidget);
    expect(find.text('Send again'), findsOneWidget);
    expect(find.text('Fixed'), findsNothing);
  });
}
