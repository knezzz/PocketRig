import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell, panelShows;
import 'package:pocket_rig/ui/project/worktree_screen.dart' show WorktreeScreen;

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

void main() {
  Future<Finder> open(WidgetTester tester) async {
    final store = await installFakes();
    panelShows.value = null; // what an earlier test's page left on show
    showWorktrees = true;
    addTearDown(() => showWorktrees = false);
    AppShell.debugStartOnInbox = false;
    await pumpDesktop(tester, store);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    return find.byKey(const ValueKey('sidebar'));
  }

  testWidgets('no worktree rows: a worktree\'s rig sits directly under its project like any rig, with the worktree as a second line', (tester) async {
    final sidebar = await open(tester);
    Finder side(String t) => find.descendant(of: sidebar, matching: find.text(t, findRichText: true));
    expect(side('atlas'), findsOneWidget);
    expect(find.descendant(of: sidebar, matching: find.byTooltip('api-retry showing all agents')), findsNothing, reason: 'no worktree row, no chevron for it');
    expect(side('retry-pair'), findsOneWidget);
    expect(side('docs-duo'), findsOneWidget);
    // Level with the project's other rigs (one step in from the project), not one more.
    final rigX = tester.getTopLeft(side('retry-pair')).dx;
    expect(tester.getTopLeft(side('docs-duo')).dx, rigX, reason: 'both worktree rigs at the same level');
    expect(rigX - tester.getTopLeft(side('atlas')).dx, 12, reason: 'one level under the project');
    // The worktree is the second line of the rig's row: its name, from the rig name\'s x, with the worktree glyph before it.
    final line = side('api-retry');
    expect(line, findsOneWidget);
    expect(tester.getTopLeft(line).dx - rigX, 0 + 16, reason: 'the glyph 12 + 4, then the name, from the label column');
    expect(find.descendant(of: sidebar, matching: find.byWidgetPredicate((w) => w is Icon || w.runtimeType.toString() == 'AppIcon')), findsWidgets);
    expect(tester.getTopLeft(line).dy, greaterThan(tester.getTopLeft(side('retry-pair')).dy), reason: 'under the name');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a rig in a worktree: its long-press list opens the worktree\'s page (Open worktree)', (tester) async {
    final sidebar = await open(tester);
    Finder side(String t) => find.descendant(of: sidebar, matching: find.text(t, findRichText: true));
    await tester.longPress(side('retry-pair'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Open worktree'), findsOneWidget);
    await tester.tap(find.text('Open worktree'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(WorktreeScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('folding the project hides its rigs; the project view menu still lists its views', (tester) async {
    final sidebar = await open(tester);
    Finder side(String t) => find.descendant(of: sidebar, matching: find.text(t, findRichText: true));
    await tester.longPress(side('atlas'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Fold'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(side('retry-pair'), findsNothing);
    expect(side('docs-duo'), findsNothing);
    expect(fleet.viewOf(Fleet.folderKey(AppScope.read(tester.element(find.byType(AppShell))).active!, '/Users/me/code/atlas'), false, start: RigView.all), RigView.collapsed);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('rigs are ordered main checkout first, then by worktree name, whatever order the feed lists them in', (tester) async {
    final sidebar = await open(tester);
    Finder side(String t) => find.descendant(of: sidebar, matching: find.text(t, findRichText: true));
    expect(tester.getTopLeft(side('retry-pair')).dy, lessThan(tester.getTopLeft(side('docs-duo')).dy));
    // The feed now lists the project's rigs and agents the other way round.
    final atlas = fleet.feedFor(AppScope.read(tester.element(find.byType(AppShell))).active!).projects.firstWhere((p) => p.path.endsWith('/atlas'));
    atlas.rigs.setAll(0, atlas.rigs.reversed.toList());
    atlas.loose.setAll(0, atlas.loose.reversed.toList());
    fleet.setView('nudge', RigView.all); // a rebuild
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getTopLeft(side('retry-pair')).dy, lessThan(tester.getTopLeft(side('docs-duo')).dy), reason: 'still by worktree name');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
