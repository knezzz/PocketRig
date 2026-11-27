import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/app_icon.dart' show AppIcon;
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell, panelShows;
import 'package:pocket_rig/ui/status_shape.dart' show StatusIcon;

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

void main() {
  testWidgets('sidebar levels: an agent outside a rig is the rig\'s sibling (its icon where the rig\'s is); the rig\'s seats are one in', (tester) async {
    final store = await installFakes();
    panelShows.value = null;
    showLoose = true;
    AppShell.debugStartOnInbox = false;
    await pumpDesktop(tester, store);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final sidebar = find.byKey(const ValueKey('sidebar'));
    Finder row(String label) =>
        find.ancestor(of: find.descendant(of: sidebar, matching: find.text(label, findRichText: true)).first, matching: find.byType(InkWell)).first;
    // The icons' centres: the rig's mark and an agent's logo are not the same size.
    double iconX(String label, Type icon) => tester.getCenter(find.descendant(of: row(label), matching: find.byType(icon)).first).dx;
    final rigIcon = iconX('conveyor', AppIcon);
    expect(iconX('scratch', StatusIcon), rigIcon, reason: 'a loose agent\'s icon is where its rig sibling\'s is');
    expect(iconX('lead', StatusIcon), greaterThan(rigIcon), reason: 'a rig seat is a level in');
    expect(tester.getTopLeft(find.descendant(of: sidebar, matching: find.text('scratch', findRichText: true)).first).dx,
        lessThan(tester.getTopLeft(find.descendant(of: sidebar, matching: find.text('lead', findRichText: true)).first).dx),
        reason: 'and so is its name');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
