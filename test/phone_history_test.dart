import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ui/terminal_screen.dart' show TerminalScreen;
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;
import 'package:pocket_rig/ui/recent_screen.dart' show RecentScreen;
import 'package:pocket_rig/ui/rig_screen.dart' show RigScreen;

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

Future<void> _lipDrag(WidgetTester tester) async {
  await tester.dragFrom(tester.getCenter(find.byKey(const ValueKey('drawer-lip'))), const Offset(120, 0));
  await tester.pumpAndSettle();
  for (var i = 0; i < 5 && find.text('conveyor').evaluate().isEmpty; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Back').last);
  await tester.pumpAndSettle();
}

Future<void> _end(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  testWidgets('phone: Back goes to the screen before, chat to rig to chat, and at the bottom shows the Inbox', (tester) async {
    await _pumpPhone(tester);
    await tester.tap(find.text('attacker').first);
    await tester.pumpAndSettle();
    expect(find.byType(TerminalScreen), findsOneWidget);

    await _lipDrag(tester);
    await tester.tap(find.text('conveyor').last);
    await tester.pumpAndSettle();
    expect(find.byType(RigScreen), findsOneWidget);

    await _back(tester);
    expect(find.byType(TerminalScreen), findsOneWidget, reason: 'the chat before the rig');
    await _back(tester);
    expect(find.byType(RecentScreen), findsOneWidget, reason: 'the bottom of the history');
    expect(find.byTooltip('Back'), findsNothing);
    await _end(tester);
  });

  testWidgets('phone: selecting the screen already on top does not push it again', (tester) async {
    await _pumpPhone(tester);
    await tester.tap(find.text('conveyor').first);
    await tester.pumpAndSettle();
    await _lipDrag(tester);
    await tester.tap(find.text('conveyor').last);
    await tester.pumpAndSettle();
    expect(find.byType(RigScreen), findsOneWidget);
    await _back(tester);
    expect(find.byType(RecentScreen), findsOneWidget, reason: 'one Back reaches the Inbox');
    await _end(tester);
  });

  testWidgets('phone: the lip opens the drawer on a drag and a tap, and carries a label', (tester) async {
    await _pumpPhone(tester);
    await tester.tap(find.text('conveyor').first);
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing);
    await tester.tap(find.byKey(const ValueKey('drawer-lip')));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('drawer-lip'))).shortestSide, greaterThanOrEqualTo(44));
    await _end(tester);
  });

  testWidgets('phone (iOS): the edge swipe away from the lip goes back and does not open the drawer', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await _pumpPhone(tester);
    await tester.tap(find.text('conveyor').first);
    await tester.pumpAndSettle();
    expect(find.byType(RigScreen), findsOneWidget);
    await tester.dragFrom(const Offset(2, 100), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(find.byType(RigScreen), findsNothing);
    expect(find.byType(RecentScreen), findsOneWidget);
    expect(find.byType(Drawer), findsNothing);
    await _end(tester);
    debugDefaultTargetPlatformOverride = null;
  });
}
