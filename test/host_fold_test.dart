import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/models.dart' show Host;
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;
import 'package:pocket_rig/ui/hosts/host_editor.dart';
import 'package:pocket_rig/ui/hosts_screen.dart' show HostsScreen;
import 'package:pocket_rig/ui/progress_bar.dart' show ProgressBar;
import 'package:pocket_rig/ui/project_tally.dart' show hostActiveCounts;
import 'package:pocket_rig/ui/theme.dart' show Tokens;

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

void main() {
  testWidgets('a host header in the sidebar folds on a tap (the editor is in its long-press list); folded it counts the active '
      'agents, needs-you in the accent; remembered per host', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    HostEditor.checkOnOpen = false;
    addTearDown(() => HostEditor.checkOnOpen = true);
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('conveyor').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final sidebar = find.byKey(const ValueKey('sidebar'));
    expect(find.descendant(of: sidebar, matching: find.text('conveyor')), findsOneWidget);
    await tester.tap(find.descendant(of: sidebar, matching: find.text('HOMELAB')));
    await tester.pump();
    expect(find.descendant(of: sidebar, matching: find.text('conveyor')), findsNothing, reason: 'folded to its header');
    expect(find.descendant(of: sidebar, matching: find.text('HOMELAB')), findsOneWidget);
    expect(fleet.hostFolded(homelab.id), isTrue, reason: 'remembered');
    // Its count: the active agents, in the accent while any needs you.
    final count = find.descendant(of: sidebar, matching: find.byWidgetPredicate((w) => w is Text && w.style?.color == Tokens.light.accent && RegExp(r'^\d+$').hasMatch(w.data ?? '')));
    expect(count, findsWidgets);
    // The right end: the host's one active count (needs you + structured questions + working + on a shell) in the accent: the
    // same number and colour as the Rigs home's folded header (hostActiveCounts).
    final active = hostActiveCounts(homelab);
    expect(active.active, greaterThan(0));
    final right = find.descendant(
        of: sidebar,
        matching: find.byWidgetPredicate((w) => w is Text && w.style?.color == Tokens.light.accent && w.data == '${active.active}'));
    expect(right, findsWidgets, reason: 'the folded host shows its ${active.active} active agents at the right');
    // The long-press list opens the editor, without unfolding.
    await tester.longPress(find.descendant(of: sidebar, matching: find.text('HOMELAB')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Edit host'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(HostEditor), findsOneWidget);
    expect(fleet.hostFolded(homelab.id), isTrue);
    // Unfold on a tap.
    await tester.tap(find.descendant(of: sidebar, matching: find.text('HOMELAB')));
    await tester.pump();
    expect(find.descendant(of: sidebar, matching: find.text('conveyor')), findsOneWidget);
    expect(find.descendant(of: find.byType(HostEditor), matching: find.text('${active.active}')), findsNothing);
    expect(find.byType(ProgressBar), findsWidgets, reason: 'unfolded: the usage rows are back');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the Rigs home folds a host on the same chevron, and the fold is one state shared with the sidebar', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('conveyor').evaluate().length < 2; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final sidebar = find.byKey(const ValueKey('sidebar'));
    final cards = find.byKey(const ValueKey('rigs-cards'));
    expect(find.descendant(of: cards, matching: find.text('conveyor')), findsOneWidget);
    // Fold HOMELAB on the home: its cards go, the header (and its usage) stays with the count; the sidebar follows.
    await tester.tap(find.descendant(of: cards, matching: find.byTooltip('Fold homelab')));
    await tester.pump();
    expect(find.descendant(of: cards, matching: find.text('conveyor')), findsNothing);
    expect(find.descendant(of: cards, matching: find.text('HOMELAB')), findsOneWidget, reason: 'the header stays');
    expect(find.descendant(of: sidebar, matching: find.text('conveyor')), findsNothing, reason: 'one fold state: the sidebar folded too');
    expect(find.descendant(of: cards, matching: find.byTooltip('Unfold homelab')), findsOneWidget);
    // And back from the sidebar.
    await tester.tap(find.descendant(of: sidebar, matching: find.text('HOMELAB')));
    await tester.pump();
    expect(find.descendant(of: cards, matching: find.text('conveyor')), findsOneWidget, reason: 'unfolded in the home too');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('with a single host a tap on its header opens Hosts and settings instead of folding it', (tester) async {
    final store = await installFakes();
    // This Mac is always listed on the desktop, so with the others gone it is the one host.
    await store.remove(macbook.id);
    await store.remove(homelab.id);
    AppShell.debugStartOnInbox = false;
    await pumpDesktop(tester, store);
    await tester.pump(const Duration(seconds: 1));
    final sidebar = find.byKey(const ValueKey('sidebar'));
    await tester.tap(find.descendant(of: sidebar, matching: find.text('THIS MAC')));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(HostsScreen), findsOneWidget);
    expect(fleet.hostFolded(Host.localId), isFalse, reason: 'not folded');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
