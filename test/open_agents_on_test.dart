import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/agent_view_switch.dart';
import 'package:pocket_rig/ui/chat/rig_chat_pager.dart' show RigChatPager;
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/open_agents_on.dart';
import 'package:pocket_rig/ui/terminal_screen.dart';

import 'golden/fixtures.dart';

Future<void> _pump(WidgetTester tester, Widget screen) async {
  final store = await installFakes();
  await tester.pumpWidget(MaterialApp(home: phone(store, screen, root: true)));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _end(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  final lead = seatFromFixture('r-conveyor', 'lead');
  tearDown(() => openAgentsOn.value = AgentView.terminal);

  testWidgets('the setting decides where an agent with a session opens; the chat-only cases stay chat', (tester) async {
    expect(openAgentsOn.value, AgentView.terminal, reason: 'the default');
    await _pump(tester, ChatScreen(rigName: 'conveyor', seat: lead));
    expect(find.byType(TerminalScreen), findsOneWidget);
    await _end(tester);

    openAgentsOn.value = AgentView.chat;
    await _pump(tester, ChatScreen(rigName: 'conveyor', seat: lead));
    expect(find.byType(TerminalScreen), findsNothing);
    expect(find.byType(RigChatPager), findsOneWidget, reason: 'Chat chosen: a rig agent opens on its chat');
    await _end(tester);

    // Whatever is chosen, these are the chat.
    for (final v in AgentView.values) {
      openAgentsOn.value = v;
      await _pump(tester, ChatScreen(rigName: 'conveyor', seat: lead, pendingMessage: 'hello'));
      expect(find.byType(TerminalScreen), findsNothing, reason: '$v: a just-started session');
      await _end(tester);
      final bare = Seat.fromJson({
        ...nodes['r-conveyor']!.firstWhere((n) => n['logicalId'] == 'lead'),
        'canonicalSessionName': null,
        'sessionName': null
      });
      await _pump(tester, ChatScreen(rigName: 'conveyor', seat: bare));
      expect(find.byType(TerminalScreen), findsNothing, reason: '$v: no session');
      await _end(tester);
    }
  });

  test('the choice is kept in a file and read back; anything else reads as Terminal', () async {
    final dir = Directory.systemTemp.createTempSync('open-on');
    addTearDown(() {
      openAgentsOnFile = () async => null;
      dir.deleteSync(recursive: true);
    });
    final f = File('${dir.path}/open-agents-on');
    openAgentsOnFile = () async => f;
    await setOpenAgentsOn(AgentView.chat);
    expect(f.readAsStringSync(), 'chat');
    openAgentsOn.value = AgentView.terminal;
    await loadOpenAgentsOn();
    expect(openAgentsOn.value, AgentView.chat, reason: 'read back after a restart');
    f.writeAsStringSync('garbage');
    await loadOpenAgentsOn();
    expect(openAgentsOn.value, AgentView.terminal);
  });
}
