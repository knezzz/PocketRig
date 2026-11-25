import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;

import 'golden/fixtures.dart';
import 'sidebar_fold_helper.dart';

/// One rig per host, its seats in /Users/me/<project>; [working] seats are mid-turn.
http.Client daemonFor(String project, {Future<void>? holdPs, bool working = false}) => MockClient((req) async {
      final path = req.url.path;
      Object body = const [];
      if (path == '/api/ps') {
        await holdPs;
        body = [
          {
            'rigId': 'r-$project',
            'name': '$project-rig',
            'nodeCount': 1,
            'runningCount': 1,
            'attentionCount': 0,
            'status': 'running'
          },
        ];
      } else if (path == '/api/rigs/r-$project/nodes') {
        body = [
          {
            'logicalId': 'lead',
            'canonicalSessionName': 'lead@$project-rig',
            'runtime': 'claude-code',
            'cwd': '/Users/me/$project',
            if (working) 'activityState': {'activity': 'working'},
          },
        ];
      } else if (path.startsWith('/api/discovery')) {
        body = {'sessions': []};
      }
      return http.Response(jsonEncode(body), 200);
    });

void main() {
  testWidgets('every host has its own section, with what it is running', (tester) async {
    final store = await installFakes();
    OpenRigClient.factory = (h) => OpenRigClient(h,
        httpClient: h.id == homelab.id ? daemonFor('alpha', working: true) : daemonFor('beta'),
        eventSource: ({rigId, replay, lastEventId}) => const Stream.empty());

    await tester.binding.setSurfaceSize(const Size(390, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(AppScope(store: store, child: const MaterialApp(home: AppShell())));
    await tester.pumpAndSettle();
    await openDrawer(tester);
    // Each host is a row of the tree, with its projects under it.
    expect(find.text('HOMELAB'), findsOneWidget);
    expect(find.text('MACBOOK'), findsOneWidget);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);

    // A rig lists its working agents unasked; its long-press list (a drawer has no chevron or right click) folds it.
    expect(find.text('lead'), findsOneWidget);
    await chooseView(tester, find.text('alpha-rig'), 'Fold');
    expect(find.text('lead'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('opening a rig from another host makes that host active', (tester) async {
    final store = await installFakes();
    OpenRigClient.factory = (h) => OpenRigClient(h,
        httpClient: h.id == homelab.id ? daemonFor('alpha') : daemonFor('beta'),
        eventSource: ({rigId, replay, lastEventId}) => const Stream.empty());
    await tester.binding.setSurfaceSize(const Size(390, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(AppScope(store: store, child: const MaterialApp(home: AppShell())));
    await tester.pumpAndSettle();
    await openDrawer(tester);
    expect(store.active?.id, homelab.id);

    await tester.tap(find.text('beta-rig'));
    await tester.pump();
    expect(store.active?.id, macbook.id);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('a slow host does not hold up the others', (tester) async {
    final store = await installFakes();
    final slow = Completer<void>();
    OpenRigClient.factory = (h) => OpenRigClient(h,
        httpClient: h.id == homelab.id ? daemonFor('alpha', holdPs: slow.future) : daemonFor('beta'),
        eventSource: ({rigId, replay, lastEventId}) => const Stream.empty());

    await tester.binding.setSurfaceSize(const Size(390, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(AppScope(store: store, child: const MaterialApp(home: AppShell())));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byIcon(Icons.menu).first);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('alpha'), findsNothing);
    expect(find.text('Loading…'), findsOneWidget);

    slow.complete();
    await tester.pumpAndSettle();
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 11));
  });

  test('the newest message per agent comes back from one SSH script', () {
    final seats = [
      Seat(rigId: 'r', logicalId: 'a', resumeToken: 'tok-a'),
      Seat(rigId: 'r', logicalId: 'b', resumeToken: 'tok-b'),
    ];
    final script = lastMessagesScript(seats);
    expect(script, contains('@@pr-seat 0'));
    expect(script, contains('tok-b.jsonl'));
    final out = [
      '@@pr-seat 0',
      jsonEncode({
        'type': 'user',
        'uuid': 'u1',
        'message': {'content': 'Run the suite'}
      }),
      jsonEncode({
        'type': 'assistant',
        'uuid': 'a1',
        'timestamp': '2026-11-02T10:00:00Z',
        'message': {
          'id': 'm1',
          'model': 'claude-opus-4-5-20251101',
          'content': [
            {'type': 'text', 'text': 'All green.'}
          ]
        }
      }),
      '@@pr-seat 1',
      jsonEncode({
        'type': 'user',
        'uuid': 'u2',
        'message': {'content': 'Ship it'}
      }),
    ].join('\n');
    final got = parseLastMessages(out);
    expect(got[0]!.text, 'All green.');
    expect(got[0]!.fromUser, isFalse);
    expect(got[1]!.text, 'Ship it');
    expect(got[1]!.fromUser, isTrue);
  });

  test('model ids read as names', () {
    expect(modelLabel('claude-opus-4-5-20251101'), 'Opus 4.5');
    expect(modelLabel('claude-sonnet-5-5'), 'Sonnet 5.5');
    expect(modelLabel('opus'), 'Opus');
    expect(modelLabel('sonnet[1m]'), 'Sonnet 1M');
  });
}
