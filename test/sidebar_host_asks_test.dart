import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;
import 'package:pocket_rig/ui/project_tally.dart' show SeatTally;
import 'package:pocket_rig/ui/theme.dart' show Tokens;

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

void main() {
  testWidgets('the sidebar host header counts the structured questions: its needs-you number moves with the Inbox count', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('conveyor').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final feed = fleet.feedFor(homelab);
    final t = SeatTally(homelab, [for (final r in feed.rigs) r], [for (final p in feed.projects) ...p.loose], wholeHost: true);
    final sidebar = find.byKey(const ValueKey('sidebar'));
    Finder number(int n) => find.descendant(
        of: sidebar, matching: find.byWidgetPredicate((w) => w is Text && w.style?.color == Tokens.light.accent && w.data == '$n'));
    expect(number(t.needs), findsWidgets);
    feed.setCoreAsks(2);
    await tester.pump();
    expect(number(t.needs + 2), findsWidgets, reason: 'two questions more, as the badge and the Inbox say');
    expect(feed.needsYou - 2, feed.needsYouItems.length);
    feed.setCoreAsks(0);
  });
}
