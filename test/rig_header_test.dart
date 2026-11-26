import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/rig/rig_room.dart' show RigRoomScreen, RemindersScreen;
import 'package:pocket_rig/data/host_store.dart' show isDesktop;
import 'package:pocket_rig/ui/kit.dart' show KillBar, PageHeader;
import 'package:pocket_rig/ui/rig/overview_tab.dart' show RigBody;
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

  testWidgets('phone: New, Message all, Room and Reminders are four tiles under the header line; Room and Reminders open their screens',
      (tester) async {
    await _open(tester, const Size(390, 900));
    expect(find.widgetWithText(FilledButton, 'New'), findsNothing, reason: 'no Mac buttons on a phone');
    final tiles = [for (final a in ['New', 'Message all', 'Room', 'Reminders']) tester.getRect(find.bySemanticsLabel(a))];
    expect({for (final r in tiles) r.top}.length, 1, reason: 'one row');
    expect(tiles.every((r) => r.height >= 44), isTrue, reason: 'finger-sized tiles');
    final icon = find.byWidgetPredicate((w) => w is AppIcon && w.kind == AppIconKind.rig);
    expect(icon, findsOneWidget, reason: 'the rig icon leads the title');
    expect(tester.widget<AppIcon>(icon).color, Tokens.light.accent, reason: 'conveyor has seats that need you: the worst state\'s colour');
    expect(find.descendant(of: find.byType(PageHeader), matching: find.byType(StatusIcon)), findsNothing, reason: 'no state ring on it');

    await tester.tap(find.bySemanticsLabel('Room'));
    await tester.pumpAndSettle();
    expect(find.byType(RigRoomScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Reminders'));
    await tester.pumpAndSettle();
    expect(find.byType(RemindersScreen), findsOneWidget);
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

  testWidgets('on the Mac the rig header has a List | Tiles switch; Tiles shows the tiles, whose own switch brings the page back',
      (tester) async {
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    await _open(tester, const Size(1280, 800));
    final onPage = find.descendant(of: find.byType(RigScreen), matching: find.text('Tiles'));
    expect(onPage, findsOneWidget);
    expect(find.descendant(of: find.byType(RigScreen), matching: find.text('List')), findsOneWidget, reason: 'one switch, List on show');
    expect(find.descendant(of: find.byType(RigScreen), matching: find.text('Chat')), findsNothing, reason: 'Chat is reached per agent');
    expect(find.descendant(of: find.byType(RigScreen), matching: find.text('Rig details')), findsNothing);
    expect(tester.getTopLeft(onPage).dx, greaterThan(tester.getTopLeft(find.widgetWithText(OutlinedButton, 'Reminders')).dx),
        reason: 'right after Reminders');
    await tester.tap(onPage);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(TilesScreen), findsOneWidget);
    expect(find.byType(RigScreen), findsNothing);
    // Each tile's header says how much context its agent has used (the lead 62%); an agent with none known shows nothing.
    final tiles = find.byType(TilesScreen);
    expect(find.descendant(of: tiles, matching: find.text('62%')), findsOneWidget);
    expect(find.descendant(of: tiles, matching: find.text('0%')), findsNothing);
    expect(find.descendant(of: tiles, matching: find.bySemanticsLabel('context 62 percent used')), findsOneWidget);
    expect(find.descendant(of: find.byType(TilesScreen), matching: find.text('Rig details')), findsNothing);
    await tester.tap(find.descendant(of: find.byType(TilesScreen), matching: find.text('List')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(RigScreen), findsOneWidget);
    await _close(tester);
  });

  testWidgets('List | Tiles: each is one click from the other, and they replace each other (Back leaves the rig)',
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
        home: phone(store, RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app', initialTab: 0), width: 1280)));
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

    await go(RigScreen, 'Tiles', TilesScreen);
    await go(TilesScreen, 'List', RigScreen);
    await go(RigScreen, 'Tiles', TilesScreen);
    await go(TilesScreen, 'List', RigScreen);
    expect(depth.routes, before, reason: 'four switches added no route: one Back leaves the rig');
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
