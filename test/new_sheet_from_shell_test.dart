import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

void main() {
  testWidgets('from the sidebar +, the Mac dialog\'s Location and Worktree menus open on a click', (tester) async {
    final store = await installFakes();
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
    addTearDown(() => SshExec.debugConnect = null);
    await pumpDesktop(tester, store);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final sidebar = find.byKey(const ValueKey('sidebar'));
    await tester.tap(find.descendant(of: sidebar, matching: find.byTooltip('New…')));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    // A click in the middle of the Location field (not on a tooltip).
    final field = find.ancestor(of: find.text('~/code/app'), matching: find.byType(Container)).first;
    await tester.tapAt(tester.getCenter(field));
    await tester.pumpAndSettle();
    expect(find.text('Type a path…'), findsOneWidget, reason: 'the Location menu opened');
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    final wt = find.ancestor(of: find.textContaining('main checkout'), matching: find.byType(Container)).first;
    await tester.tapAt(tester.getCenter(wt));
    await tester.pumpAndSettle();
    expect(find.text('New worktree…'), findsOneWidget, reason: 'the Worktree menu opened');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
