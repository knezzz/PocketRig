import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ui/terminal_screen.dart' show TerminalScreen;
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell, detailNavigator;
import 'package:pocket_rig/ui/recent_screen.dart' show RecentScreen;
import 'package:pocket_rig/ui/rig_screen.dart' show RigScreen;
import 'package:pocket_rig/ui/tiles_screen.dart' show TilesScreen;

import 'golden/fixtures.dart';

Future<void> _pumpPhone(WidgetTester tester) async {
  final store = await installFakes();
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(AppScope(store: store, child: const MaterialApp(home: AppShell())));
  await tester.pumpAndSettle();
  await openDrawer(tester);
  for (var i = 0; i < 5 && find.text('conveyor').evaluate().isEmpty; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

Future<void> _end(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  testWidgets('phone: a rig tapped in the drawer opens its details, never the tiles', (tester) async {
    await _pumpPhone(tester);
    await tester.tap(find.text('conveyor').first);
    await tester.pumpAndSettle();
    expect(find.byType(RigScreen), findsOneWidget);
    expect(find.byType(TerminalScreen), findsNothing);
    expect(find.byType(TilesScreen), findsNothing);
    await _end(tester);
  });

  testWidgets('phone: an agent tapped in the drawer opens its chat; a kill pops back to the screen before',
      (tester) async {
    await _pumpPhone(tester);
    await tester.tap(find.text('attacker').first);
    await tester.pumpAndSettle();
    expect(find.byType(TerminalScreen), findsOneWidget);
    expect(find.byType(TilesScreen), findsNothing);

    // A kill or remove in the chat pops it: back to the screen before (the Inbox here), not a blank panel.
    detailNavigator(tester.element(find.byType(TerminalScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(TerminalScreen), findsNothing);
    expect(find.byType(RecentScreen), findsOneWidget);
    await _end(tester);
  });
}
