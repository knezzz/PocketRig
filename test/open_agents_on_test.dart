import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/loose_agents.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/agent_view_switch.dart';
import 'package:pocket_rig/ui/chat/rig_chat_pager.dart' show RigChatPager;
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/loose_agent_screen.dart';
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

  testWidgets('opensAsChat: the setting is Chat and the seat has a chat', (tester) async {
    final codex = Seat(rigId: 'r', logicalId: 'c', sessionName: 'c@r', runtime: 'codex');
    expect(opensAsChat(lead), isFalse, reason: 'Terminal is the default');
    openAgentsOn.value = AgentView.chat;
    expect(opensAsChat(lead), isTrue);
    expect(opensAsChat(codex), isFalse, reason: 'a Codex seat has no chat');
  });

  testWidgets('an agent outside a rig opens as the setting says; an explicit Chat is the chat whatever it is', (tester) async {
    final store = await installFakes();
    Future<void> open({required bool claude, bool chat = false}) async {
      final a = LooseAgent(id: 'x', tmuxSession: 'x', runtime: claude ? 'claude-code' : 'codex', claudeSessionId: claude ? 's' : null);
      await tester.pumpWidget(MaterialApp(
          home: phone(store, Builder(builder: (c) => TextButton(onPressed: () => openLooseAgent(Navigator.of(c), a, const [], chat: chat), child: const Text('go'))), root: true)));
      await tester.tap(find.text('go'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await open(claude: true);
    expect(find.byType(TerminalScreen), findsOneWidget, reason: 'Terminal: a Claude agent in tmux opens its terminal');
    await _end(tester);
    await open(claude: false);
    expect(find.byType(TerminalScreen), findsOneWidget, reason: 'Terminal: so does a Codex agent in tmux (it had only its details)');
    await _end(tester);

    openAgentsOn.value = AgentView.chat;
    await open(claude: true);
    expect(find.byType(TerminalScreen), findsNothing, reason: 'Chat: its chat');
    await _end(tester);
    await open(claude: false);
    expect(find.byType(LooseAgentScreen), findsOneWidget, reason: 'Chat: Codex has no chat, so its details');
    await _end(tester);

    openAgentsOn.value = AgentView.terminal;
    await open(claude: true, chat: true);
    expect(find.byType(TerminalScreen), findsNothing, reason: "an explicit 'Chat' is the chat, even when the setting is Terminal");
    await _end(tester);
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
