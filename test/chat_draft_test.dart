import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/drafts.dart';
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

void main() {
  setUp(() => animateStatusSpinners = false);

  testWidgets(
      'an unsent message is kept per agent: back again, after a restart; send clears it; another agent is empty',
      (tester) async {
    final store = await installFakes();
    final dir = Directory.systemTemp.createTempSync('drafts');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/drafts.json');
    drafts = Drafts(file: file);
    addTearDown(() => drafts = Drafts());

    Future<void> open(String seat) async {
      await tester.pumpWidget(MaterialApp(
          home: phone(
              store,
              ChatScreen(
                  key: UniqueKey(),
                  rigName: 'conveyor',
                  seat: seatFromFixture('r-conveyor', seat),
                  asChat: true))));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    String boxText() =>
        tester.widget<TextField>(find.byType(TextField).last).controller!.text;

    await open('impl');
    await tester.enterText(find.byType(TextField).last, 'half a thought');
    await tester.pump();

    await open('tests');
    expect(boxText(), '', reason: "another agent's box doesn't show it");

    await open('impl');
    expect(boxText(), 'half a thought', reason: 'left and came back');

    drafts = Drafts(file: file)..load(); // the app restarted
    await open('impl');
    expect(boxText(), 'half a thought', reason: 'after a restart');

    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    expect(boxText(), '');
    drafts = Drafts(file: file)..load();
    await open('impl');
    expect(boxText(), '', reason: 'sending cleared it');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 20));
  });
}
