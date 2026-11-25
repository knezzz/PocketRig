import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/needs_you.dart' show answerSettle;
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/chat/permission_dock.dart';
import 'package:pocket_rig/ui/chat_screen.dart';

import 'golden/fixtures.dart';

/// lead asks a permission; Allow once presses keys over SSH, and [keysResult] is what the host says back.
Future<int> _allow(WidgetTester tester, {required String keysResult, String button = 'Allow once', Completer<void>? gate}) async {
  final store = await installFakes();
  var presses = 0;
  final shell = SshExec.debugConnect!;
  SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
        if (cmd.contains('send-keys')) {
          presses++;
          // A slow answer: the test lets real time pass before the connection gives up (DateTime.now isn't faked by pump).
          if (gate != null) await gate.future;
          return keysResult;
        }
        return (await shell(h)).run(cmd);
      });
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
                      'needsInput': {'count': 1, 'reason': 'Bash: npm run test:integration'}
                    }
                  },
                Map() => {for (final e in j.entries) e.key: edit(e.value)},
                _ => j,
              };
          return http.Response(jsonEncode(edit(jsonDecode(res.body))), 200);
        }));
  };
  await tester.pumpWidget(MaterialApp(
      home: phone(store, ChatScreen(key: UniqueKey(), rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'lead'), asChat: true))));
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(find.byType(PermissionDock), findsOneWidget);
  await tester.tap(find.text(button));
  await tester.pump(const Duration(milliseconds: 600));
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return presses;
}

void main() {
  testWidgets('an answer that may have arrived keeps the card resolved: a second tap cannot press the keys again', (tester) async {
    // The session check passed (READY) but the confirmation never came back: the connection dropped mid-answer.
    final presses = await _allow(tester, keysResult: 'POCKETRIG_READY\n');
    expect(presses, 1);
    expect(find.textContaining('May have arrived: check the terminal'), findsOneWidget);
    expect(find.byType(PermissionDock), findsNothing, reason: 'no second Allow to tap');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a plain failure (nothing was typed) brings the card back to try again', (tester) async {
    final presses = await _allow(tester, keysResult: "can't find session: lead@conveyor\n(sessions here: a )");
    expect(presses, 1);
    expect(find.textContaining('May have arrived'), findsNothing);
    expect(find.byType(PermissionDock), findsOneWidget, reason: 'it can be answered again');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the settle clock of an unconfirmed answer runs from when the connection gave up, not from the tap', (tester) async {
    // The drop takes longer than the settle time: counted from the tap, the first poll would see the same ask as settled.
    final gate = Completer<void>();
    await _allow(tester, keysResult: 'POCKETRIG_READY\n', gate: gate);
    await tester.runAsync(() => Future<void>.delayed(answerSettle + const Duration(milliseconds: 500)));
    gate.complete(); // the connection gives up now
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 100)); // past the 1.5 s poll
    }
    expect(find.textContaining('May have arrived: check the terminal'), findsOneWidget);
    expect(find.byType(PermissionDock), findsNothing, reason: 'still waiting for the poll to say, not settled by the slow drop');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Deny & tell it instead: after a Deny that may not have landed, the note is not offered or sent', (tester) async {
    await _allow(tester, keysResult: 'POCKETRIG_READY\n', button: 'Deny & tell it instead…');
    expect(find.text('Tell lead what to do instead'), findsNothing, reason: 'the Deny was not confirmed');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Deny & tell it instead: a confirmed Deny offers the note', (tester) async {
    await _allow(tester, keysResult: 'POCKETRIG_READY\nPOCKETRIG_SENT\n', button: 'Deny & tell it instead…');
    expect(find.text('Tell lead what to do instead'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
