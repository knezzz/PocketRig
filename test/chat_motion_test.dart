import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/chat/session_log.dart';
import 'package:pocket_rig/chat/transcript.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/chat/message_views.dart';
import 'package:pocket_rig/ui/chat/question_card.dart';
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

/// What the next chat's tail replays.
List<String> replay = const [];

class _ReplayTail extends SessionLogTail {
  _ReplayTail(super.host, super.path);
  @override
  Future<void> start() async {
    reportStatus('live');
    feed(Uint8List.fromList(utf8.encode('${replay.join('\n')}\n')));
  }
}

String _line(String uuid, String type, Object content, {DateTime? at}) => jsonEncode({
      'type': type,
      'uuid': uuid,
      'timestamp': (at ?? DateTime.utc(2026, 1, 1)).toIso8601String(),
      'message': {'id': 'm$uuid', 'content': content},
    });

String _call(String uuid, String id, String name, Map<String, Object?> input, {DateTime? at}) =>
    _line(uuid, 'assistant', [
      {'type': 'tool_use', 'id': id, 'name': name, 'input': input}
    ], at: at);

final _question = {
  'questions': [
    {
      'question': 'Which word should the app use?',
      'header': 'Croatian',
      'multiSelect': false,
      'options': [
        {'label': 'kukica', 'description': 'Change all 45 lines'},
        {'label': 'Keep kuka', 'description': 'No change'},
      ],
    }
  ]
};

Seat _seat({bool needs = false, String? activity}) => Seat(
    rigId: 'r-conveyor',
    logicalId: 'lead',
    sessionName: 'conveyor-lead',
    runtime: 'claude-code',
    needsInput: needs,
    activity: activity);

Future<void> _open(WidgetTester tester, Seat seat) async {
  final store = await installFakes();
  SessionLogTail.factory = _ReplayTail.new;
  await tester.pumpWidget(MaterialApp(home: phone(store, ChatScreen(rigName: 'conveyor', seat: seat, asChat: true))));
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  setUp(() => animateStatusSpinners = false);

  testWidgets('an unanswered question in the log is shown even when the seat state lags', (tester) async {
    replay = [
      _line('u1', 'user', 'Which word?'),
      _call('a1', 't1', 'AskUserQuestion', _question),
    ];
    // Tall enough for the question card (the Inbox's carousel look) and the call row above it.
    tester.view.physicalSize = const Size(800, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _open(tester, _seat()); // the daemon hasn't flagged needs-input yet
    expect(find.byType(QuestionCard), findsOneWidget);
    expect(find.text('kukica'), findsOneWidget);
    expect(find.text('ASK'), findsOneWidget, reason: 'the call row reads ASK, not a wrapped tool name');
    await _close(tester);
  });

  testWidgets('a long chat opens at the bottom: the pending question is on screen without scrolling', (tester) async {
    replay = [
      for (var i = 0; i < 40; i++) _line('u$i', 'user', 'Message $i, long enough to take up a line or two of the chat'),
      _call('a1', 't1', 'AskUserQuestion', _question),
    ];
    await _open(tester, _seat(needs: true));
    // Inside the chat list's viewport, not merely built off screen.
    for (final t in ['Which word should the app use?', 'kukica']) {
      final text = find.descendant(of: find.byType(QuestionCard), matching: find.text(t));
      final viewport = tester.getRect(find.ancestor(of: text, matching: find.byType(Scrollable)).first);
      expect(viewport.contains(tester.getCenter(text)), isTrue, reason: '$t at ${tester.getCenter(text)} in $viewport');
    }
    await _close(tester);
  });

  testWidgets('a working seat shows what it is doing; only new rows make an entrance', (tester) async {
    final now = DateTime.now().toUtc();
    replay = [
      _line('u1', 'user', 'Run the suite'),
      _line('a1', 'assistant', [
        {'type': 'text', 'text': 'Running it now.'}
      ], at: now),
      _call('a2', 't1', 'Bash', {'command': 'npm test', 'description': 'npm test'}, at: now),
    ];
    await _open(tester, _seat(activity: 'working'));
    expect(find.text('Running npm test…'), findsOneWidget);
    final appears = tester.widgetList<Appear>(find.byType(Appear)).toList();
    expect(appears.where((a) => a.animate), isNotEmpty, reason: 'the reply from just now eases in');
    final old = tester.widget<Appear>(find.ancestor(of: find.text('Run the suite'), matching: find.byType(Appear)));
    expect(old.animate, isFalse, reason: 'old history is simply there');
    await _close(tester);
  });

  test('tool rows and the working line read short labels', () {
    ToolCall call(String name, Map<String, Object?> input) => ToolCall('k', null, id: 'k', name: name, input: input);
    expect(call('AskUserQuestion', _question).verb, 'ASK');
    expect(call('AskUserQuestion', _question).target, 'Which word should the app use?');
    expect(call('mcp__github__create_issue', const {}).verb, 'CREATE_ISSUE');
    expect(activityLabel(null), 'Thinking');
    expect(activityLabel(call('Read', {'file_path': '/w/src/router.ts'})), 'Reading router.ts');
    expect(activityLabel(call('Bash', {'description': 'npm test'})), 'Running npm test');
  });

  test('a batch decoded elsewhere builds the same chat', () {
    final lines = [_line('u1', 'user', 'hi'), 'not json', '', _call('a1', 't1', 'Read', {'file_path': '/a'})];
    final a = ChatTranscript()..addAll(lines);
    final b = ChatTranscript();
    decodeLogLines(lines).forEach(b.addDecoded);
    expect(b.items.map((i) => i.key), a.items.map((i) => i.key));
    expect(b.items.length, 2);
  });
}
