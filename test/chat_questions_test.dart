import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/chat/transcript.dart';
import 'package:pocket_rig/terminal/transport.dart' show TypedAnswer, tmuxPressCommand;
import 'package:pocket_rig/ui/chat/question_card.dart';
import 'package:pocket_rig/ui/inbox/question_carousel.dart';
import 'package:pocket_rig/ui/kit.dart' show Panel;

ToolCall ask(List<Map<String, Object?>> questions) =>
    ToolCall('k', DateTime(2026), id: 't', name: 'AskUserQuestion', input: {'questions': questions});

Map<String, Object?> q(String text, {bool multi = false, List<String> options = const ['A', 'B', 'C']}) => {
      'question': text,
      'header': text,
      'multiSelect': multi,
      'options': [for (final o in options) {'label': o, 'description': 'about $o'}],
    };

String line(String uuid, List<Map<String, Object?>> content, {String role = 'assistant'}) => jsonEncode({
      'type': role,
      'uuid': uuid,
      'message': {'id': 'm$uuid', 'role': role, 'content': content},
    });

void main() {
  group('questionKeys (as checked against Claude Code 2.1)', () {
    test('one single-select question submits on its digit', () {
      expect(questionKeys(AskQuestion.from(ask([q('Size')]))!, [{2}]), ['3']);
    });
    test('one multi-select question: toggles, Tab, then 1 on the review page', () {
      expect(questionKeys(AskQuestion.from(ask([q('Tools', multi: true)]))!, [{1}]), ['2', 'Tab', '1']);
    });
    test('two questions: digit, toggles in order, Tab, then submit', () {
      final qs = AskQuestion.from(ask([q('Color'), q('Pets', multi: true)]))!;
      expect(questionKeys(qs, [{1}, {2, 0}]), ['2', '1', '3', 'Tab', '1']);
    });
  });

  test('AskQuestion.from reads the logged input and ignores other tools', () {
    final qs = AskQuestion.from(ask([q('Pets', multi: true)]))!;
    expect((qs.single.question, qs.single.multi, qs.single.options.first), ('Pets', true, ('A', 'about A')));
    expect(AskQuestion.from(ToolCall('k', DateTime(2026), id: 't', name: 'Bash', input: {})), isNull);
    expect(AskQuestion.from(ask([])), isNull);
  });

  test('transcript lists changed files, published artifacts and opened PRs', () {
    final t = ChatTranscript()
      ..addAll([
        line('1', [
          {'type': 'tool_use', 'id': 'e', 'name': 'Edit', 'input': {'file_path': '/w/a.dart', 'old_string': 'a', 'new_string': 'b\nc'}},
          {'type': 'tool_use', 'id': 'p', 'name': 'Artifact', 'input': {'file_path': '/s/report.html'}},
          {'type': 'tool_use', 'id': 'g', 'name': 'Bash', 'input': {'command': 'gh pr create --fill'}},
          {'type': 'tool_use', 'id': 'v', 'name': 'Bash', 'input': {'command': 'gh pr view 9'}},
        ]),
        line('2', [
          {'type': 'tool_result', 'tool_use_id': 'e', 'content': 'ok'},
          {'type': 'tool_result', 'tool_use_id': 'p', 'content': 'Published https://claude.ai/artifact/AbC123 (private)'},
          {'type': 'tool_result', 'tool_use_id': 'g', 'content': 'https://github.com/o/r/pull/12\n'},
          {'type': 'tool_result', 'tool_use_id': 'v', 'content': 'https://github.com/o/r/pull/9'},
        ], role: 'user'),
      ]);
    expect(t.changedFiles.keys, ['/w/a.dart']);
    expect(t.changedFiles['/w/a.dart'], isNotNull);
    expect(t.publishedArtifacts, [('report.html', Uri.parse('https://claude.ai/artifact/AbC123'))]);
    expect(t.openedPrs, [Uri.parse('https://github.com/o/r/pull/12')]);
  });

  test('an answer in words picks "Type something", then types it', () {
    final qs = AskQuestion.from(ask([q('Color'), q('Pets', multi: true)]))!;
    expect(questionSteps(qs, [<int>{}, {1}], ['teal', null]), ['4', const TypedAnswer('teal'), '2', 'Tab', '1']);
    expect(questionSteps(qs, [{0}, {1}], [null, null]), questionKeys(qs, [{0}, {1}]));
  });

  testWidgets('QuestionCard sizes to its content, even in a slot with a fixed height', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 800,
          child: QuestionCard(
            seatName: 'lead',
            questions: AskQuestion.from(ask([q('Color')]))!,
            onSend: (_, __) {},
            onDecline: () {},
          ),
        ),
      ),
    ));
    expect(tester.getSize(find.byType(Panel)).height, lessThan(500), reason: 'the card, not its slot');
  });

  testWidgets('QuestionCard sends once however fast Send is tapped (a second tap before the screen reacts is ignored)', (tester) async {
    var sends = 0;
    final inFlight = Completer<void>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: QuestionCard(
            seatName: 'lead',
            questions: AskQuestion.from(ask([q('Color')]))!,
            onSend: (p, o) {
              sends++;
              return inFlight.future; // the answer is on its way
            },
            onDecline: () {},
          ),
        ),
      ),
    ));
    await tester.tap(find.text('A'));
    await tester.pump();
    await tester.tap(find.text('Send answer'));
    await tester.tap(find.text('Send answer')); // the card has not been replaced yet
    await tester.pump();
    expect(sends, 1);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send answer')).onPressed, isNull, reason: 'off while it is on its way');
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Decline')).onPressed, isNull);
    inFlight.complete();
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send answer')).onPressed, isNotNull, reason: 'a failed answer can be tried again');
  });

  testWidgets('QuestionCard shows one question at a time and sends once each has an answer', (tester) async {
    List<Set<int>>? sent;
    List<String?>? words;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: QuestionCard(
            seatName: 'lead',
            questions: AskQuestion.from(ask([q('Color'), q('Pets', multi: true, options: ['Cat', 'Dog'])]))!,
            onSend: (p, o) {
              sent = p;
              words = o;
            },
            onDecline: () {},
          ),
        ),
      ),
    ));
    expect(find.textContaining('1 OF 2'), findsOneWidget);
    expect(find.text('Cat'), findsNothing, reason: 'the second question waits its turn');
    expect(find.text('Decline all'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Next question')).onPressed, isNull,
        reason: 'nothing picked yet');
    // One pattern with the Inbox: Decline on the left, the primary action on the right and twice as wide.
    final decline = tester.getRect(find.widgetWithText(OutlinedButton, 'Decline all'));
    final next = tester.getRect(find.widgetWithText(FilledButton, 'Next question'));
    expect(decline.right, lessThan(next.left));
    expect(decline.height, next.height, reason: 'Decline all is one line');
    expect(next.width, closeTo(decline.width * 2, 8));
    await tester.tap(find.text('B'));
    await tester.tap(find.text('A')); // single select: replaces B
    await tester.pump();
    await tester.tap(find.text('Next question'));
    await tester.pump();
    expect(find.textContaining('2 OF 2'), findsOneWidget);
    expect(find.text('Other'), findsNothing, reason: 'words only answer a single-select question here: the menu\'s Type-something row');
    await tester.tap(find.text('Cat'));
    await tester.tap(find.text('Dog'));
    await tester.pump();
    await tester.tap(find.text('Send answers'));
    expect(sent, [{0}, {0, 1}]);
    expect(words, [null, null]);

    // Back to the first with ‹, and answer it in words instead.
    await tester.tap(find.text('‹'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'teal');
    await tester.pump();
    await tester.tap(find.text('›'));
    await tester.pump();
    await tester.tap(find.text('Send answers'));
    expect(sent, [<int>{}, {0, 1}]);
    expect(words, ['teal', null]);
  });

  test('an answer in words is typed into the pane and submitted, not delivered as a message', () {
    final qs = AskQuestion.from(ask([q('Color')]))!;
    final cmd = tmuxPressCommand('dev@rig', questionSteps(qs, [<int>{}], ["it's teal"]));
    expect(cmd, startsWith("tmux send-keys -t '=dev@rig:' '4' && sleep 0.3 && "));
    expect(cmd, contains("send-keys -t '=dev@rig:' -l -- 'it'\\''s teal' && "));
    expect(cmd, endsWith("send-keys -t '=dev@rig:' Enter"));
  });

  test('an answer starting with a dash is not read as a tmux flag, and a newline becomes a space', () {
    final qs = AskQuestion.from(ask([q('Color')]))!;
    expect(tmuxPressCommand('s', questionSteps(qs, [<int>{}], ['-foo'])), contains("-l -- '-foo' && "));
    expect(questionSteps(qs, [<int>{}], ['a\n  b\n']), ['4', const TypedAnswer('a b')]);
  });

  testWidgets('one question UI: the Inbox takes words on a pick-any question, the chat does not; both send once', (tester) async {
    Future<(List<Set<int>>, List<String?>)?> run({required bool inbox}) async {
      (List<Set<int>>, List<String?>)? got;
      var sends = 0;
      final done = Completer<void>();
      final qs = AskQuestion.from(ask([q('Tools', multi: true, options: ['A', 'B'])]))!;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: inbox
                ? QuestionCarousel(seatName: 'lead', questions: qs, onDecline: () {}, onSend: (p, o) {
                    sends++;
                    got = (p, o);
                    return done.future;
                  })
                : QuestionCard(seatName: 'lead', questions: qs, onDecline: () {}, onSend: (p, o) {
                    sends++;
                    got = (p, o);
                    return done.future;
                  }),
          ),
        ),
      ));
      await tester.tap(find.text('A'));
      await tester.pump();
      if (inbox) {
        await tester.enterText(find.byType(TextField), 'and C');
        await tester.pump();
      } else {
        expect(find.byType(TextField), findsNothing, reason: 'the menu has no Type-something row for a pick-any question');
      }
      await tester.tap(find.text('Send answer'));
      await tester.tap(find.text('Send answer'));
      await tester.pump();
      expect(sends, 1, reason: inbox ? 'the Inbox card' : 'the chat card');
      return got;
    }

    final inboxGot = (await run(inbox: true))!;
    expect(inboxGot.$1, [{0}]);
    expect(inboxGot.$2, ['and C']);
    final chatGot = (await run(inbox: false))!;
    expect(chatGot.$1, [{0}]);
    expect(chatGot.$2, [null]);
  });
}
