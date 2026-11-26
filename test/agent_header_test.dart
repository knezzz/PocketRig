import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/terminal/transport.dart';
import 'package:pocket_rig/ui/agent_header.dart';
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/progress_bar.dart';
import 'package:pocket_rig/ui/status_shape.dart';
import 'package:pocket_rig/ui/terminal_screen.dart';

import 'golden/fixtures.dart';

void main() {
  testWidgets('chat and terminal share one AgentHeader: the agent icon at the mark, the name, Terminal | Chat; a phone adds the context bar',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = await installFakes();
    final seat = seatFromFixture('r-conveyor', 'lead');
    for (final screen in <Widget>[
      ChatScreen(rigName: 'conveyor', seat: seat, asChat: true),
      TerminalScreen(target: SeatTarget('conveyor', seat)),
    ]) {
      await tester.pumpWidget(MaterialApp(home: phone(store, screen)));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(AgentHeader), findsOneWidget, reason: '${screen.runtimeType}');
      final header = find.byType(AgentHeader);
      expect(find.descendant(of: header, matching: find.text('lead')), findsOneWidget);
      expect(find.descendant(of: header, matching: find.byType(StatusIcon)), findsOneWidget, reason: 'the agent icon: logo in the state colour');
      expect(find.descendant(of: find.byType(StatusIcon), matching: find.byType(StatusShape)), findsNothing, reason: 'no dot on the agent icon');
      expect(find.descendant(of: header, matching: find.text('Terminal')), findsOneWidget);
      expect(find.descendant(of: header, matching: find.text('Chat')), findsOneWidget);
      if (seat.contextUsedPercent != null) {
        expect(find.descendant(of: header, matching: find.byType(ContextBar)), findsOneWidget, reason: 'the phone row');
      }
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('on a wide window the header is one row: the name sits level with Terminal | Chat', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = await installFakes();
    await tester.pumpWidget(MaterialApp(
        home: phone(store, ChatScreen(rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'lead'), asChat: true))));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final header = find.byType(AgentHeader);
    final name = tester.getCenter(find.descendant(of: header, matching: find.text('lead')));
    final terminal = tester.getCenter(find.descendant(of: header, matching: find.text('Terminal')));
    expect((name.dy - terminal.dy).abs(), lessThan(6), reason: 'one row, not stacked lines');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the branch chip has the worktree\'s name under it for a seat in a worktree, and nothing under it in the main checkout', (tester) async {
    tester.view.physicalSize = const Size(1000, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget header(String cwd) => MaterialApp(
        home: Scaffold(
            body: AgentHeader(
                seat: Seat.fromJson({'rigId': 'r', 'logicalId': 'x', 'runtime': 'claude-code', 'cwd': cwd}),
                title: 'x',
                subtitle: const Text('sub'),
                menuTooltip: 'Menu',
                onMenu: () {},
                branch: 'fix-ci')));
    await tester.pumpWidget(header('/w/app/.claude/worktrees/api-retry'));
    expect(find.text('fix-ci'), findsOneWidget);
    expect(find.text('api-retry'), findsOneWidget);
    expect(tester.getTopLeft(find.text('api-retry')).dy, greaterThan(tester.getBottomLeft(find.text('fix-ci')).dy - 1));
    await tester.pumpWidget(header('/w/app'));
    expect(find.text('fix-ci'), findsOneWidget);
    expect(find.text('api-retry'), findsNothing);
  });
}
