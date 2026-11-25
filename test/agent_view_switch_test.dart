import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/terminal_screen.dart';

import 'golden/fixtures.dart';

void main() {
  testWidgets('switching Chat and Terminal adds no page: Back from either view leaves the agent for where it came from',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = await installFakes();
    final lead = seatFromFixture('r-conveyor', 'lead');
    await tester.pumpWidget(MaterialApp(
      home: phone(
        store,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => ChatScreen(rigName: 'conveyor', seat: lead, asChat: true))),
                child: const Text('open agent'),
              ),
            ),
          ),
        ),
        root: true,
      ),
    ));
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.tap(find.text('open agent'));
    await settle();
    expect(find.byType(TerminalScreen), findsNothing);
    for (final to in ['Terminal', 'Chat', 'Terminal', 'Chat']) {
      await tester.tap(find.text(to).first);
      await settle();
      expect(find.byType(TerminalScreen), to == 'Terminal' ? findsOneWidget : findsNothing, reason: 'on $to');
    }
    expect(find.text('open agent'), findsNothing, reason: 'still on the agent');
    await tester.tap(find.byTooltip('Back'));
    await settle();
    expect(find.text('open agent'), findsOneWidget, reason: 'one Back, and you are where you came from');

    // The same from the terminal side.
    await tester.tap(find.text('open agent'));
    await settle();
    await tester.tap(find.text('Terminal').first);
    await settle();
    expect(find.byType(TerminalScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await settle();
    expect(find.text('open agent'), findsOneWidget, reason: 'Back from the terminal too');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
