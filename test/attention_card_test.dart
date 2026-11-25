import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/terminal/transport.dart';
import 'package:pocket_rig/ui/kit.dart';
import 'package:pocket_rig/ui/recent_screen.dart';
import 'package:pocket_rig/ui/terminal_screen.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

void main() {
  setUp(() => animateStatusSpinners = false);

  testWidgets('a blocked-on-you card opens the rig\'s own seat', (tester) async {
    final store = await installFakes();
    // The phone frame is 390×844: the whole of it on screen.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: phone(store, const RecentScreen(visible: false))));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The fixture's item is from implementation-pair's Codex impl: no chat, so its terminal.
    // Every Needs-you card has a Terminal link: this one is the blocked-on-you card's.
    final summary = find.textContaining('Blocked on you');
    await tester.scrollUntilVisible(summary, 100, scrollable: find.byType(Scrollable).first);
    final open = find.descendant(
        of: find.ancestor(of: summary, matching: find.byType(Panel)).first, matching: find.text('Terminal'));
    await tester.ensureVisible(open);
    await tester.pump();
    await tester.tap(open);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final target = tester.widget<TerminalScreen>(find.byType(TerminalScreen)).target as SeatTarget;
    expect(target.rigName, 'implementation-pair');
    expect(target.seat.nodeId, isNotNull, reason: 'the feed\'s seat, not one made up from the address');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
