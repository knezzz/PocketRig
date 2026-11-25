import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/loose_agents.dart';
import 'package:pocket_rig/ui/answer_bar.dart';

void main() {
  testWidgets('Deny, Always and Allow once are three equal buttons in one row, 48 tall on touch; Always says what it covers under them',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 358,
                child: AnswerBar(onAllow: () {}, onDeny: () {}, onAlways: () {}, alwaysScope: 'npm run test:integration')))));
    final deny = tester.getRect(find.widgetWithText(OutlinedButton, 'Deny'));
    final always = tester.getRect(find.widgetWithText(OutlinedButton, 'Always'));
    final allow = tester.getRect(find.widgetWithText(FilledButton, 'Allow once'));
    expect(deny.left, lessThan(always.left), reason: 'the same order on every screen');
    expect(always.left, lessThan(allow.left));
    expect(deny.top, allow.top);
    expect(always.top, allow.top, reason: 'one row');
    expect(deny.width, closeTo(allow.width, 1), reason: 'equal');
    expect(always.width, closeTo(allow.width, 1), reason: 'equal');
    expect(allow.height, 48);
    final scope = find.text('Always allows “npm run test:integration”');
    expect(scope, findsOneWidget, reason: 'the whole pattern, not cut');
    expect(tester.getRect(scope).top, greaterThan(allow.bottom), reason: 'under the buttons');
  });

  test('a hook entry with no time (0) has no last-active time, not 1970', () {
    final a = parseHookFile(jsonEncode([
      {'id': 's', 'cwd': '/w', 'tmux': 't', 'waiting': false, 'at': 0},
    ])).single;
    expect(a.lastActivityAt, isNull);
  });
}
