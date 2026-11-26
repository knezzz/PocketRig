import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/rig/rig_room.dart' show RigRoomScreen, RemindersScreen;
import 'package:pocket_rig/data/host_store.dart' show isDesktop;
import 'package:pocket_rig/ui/kit.dart' show KillBar, PageHeader;
import 'package:pocket_rig/ui/rig/overview_tab.dart' show RigBody;
import 'package:pocket_rig/ui/chat/rig_chat_pager.dart' show RigChatPager;
import 'package:pocket_rig/ui/chat_screen.dart' show ChatScreen;
import 'package:pocket_rig/ui/rig/rig_host.dart' show RigHost, RigMode;
import 'package:pocket_rig/ui/rig_screen.dart';
import 'package:pocket_rig/ui/tiles_screen.dart' show TilesScreen;
import 'package:pocket_rig/ui/app_icon.dart';
import 'package:pocket_rig/ui/host_color.dart' show contrastRatio;
import 'package:pocket_rig/ui/status_shape.dart';
import 'package:pocket_rig/ui/theme.dart' show Tokens;
import 'package:pocket_rig/ui/theme.dart' show animateStatusSpinners;

import 'golden/fixtures.dart';

Future<void> _open(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final store = await installFakes();
  await tester.pumpWidget(MaterialApp(
      home: phone(store, RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app', initialTab: 0), width: size.width)));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  // The Agents tab's Danger zone, scrolled to the foot of the tab.
  Future<void> toDangerZone(WidgetTester tester) async {
    final list = tester.state<ScrollableState>(find.descendant(of: find.byType(RigBody), matching: find.byType(Scrollable)).first).position;
    for (var i = 0; i < 3; i++) {
      list.jumpTo(list.maxScrollExtent);
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  setUp(() => animateStatusSpinners = false);

  testWidgets('phone: no Mac buttons and no tiles; the ⋯ sheet has New, Message all, Room, Reminders and Rig details above the rig\'s options; Room and Reminders open their screens',
      (tester) async {
    await _open(tester, const Size(390, 900));
    expect(find.widgetWithText(FilledButton, 'New'), findsNothing, reason: 'no Mac buttons on a phone');
    expect(find.bySemanticsLabel('Room'), findsNothing, reason: 'no tiles under the header either');
    await tester.tap(find.byTooltip('Rig options'));
    await tester.pumpAndSettle();
    final y = {for (final t in ['New', 'Message all', 'Room', 'Reminders', 'Rename label']) t: tester.getTopLeft(find.text(t).last).dy};
    expect(y['New']! < y['Message all']! && y['Message all']! < y['Room']! && y['Room']! < y['Reminders']! && y['Reminders']! < y['Rename label']!, isTrue,
        reason: 'the rig actions first, then the rig\'s options');
    expect(find.text('Rig details'), findsNothing, reason: 'this is the rig page');
    await tester.tap(find.text('Room').last);
    await tester.pumpAndSettle();
    expect(find.byType(RigRoomScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Rig options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reminders').last);
    await tester.pumpAndSettle();
    expect(find.byType(RemindersScreen), findsOneWidget);
    await _close(tester);
  });

  testWidgets('the phone rig page header: the rig icon in its worst state\'s colour', (tester) async {
    await _open(tester, const Size(390, 900));
    final icon = find.byWidgetPredicate((w) => w is AppIcon && w.kind == AppIconKind.rig);
    expect(icon, findsOneWidget, reason: 'the rig icon leads the title');
    expect(tester.widget<AppIcon>(icon).color, Tokens.light.accent, reason: 'conveyor has seats that need you: the worst state\'s colour');
    expect(find.descendant(of: find.byType(PageHeader), matching: find.byType(StatusIcon)), findsNothing, reason: 'no state ring on it');
    await _close(tester);
  });

  testWidgets('a wide page has the actions as header buttons, not tiles', (tester) async {
    await _open(tester, const Size(1280, 800));
    for (final a in ['New', 'Message all', 'Room', 'Reminders']) {
      expect(find.widgetWithText(OutlinedButton, a).evaluate().length + find.widgetWithText(FilledButton, a).evaluate().length, 1, reason: a);
    }
    expect(find.widgetWithText(FilledButton, 'New'), findsOneWidget, reason: 'New is the filled one');
    final title = tester.getTopLeft(find.text('conveyor')).dy;
    expect(tester.getTopLeft(find.widgetWithText(FilledButton, 'New')).dy, lessThan(title + 40), reason: 'in the bar, level with the title');
    // The line under the title runs across the page: it is its own row, not squeezed beside the buttons.
    expect(tester.getTopLeft(find.text('4 agents')).dy, greaterThan(title + 20), reason: 'a row under the title');
    // The Danger zone is in the page column, like the header and the content.
    await toDangerZone(tester);
    const column = (1280 - 880) / 2;
    expect(tester.getTopLeft(find.text('Stop rig…')).dx, greaterThanOrEqualTo(column), reason: 'Stop rig… inside the 880 column');
    await _close(tester);
  });

  testWidgets('on the Mac the rig page has Rig details (selected) and no Tiles button, no List | Tiles', (tester) async {
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    await _open(tester, const Size(1280, 800));
    expect(find.text('List'), findsNothing);
    expect(find.text('Tiles'), findsNothing, reason: 'Rig details toggles; there is no Tiles button');
    final details = find.descendant(of: find.byType(RigScreen), matching: find.widgetWithText(OutlinedButton, 'Rig details'));
    expect(details, findsOneWidget);
    expect(tester.getTopLeft(details).dx, greaterThan(tester.getTopLeft(find.widgetWithText(OutlinedButton, 'Reminders')).dx),
        reason: 'right after Reminders');
    await _close(tester);
  });

  testWidgets('the same row on the page, the tiles and the chat; Rig details toggles page and tiles, and from the chat opens the page (one route throughout)',
      (tester) async {
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = await installFakes();
    final depth = _Depth();
    await tester.pumpWidget(MaterialApp(
        navigatorObservers: [depth],
        home: phone(store, RigHost(rig: rigFromFixture('r-conveyor'), projectName: 'app', initial: RigMode.rig), width: 1280)));
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await settle();
    final before = depth.routes;
    Finder on(Type t) => find.byType(t);
    Future<void> go(Type from, String label, Type to) async {
      expect(on(from), findsOneWidget);
      await tester.tap(find.descendant(of: on(from), matching: find.text(label)));
      await settle();
      expect(on(to), findsOneWidget, reason: label);
      expect(on(from), findsNothing, reason: 'replaced, not stacked');
    }

    // The same fixed row on every rig view: the same six controls, in this order, the same widths.
    List<double> row() {
      final xs = <double>[];
      final widths = <double>[];
      for (final label in ['New', 'Message all', 'Room', 'Reminders', 'Rig details']) {
        final f = find.widgetWithText(OutlinedButton, label).evaluate().isNotEmpty
            ? find.widgetWithText(OutlinedButton, label)
            : find.widgetWithText(FilledButton, label);
        expect(f, findsOneWidget, reason: label);
        xs.add(tester.getTopLeft(f).dx);
        widths.add(tester.getSize(f).width);
      }
      expect(find.byTooltip('Rig options'), findsOneWidget);
      xs.add(tester.getTopLeft(find.byTooltip('Rig options')).dx);
      expect([...xs]..sort(), xs, reason: 'left to right in that order');
      return widths;
    }

    final onPage = row();
    await tester.tap(find.descendant(of: find.byType(RigScreen), matching: find.text('Rig details')));
    await settle();
    expect(find.byType(TilesScreen), findsOneWidget);
    expect(row(), onPage, reason: 'the tiles have the same row');
    await tester.tap(find.descendant(of: find.byType(TilesScreen), matching: find.text('Rig details')));
    await settle();
    expect(find.byType(RigScreen), findsOneWidget);
    // The rig's chat (an agent opened from it takes its place here).
    final lead = seatFromFixture('r-conveyor', 'lead');
    Navigator.of(tester.element(find.byType(RigScreen))).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => ChatScreen(rigName: 'conveyor', seat: lead, asChat: true)));
    await settle();
    expect(row(), onPage, reason: 'the chat has the same row');
    await go(RigChatPager, 'Rig details', RigScreen); // from the chat: the rig's page, in a host
    expect(depth.routes, before, reason: 'the switches added no route: one Back leaves the rig');
    await _close(tester);
  });

  testWidgets('no Tiles button on a phone', (tester) async {
    await _open(tester, const Size(390, 900));
    expect(find.text('Tiles'), findsNothing);
    await _close(tester);
  });

  testWidgets('on a wide page the Agents tab has Work and Activity in a right column; on a phone they are under the agents',
      (tester) async {
    await _open(tester, const Size(1280, 900));
    final agents = tester.getTopLeft(find.text('AGENTS · 4'));
    final work = tester.getTopLeft(find.text('WORK · 4 OPEN'));
    expect(work.dx, greaterThan(agents.dx + 400), reason: 'beside the agents');
    expect(work.dy, lessThan(agents.dy + 60), reason: 'level with them');
    await _close(tester);

    await _open(tester, const Size(390, 1800));
    expect(tester.getTopLeft(find.text('WORK · 4 OPEN')).dy, greaterThan(tester.getTopLeft(find.text('AGENTS · 4')).dy + 100), reason: 'under them');
    await _close(tester);
  });

  testWidgets('the Danger zone\'s Stop is outlined (red text and hairline) and its red passes 4.5:1 on the light and the dark ground',
      (tester) async {
    for (final dark in [false, true]) {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = await installFakes();
      await tester.pumpWidget(MaterialApp(
          home: phone(store, RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app'), dark: dark)));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await toDangerZone(tester);
      final stop = find.widgetWithText(OutlinedButton, 'Stop rig…');
      expect(stop, findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Stop rig…'), findsNothing, reason: 'the filled red is for the confirm dialog');
      final red = tester.widget<OutlinedButton>(stop).style!.foregroundColor!.resolve({})!;
      final ground = (dark ? Tokens.dark : Tokens.light).ground;
      expect(contrastRatio(red, ground), greaterThanOrEqualTo(4.5), reason: dark ? 'dark' : 'light');
      await _close(tester);
    }
  });

  testWidgets('the Agents tab scrolls to its last line: the Danger zone ends on screen, on a wide page and on a phone', (tester) async {
    for (final size in [const Size(1280, 700), const Size(390, 700)]) {
      await _open(tester, size);
      await toDangerZone(tester);
      final stop = tester.getRect(find.widgetWithText(OutlinedButton, 'Stop rig…'));
      expect(stop.bottom, lessThanOrEqualTo(size.height), reason: 'Stop rig… is reachable at ${size.width}');
      expect(find.byType(KillBar), findsNothing, reason: 'no pinned bar on a running rig');
      await _close(tester);
    }
  });
}

/// The number of routes on the navigator: a push adds one, a replace none.
class _Depth extends NavigatorObserver {
  int routes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => routes++;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => routes--;
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => routes--;
}
