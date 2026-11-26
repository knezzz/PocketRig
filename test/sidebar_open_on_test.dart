import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/agent_view_switch.dart';
import 'package:pocket_rig/ui/chat_screen.dart' show ChatPage;
import 'package:pocket_rig/ui/open_agents_on.dart';
import 'package:pocket_rig/ui/terminal_screen.dart';

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

void main() {
  testWidgets('the sidebar follows Open agents on: Terminal enlarges the tile, Chat opens the chat', (tester) async {
    final store = await installFakes();
    addTearDown(() => openAgentsOn.value = AgentView.terminal);
    openAgentsOn.value = AgentView.chat;
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('app').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final sidebar = find.ancestor(of: find.text('Add project folder').first, matching: find.byType(ListView));
    await tester.tap(find.descendant(of: sidebar, matching: find.text('attacker')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TerminalScreen), findsNothing);
    expect(find.byType(ChatPage), findsWidgets, reason: 'Chat: the sidebar opens the agent as its chat');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the sidebar seat sheet\'s Chat opens in the main area, the sidebar stays (as a click does)', (tester) async {
    final store = await installFakes();
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('app').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.tap(find.byTooltip('Actions for attacker'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    // The agent's list is the same one as the header's and the tile's; Agent details is the seat sheet.
    expect(find.widgetWithText(MenuItemButton, 'Open as chat'), findsOneWidget);
    await tester.tap(find.widgetWithText(MenuItemButton, 'Agent details'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    final chat = find.widgetWithText(OutlinedButton, 'Chat');
    expect(tester.getCenter(chat).dy, lessThan(800), reason: 'the sheet is up');
    await tester.tap(chat);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ChatPage), findsWidgets);
    expect(find.text('Add project folder'), findsWidgets, reason: 'the sidebar is still there: a page in the content panel');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
