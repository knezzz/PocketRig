import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;
import 'package:pocket_rig/ui/rigs_home.dart';
import 'package:pocket_rig/ui/worktree_chip.dart';

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

void main() {
  testWidgets('worktree chips: always on a rig card of the Rigs home, on a row only when it differs from its rig\'s; in the '
      'sidebar only for a worktree that is not main', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    showWorktrees = true;
    showLoose = true;
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('retry-pair').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final home = find.byKey(const ValueKey('rigs-cards'));
    Finder chip(String name) => find.descendant(of: home, matching: find.byWidgetPredicate((w) => w is WorktreeChip && w.name == name));
    expect(chip('main'), findsWidgets, reason: 'conveyor and the others run in the main checkout: still a chip on the card');
    // retry-pair runs in the api-retry worktree: one chip, on its card; its seats are in the same worktree: no chip on them.
    await tester.scrollUntilVisible(find.descendant(of: home, matching: find.text('retry-pair')), 200,
        scrollable: find.descendant(of: home, matching: find.byType(Scrollable)).first);
    expect(chip('api-retry'), findsWidgets);
    final card = find.ancestor(of: find.descendant(of: home, matching: find.text('retry-pair')), matching: find.byType(Column)).first;
    expect(find.descendant(of: card, matching: find.byWidgetPredicate((w) => w is WorktreeChip && w.name == 'api-retry')),
        findsOneWidget, reason: 'on the card only, not repeated on its agents');

    // On a phone width the rig name is whole and the chip sits beside or under it, never cutting the name.
    final name = tester.getRect(find.descendant(of: card, matching: find.text('retry-pair')));
    final chipRect = tester.getRect(find.descendant(of: card, matching: find.byWidgetPredicate((w) => w is WorktreeChip)).first);
    expect(chipRect.left >= name.right || chipRect.top >= name.bottom, isTrue, reason: 'beside the name or under it, not over it');

    // The sidebar: a rig in a worktree sits under the worktree's own row (no chip: the row says it), main has neither.
    final sidebar = find.ancestor(of: find.text('Add project folder'), matching: find.byType(ListView));
    Finder inSidebar(Finder f) => find.descendant(of: sidebar, matching: f);
    expect(inSidebar(find.text('api-retry')), findsOneWidget, reason: 'the worktree row');
    expect(inSidebar(find.byWidgetPredicate((w) => w is WorktreeChip && w.name == 'api-retry')), findsNothing, reason: 'no chip under it');
    expect(inSidebar(find.byWidgetPredicate((w) => w is WorktreeChip && w.name == 'main')), findsNothing,
        reason: 'main is the default: no chip in the sidebar');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('on a phone a rig name is never cut for its chip: adversarial-review shows whole', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    await tester.pumpWidget(MaterialApp(home: phone(store, const RigsHome())));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final name = find.text('adversarial-review');
    await tester.scrollUntilVisible(name, 200, scrollable: find.byType(Scrollable).first);
    expect(name, findsOneWidget);
    expect(tester.renderObject<RenderParagraph>(name).didExceedMaxLines, isFalse, reason: 'not ellipsized');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
