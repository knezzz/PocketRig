import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/host_store.dart' show isDesktop;
import 'package:pocket_rig/data/projects.dart' show groupByWorktree;
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/agent_header.dart' show AgentHeader;
import 'package:pocket_rig/ui/desktop_shell.dart' show panelShows;
import 'package:pocket_rig/ui/chat_screen.dart' show ChatScreen;
import 'package:pocket_rig/ui/terminal_screen.dart' show TerminalScreen;
import 'package:pocket_rig/ui/rig/rig_host.dart' show RigHost;
import 'package:pocket_rig/ui/rig_screen.dart' show RigScreen;
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/terminal/transport.dart';
import 'package:pocket_rig/ui/agent_panels.dart' show AgentPanelDock, AgentPanelsToggle;
import 'package:pocket_rig/ui/status_shape.dart';
import 'package:pocket_rig/ui/theme.dart' show Tokens, animateStatusSpinners;
import 'package:pocket_rig/ui/tiles_screen.dart';
import 'package:xterm/xterm.dart';

import 'golden/fixtures.dart';

void main() {
  setUp(() => animateStatusSpinners = false);

  testWidgets('a rig with a seat in the main checkout and one with no folder opens its tiles with every seat at once (not after a poll)', (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    debugOpenTerminal = (h, t) async => _Recording(<String>[]);
    final rig = rigFromFixture('r-conveyor');
    const repo = '/w/app';
    final cwds = {'lead': '$repo/.claude/worktrees/x', 'impl': '$repo/.claude/worktrees/x/lib', 'review': repo, 'tests': null};
    final seats = [
      for (final n in nodes['r-conveyor']!.take(4)) Seat.fromJson({...n, 'cwd': cwds[n['logicalId']], 'sessionStatus': 'running'})
    ];
    // The rig as the sidebar and the Rigs home hand it to the tiles: through the grouping, which used to cut it per place.
    final groups = groupByWorktree(Project(path: repo, rigs: [RigWithSeats(rig, seats)]));
    expect(groups, hasLength(1), reason: 'one place');
    final given = groups.single.rigs.single;
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: phone(store, TilesScreen(rig: given.rig, seats: given.seats, projectName: 'app'))));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(TerminalView), findsNWidgets(4), reason: 'all four seats on first open, before the seats poll');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a tile scrolled back into tmux\'s history shows Back to live, and it returns to the live output (as the single terminal does)', (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    debugOpenTerminal = (h, t) async => FakeTerminal('view');
    final ran = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          ran.add(cmd);
          return cmd.contains('pane_in_mode') ? '1' : '';
        });
    addTearDown(() => SshExec.debugConnect = null);
    final rig = rigFromFixture('r-conveyor');
    final seats = [for (final n in nodes['r-conveyor']!) Seat.fromJson(n)];
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: phone(store, TilesScreen(rig: rig, seats: seats, projectName: 'app'))));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Back to live'), findsNothing);
    await tester.dragFrom(tester.getCenter(find.byType(TerminalView).first), const Offset(0, 200));
    await tester.pump(const Duration(milliseconds: 300));
    expect(ran.where((c) => c.contains('scroll-up')), isNotEmpty, reason: 'a drag down shows older lines');
    expect(find.text('Back to live'), findsOneWidget, reason: 'only the scrolled tile has it');
    ran.clear();
    await tester.tap(find.text('Back to live'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(ran.where((c) => c.contains('cancel')), isNotEmpty, reason: 'leaves copy mode');
    expect(find.text('Back to live'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Rig details toggles the rig page and the tiles in one screen: the tiles stay alive while the page shows, no reconnect, one client per seat; an agent opened from the page enlarges its tile',
      (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    var opened = 0;
    debugOpenTerminal = (h, t) async {
      opened++;
      return FakeTerminal('view');
    };
    final rig = rigFromFixture('r-conveyor');
    final seats = [for (final n in nodes['r-conveyor']!) Seat.fromJson(n)];
    final n = seats.where((s) => s.isAgent && s.state != SeatState.stopped).length;
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final routes = _Depth();
    await tester.pumpWidget(MaterialApp(
        navigatorObservers: [routes],
        home: phone(store, RigHost(rig: rig, seats: seats, projectName: 'app'), width: 1400, height: 900)));
    await tester.pump(const Duration(milliseconds: 200));
    final before = routes.count;
    expect(find.byType(TerminalView), findsNWidgets(n));
    expect(opened, n);
    final tilesState = tester.state(find.byType(TilesScreen));
    final detailsButton = find.descendant(of: find.byType(TilesScreen), matching: find.text('Rig details'));

    Color? ink(Finder f) => tester.widget<OutlinedButton>(find.descendant(of: f, matching: find.widgetWithText(OutlinedButton, 'Rig details'))).style?.foregroundColor?.resolve({});
    final accent = Tokens.light.accent;
    expect(ink(find.byType(TilesScreen)), isNot(accent), reason: 'on the tiles Rig details looks normal');
    await tester.tap(detailsButton);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(RigScreen), findsOneWidget, reason: 'Rig details shows the page');
    expect(ink(find.byType(RigScreen)), accent, reason: 'while the page shows it is selected');
    expect(find.text('Tiles'), findsNothing, reason: 'no Tiles button: Rig details toggles');
    expect(find.byType(TilesScreen), findsNothing, reason: 'the tiles are hidden');
    expect(find.byType(TilesScreen, skipOffstage: false), findsOneWidget, reason: 'but still mounted');
    expect(opened, n, reason: 'no new connection while the page shows');

    await tester.tap(find.descendant(of: find.byType(RigScreen), matching: find.text('Rig details')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(TilesScreen), findsOneWidget);
    expect(find.byType(RigScreen), findsNothing);
    expect(tester.state(find.byType(TilesScreen)), same(tilesState), reason: 'the same tiles, not rebuilt');
    expect(find.byType(TerminalView), findsNWidgets(n));
    expect(opened, n, reason: 'back on the tiles: no reconnect, one client per seat');
    expect(routes.count, before, reason: 'two screens, one route: Back leaves the rig from either');

    // An agent opened from the page: the tile's client is the only one (it enlarges).
    await tester.tap(find.descendant(of: find.byType(TilesScreen), matching: find.text('Rig details')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tilesEnlarge('r-conveyor', 'lead'), isTrue, reason: 'the host takes it even while the page shows');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(TilesScreen), findsOneWidget, reason: 'the tiles come up');
    expect(find.byType(RigScreen), findsNothing);
    expect(opened, n, reason: 'enlarging used the tile\'s own client');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an enlarged tile gets the agent row under the rig row (name left; Chat | Terminal, panels toggle, ⋯ right), not a second page header; a rig chat\'s Terminal enlarges the live tile instead of opening a second client',
      (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    var opened = 0;
    debugOpenTerminal = (h, t) async {
      opened++;
      return FakeTerminal('view');
    };
    final rig = rigFromFixture('r-conveyor');
    final seats = [for (final n in nodes['r-conveyor']!) Seat.fromJson(n)];
    final n = seats.where((s) => s.isAgent && s.state != SeatState.stopped).length;
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: phone(store, RigHost(rig: rig, seats: seats, projectName: 'app'), width: 1400, height: 900)));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(AgentHeader), findsNothing, reason: 'no agent row while the grid shows');
    final lead = seatFromFixture('r-conveyor', 'lead');
    tester.state<NavigatorState>(find.byType(Navigator).last).push(
        MaterialPageRoute<void>(builder: (_) => ChatScreen(rigName: 'conveyor', seat: lead, asChat: true)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ChatScreen), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AgentHeader), matching: find.text('Terminal')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ChatScreen), findsNothing, reason: 'the chat went; the tile is the terminal');
    expect(find.byType(TerminalScreen), findsNothing, reason: 'no second terminal screen');
    expect(opened, n, reason: 'no second client for that agent');

    final row = find.byType(AgentHeader);
    expect(row, findsOneWidget, reason: 'the enlarged tile\'s agent row');
    expect(find.descendant(of: row, matching: find.text('lead')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.byTooltip('Back')), findsNothing, reason: 'the rig row above has the Back');
    final rig0 = tester.getRect(find.byTooltip('Rig options'));
    final agentMenu = tester.getRect(find.byTooltip('Actions for lead'));
    expect(agentMenu.right, lessThanOrEqualTo(rig0.right), reason: 'the agent ⋯ at the right edge, with the rig ⋯ above');
    expect(tester.getRect(find.descendant(of: row, matching: find.text('lead'))).left, lessThan(300), reason: 'the name at the left');
    expect(tester.getRect(find.text('Terminal')).left, greaterThan(tester.getRect(find.descendant(of: row, matching: find.text('lead'))).right),
        reason: 'the switch, toggle and ⋯ on the right');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('tiles > the enlarged tile\'s Chat > the chat\'s Rig details goes back to the one host on its page: one host, one client per seat, and the hidden tiles leave the sidebar alone',
      (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    var opened = 0;
    debugOpenTerminal = (h, t) async {
      opened++;
      return FakeTerminal('view');
    };
    final rig = rigFromFixture('r-conveyor');
    final seats = [for (final n in nodes['r-conveyor']!) Seat.fromJson(n)];
    final n = seats.where((s) => s.isAgent && s.state != SeatState.stopped).length;
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: phone(store, RigHost(rig: rig, seats: seats, projectName: 'app'), width: 1400, height: 900)));
    await tester.pump(const Duration(milliseconds: 200));
    expect(opened, n);
    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
    }

    tilesEnlarge('r-conveyor', 'lead');
    await settle();
    await tester.tap(find.descendant(of: find.byType(AgentHeader), matching: find.text('Chat')));
    await settle();
    expect(find.byType(ChatScreen), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(ChatScreen), matching: find.text('Rig details')));
    await settle();
    expect(find.byType(ChatScreen), findsNothing, reason: 'back to the host');
    expect(find.byType(RigHost, skipOffstage: false), findsOneWidget, reason: 'not a second host');
    expect(find.byType(RigScreen), findsOneWidget, reason: 'on its page');
    expect(find.byType(TilesScreen, skipOffstage: false), findsOneWidget);
    expect(opened, n, reason: 'one client per seat');

    // The hidden tiles do not touch the sidebar's selection: it stays on the rig page, poll after poll.
    final shown = panelShows.value;
    await tester.pump(const Duration(seconds: 12));
    expect(panelShows.value, shown, reason: 'the hidden enlarged tile did not take the selection back');
    await tester.tap(find.descendant(of: find.byType(RigScreen), matching: find.text('Rig details')));
    await settle();
    expect(find.byType(TilesScreen), findsOneWidget);
    expect(opened, n, reason: 'still one client per seat after the whole round trip');

    // A chat over the host with another page between: Terminal still enlarges the tile, with nothing opened.
    tester.state<NavigatorState>(find.byType(Navigator).last).push(
        MaterialPageRoute<void>(builder: (_) => ChatScreen(rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'lead'), asChat: true)));
    await settle();
    await tester.tap(find.descendant(of: find.byType(AgentHeader), matching: find.text('Terminal')));
    await settle();
    expect(find.byType(TerminalScreen), findsNothing);
    expect(opened, n);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('desktop: a tile per running agent; a double click enlarges one, another shrinks it back', (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    final resizes = <String>[];
    var opened = 0;
    debugOpenTerminal = (h, t) async {
      opened++;
      return _Recording(resizes);
    };
    final rig = rigFromFixture('r-conveyor');
    final seats = [for (final n in nodes['r-conveyor']!) Seat.fromJson(n)];
    final n = seats.where((s) => s.isAgent && s.state != SeatState.stopped).length;
    expect(n, greaterThan(1));
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: phone(store, TilesScreen(rig: rig, seats: seats, projectName: 'app'))));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(TerminalView), findsNWidgets(n));
    expect(resizes, hasLength(n), reason: 'each tile reflows its agent\'s window to the tile');
    final sizes = [for (final v in tester.widgetList<TerminalView>(find.byType(TerminalView))) v.textStyle.fontSize];
    expect(sizes, everyElement(12.0), reason: 'tiles use the terminal\'s readable font');
    expect(find.byType(StatusShape), findsNWidgets(n));
    // Active agents' names are bold in their status color; idle ones plain.
    final working = seats.firstWhere((s) => s.state == SeatState.working);
    final name = tester.widget<Text>(find.text(working.logicalId));
    expect(name.style?.fontWeight, FontWeight.w700);
    expect(name.style?.color, isNot(Tokens.light.ink));
    expect(name.style?.fontSize, 13);

    Future<void> doubleClick() async {
      final at = tester.getCenter(find.byType(TerminalView).first);
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 100));
      // Mid-flight the tile is on its way and the rest still show, fading; nothing reconnects.
      expect(find.byType(TerminalView), findsNWidgets(n));
      expect(opened, n);
      await tester.pump(const Duration(milliseconds: 300));
    }

    int cols(String size) => int.parse(size.split('x').first);
    final small = cols(resizes.last);
    resizes.clear();
    await doubleClick();
    expect(find.byType(TerminalView), findsOneWidget);
    expect(opened, n, reason: 'enlarging resizes the tile\'s own client; a second one would fight it for the window');
    expect(cols(resizes.last), greaterThan(small), reason: 'the enlarged tile reflows the window to its size, less the dock');
    expect(find.byType(AgentPanelDock), findsOneWidget, reason: 'the enlarged tile has the full terminal\'s panels');
    expect(find.byType(AgentPanelsToggle), findsOneWidget);
    expect(find.textContaining('app / '), findsOneWidget, reason: 'enlarged, the project and rig stay in sight');
    await tester.pump(const Duration(milliseconds: 400));
    await doubleClick();
    expect(find.byType(TerminalView), findsNWidgets(n));
    expect(find.byType(AgentPanelDock), findsNothing);
    expect(find.byType(AgentPanelsToggle), findsNothing);
    expect(opened, n);
    expect(cols(resizes.last), small, reason: 'shrinking reflows it back');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  test('a running rig opens as tiles on desktop, and as its details on the phone (an agent as its chat), never the tiles', () {
    final rig = rigFromFixture('r-conveyor');
    final seats = [for (final n in nodes['r-conveyor']!) Seat.fromJson(n)];
    final r = RigWithSeats(rig, seats);
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    expect(rigHome(r, 'app'), isA<RigHost>());
    isDesktop = false;
    expect(rigHome(r, 'app'), isA<RigScreen>(), reason: 'a plain rig tap on the phone: its details');
    final lead = seats.firstWhere((s) => s.isClaude && TilesScreen.tiled(s));
    final chat = rigHome(r, 'app', enlarge: lead.logicalId);
    expect(chat, isA<ChatScreen>(), reason: 'an agent: its chat');
    expect((chat as ChatScreen).seat.logicalId, lead.logicalId);
  });

  testWidgets('desktop: a right click on a tile does nothing; its ⋯ opens the agent list, the one the header has', (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    debugOpenTerminal = (h, t) async => _Recording(<String>[]);
    final rig = rigFromFixture('r-conveyor');
    final seats = [for (final n in nodes['r-conveyor']!) Seat.fromJson(n)];
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: phone(store, TilesScreen(rig: rig, seats: seats, projectName: 'app'))));
    await tester.pump(const Duration(milliseconds: 300));

    final mouse = await tester.startGesture(tester.getCenter(find.byType(TerminalView).first),
        kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await mouse.up();
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing, reason: 'no menu');
    expect(find.byType(BottomSheet), findsNothing, reason: 'no sheet');

    expect(find.byTooltip(RegExp('Actions for ')), findsWidgets, reason: 'a ⋯ on each tile');
    await tester.tap(find.byTooltip(RegExp('Actions for ')).first);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MenuItemButton, 'Open as terminal'), findsOneWidget);
    expect(find.widgetWithText(MenuItemButton, 'Agent details'), findsOneWidget);
    expect(find.widgetWithText(MenuItemButton, 'Reconnect'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}

class _Recording extends FakeTerminal {
  _Recording(this.resizes) : super('view');
  final List<String> resizes;
  @override
  void resize(int cols, int rows) => resizes.add('${cols}x$rows');
}

/// The number of routes on the navigator: a push adds one, a replace none.
class _Depth extends NavigatorObserver {
  int count = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => count++;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => count--;
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => count--;
}
