import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/host_store.dart' show isDesktop;
import 'package:pocket_rig/ui/answer_bar.dart';
import 'package:pocket_rig/ui/chat/permission_dock.dart';
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/rig/seat_sheet.dart' show SeatSheetBody;
import 'package:pocket_rig/ui/loose_agent_screen.dart';
import 'package:pocket_rig/ui/kit.dart' show OptionRow;
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() => animateStatusSpinners = false);

  testWidgets('the files pill shows the diff and opens every file; the branch PR stays in the git bar', (tester) async {
    final store = await installFakes();
    await tester.pumpWidget(MaterialApp(
        home: phone(store, ChatScreen(rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'lead'), asChat: true))));
    await _settle(tester);

    expect(find.text('3 files'), findsOneWidget);
    expect(find.text('#42 Retry 409s with backoff'), findsNothing, reason: 'the git bar above already shows it');
    expect(find.text('· PR #42'), findsOneWidget, reason: 'in the git line under the header');

    await tester.tap(find.text('3 files'));
    await _settle(tester);
    expect(find.text('Files changed · 3'), findsOneWidget);
    expect(find.text('router.ts'), findsWidgets);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a loose agent\'s menu is lean: terminal, details, kill; files live in the pills', (tester) async {
    final store = await installFakes();
    final agent = scratchAgent();
    await tester.pumpWidget(MaterialApp(
        home: phone(store, ChatScreen(rigName: 'no rig', seat: agent.toSeat(), loose: agent, rigs: rigsWithSeatsFromFixture(), asChat: true))));
    await _settle(tester);

    await tester.tap(find.byTooltip('Menu'));
    await _settle(tester);
    expect(find.text('Open terminal'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Kill agent…'), findsOneWidget, reason: 'a red button pinned at the bottom');
    expect(find.widgetWithText(OptionRow, 'Kill agent…'), findsNothing);
    expect(find.text('Files changed · 3'), findsNothing, reason: 'the files pill covers them');
    expect(find.textContaining('Artifacts ·'), findsNothing);
    expect(find.textContaining('Pull requests ·'), findsNothing);

    await tester.tap(find.text('Agent details'));
    await _settle(tester);
    expect(find.byType(LooseAgentScreen), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a rig seat\'s ⋯ opens the seat sheet; a loose agent\'s does not', (tester) async {
    final store = await installFakes();
    await tester.pumpWidget(MaterialApp(
        home: phone(store, ChatScreen(rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'lead'), asChat: true))));
    await _settle(tester);
    await tester.tap(find.byTooltip('Menu'));
    await _settle(tester);
    expect(find.byType(SeatSheetBody), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Chat'), findsNothing, reason: 'the chat is already open');
    expect(find.text('Terminal'), findsWidgets);

    final agent = scratchAgent();
    await tester.pumpWidget(MaterialApp(
        home: phone(store, ChatScreen(rigName: 'no rig', seat: agent.toSeat(), loose: agent, rigs: rigsWithSeatsFromFixture(), asChat: true))));
    await _settle(tester);
    await tester.tap(find.byTooltip('Menu'));
    await _settle(tester);
    expect(find.byType(SeatSheetBody), findsNothing);
    expect(find.text('Permissions…'), findsNothing);
    expect(find.text('Compact context…'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a pending permission docks in the composer\'s place with the one answer bar', (tester) async {
    final store = await installFakes();
    // conveyor's lead waits on a permission in the fixture.
    await tester.pumpWidget(MaterialApp(
        home: phone(store, ChatScreen(rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'lead'), asChat: true))));
    await _settle(tester);
    expect(find.byType(PermissionDock), findsOneWidget);
    expect(find.byType(AnswerBar), findsOneWidget);
    for (final t in ['Deny', 'Allow once', 'Deny & tell it instead…']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.byTooltip('Send'), findsNothing, reason: 'the prompt takes the composer\'s place');
    expect(find.text('Waiting for you'), findsOneWidget);
    expect(find.text(permissionKeysHint), findsNothing, reason: 'the keyboard hint is for desktop');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('desktop: the docked permission says ⌘↵ / esc, and Esc denies', (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    await tester.pumpWidget(MaterialApp(
        home: phone(store, ChatScreen(rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'lead'), asChat: true))));
    await _settle(tester);
    expect(find.text(permissionKeysHint), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.textContaining('✕ Denied'), findsOneWidget);
    expect(find.byType(PermissionDock), findsNothing, reason: 'answered: the composer is back');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the subagents pill counts every subagent the session started and lists them', (tester) async {
    final store = await installFakes();
    Map<String, Object?> agent(String id, String what) => {
          'type': 'assistant',
          'uuid': 'sa-$id',
          'message': {
            'id': 'msa-$id',
            'content': [
              {'type': 'tool_use', 'id': id, 'name': 'Agent', 'input': {'description': what, 'subagent_type': 'Explore', 'prompt': '…'}}
            ]
          }
        };
    extraChatLog = [
      agent('s1', 'Map the router'),
      {'type': 'user', 'uuid': 'sr1', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 's1', 'content': 'done'}]}},
      agent('s2', 'Find the 409 tests'),
    ];
    await tester.pumpWidget(MaterialApp(
        home: phone(store, ChatScreen(rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'lead'), asChat: true))));
    await _settle(tester);

    // None runs on the host: marked done, and last in the row.
    expect(find.text('2 subagents done'), findsOneWidget);
    final row = tester.widget<SessionPills>(find.byType(SessionPills));
    expect((row.pills.last as SessionPill).label, '2 subagents done');
    await tester.tap(find.text('2 subagents done'));
    await _settle(tester);
    expect(find.text('Subagents · 2'), findsOneWidget);
    expect(find.widgetWithText(OptionRow, 'Map the router'), findsOneWidget);
    expect(find.widgetWithText(OptionRow, 'Find the 409 tests'), findsOneWidget);
    expect(find.text('Explore · finished'), findsNWidgets(2), reason: 'none runs on the host');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a working agent\'s send button turns into Stop until something is typed', (tester) async {
    final store = await installFakes();
    // conveyor's impl seat is working in the fixture.
    await tester.pumpWidget(MaterialApp(
        home: phone(store, ChatScreen(rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'impl'), asChat: true))));
    await _settle(tester);
    expect(find.byTooltip('Stop'), findsOneWidget);
    expect(find.text('Queue a message for after this turn…'), findsOneWidget);
    expect(find.byTooltip('Send'), findsNothing);

    await tester.enterText(find.byType(TextField).last, 'also check the 412s');
    await tester.pump();
    expect(find.byTooltip('Send'), findsOneWidget, reason: 'typing queues a message instead');
    expect(find.byTooltip('Stop'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
