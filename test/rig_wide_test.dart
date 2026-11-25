import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/models.dart' show QueueItem;
import 'package:pocket_rig/terminal/transport.dart' show debugOpenTerminal;
import 'package:pocket_rig/ui/chat/diff_view.dart' show DiffScreen;
import 'package:pocket_rig/ui/common.dart' show DeltaText;
import 'package:pocket_rig/ui/chat_screen.dart' show ChatScreen;
import 'package:pocket_rig/ui/terminal_screen.dart' show TerminalScreen;
import 'package:pocket_rig/ui/rig/rig_chat.dart' show HandoffDetail, RigChatMessage;
import 'package:pocket_rig/ui/rig/seats_tab.dart' show SeatList;
import 'package:pocket_rig/ui/rig/work_queue_screen.dart' show QueueRow, WorkScreen;
import 'package:pocket_rig/ui/kit.dart' show PageHeader, Panel;
import 'package:pocket_rig/ui/rig_screen.dart';

import 'golden/fixtures.dart';

void main() {
  Future<void> open(WidgetTester tester, Size size, {String name = 'conveyor'}) async {
    final store = await installFakes();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await fleet.feedFor(homelab).refresh();
    final rig = fleet.feedFor(homelab).rigs.map((r) => r.rig).firstWhere((r) => r.name == name);
    await tester.pumpWidget(MaterialApp(home: phone(store, RigScreen(rig: rig, projectName: 'app'))));
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  for (final width in [1280.0, 1600.0]) {
    testWidgets('Agents at $width wide: the list (520-760) beside a 360 side column, the Danger zone under the list', (tester) async {
      await open(tester, Size(width, 900));
      final list = tester.getRect(find.byType(SeatList));
      final work = tester.getRect(find.textContaining('WORK ·'));
      final activity = tester.getRect(find.text('ACTIVITY'));
      expect(list.width, inInclusiveRange(520, 760));
      expect(work.left, greaterThan(list.right), reason: 'Work is beside the list, not under it');
      expect(activity.left, work.left, reason: 'one side column');
      expect(list.left, 20, reason: 'the body padding, not a centred column');
      // The side column is 360 wide: its cards start at the gutter after the list and end 360 later.
      final panel = tester.getRect(find.ancestor(of: find.text('ACTIVITY'), matching: find.byType(Column)).first);
      expect(panel.width, 360);
      expect(panel.left, closeTo(list.right + 24, 1.5), reason: 'a 24 gutter');
      final danger = tester.getRect(find.text('Danger zone'));
      expect(danger.top, greaterThan(list.bottom - 1), reason: 'the Danger zone is under the list');
      expect(danger.left, lessThan(list.right), reason: 'in the list\'s column');
      await close(tester);
    });
  }

  testWidgets('below 1000 the Agents tab keeps today\'s layout: a 300 side column, no wide gutter', (tester) async {
    await open(tester, const Size(900, 900));
    final work = tester.getRect(find.textContaining('WORK ·'));
    final activity = tester.getRect(find.text('ACTIVITY'));
    expect(activity.left, work.left);
    final panel = tester.getRect(find.ancestor(of: find.text('ACTIVITY'), matching: find.byType(Column)).first);
    expect(panel.width, 300);
    await close(tester);
  });

  for (final width in [1280.0, 1600.0]) {
    testWidgets('Work at $width wide: the queue list (420-480) beside the chosen item\'s card (at most 640), the first chosen on load', (tester) async {
      await open(tester, Size(width, 900));
      await tester.tap(find.descendant(of: find.byType(RigScreen), matching: find.textContaining('Work')).first);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      final first = find.text('Integration suite on staging'); // the most recently updated
      expect(first, findsWidgets);
      final detail = find.byType(HandoffDetail);
      expect(detail, findsOneWidget, reason: 'the card is beside the list');
      expect(tester.widget<HandoffDetail>(detail).item.summary, 'Integration suite on staging', reason: 'the first item is chosen on load');
      final list = tester.getRect(find.byType(QueueRow).first);
      final card = tester.getRect(detail);
      expect(card.left, greaterThan(list.right), reason: 'side by side');
      expect(list.width, inInclusiveRange(420, 480), reason: 'the list is about 420 wide');
      expect(card.width, lessThanOrEqualTo(640));
      // Choosing another item shows its card, with no sheet.
      await tester.tap(find.text('Router retry diff'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.widget<HandoffDetail>(find.byType(HandoffDetail)).item.summary, 'Router retry diff');
      expect(find.byType(BottomSheet), findsNothing);
      await close(tester);
    });
  }

  testWidgets('the Work detail has Open <seat>: the destination seat, the chat for Claude and the terminal otherwise; the sheet has none', (tester) async {
    debugOpenTerminal = (h, t) async => FakeTerminal('ssh', lines: const ['hello']);
    addTearDown(() => debugOpenTerminal = null);
    await open(tester, const Size(1280, 900));
    await tester.tap(find.descendant(of: find.byType(RigScreen), matching: find.textContaining('Work')).first);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    // The first item goes to lead (Claude Code): its chat.
    expect(tester.widget<HandoffDetail>(find.byType(HandoffDetail)).item.destinationSession, 'lead@conveyor');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Open lead'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(tester.widget<ChatScreen>(find.byType(ChatScreen)).seat.logicalId, 'lead');
    await tester.pageBack();
    await tester.pumpAndSettle();
    // An item to impl (Codex): its terminal.
    await tester.tap(find.text('Slice 3 — retry 409s'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Open impl'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(TerminalScreen), findsOneWidget);
    await close(tester);
  });

  testWidgets('a HandoffDetail without a seat to open (the sheet) has no Open button', (tester) async {
    final item = QueueItem.fromJson(queue.first);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: HandoffDetail(item: item))));
    await tester.pump();
    expect(find.textContaining('Open '), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Handoffs wide is the same split: messages at the left, the chosen one\'s card beside them', (tester) async {
    await open(tester, const Size(1280, 900));
    await tester.tap(find.descendant(of: find.byType(RigScreen), matching: find.textContaining('Work')).first);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Handoffs'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(RigChatMessage), findsWidgets);
    final detail = find.byType(HandoffDetail);
    expect(detail, findsOneWidget);
    expect(tester.getRect(detail).left, greaterThan(tester.getRect(find.byType(RigChatMessage).first).right));
    await close(tester);
  });

  testWidgets('the Work page at 1280: a full-width header, a labelled + Add to queue, the list beside the card, whose history reads', (tester) async {
    final store = await installFakes();
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await fleet.feedFor(homelab).refresh();
    final rig = fleet.feedFor(homelab).rigs.map((r) => r.rig).firstWhere((r) => r.name == 'conveyor');
    await tester.pumpWidget(MaterialApp(home: phone(store, WorkScreen(rig: rig))));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(tester.getSize(find.byType(PageHeader)).width, 1280);
    expect(find.text('+ Add to queue'), findsOneWidget);
    expect(find.byTooltip('Add to queue'), findsNothing, reason: 'a labelled button, not an icon');
    expect(tester.getRect(find.byType(HandoffDetail)).left, greaterThan(tester.getRect(find.byType(QueueRow).first).right));
    expect(find.textContaining('staging is down', findRichText: true), findsOneWidget, reason: 'the demo daemon answers the history the card reads');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Work wide with nothing queued says Nothing open in the middle', (tester) async {
    await open(tester, const Size(1280, 900), name: 'research-team');
    await tester.tap(find.descendant(of: find.byType(RigScreen), matching: find.textContaining('Work')).first);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Nothing open'), findsOneWidget);
    expect(find.byType(HandoffDetail), findsNothing);
    await close(tester);
  });

  testWidgets('Work below 1000 is today\'s single column: a tap opens the sheet', (tester) async {
    await open(tester, const Size(900, 900));
    await tester.tap(find.descendant(of: find.byType(RigScreen), matching: find.textContaining('Work')).first);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(HandoffDetail), findsNothing);
    await tester.tap(find.text('Router retry diff'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  for (final width in [1280.0, 1600.0]) {
    testWidgets('Code at $width wide: 360 of branch, PR and changed files, the chosen file\'s diff beside it, the first chosen on load', (tester) async {
      await open(tester, Size(width, 900));
      await tester.tap(find.descendant(of: find.byType(RigScreen), matching: find.text('Code')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.textContaining('CHANGED FILES · 3 +42 −6'), findsOneWidget, reason: 'the label shows the total');
      final diff = find.byType(DiffScreen);
      expect(diff, findsOneWidget);
      expect(tester.widget<DiffScreen>(diff).path, 'src/rig/router.ts', reason: 'the first changed file is chosen');
      expect(tester.widget<DiffScreen>(diff).embedded, isTrue);
      final pane = tester.getRect(diff);
      expect(pane.left, greaterThanOrEqualTo(360), reason: 'the diff starts after the 360 list');
      expect(pane.width, greaterThan(width - 360 - 40), reason: 'the diff takes the rest');
      expect(find.textContaining('sleep(2 ** n', findRichText: true), findsWidgets, reason: 'the diff pane shows the file\'s diff');
      expect(tester.getRect(diff).right, width - 20, reason: 'the diff pane ends at the same 20 padding as the other tabs');
      // The same list as the phone's and the worktree page's (ChangesCard): the repo path, the delta in colour.
      expect(find.text('test/router.test.ts'), findsOneWidget, reason: 'the repo path, not the basename');
      expect(find.byType(DeltaText), findsWidgets);
      await tester.tap(find.text('test/router.test.ts'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<DiffScreen>(find.byType(DiffScreen)).path, 'test/router.test.ts');
      expect(find.byType(DiffScreen), findsOneWidget, reason: 'chosen in the pane, nothing pushed');
      await close(tester);
    });
  }

  testWidgets('Code below 1000 keeps today\'s single column (no diff pane)', (tester) async {
    await open(tester, const Size(900, 900));
    await tester.tap(find.descendant(of: find.byType(RigScreen), matching: find.text('Code')));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(DiffScreen), findsNothing);
    expect(find.textContaining('CHANGED FILES'), findsNothing);
    await close(tester);
  });

  for (final width in [1280.0, 1600.0]) {
    testWidgets('Progress at $width wide: slices and checklists (560-720) beside a 360 column of the rig\'s messages', (tester) async {
      await open(tester, Size(width, 900));
      await tester.tap(find.descendant(of: find.byType(RigScreen), matching: find.text('Progress')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      final slices = tester.getRect(find.textContaining('SLICES ·'));
      final messages = tester.getRect(find.textContaining('MESSAGES'));
      expect(messages.left, greaterThan(slices.right), reason: 'messages are beside the slices, not under them');
      expect(slices.left, 20, reason: 'the body padding');
      final slice = tester.getRect(find.byType(Panel).first);
      expect(slice.width, inInclusiveRange(560, 720));
      expect(find.widgetWithText(OutlinedButton, 'Handoffs between seats'), findsOneWidget);
      expect(tester.getRect(find.widgetWithText(OutlinedButton, 'Handoffs between seats')).width, 360);
      await close(tester);
    });
  }

  testWidgets('Progress below 1000 keeps today\'s single column', (tester) async {
    await open(tester, const Size(900, 900));
    await tester.tap(find.descendant(of: find.byType(RigScreen), matching: find.text('Progress')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final slices = tester.getRect(find.textContaining('SLICES ·'));
    final messages = tester.getRect(find.textContaining('MESSAGES'));
    expect(messages.top, greaterThan(slices.top), reason: 'under the slices');
    expect(messages.left, slices.left);
    await close(tester);
  });

  testWidgets('the Progress gutter is 20 narrow and wide, as the other tabs\'', (tester) async {
    for (final w in [900.0, 1280.0]) {
      await open(tester, Size(w, 900));
      await tester.tap(find.descendant(of: find.byType(RigScreen), matching: find.text('Progress')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      final slices = tester.getRect(find.textContaining('SLICES ·'));
      expect(slices.left - tester.getRect(find.byType(RigScreen)).left, greaterThanOrEqualTo(20), reason: 'at $w');
      final list = tester.widgetList<ListView>(find.descendant(of: find.byType(RigScreen), matching: find.byType(ListView))).where((l) => l.padding != null && (l.padding! as EdgeInsets).bottom == 28);
      expect(list, isNotEmpty, reason: 'the Progress list at $w');
      expect(list.map((l) => (l.padding! as EdgeInsets).left), everyElement(20), reason: 'at $w');
      await close(tester);
    }
  });
}
