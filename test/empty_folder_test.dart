import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart' show fleet;
import 'package:pocket_rig/data/projects.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/rigs_home.dart' show RigsHome;
import 'package:pocket_rig/ui/theme.dart' show Tokens;
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell, panelShows;

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

void main() {
  test('foldersToRemember: where a rig, an agent or a shell was seen; not pinned, home, no folder or empty ones', () {
    final shell = Project(path: '/w/shell')..shells.add(const ProjectShell('rp-x', '/w/shell'));
    final withRig = Project(path: '/w/rig', rigs: [RigWithSeats(rigFromFixture('r-conveyor'), const [])]);
    final agent = Project(path: '/w/agent', loose: [scratchAgent()]);
    final pinned = Project(path: '/w/pinned', pinned: true, rigs: [RigWithSeats(rigFromFixture('r-conveyor'), const [])]);
    final empty = Project(path: '/w/empty');
    final noFolder = Project(path: '(no folder)', loose: [scratchAgent()]);
    final home = Project(path: '~', loose: [scratchAgent()]);
    expect(foldersToRemember([shell, withRig, agent, pinned, empty, noFolder, home]), ['/w/shell', '/w/rig', '/w/agent']);
    expect(empty.nothingHere, isTrue);
    expect(withRig.nothingHere, isFalse);
    expect(noFolder.nothingHere, isFalse);
  });

  testWidgets('a folder where something ran stays, greyed, after the last agent stops, until the x (after a confirm)', (tester) async {
    final store = await installFakes();
    final host = store.active!;
    panelShows.value = null;
    AppShell.debugStartOnInbox = false;
    fleet.remember = store.rememberFolders;
    addTearDown(() => fleet.remember = null);
    await pumpDesktop(tester, store);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(host.pinnedFolders, contains(app), reason: 'the folder with a rig was remembered');
    // The last thing in it stops: nothing runs there any more.
    final feed = fleet.feedFor(host);
    feed.rigs = [for (final r in feed.rigs) if (!r.seats.any((s) => s.cwd != null && s.cwd!.startsWith(app))) r];
    feed.loose = [for (final a in feed.loose) if (a.cwd == null || !a.cwd!.startsWith(app)) a];
    // ignore: invalid_use_of_protected_member
    feed.notifyListeners();
    await tester.pump(const Duration(milliseconds: 300));
    final sidebar = find.byKey(const ValueKey('sidebar'));
    final name = find.descendant(of: sidebar, matching: find.text('app'));
    expect(name, findsOneWidget, reason: 'it stays');
    expect(tester.widget<Text>(name).style?.color, Tokens.light.faint, reason: 'greyed: the faint colour');
    final x = find.descendant(of: sidebar, matching: find.byTooltip('Remove app from the list'));
    expect(x, findsOneWidget);

    // On a Mac the x shows on hover.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(name));
    await tester.pump();
    await tester.tap(x);
    await tester.pumpAndSettle();
    expect(find.text('Remove app from the list?'), findsOneWidget, reason: 'a confirm first');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(host.pinnedFolders, contains(app));
    await mouse.moveTo(tester.getCenter(name));
    await tester.pump();
    await tester.tap(x);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(host.pinnedFolders, isNot(contains(app)));
    expect(find.descendant(of: sidebar, matching: find.text('app')), findsNothing, reason: 'gone from the list');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the Rigs home lists a kept empty folder last, greyed, with "nothing running" and an x that is always there on a phone', (tester) async {
    final store = await installFakes();
    store.active!.pinnedFolders.add('/Users/me/code/kept');
    AppShell.debugStartOnInbox = false;
    tester.view.physicalSize = const Size(390, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: phone(store, const RigsHome())));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('kept'), findsOneWidget);
    expect(tester.widget<Text>(find.text('kept')).style?.color, Tokens.light.faint);
    expect(find.text('nothing running · ~/code/kept'), findsOneWidget);
    final x = find.byTooltip('Remove kept from the list');
    expect(x, findsOneWidget);
    expect(tester.widget<Opacity>(find.ancestor(of: x, matching: find.byType(Opacity)).first).opacity, 1, reason: 'a finger has no hover');
    // The ⋯ ends at the row's right edge and the x sits just left of it: nothing is stranded mid-row.
    final row = tester.getRect(find.ancestor(of: find.text('kept'), matching: find.byType(InkWell)).first);
    expect(tester.getRect(find.byTooltip('Actions for kept')).right, closeTo(row.right, 2.5));
    expect(tester.getRect(x).right, closeTo(tester.getRect(find.byTooltip('Actions for kept')).left, 4));
    await tester.tap(x);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(store.active!.pinnedFolders, isNot(contains('/Users/me/code/kept')));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
