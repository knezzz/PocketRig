import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/chat/session_log.dart';
import 'package:pocket_rig/data/needs_you.dart' show answerSettle;
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/chat/permission_dock.dart';
import 'package:pocket_rig/ui/chat_screen.dart';

import 'golden/fixtures.dart';

/// An agent with parallel tool calls asks one permission after another: the daemon keeps saying the seat
/// waits, with the next ask's reason, once the first is answered.
class _Tail extends FakeTail {
  _Tail(super.host, super.path) {
    last = this;
  }
  static _Tail? last;

  /// The result of call [id] reaches the log.
  void finish(String id) => feed(Uint8List.fromList(utf8.encode('${jsonEncode({
        'type': 'user',
        'uuid': 'res-$id',
        'message': {
          'content': [
            {'type': 'tool_result', 'tool_use_id': id, 'content': 'ok'}
          ]
        },
      })}\n')));
}

Finder inDock(String text) => find.descendant(of: find.byType(PermissionDock), matching: find.textContaining(text));

void main() {
  var sends = 0;
  Duration pressTime = Duration.zero;

  Future<void> run(WidgetTester tester,
      {required String? nextReason, String? firstReason, bool finishFirst = false, bool pressing = false}) async {
    final store = await installFakes();
    SessionLogTail.factory = _Tail.new;
    sends = 0;
    final shell = SshExec.debugConnect!;
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          if (cmd.contains('send-keys')) {
            sends++;
            await Future<void>.delayed(pressTime);
            return 'POCKETRIG_SENT';
          }
          return (await shell(h)).run(cmd);
        });
    // Two parallel calls, both waiting for their permission: the log shows both at once.
    extraChatLog = [
      {
        'type': 'assistant',
        'uuid': 'a8',
        'message': {
          'id': 'm4',
          'content': [
            {'type': 'tool_use', 'id': 't6', 'name': 'Bash', 'input': {'command': 'npm run test:integration'}},
            {'type': 'tool_use', 'id': 't7', 'name': 'Edit', 'input': {'file_path': 'lib/second.dart', 'old_string': 'a', 'new_string': 'b'}},
          ]
        },
      }
    ];
    var reason = firstReason ?? 'Bash: npm run test:integration';
    OpenRigClient.factory = (h) {
      final inner = fakeDaemon(h);
      return OpenRigClient(h,
          eventSource: ({rigId, replay, lastEventId}) => const Stream.empty(),
          httpClient: MockClient((req) async {
            final res = await inner.get(req.url);
            if (!req.url.path.endsWith('/nodes')) return res;
            Object? edit(Object? j) => switch (j) {
                  List() => [for (final e in j) edit(e)],
                  Map() when j['logicalId'] == 'lead' => {
                      ...j,
                      'activityState': {
                        ...(j['activityState'] as Map),
                        'needsInput': {'count': 1, 'reason': reason}
                      }
                    },
                  Map() => {for (final e in j.entries) e.key: edit(e.value)},
                  _ => j,
                };
            return http.Response(jsonEncode(edit(jsonDecode(res.body))), 200);
          }));
    };
    await tester.pumpWidget(MaterialApp(
        home: phone(store, ChatScreen(rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'lead'), asChat: true))));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(PermissionDock), findsOneWidget);
    expect(inDock('npm run test:integration'), findsWidgets, reason: 'the dock describes the oldest pending call');
    expect(inDock('second.dart'), findsNothing, reason: 'the newer call is not the one being asked');

    await tester.tap(find.text('Allow once'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(PermissionDock), findsNothing, reason: 'answered: the old prompt is gone and not answerable twice');

    if (finishFirst) {
      // The log says the first call is done; the next poll is still a second away.
      await tester.pump(const Duration(milliseconds: 300)); // the keys are down
      reason = nextReason!;
      _Tail.last!.finish('t6');
      await tester.pump(const Duration(milliseconds: 300));
      return;
    }
    await tester.pump(const Duration(seconds: 1));
    expect(sends, 1, reason: 'the answer went through');
    if (pressing) {
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return;
    }
    // The agent asks the next permission.
    if (nextReason != null) {
      reason = nextReason;
    } else {
      // Same words: only time tells (DateTime.now isn't faked by pump). Let the keys finish first.
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.runAsync(() => Future<void>.delayed(answerSettle + const Duration(milliseconds: 300)));
    }
    for (var i = 0; i < 70; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('answering one permission shows the next one without leaving the chat', (tester) async {
    await run(tester, nextReason: 'Edit: lib/second.dart');
    expect(find.byType(PermissionDock), findsOneWidget, reason: 'the second ask');
    expect(inDock('second.dart'), findsWidgets, reason: 'it describes the second call');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 12));
  });

  testWidgets('the old menu is not offered again while its call is unfinished in the log, however long the daemon lags',
      (tester) async {
    await run(tester, nextReason: null);
    expect(find.byType(PermissionDock), findsNothing, reason: 'same ask, call t6 still unfinished: it is the old menu');
    expect(sends, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 12));
  });

  testWidgets('a bare reason code like permission_prompt still shows the oldest call, single or parallel', (tester) async {
    await run(tester, nextReason: 'permission_prompt', firstReason: 'permission_prompt');
    expect(find.byType(PermissionDock), findsOneWidget, reason: 'a changed reason is the next ask');
    expect(inDock('Wants to use a tool'), findsNothing, reason: 'the log describes it, not the generic words');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 12));
  });

  testWidgets('the log showing the first call done brings up the second ask at once', (tester) async {
    await run(tester, nextReason: 'Edit: lib/second.dart', finishFirst: true);
    expect(inDock('second.dart'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 12));
  });

  testWidgets('while the first press is still going, the old ask stays hidden and nothing else is pressed', (tester) async {
    pressTime = const Duration(seconds: 6); // longer than the settle time
    addTearDown(() => pressTime = Duration.zero);
    await run(tester, nextReason: null, pressing: true);
    expect(find.byType(PermissionDock), findsNothing, reason: 'the old ask is not offered again mid-press');
    expect(sends, 1);
    await tester.pump(const Duration(seconds: 8));
    expect(sends, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 12));
  });
}
