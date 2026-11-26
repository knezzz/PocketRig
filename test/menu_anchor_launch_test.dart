import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/main.dart' show PocketRigApp, navigatorKey;
import 'package:pocket_rig/ui/action_rows.dart';
import 'package:pocket_rig/ui/desktop_menu.dart';

import 'golden/fixtures.dart';

/// Its own file: the pointer tracking is process-wide, so no earlier test may have switched it on. The app switches it on at
/// launch (the demo build has its own main): the very first menu opens under its button, not at the window's top left.
void main() {
  testWidgets('the first menu after launch opens under its button', (tester) async {
    final store = await installFakes();
    await tester.pumpWidget(PocketRigApp(store: store, deepLinks: false));
    await tester.pump(const Duration(seconds: 1));
    final ActionRows rows = (items: [(Icons.edit_outlined, 'Rename', null, () {})], danger: const []);
    navigatorKey.currentState!.push(MaterialPageRoute<void>(
        builder: (c) => Scaffold(
            body: Align(
                alignment: Alignment.topRight,
                child: Builder(builder: (c) => IconButton(tooltip: 'more', onPressed: () => showDesktopMenu(c, rows), icon: const Icon(Icons.more_horiz)))))));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    final button = tester.getRect(find.byTooltip('more'));
    await tester.tap(find.byTooltip('more'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final item = tester.getRect(find.byType(MenuItemButton).first);
    expect(item.left, greaterThan(400), reason: 'not at the window\'s left edge');
    expect(item.right + 5, closeTo(button.right, 4), reason: 'right edges together');
    expect(item.top - 5, closeTo(button.bottom + 4, 2), reason: 'just under it');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
