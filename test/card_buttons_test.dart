import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/answer_bar.dart';
import 'package:pocket_rig/ui/chat/permission_dock.dart';
import 'package:pocket_rig/ui/chat/question_card.dart';
import 'package:pocket_rig/ui/chat/session_pills.dart' show chatGutter;
import 'package:pocket_rig/ui/permission_card.dart';

import 'chat_questions_test.dart' show ask, q;
import 'package:pocket_rig/models.dart' show AskQuestion;

Future<void> pumpIn(WidgetTester tester, double width, Widget child) async {
  tester.view.physicalSize = Size(width + 40, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.topLeft, child: SizedBox(width: width, child: child)))));
}

void main() {
  Widget bar() => AnswerBar(onAllow: () {}, onDeny: () {}, onAlways: () {});

  testWidgets('permission buttons keep their size on a wide card: Deny and Always at the left, Allow once at the right edge', (tester) async {
    await pumpIn(tester, 900, bar());
    final deny = tester.getRect(find.widgetWithText(OutlinedButton, 'Deny'));
    final always = tester.getRect(find.widgetWithText(OutlinedButton, 'Always'));
    final allow = tester.getRect(find.widgetWithText(FilledButton, 'Allow once'));
    expect([deny.width, always.width, allow.width], [140, 140, 160]);
    expect(deny.left, 0);
    expect(always.left, 148);
    expect(allow.right, 900, reason: 'Allow once hugs the right edge');
  });

  testWidgets('on a phone-width card the three buttons still share the width', (tester) async {
    await pumpIn(tester, 360, bar());
    final deny = tester.getRect(find.widgetWithText(OutlinedButton, 'Deny'));
    final allow = tester.getRect(find.widgetWithText(FilledButton, 'Allow once'));
    expect(deny.width, greaterThan(100));
    expect(allow.right, 360);
    expect(deny.left, 0);
  });

  testWidgets('a question card\'s buttons keep their size on a wide card: Decline at the left, Send at the right edge', (tester) async {
    await pumpIn(tester, 900, QuestionCard(seatName: 'lead', questions: AskQuestion.from(ask([q('Color')]))!, onSend: (_, __) {}, onDecline: () {}));
    final decline = tester.getRect(find.widgetWithText(OutlinedButton, 'Decline'));
    final send = tester.getRect(find.widgetWithText(FilledButton, 'Send answer'));
    expect(decline.width, 140);
    expect(send.width, 160);
    expect(send.right, lessThanOrEqualTo(900 - 12), reason: 'inside the card\'s padding');
    expect(send.right, greaterThan(900 - 14), reason: 'at its right edge');
  });

  testWidgets('the permission card above the composer starts at the transcript\'s own inset', (tester) async {
    await pumpIn(
        tester,
        900,
        PermissionDock(
            who: 'lead', ask: PermissionAsk(tool: 'Bash', detail: 'ls'), question: 'Allow?', onAllow: () {}, onDeny: () {}, desktop: false));
    final card = tester.getRect(find.descendant(of: find.byType(PermissionCard), matching: find.byType(DecoratedBox)).first);
    expect(card.left, chatGutter);
    expect(card.right, 900 - chatGutter);
  });
}
