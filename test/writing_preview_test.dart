import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/chat/session_log.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/chat_screen.dart';

import 'golden/fixtures.dart';

String pane(String name) => File('test/fixtures/panes/$name.txt').readAsStringSync();

class _Tail extends FakeTail {
  _Tail(super.host, super.path) {
    last = this;
  }
  static _Tail? last;
  void say(String text) => feed(Uint8List.fromList(utf8.encode('${jsonEncode({
        'type': 'assistant',
        'uuid': 'live-${text.hashCode}',
        'message': {
          'id': 'live-${text.hashCode}',
          'content': [
            {'type': 'text', 'text': text}
          ]
        },
      })}\n')));
}

void main() {
  late String current; // the pane the host returns
  var captures = 0;

  Future<void> open(WidgetTester tester, {bool active = true}) async {
    final store = await installFakes();
    SessionLogTail.factory = _Tail.new;
    captures = 0;
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          if (cmd.contains('capture-pane')) {
            captures++;
            return current;
          }
          return fakeShell(cmd);
        });
    // r-adv/attacker is a Claude agent that is working.
    await tester.pumpWidget(MaterialApp(
      home: phone(store, ChatScreen(rigName: 'adversarial-review', seat: seatFromFixture('r-adv', 'attacker'), asChat: true)),
    ));
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  const written = 'Now the tests: a retry test on the fake client, and one that checks it gives up after three tries instead of looping.';

  testWidgets('the reply being written shows as a writing bubble, then the transcript message replaces it', (tester) async {
    current = pane('mid_reply');
    await open(tester);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('writing…'), findsOneWidget);
    expect(find.textContaining('a retry test on the fake client'), findsOneWidget);
    expect(captures, greaterThan(0));

    // The log gets the finished block while the pane still shows it: one copy on screen, the real one.
    _Tail.last!.say('$written\n\nThe retry waits 200 ms between tries, so the tests use a fake clock.');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('writing…'), findsNothing);
    expect(find.textContaining('a retry test on the fake client'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('writing…'), findsNothing, reason: 'the pane still shows it; the transcript has it');
    await close(tester);
  });

  testWidgets('a finished message with inline code and bold still replaces the preview', (tester) async {
    current = pane('mid_reply'); // the pane shows the rendered text, the log the markdown
    await open(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('writing…'), findsOneWidget);
    _Tail.last!.say('Now the tests: `a retry` test on the **fake client**, and one that checks it gives up after three tries instead of looping.');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('writing…'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('writing…'), findsNothing, reason: 'the pane still shows it');
    await close(tester);
  });

  testWidgets('no preview at an idle prompt, and none after the page is gone', (tester) async {
    current = pane('idle');
    await open(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('writing…'), findsNothing);
    final before = captures;
    expect(before, greaterThan(0), reason: 'it looked');
    current = pane('mid_reply');
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('writing…'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    final gone = captures;
    await tester.pump(const Duration(seconds: 5));
    expect(captures, gone, reason: 'a closed chat does not read the pane');
  });
}
