import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;
import 'package:pocket_rig/ui/hosts/host_editor.dart';
import 'package:pocket_rig/ui/rigs_home.dart';

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

void main() {
  testWidgets('the sidebar host header long-press list and the Rigs home host header open that host editor', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    HostEditor.checkOnOpen = false;
    addTearDown(() => HostEditor.checkOnOpen = true);
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('HOMELAB').evaluate().length < 2; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final sidebar = find.ancestor(of: find.text('Add project folder').first, matching: find.byType(ListView));
    await tester.longPress(find.descendant(of: sidebar, matching: find.text('HOMELAB')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Edit host'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<HostEditor>(find.byType(HostEditor)).host, homelab, reason: 'the sidebar header opens homelab\'s editor');

    // Back to the home, and the host header there does the same.
    await tester.tap(find.text('Rigs').first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(RigsHome), findsOneWidget);
    final macHeader = find.descendant(of: find.byType(RigsHome), matching: find.text('MACBOOK'));
    final list = find.descendant(of: find.byType(RigsHome), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(macHeader, 200, scrollable: list);
    // It stops at the viewport's edge, where a tap misses: bring it well inside.
    await tester.drag(list, const Offset(0, -120));
    await tester.pump();
    await tester.tap(macHeader);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<HostEditor>(find.byType(HostEditor)).host, macbook);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
