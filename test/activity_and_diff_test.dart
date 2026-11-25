import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/chat/session_log.dart';
import 'package:pocket_rig/data/git_status.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/chat/diff_view.dart';
import 'package:pocket_rig/ui/loose_agent_screen.dart';
import 'package:pocket_rig/ui/stop_rig.dart';
import 'package:pocket_rig/ui/theme.dart';

void main() {
  final now = DateTime(2026, 11, 1, 12);
  int ms(Duration ago) => now.subtract(ago).millisecondsSinceEpoch;

  group('agent status', () {
    test('an idle reminder is idle, not waiting on you', () {
      final a = LooseAgent.fromHook({
        'id': 's',
        'waiting': true,
        'kind': 'idle',
        'message': 'Claude is waiting for your input',
        'at': ms(const Duration(minutes: 4)),
      })!;
      expect(a.waiting, isFalse);
      expect(looseStatus(a, now), 'idle · 4m');
    });

    test('a real prompt still waits, and any other question too', () {
      final p = LooseAgent.fromHook(
          {'id': 's', 'waiting': true, 'kind': 'permission', 'message': 'Claude needs your permission to use Bash'})!;
      expect(p.isPermission, isTrue);
      expect(looseStatus(p, now), 'needs you');
      expect(LooseAgent.fromHook({'id': 's', 'waiting': true, 'kind': 'idle', 'message': 'Pick one'})!.waiting, isTrue);
    });

    test('with an older watcher, a recent hook means working', () {
      LooseAgent at(Duration ago) => LooseAgent.fromHook({'id': 's', 'at': ms(ago)})!;
      expect(looseStatus(at(const Duration(seconds: 10)), now), 'working');
      expect(looseStatus(at(const Duration(minutes: 5)), now), 'idle · 5m');
    });

    test('working stops counting after a long silence', () {
      LooseAgent at(Duration ago) => LooseAgent.fromHook({'id': 's', 'activity': 'working', 'activeAt': ms(ago)})!;
      expect(looseStatus(at(const Duration(minutes: 1)), now), 'working');
      expect(looseStatus(at(const Duration(hours: 2)), now), 'idle · 2h');
    });
  });

  test('deleteRig asks the daemon to delete and reports a refusal', () async {
    Map<String, Object?>? sent;
    OpenRigClient client(Object reply) => OpenRigClient(Host(id: 'h', name: 'h', address: 'h', sshUser: 'u'),
        httpClient: MockClient((req) async {
          sent = jsonDecode(req.body) as Map<String, Object?>;
          return http.Response(jsonEncode(reply), 200);
        }));
    await client({'deleted': true}).deleteRig('r1');
    expect(sent, {'rigId': 'r1', 'delete': true});
    await expectLater(
        client({
          'deleted': false,
          'errors': ['still busy']
        }).deleteRig('r1'),
        throwsA(isA<OpenRigException>()));
  });

  testWidgets('deleting a rig takes two separate confirmations', (tester) async {
    bool? result;
    final rig = Rig(id: 'r', name: 'build', nodeCount: 2, runningCount: 2, attentionCount: 0, status: 'running');
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await confirmDeleteRig(context, rig),
          child: const Text('go'),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(find.text('Delete build for good?'), findsNothing);

    result = null;
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Delete build for good?'), findsOneWidget);
    expect(result, isNull, reason: 'one yes must not be enough');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete rig'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  test('gh pr list output becomes pull requests, skipping junk', () {
    final prs = PullRequest.parseList(
        '[{"number":7,"title":"Fix","state":"MERGED","url":"u","statusCheckRollup":[{"state":"SUCCESS"}]},{"x":1}]');
    expect(prs.map((p) => (p.number, p.state, p.checks)), [(7, 'MERGED', 'passing')]);
    expect(PullRequest.parseList('not json'), isEmpty);
  });

  test('diff lines are told apart, and paths are quoted', () {
    expect(diffLineKind('+++ b/a.dart'), DiffLine.meta);
    expect(diffLineKind('--- a/a.dart'), DiffLine.meta);
    expect(diffLineKind('diff --git a/a b/a'), DiffLine.meta);
    expect(diffLineKind('@@ -1,2 +1,3 @@'), DiffLine.hunk);
    expect(diffLineKind('+new'), DiffLine.added);
    expect(diffLineKind('-old'), DiffLine.removed);
    expect(diffLineKind(' same'), DiffLine.context);
    expect(diffCommand('/w', "it's.txt", untracked: false), contains("--no-ext-diff HEAD -- 'it'\\''s.txt'"));
    expect(diffCommand('/w', 'n.txt', untracked: true), contains('--no-index -- /dev/null'));
  });

  test('the log tail reads over SSH on another isolate and reports failures', () async {
    // No SSH key fails inside the worker, so Host crossing the isolate is covered too.
    final tail = SessionLogTail(Host(id: 'h', name: 'home', address: 'h', sshUser: 'u'), '/x.jsonl');
    final status = <String>[];
    tail.status.listen(status.add);
    await tail.start();
    await Future.doWhile(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return !status.contains('reconnecting…');
    }).timeout(const Duration(seconds: 10));
    expect(status.first, contains('No SSH key saved for home'));
    await tail.close();
  });
}
