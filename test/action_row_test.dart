import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/main.dart' show AppScope, navigatorKey;
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/kit.dart';
import 'package:pocket_rig/ui/project_screen.dart';
import 'package:pocket_rig/ui/terminal_screen.dart' show TerminalScreen;
import 'package:pocket_rig/ui/theme.dart' show animateStatusSpinners;

import 'golden/fixtures.dart';

/// A daemon action item in ProjectScreen's Needs you opens the seat that asked, as the Inbox card does; with no
/// asker there is nobody to open, so its row has no Answer and no tap.
void main() {
  setUp(() => animateStatusSpinners = false);

  Future<void> open(WidgetTester tester) async {
    final store = await installFakes();
    extraAttention = [
      // A seat in the feed, a rig that's gone, and one that names only the folder.
      {'id': 'a1', 'kind': 'action', 'summary': 'Approve the release', 'asker': 'tests@conveyor', 'project': {'root': app}},
      {'id': 'a2', 'kind': 'action', 'summary': 'Check the old rig', 'asker': 'ghost@gone-rig', 'project': {'root': app}},
      {'id': 'a3', 'kind': 'action', 'summary': 'Pick a branch', 'project': {'root': app}},
    ];
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
    addTearDown(() => SshExec.debugConnect = null);
    await tester.pumpWidget(AppScope(
        store: store,
        child: MaterialApp(navigatorKey: navigatorKey, home: phone(store, const ProjectScreen(path: app)))));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  RowTile row(String detail) => find.ancestor(of: find.text(detail), matching: find.byType(RowTile)).evaluate().first.widget
      as RowTile;
  Finder rowFinder(String detail) => find.ancestor(of: find.text(detail), matching: find.byType(RowTile)).first;

  testWidgets('an item with an asker has Answer and opens the asker; one without has neither', (tester) async {
    await open(tester);
    expect(find.descendant(of: rowFinder('Approve the release'), matching: find.text('Answer')), findsOneWidget);
    expect(find.descendant(of: rowFinder('Check the old rig'), matching: find.text('Answer')), findsOneWidget,
        reason: 'a rig that is gone still opens its terminal, as the Inbox card does');
    expect(row('Pick a branch').onTap, isNull, reason: 'no asker, nobody to open');
    expect(find.descendant(of: rowFinder('Pick a branch'), matching: find.text('Answer')), findsNothing);

    await tester.tap(find.descendant(of: rowFinder('Approve the release'), matching: find.text('Answer')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ChatScreen).evaluate().isNotEmpty || find.byType(TerminalScreen).evaluate().isNotEmpty, isTrue,
        reason: 'the seat opens');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
