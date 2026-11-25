import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/host_store.dart';

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

void main() {
  testWidgets('the sidebar starts with a Search field (⌘K opens the command palette) and a + that opens the New sheet; its default '
      'width is 264', (tester) async {
    final store = await installFakes();
    await pumpDesktop(tester, store);
    final sidebar = find.byKey(const ValueKey('sidebar'));
    expect(tester.getSize(sidebar).width, HostStore.defaultSidebarWidth);
    expect(HostStore.defaultSidebarWidth, 264);
    expect(find.descendant(of: sidebar, matching: find.text('Search')), findsOneWidget);
    expect(find.descendant(of: sidebar, matching: find.text('⌘K')), findsOneWidget);
    // Above the Rigs and Inbox rows.
    expect(tester.getTopLeft(find.descendant(of: sidebar, matching: find.text('Search'))).dy,
        lessThan(tester.getTopLeft(find.descendant(of: sidebar, matching: find.text('Inbox'))).dy));

    await tester.tap(find.descendant(of: sidebar, matching: find.text('Search')));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget, reason: 'the palette\'s field');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget, reason: '⌘K opens it too');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(of: sidebar, matching: find.byTooltip('New…')));
    await tester.pumpAndSettle();
    expect(find.text('Start agent'), findsOneWidget, reason: 'the New sheet');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
