import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/git_status.dart';
import 'package:pocket_rig/data/rig_spec.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ui/launch_sheet.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

const spec = '''
version: "0.2"
name: crew
pods:
  - id: core
    members:
      - id: lead
        runtime: claude-code
      - id: qa
        runtime: codex
''';

void main() {
  testWidgets('checks the plan, follows the seats while starting, then opens the rig', (tester) async {
    final store = await installFakes();
    final launched = Completer<void>();
    final ups = <Map>[];
    var leadReady = false;
    OpenRigClient.factory = (h) => OpenRigClient(h,
        eventSource: ({rigId, replay, lastEventId}) => const Stream.empty(),
        httpClient: MockClient((req) async {
          final path = req.url.path;
          Object body = const [];
          if (path == '/api/up') {
            final b = jsonDecode(req.body) as Map;
            ups.add(b);
            if (b['plan'] == true) {
              body = {
                'status': 'planned',
                'stages': [
                  {'stage': 'resolve_spec', 'status': 'ok'},
                  {'stage': 'verify_runtimes', 'status': 'ok', 'detail': 'claude, codex'},
                ],
              };
            } else {
              await launched.future;
              body = {'status': 'completed', 'rigId': 'r1'};
            }
          } else if (path == '/api/ps') {
            body = [
              {'rigId': 'r1', 'name': 'crew-feat', 'nodeCount': 2, 'runningCount': 1, 'attentionCount': 0, 'status': 'running'},
            ];
          } else if (path == '/api/rigs/r1/nodes') {
            body = [
              {'logicalId': 'core.lead', 'startupStatus': leadReady ? 'ready' : 'pending', 'runtime': 'claude-code'},
            ];
          }
          return http.Response(jsonEncode(body), 200);
        }));

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(AppScope(
      store: store,
      child: MaterialApp(
        home: Scaffold(
          body: LaunchSheet(
            file: RigSpecFile(path: '/p/rig.yaml', projectPath: '/p'),
            spec: RigSpecSummary.parse(spec),
            projectName: 'p',
            worktrees: [Worktree('/p', 'main'), Worktree('/p/.claude/worktrees/feat', 'feat')],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Spec is valid'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);

    // Picking the worktree renames the rig and checks again there.
    await tester.tap(find.text('feat'));
    await tester.pumpAndSettle();
    expect(ups.last, containsPair('cwdOverride', '/p/.claude/worktrees/feat'));
    expect(ups.last, containsPair('rigName', 'crew-feat'));
    expect(ups.last, containsPair('plan', true));

    await tester.tap(find.text('Start in feat'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Starting lead'), findsOneWidget);
    expect(find.text('0 of 2 seats ready · first starts often take 2–3 minutes'), findsOneWidget);
    expect(find.text('Waiting'), findsOneWidget); // qa isn't on the daemon yet
    expect(find.text('worktree feat · feat'), findsOneWidget, reason: 'where it is starting');
    expect(find.text('You can close this. The rig keeps starting, and you\'ll get a toast when it\'s up.'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Open rig now')).onPressed, isNotNull,
        reason: 'the rig exists, so it can be opened while it starts');

    leadReady = true;
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('1 of 2 seats ready · first starts often take 2–3 minutes'), findsOneWidget);

    launched.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('crew-feat is running'), findsOneWidget);
    expect(find.text('Open rig'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
  });

  testWidgets('a seat that failed to launch is red with the daemon\'s reason and a Retry that launches it again', (tester) async {
    final store = await installFakes();
    final posts = <(String, Map)>[];
    OpenRigClient.factory = (h) => OpenRigClient(h,
        eventSource: ({rigId, replay, lastEventId}) => const Stream.empty(),
        httpClient: MockClient((req) async {
          final path = req.url.path;
          Object body = const [];
          if (path == '/api/up') {
            final b = jsonDecode(req.body) as Map;
            body = b['plan'] == true
                ? {
                    'status': 'planned',
                    'stages': [
                      {'stage': 'resolve_spec', 'status': 'ok'}
                    ]
                  }
                : {
                    'status': 'partial',
                    'rigId': 'r1',
                    'stages': [
                      {
                        'stage': 'import_rig',
                        'status': 'failed',
                        'detail': {
                          'nodes': [
                            {'logicalId': 'core.lead', 'status': 'launched'},
                            {'logicalId': 'core.qa', 'status': 'failed', 'error': 'codex: command not found'},
                          ]
                        }
                      }
                    ],
                  };
          } else if (path == '/api/ps') {
            body = [
              {'rigId': 'r1', 'name': 'crew', 'nodeCount': 2, 'runningCount': 1, 'attentionCount': 0, 'status': 'running'},
            ];
          } else if (path == '/api/rigs/r1/nodes') {
            body = [
              {'logicalId': 'core.lead', 'startupStatus': 'ready', 'runtime': 'claude-code'},
              {'logicalId': 'core.qa', 'startupStatus': 'failed', 'latestError': 'codex: command not found', 'runtime': 'codex'},
            ];
          } else if (path.startsWith('/api/seat/launch/')) {
            posts.add((path, jsonDecode(req.body) as Map));
            body = {'ok': true};
          }
          return http.Response(jsonEncode(body), 200);
        }));
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(AppScope(
      store: store,
      child: MaterialApp(
        home: Scaffold(
          body: LaunchSheet(
            file: RigSpecFile(path: '/p/rig.yaml', projectPath: '/p'),
            spec: RigSpecSummary.parse(spec),
            projectName: 'p',
            worktrees: [Worktree('/p', 'main')],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton).last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('Didn\'t start: codex: command not found'), findsOneWidget, reason: 'the reason, in the seat\'s row');
    expect(tester.widget<Text>(find.text('Didn\'t start: codex: command not found')).style!.color, Tokens.light.removed);
    expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget, reason: 'only the failed seat has one');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Retry'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(posts, hasLength(1));
    expect(posts.single.$1, '/api/seat/launch/core.qa');
    expect(posts.single.$2, containsPair('fresh', true));
    expect(posts.single.$2.containsKey('stop'), isFalse, reason: 'nothing is running in it to stop');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('closed before the rig is up: a toast says when it is, with Open', (tester) async {
    animateStatusSpinners = false;
    addTearDown(() => animateStatusSpinners = true);
    final store = await installFakes();
    final launched = Completer<void>();
    OpenRigClient.factory = (h) => OpenRigClient(h,
        eventSource: ({rigId, replay, lastEventId}) => const Stream.empty(),
        httpClient: MockClient((req) async {
          Object body = const [];
          if (req.url.path == '/api/up') {
            final b = jsonDecode(req.body) as Map;
            if (b['plan'] == true) {
              body = {'status': 'planned', 'stages': [{'stage': 'resolve_spec', 'status': 'ok'}, {'stage': 'execute_external_installs', 'status': 'skipped'}]};
            } else {
              await launched.future;
              body = {'status': 'completed', 'rigId': 'r1'};
            }
          }
          return http.Response(jsonEncode(body), 200);
        }));
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(AppScope(
      store: store,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showLaunchSheet(context,
                  file: RigSpecFile(path: '/p/rig.yaml', projectPath: '/p'), spec: RigSpecSummary.parse(spec), projectName: 'p'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Installs'), findsOneWidget);
    expect(find.byIcon(Icons.remove_circle_outline), findsOneWidget, reason: 'a skipped stage is a dash mark, not a check');
    expect(find.text('First starts take 2–3 min. You can close this; it keeps starting.'), findsOneWidget);
    await tester.tap(find.text('Start rig'));
    await tester.pump();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(LaunchSheet), findsNothing);

    launched.complete();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('crew is up'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });

  test('LaunchResult names the seats that failed to launch, from the stages\' nodes', () {
    final r = LaunchResult.fromJson({
      'status': 'partial',
      'stages': [
        {
          'stage': 'import_rig',
          'status': 'failed',
          'detail': {
            'nodes': [
              {'logicalId': 'a', 'status': 'launched'},
              {'logicalId': 'b', 'status': 'failed', 'error': 'no tmux'},
              {'logicalId': 'c', 'status': 'failed'},
            ]
          }
        }
      ],
    });
    expect(r.failedSeats, {'b': 'no tmux'}, reason: 'a failed node with an error; a launched one is not listed');
    expect(LaunchResult.fromJson({'status': 'completed'}).failedSeats, isEmpty);
  });
}
