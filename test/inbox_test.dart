import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/chat/question_card.dart';
import 'package:pocket_rig/ui/inbox/answering.dart';
import 'package:pocket_rig/ui/inbox/question_carousel.dart';
import 'package:pocket_rig/ui/recent_screen.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

void main() {
  testWidgets('the Inbox answers in place: the command, its context and the answer bar on each card', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    final store = await installFakes();
    await tester.pumpWidget(MaterialApp(home: phone(store, const RecentScreen(visible: false))));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final n = RegExp(r'NEEDS YOU · (\d+)').firstMatch(tester.widget<Text>(find.textContaining('NEEDS YOU ·')).data!)!.group(1);
    expect(find.text('Inbox $n'), findsOneWidget, reason: 'the header counts what the list counts');
    // conveyor's lead wants to run a command: the command, then Deny · Always "npm run" · Allow once.
    expect(find.textContaining('wants to run a command', findRichText: true), findsOneWidget);
    expect(find.text('npm run test:integration'), findsOneWidget);
    expect(find.text('Always'), findsOneWidget);
    expect(find.text('Always allows “npm run”'), findsOneWidget, reason: 'what Always covers, under the buttons');
    expect(find.text('Allow once'), findsWidgets);
    expect(find.text('Deny & tell it instead…'), findsWidgets);
    expect(find.text('Open in chat ›'), findsWidgets);
    expect(find.text('Terminal'), findsWidgets);
    // The card's underlined links are 48dp to tap on a phone, as the other links' are (compactAction; one had a 28dp box).
    for (final label in ['Open in chat ›', 'Terminal']) {
      final button = find.ancestor(of: find.text(label).first, matching: find.byType(TextButton)).first;
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48), reason: label);
    }
    // Its context has its own bar under the answer, not a line of text.
    expect(find.text('CONTEXT'), findsOneWidget);
    expect(find.text('62%'), findsOneWidget);
    // The old hidden mode picker is gone.
    expect(find.text('Seat permissions'), findsNothing);
    // Working agents are in the sidebar, not the Inbox.
    expect(find.textContaining('WORKING NOW'), findsNothing);
    semantics.dispose();

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('several questions go one at a time and are sent together', (tester) async {
    List<Set<int>>? sent;
    List<String?>? typed;
    final qs = [
      const AskQuestion('Squash the fixups?', 'Commits', false, [('Squash', 'One clean commit'), ('Keep them', null)]),
      const AskQuestion('Which base?', 'Branch', false, [('main', null), ('release', null)]),
    ];
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.dark, Brightness.dark),
      home: Scaffold(
        body: SingleChildScrollView(
          child: QuestionCarousel(
            seatName: 'reviewer',
            questions: qs,
            onSend: (p, o) => (sent, typed) = (p, o),
            onDecline: () {},
          ),
        ),
      ),
    ));
    expect(find.text('1 OF 2 · COMMITS'), findsOneWidget);
    expect(find.text('Decline all'), findsOneWidget);
    final next = find.widgetWithText(FilledButton, 'Next question');
    expect(tester.widget<FilledButton>(next).onPressed, isNull, reason: 'nothing picked yet');
    expect(tester.getSize(find.widgetWithText(OutlinedButton, 'Decline all')).height, tester.getSize(next).height,
        reason: 'Decline all is one line, as tall as Next, not a squeezed column');
    await tester.tap(find.text('Squash'));
    await tester.pump();
    await tester.tap(next);
    await tester.pump();
    expect(find.text('2 OF 2 · BRANCH'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'rebase on develop');
    await tester.pump();
    await tester.tap(find.text('Send answers'));
    expect(sent, [
      {0},
      <int>{},
    ]);
    expect(typed, [null, 'rebase on develop']);
  });

  test('a pending ask reads the waiting call, its questions and the task in progress from the log', () {
    final lines = [
      '{"type":"assistant","uuid":"a1","timestamp":"2026-11-09T10:00:00Z","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"TodoWrite","input":{"todos":[{"content":"Add rate limiting to /login","status":"in_progress","activeForm":"Adding"}]}}]}}',
      '{"type":"user","uuid":"u1","timestamp":"2026-11-09T10:00:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}',
      '{"type":"assistant","uuid":"a2","timestamp":"2026-11-09T10:00:02Z","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"npm run test -- --watch=false","description":"Run the unit suite once"}}]}}',
    ];
    final p = PendingAsk.fromLines(lines)!;
    expect(p.command, 'npm run test -- --watch=false');
    expect(p.why, 'Run the unit suite once');
    expect(p.task, 'Add rate limiting to /login');
    expect(p.questions, isNull);
  });
}
