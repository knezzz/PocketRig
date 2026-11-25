import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart' show fleet;
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/command_palette.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show panelShows, seatPanelKey;
import 'package:pocket_rig/ui/rig/seat_actions.dart' show seatActionRows;
import 'package:pocket_rig/ui/rig/seat_sheet.dart' show showSeatSheet;
import 'package:pocket_rig/ui/terminal_screen.dart' show TerminalScreen;

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

Future<void> _shortcut(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pumpAndSettle();
}

final _palette = find.byKey(const ValueKey('command palette'));
Finder _in(Finder f) => find.descendant(of: _palette, matching: f);

void main() {
  test('a query matches when every word is in the group, label or detail', () {
    const c = PaletteCommand('Seat · lead', 'Remove from rig…', Icons.delete_outline, _noop);
    expect(paletteMatches(c, ''), isTrue);
    expect(paletteMatches(c, 'remove rig'), isTrue);
    expect(paletteMatches(c, 'LEAD remove'), isTrue);
    expect(paletteMatches(c, 'remove inbox'), isFalse);
  });

  testWidgets('⌘⇧P on a selected seat lists exactly the actions the seat sheet has, and one runs', (tester) async {
    final store = await installFakes();
    await pumpDesktop(tester, store);
    final lead = seatFromFixture('r-conveyor', 'lead');
    addTearDown(() => panelShows.value = null);
    panelShows.value = seatPanelKey(lead);

    await _shortcut(tester);
    expect(_palette, findsOneWidget, reason: 'the palette is up');
    final labels = [
      for (final (_, label, _, run) in seatActionRows(tester.element(_palette), 'conveyor', lead,
              onRefresh: () async {})
          .items)
        if (run != null) label,
    ];
    expect(labels, containsAll(['Chat', 'Terminal']));
    for (final l in labels) {
      expect(_in(find.text(l)), findsOneWidget, reason: 'the palette lists $l');
    }
    expect(_in(find.text('Seat · lead')), findsWidgets, reason: 'under the seat\'s heading');
    expect(_in(find.textContaining('Rescan')), findsWidgets, reason: 'then each host\'s list');
    await tester.enterText(_in(find.byType(TextField)), 'inbox'); // the list builds only what is on screen
    await tester.pumpAndSettle();
    expect(_in(find.text('Inbox')), findsOneWidget, reason: 'then where to go');
    await tester.enterText(_in(find.byType(TextField)), '');
    await tester.pumpAndSettle();

    // The same seat's sheet has each of those actions.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_palette, findsNothing, reason: 'Esc closes it');
    final shell = tester.element(find.text('Inbox').first);
    showSeatSheet(shell, 'conveyor', lead);
    await tester.pumpAndSettle();
    for (final l in labels) {
      // The sheet is a long list that builds what is on screen: scroll to each.
      // Down first, then back up: the label may be above what the last one left on screen.
      for (var i = 0; i < 40 && find.textContaining(l).evaluate().isEmpty; i++) {
        await tester.drag(find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable)).first, Offset(0, i < 20 ? -150 : 150));
        await tester.pump();
      }
      expect(find.textContaining(l), findsWidgets, reason: 'the seat sheet has $l too');
    }
    await tester.tapAt(const Offset(10, 10)); // the scrim
    await tester.pumpAndSettle();

    await _shortcut(tester);
    await tester.tap(_in(find.text('Terminal')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TerminalScreen), findsOneWidget, reason: 'the command ran after the palette closed');
    expect(find.text('Add project folder'), findsWidgets, reason: 'it opened in the content panel: the sidebar stays');

    // Kill from the palette ends the session and closes the terminal that was showing it.
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async => cmd.contains('kill-session') ? 'gone\n' : fakeShell(cmd));
    addTearDown(() => SshExec.debugConnect = null);
    await _shortcut(tester);
    await tester.tap(_in(find.text('Kill session…')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kill session').last); // the confirm sheet's button
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byType(TerminalScreen), findsNothing, reason: 'the killed seat\'s screen left the panel');
    expect(find.text('Add project folder'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('⌘⇧P on a loose agent lists its own list: Rename, Restart/Open and a red Kill agent…', (tester) async {
    final store = await installFakes();
    showLoose = true;
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final loose = fleet.feedFor(store.active!).projects.expand((p) => p.loose).first;
    addTearDown(() => panelShows.value = null);
    panelShows.value = seatPanelKey(loose.toSeat());
    await _shortcut(tester);
    expect(_in(find.text('Agent · ${loose.name}')), findsWidgets);
    expect(_in(find.text('Rename')), findsOneWidget);
    expect(_in(find.text('Kill agent…')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('typing narrows the list; with nothing selected it offers the hosts and where to go', (tester) async {
    final store = await installFakes();
    await pumpDesktop(tester, store);
    panelShows.value = null;
    await _shortcut(tester);
    expect(_in(find.text('Hosts and settings')), findsOneWidget);
    expect(_in(find.text('Terminal')), findsNothing, reason: 'no seat is selected');
    final field = _in(find.byType(TextField));
    await tester.enterText(field, 'rescan');
    await tester.pumpAndSettle();
    final rescans = [
      for (final e in _in(find.textContaining('Rescan')).evaluate()) (e.widget as Text).data!,
    ];
    expect(rescans.length, store.hosts.length, reason: 'one per host');
    expect(rescans.toSet().length, rescans.length, reason: 'each named by its host: $rescans');
    for (final h in store.hosts) {
      expect(rescans, contains('Rescan ${h.name}'));
    }
    expect(_in(find.text('Hosts and settings')), findsNothing);
    await tester.enterText(field, 'zzzz');
    await tester.pumpAndSettle();
    expect(_in(find.text('Nothing matches.')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}

void _noop() {}
