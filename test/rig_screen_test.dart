import 'package:flutter/material.dart';
import 'dart:ui' show Tristate;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/host_store.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/common.dart' show ErrorBanner;
import 'package:pocket_rig/ui/kit.dart' show AgentRow;
import 'package:pocket_rig/ui/permission_sheet.dart';
import 'package:pocket_rig/ui/rig/rig_chat.dart';
import 'package:pocket_rig/ui/rig/seat_graph.dart';
import 'package:pocket_rig/ui/rig/seat_sheet.dart';
import 'package:pocket_rig/ui/rig/work_queue_screen.dart';
import 'package:pocket_rig/ui/rig_screen.dart';
import 'package:pocket_rig/ui/app_icon.dart';
import 'package:pocket_rig/ui/status_shape.dart';
import 'package:pocket_rig/ui/stop_rig.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

class _Spy extends http.BaseClient {
  _Spy(this.inner, this.log);
  final http.Client inner;
  final List<String> log;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    log.add('${request.method} ${request.url.path}');
    return inner.send(request);
  }
}

void main() {
  setUp(() => animateStatusSpinners = false);

  /// [initialTab] null: the screen's own default (Agents); 1 opens a running rig on its Graph tab.
  Future<HostStore> open(WidgetTester tester, {int? initialTab = 0}) async {
    final store = await installFakes();
    final rig = rigFromFixture('r-conveyor');
    await tester.pumpWidget(MaterialApp(
        home: phone(
            store,
            initialTab == null
                ? RigScreen(rig: rig, projectName: 'app')
                : RigScreen(rig: rig, projectName: 'app', initialTab: initialTab))));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return store;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  Future<void> tab(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(of: find.byWidgetPredicate((w) => w.runtimeType.toString().startsWith('TabStrip<')), matching: find.text(label)));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('after Snapshot from the ⋯ the screen reads its seats again at once, not on the next 5 s poll',
      (tester) async {
    final store = await installFakes();
    final log = <String>[];
    final inner = OpenRigClient.factory;
    OpenRigClient.factory = (h) => OpenRigClient(h, httpClient: _Spy(fakeDaemon(h), log));
    addTearDown(() => OpenRigClient.factory = inner);
    AppScope.resetClients();
    final rig = rigFromFixture('r-conveyor');
    await tester.pumpWidget(MaterialApp(home: phone(store, RigScreen(rig: rig, projectName: 'app', initialTab: 0))));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    int seatReads() => log.where((l) => l == 'GET /api/rigs/r-conveyor/nodes').length;
    final before = seatReads();
    await tester.tap(find.byTooltip('Rig options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Snapshot'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100)); // well under the 5 s poll
    }
    expect(log.where((l) => l.startsWith('POST') && l.endsWith('/snapshots')).length, 1);
    expect(seatReads(), greaterThan(before));
    await close(tester);
  });

  testWidgets('five tabs on a running rig (Agents, Graph, Work, Code, Progress), four on a stopped one (no Graph): Agents lists every seat unfiltered, with Work and Activity under them; Work, Code and Progress hold the rest', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester);
    expect(find.text('conveyor'), findsOneWidget);
    expect(find.textContaining('auto every 15m', findRichText: true), findsNothing, reason: 'the header keeps one short line');
    final tabs = find.byWidgetPredicate((w) => w.runtimeType.toString().startsWith('TabStrip<'));
    for (final t in ['Agents', 'Graph', 'Work 4', 'Code', 'Progress']) {
      expect(find.descendant(of: tabs, matching: find.text(t)), findsOneWidget, reason: t);
    }
    expect(find.text('All 4'), findsNothing, reason: 'no status filter chips');
    // The header's one line: project · host · worktree · agents; the four actions are tiles under it on a phone.
    expect(find.text('4 agents'), findsOneWidget);
    expect(find.text('main'), findsOneWidget, reason: 'the worktree chip: the main checkout');
    for (final a in ['New', 'Message all', 'Room', 'Reminders']) {
      expect(find.bySemanticsLabel(a), findsOneWidget, reason: a);
    }
    expect(find.text('Rig tools'), findsNothing, reason: 'the old tools list is gone: its three are header actions');
    expect(find.text('Shell here'), findsNothing, reason: 'no bottom bar: Shell here and Snapshot are in the ⋯ list');
    expect(find.text('Snapshot'), findsNothing);
    for (final s in ['lead', 'impl  codex', 'review', 'tests  codex']) {
      expect(find.descendant(of: find.byType(AgentRow), matching: find.textContaining(s, findRichText: true)), findsOneWidget, reason: s);
    }

    // Switching tabs doesn't move the header text.
    final title = tester.getTopLeft(find.text('conveyor'));
    // Work is a tab of its own (and the first few items sit under the agents, with the activity).
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('WORK · 4 OPEN'), 200, scrollable: list);
    await tab(tester, 'Work 4');
    expect(tester.getTopLeft(find.text('conveyor')), title, reason: 'the header stays put');
    expect(find.text('lead', findRichText: true), findsNothing, reason: 'the seats are on the Agents tab');
    expect(find.text('WORK · 4 OPEN'), findsOneWidget);
    expect(find.text('Queue & handoffs'), findsOneWidget);
    // Code is another: the snapshot details, the branch and its PR.
    await tab(tester, 'Code');
    expect(find.textContaining('auto every 15m'), findsOneWidget, reason: 'the snapshot details are on Code');
    expect(find.byWidgetPredicate((w) => w is AppIcon && w.kind == AppIconKind.worktree), findsWidgets, reason: 'the branch row uses the worktree glyph, as the chips do');
    final code = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('CODE'), 200, scrollable: code);
    // Git is read over SSH once the seats say where the rig works.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.scrollUntilVisible(find.text('feat/409-retry'), 200, scrollable: code);
    expect(find.text('#42 Retry 409s with backoff'), findsOneWidget);
    // Progress is its own tab.
    await tab(tester, 'Progress');
    expect(tester.getTopLeft(find.text('conveyor')), title, reason: 'the header stays put');
    expect(find.text('Fix the flaky queue-sweep test'), findsOneWidget, reason: 'the slices are on the Progress tab');
    // The checklist's wording for a screen reader tells under way from not started.
    expect(find.bySemanticsLabel(RegExp('Implement it in the router: in progress')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Write the runbook note: to do')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Staging run: blocked')), findsOneWidget);
    // A blocked step is red text, not only a small icon; its parent says how many steps under it are blocked.
    final step = tester.widget<RichText>(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'Staging run'));
    expect(step.text.style?.color, Tokens.light.removed);
    expect(find.textContaining('1 blocked', findRichText: true), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Design the backoff: done')), findsOneWidget);
    await tab(tester, 'Agents');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 1500)); // back to the top: the tab kept its scroll
    await tester.pump();
    expect(find.descendant(of: find.byType(AgentRow), matching: find.textContaining('lead', findRichText: true)), findsOneWidget);
    handle.dispose();
    await close(tester);
  });

  testWidgets('on a stopped rig Message all is off (no seat to type into); New, Room and Reminders stay', (tester) async {
    final store = await installFakes();
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
        home: phone(store, RigScreen(rig: rigFromFixture('r-research'), projectName: 'app', initialTab: 0))));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    bool enabled(String label) => tester.getSemantics(find.bySemanticsLabel(label)).flagsCollection.isEnabled == Tristate.isTrue;
    expect(enabled('Message all'), isFalse);
    expect(enabled('Room'), isTrue);
    expect(enabled('Reminders'), isTrue);
    handle.dispose();
    await close(tester);
  });

  testWidgets('a rig-level error shows once, under the header, on every tab', (tester) async {
    final store = await installFakes();
    await store.select(macbook.id); // offline: the rig's seats can't be read
    await tester.pumpWidget(MaterialApp(
        home: phone(store, RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app', initialTab: 0))));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ErrorBanner), findsOneWidget, reason: 'seats tab');
    final message = tester.widget<ErrorBanner>(find.byType(ErrorBanner)).message;
    // The Progress tab may add its own banner for the slices it couldn't read; the rig's is the same on every tab.
    final banner = find.byWidgetPredicate((w) => w is ErrorBanner && w.message == message);
    final title = tester.getTopLeft(find.text('conveyor'));
    for (final t in ['Work', 'Code', 'Progress', 'Agents']) {
      await tab(tester, t);
      // Progress may add the same message for its own failed read.
      expect(banner, t == 'Progress' ? findsWidgets : findsOneWidget, reason: '$t tab');
      expect(tester.getTopLeft(find.text('conveyor')), title, reason: 'the header stays put on $t');
    }
    await close(tester);
  });

  testWidgets('a row’s ⋯ opens the seat sheet; the header ⋯ has the rig’s options', (tester) async {
    await open(tester);
    // The tab bar took room, so the third row sits low: lift it clear of the bottom bar.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await tester.pump();
    await tester.longPress(find.descendant(of: find.byType(AgentRow), matching: find.textContaining('review', findRichText: true)).first);
    await tester.pumpAndSettle();
    expect(find.byType(SeatSheetBody), findsOneWidget);
    expect(find.text('Reply…'), findsOneWidget, reason: 'review asked a question');
    await tester.tapAt(const Offset(195, 60));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Rig options'));
    await tester.pumpAndSettle();
    for (final o in ['Rename label', 'Edit spec', 'Snapshot', 'Shell here', 'Stop rig…']) {
      expect(find.text(o), findsWidgets, reason: o);
    }
    expect(find.text('Delete rig…'), findsNothing, reason: 'a running rig is stopped first');
    // The page's own Stop bar shows the same words: this is the one in the options sheet.
    await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('Stop rig…')));
    await tester.pumpAndSettle();
    // The stop sheet says what each seat is doing, and snapshots first by default.
    expect(find.text('Stop conveyor?'), findsOneWidget);
    Finder inSheet(String t) =>
        find.descendant(of: find.byType(BottomSheet), matching: find.textContaining(t, findRichText: true));
    for (final note in ['lead is waiting for you', 'review asked a question', 'impl is mid-turn', 'tests is idle']) {
      expect(inSheet(note), findsOneWidget, reason: note);
    }
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isTrue);
    expect(find.text('Snapshot & stop'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await close(tester);
  });

  testWidgets('the Graph tab: a node tap opens the seat like its row, a long press the seat sheet',
      (tester) async {
    await open(tester, initialTab: 1);
    expect(find.byType(SeatGraph), findsOneWidget);
    expect(find.byType(GraphLegend), findsOneWidget);
    // lead runs Claude Code: its row opens the chat, and so does its node. No peek sheet in between.
    await tester.tap(find.byType(SeatNode).first);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.text('Details'), findsNothing);
    await close(tester);

    await open(tester, initialTab: 1);
    await tester.longPress(find.byType(SeatNode).first);
    await tester.pumpAndSettle();
    expect(find.byType(SeatSheetBody), findsOneWidget);
    expect(find.byType(ChatScreen), findsNothing);
    await close(tester);
  });

  testWidgets('Graph is a tab of its own on a running rig and not on a stopped one; Agents has no List | Map toggle', (tester) async {
    await open(tester);
    expect(find.text('Map'), findsNothing, reason: 'the graph is a tab now');
    expect(find.byType(SeatGraph), findsNothing);
    await tab(tester, 'Graph');
    expect(find.byType(SeatGraph), findsOneWidget);
    await close(tester);

    final store = await installFakes();
    await tester.pumpWidget(MaterialApp(
        home: phone(store, RigScreen(rig: rigFromFixture('r-research'), projectName: 'app', initialTab: 1))));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.descendant(of: find.byWidgetPredicate((w) => w.runtimeType.toString().startsWith('TabStrip<')), matching: find.text('Graph')), findsNothing);
    expect(find.byType(SeatGraph), findsNothing, reason: 'a stopped rig opens on Agents');
    await close(tester);
  });

  testWidgets('permissions: only Auto switches live; other modes save for the next start', (tester) async {
    final store = await installFakes();
    // The fake daemon reports Ask for sessions named impl*.
    final seat = Seat(
        rigId: 'r-conveyor',
        logicalId: 'impl2',
        sessionName: 'impl2@conveyor',
        runtime: 'claude-code',
        activity: 'working');
    await tester.pumpWidget(AppScope(
      store: store,
      child: MaterialApp(
        home: Builder(
          builder: (context) =>
              TextButton(onPressed: () => showPermissionSheet(context, seat), child: const Text('open')),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('now'), findsOneWidget, reason: 'beside the current mode');
    expect(find.text('Never asks. Nothing will reach your Inbox.'), findsOneWidget);
    await tester.tap(find.text('Auto'));
    await tester.pump();
    expect(find.text('Switch now'), findsOneWidget);
    expect(find.textContaining('keeps the conversation'), findsOneWidget);
    await tester.tap(find.text('Accept edits'));
    await tester.pump();
    expect(find.text('Switch now'), findsNothing);
    expect(find.text('Save (next start)'), findsOneWidget);
    expect(find.textContaining('Only Auto can be switched in a running session'), findsOneWidget);
    expect(find.text('Relaunch…'), findsOneWidget);
    expect(canSwitchLive(seat, PermissionMode.auto), isTrue);
    expect(canSwitchLive(seat, PermissionMode.plan), isFalse);
    expect(canSwitchLive(Seat(rigId: 'r', logicalId: 'x', sessionName: 'x@r', runtime: 'codex'), PermissionMode.auto),
        isFalse);
  });

  testWidgets('Work: Queue and Handoffs over the same items, with Open/Closed/All', (tester) async {
    final store = await installFakes();
    await tester.pumpWidget(MaterialApp(home: phone(store, WorkScreen(rig: rigFromFixture('r-conveyor')))));
    await tester.pumpAndSettle();
    expect(find.text('Open 4'), findsOneWidget);
    expect(find.text('Closed 0'), findsOneWidget);
    expect(find.byType(QueueRow), findsNWidgets(4));
    // Blocked is the failed shape, in progress the working one.
    final shapes = tester.widgetList<StatusShape>(find.byType(StatusShape)).map((s) => s.status).toSet();
    expect(shapes, containsAll([Status.failed, Status.working, Status.idle]));
    await tester.tap(find.text('Handoffs'));
    await tester.pump();
    expect(find.byType(RigChatMessage), findsNWidgets(4));
    // One strip: the filter is light text on the Queue only, and Handoffs lists every item.
    expect(find.text('Closed 0'), findsNothing);
    await tester.tap(find.text('Queue'));
    await tester.pump();
    expect(find.byWidgetPredicate((w) => w.runtimeType.toString().startsWith('Segmented<')), findsOneWidget, reason: 'one strip');
    await tester.tap(find.text('Closed 0'));
    await tester.pump();
    expect(find.byType(QueueRow), findsNothing);
    expect(find.text('Nothing here yet.'), findsOneWidget);
    expect(find.text('Open 4'), findsOneWidget, reason: 'the filter stays when the list is empty');
    await close(tester);
  });

  test('stop notes say what each seat is in the middle of', () {
    expect(stopNote(seatFromFixture('r-conveyor', 'lead')), 'is waiting for you');
    expect(stopNote(seatFromFixture('r-conveyor', 'review')), 'asked a question');
    expect(stopNote(seatFromFixture('r-conveyor', 'impl')), 'is mid-turn');
    expect(stopNote(seatFromFixture('r-conveyor', 'tests')), 'is idle');
  });
}
