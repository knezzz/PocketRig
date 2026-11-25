import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/chat_cache.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/agent_panels.dart';
import 'package:pocket_rig/ui/chat/rig_chat_pager.dart' show RigChatPager;
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/terminal_screen.dart';

import 'golden/fixtures.dart';

class _Cache extends ChatCache {
  _Cache(this.media) : super(NativeDatabase.memory());
  final List<RigMedia> media;
  @override
  Stream<List<RigMedia>> watchChatMedia(String hostId, String key) => Stream.value(media);
}

Future<void> _pump(WidgetTester tester, Widget screen) async {
  final store = await installFakes();
  await tester.pumpWidget(MaterialApp(
      home: phone(store, screen, root: true)));
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

  testWidgets('phone: an agent with a tmux session opens on its terminal; the chat only where the terminal has nothing to show',
      (tester) async {
    await _pump(tester, ChatScreen(rigName: 'conveyor', seat: lead));
    expect(find.byType(TerminalScreen), findsOneWidget, reason: 'a rig agent with a session');
    await _end(tester);

    await _pump(tester, ChatScreen(rigName: 'conveyor', seat: lead, pendingMessage: 'hello'));
    expect(find.byType(TerminalScreen), findsNothing, reason: 'a just-started session waits in the chat');
    await _end(tester);

    await _pump(tester, ChatScreen(rigName: 'conveyor', seat: lead, waitForLog: true));
    expect(find.byType(TerminalScreen), findsNothing);
    await _end(tester);

    final subagent = Seat.fromJson({
      ...nodes['r-conveyor']!.firstWhere((n) => n['logicalId'] == 'lead'),
      'contextUsage': {'transcriptPath': '/h/.claude/projects/p/s/subagents/agent-a1.jsonl'},
    });
    await _pump(tester, ChatScreen(rigName: 'conveyor', seat: subagent));
    expect(find.byType(TerminalScreen), findsNothing, reason: 'a subagent has no pane of its own');
    await _end(tester);

    final bare = Seat.fromJson({...nodes['r-conveyor']!.firstWhere((n) => n['logicalId'] == 'lead'), 'canonicalSessionName': null, 'sessionName': null});
    await _pump(tester, ChatScreen(rigName: 'conveyor', seat: bare));
    expect(find.byType(TerminalScreen), findsNothing, reason: 'no session, no terminal');
    await _end(tester);
  });

  testWidgets('phone: the Terminal | Chat switch goes back and forth without stacking screens', (tester) async {
    await _pump(tester, ChatScreen(rigName: 'conveyor', seat: lead));
    expect(find.byType(TerminalScreen), findsOneWidget);

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.bySemanticsLabel('Chat').first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(RigChatPager), findsOneWidget, reason: 'round $i: the chat');
      await tester.tap(find.bySemanticsLabel('Terminal').first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(TerminalScreen), findsOneWidget, reason: 'round $i: the terminal');
    }
    await _end(tester);
  });

  testWidgets('phone: a strip under the terminal counts Files, Images and Artifacts and opens a sheet with a tab each; it is hidden when all are empty',
      (tester) async {
    agentPanelsFile = () async => null;
    final now = DateTime.now();
    final key = chatKey(lead);
    chatCache = _Cache([
      RigMedia('file', '/w/c.dart', null, now, key),
      RigMedia('image', '/w/b.png', null, now, key),
      RigMedia('image', '/w/a.png', null, now, key),
      RigMedia('file', '/w/notes.md', null, now, key),
    ]);
    addTearDown(() => chatCache = null);
    await _pump(tester, ChatScreen(rigName: 'conveyor', seat: lead));
    expect(find.text('Files 1 · Images 2 · Artifacts 1 · Subagents 0 · Shells 0'), findsOneWidget);

    await tester.tap(find.text('Files 1 · Images 2 · Artifacts 1 · Subagents 0 · Shells 0'));
    await tester.pumpAndSettle();
    expect(find.text('Files 1'), findsOneWidget);
    expect(find.text('Images 2'), findsOneWidget);
    expect(find.text('Artifacts 1'), findsOneWidget);
    expect(find.text('c.dart'), findsOneWidget, reason: 'the Files tab first');
    await tester.tap(find.text('Artifacts 1'));
    await tester.pumpAndSettle();
    expect(find.text('notes.md'), findsOneWidget);
    await _end(tester);

    final first = chatCache;
    chatCache = _Cache(const []);
    addTearDown(() => first?.close());
    await _pump(tester, ChatScreen(rigName: 'conveyor', seat: lead));
    expect(find.textContaining('Files'), findsNothing, reason: 'nothing to show: no strip');
    await _end(tester);
  });

  for (final still in [false, true]) {
    testWidgets('phone: the switch is a quiet cross-fade, not a page slide${still ? ' (none with reduce motion)' : ''}; Back leaves the agent',
        (tester) async {
      if (still) tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final store = await installFakes();
      await tester.pumpWidget(MaterialApp(
          home: phone(store, Builder(builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatScreen(rigName: 'conveyor', seat: lead))),
              child: const Text('open agent'))), root: true)));
      await tester.tap(find.text('open agent'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(TerminalScreen), findsOneWidget);

      void quiet(Finder screen, String where) {
        final route = ModalRoute.of(tester.element(screen))!;
        expect(route, isA<PageRouteBuilder<dynamic>>(), reason: where);
        expect((route as PageRouteBuilder<dynamic>).transitionDuration, still ? Duration.zero : const Duration(milliseconds: 150),
            reason: where);
      }

      await tester.tap(find.bySemanticsLabel('Chat').first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(RigChatPager), findsOneWidget);
      quiet(find.byType(RigChatPager), 'terminal to chat');
      await tester.tap(find.bySemanticsLabel('Terminal').first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(TerminalScreen), findsOneWidget);
      quiet(find.byType(TerminalScreen), 'chat to terminal');
      await tester.tap(find.bySemanticsLabel('Chat').first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(RigChatPager), findsOneWidget);

      // Back from the chat leaves the agent, not the terminal it came from.
      await tester.tap(find.byTooltip('Back').first);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('open agent'), findsOneWidget);
      await _end(tester);
    });
  }
}
