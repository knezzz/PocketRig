import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/terminal/transport.dart' show SeatTarget;
import 'package:pocket_rig/ui/agent_header.dart';
import 'package:pocket_rig/ui/agent_view_switch.dart';
import 'package:pocket_rig/ui/chat/rig_chat_pager.dart' show RigChatPager;
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/terminal_screen.dart';

import 'golden/fixtures.dart';

Seat _seat(String runtime, {bool session = true}) => Seat.fromJson({
      'rigId': 'r',
      'logicalId': 'x',
      if (session) 'canonicalSessionName': 'x@r',
      'runtime': runtime,
      'sessionStatus': 'running',
    });

Future<void> _pump(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final store = await installFakes();
  await tester.pumpWidget(MaterialApp(home: phone(store, screen, root: true)));
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const noChat = 'Chat needs Claude Code\'s session log';

void main() {
  test('which views an agent has, and why one is missing', () {
    final claude = agentViews(_seat('claude-code'));
    expect((claude.terminalWhy, claude.chatWhy), (null, null));
    final codex = agentViews(_seat('codex'));
    expect((codex.terminalWhy, codex.chatWhy), (null, noChat));
    final bare = agentViews(_seat('claude-code', session: false));
    expect((bare.terminalWhy, bare.chatWhy), ('No tmux session', 'No tmux session'));
    final codexBare = agentViews(_seat('codex', session: false));
    expect((codexBare.terminalWhy, codexBare.chatWhy), ('No tmux session', noChat));
    expect(agentViews(null).terminalWhy, 'No tmux session');
  });

  testWidgets('the switch dims a missing view with its reason, never hides it, and a tap on it goes nowhere', (tester) async {
    final went = <AgentView>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AgentViewSwitch(
                showing: AgentView.terminal, views: agentViews(_seat('codex')), onChanged: went.add))));
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    await tester.tap(find.text('Chat'));
    await tester.pump();
    expect(went, isEmpty);
    expect(find.byTooltip(noChat), findsOneWidget);
  });

  testWidgets('chat screen: the switch is there for a Claude seat, and for one with no tmux session the Terminal side says why', (tester) async {
    await _pump(tester, ChatScreen(key: UniqueKey(), rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'lead'), asChat: true));
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.byTooltip('No tmux session'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await _pump(tester, ChatScreen(key: UniqueKey(), rigName: 'conveyor', seat: _seat('claude-code', session: false), asChat: true));
    expect(find.text('Terminal'), findsOneWidget, reason: 'not hidden');
    expect(find.byTooltip('No tmux session'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('terminal screen: a Codex seat has the switch too, with Chat dimmed and the reason on it', (tester) async {
    await _pump(tester, TerminalScreen(target: SeatTarget('conveyor', seatFromFixture('r-conveyor', 'impl'))));
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    expect(find.byTooltip(noChat), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('terminal screen: a Claude seat can go to Chat (no reason on it)', (tester) async {
    await _pump(tester, TerminalScreen(target: SeatTarget('conveyor', seatFromFixture('r-conveyor', 'lead'))));
    expect(find.text('Chat'), findsOneWidget);
    expect(find.byTooltip(noChat), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the rig chat pager: the switch is there on a Claude seat, Terminal enabled', (tester) async {
    await _pump(
        tester,
        RigChatPager(
            key: UniqueKey(),
            rigName: 'conveyor',
            seat: seatFromFixture('r-conveyor', 'lead')));
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    expect(find.byTooltip('No tmux session'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the switch sits at one x whether the header has a panels toggle or not, and a dimmed tab shows the forbidden cursor', (tester) async {
    Widget header({required List<Widget> extra}) => MaterialApp(
        home: Scaffold(
            body: AgentHeader(
                seat: _seat('codex'),
                title: 'x',
                subtitle: const Text('sub'),
                menuTooltip: 'Menu',
                onMenu: () {},
                showing: AgentView.terminal,
                views: agentViews(_seat('codex')),
                onSwitch: () {},
                extraActions: extra)));
    await tester.pumpWidget(header(extra: const []));
    final plain = tester.getTopRight(find.byType(AgentViewSwitch));
    await tester.pumpWidget(header(extra: [IconButton(onPressed: () {}, icon: const Icon(Icons.view_sidebar_outlined))]));
    expect(tester.getTopRight(find.byType(AgentViewSwitch)), plain, reason: 'the panels toggle is left of the switch');
    final cursor = tester.widget<MouseRegion>(find.ancestor(of: find.byTooltip(noChat), matching: find.byType(MouseRegion)).first).cursor;
    expect(cursor, SystemMouseCursors.forbidden);
  });
}
