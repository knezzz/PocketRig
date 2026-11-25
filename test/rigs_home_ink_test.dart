import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;
import 'package:pocket_rig/ui/kit.dart' show AgentRow;
import 'package:pocket_rig/ui/rigs_home.dart';

import 'golden/fixtures.dart';

/// A row's ink draws on the nearest Material above it: an opaque box between them (a card's DecoratedBox) hides the ripple.
void main() {
  testWidgets('the Rigs home cards\' rows ripple: no opaque box between a row\'s InkWell and the Material it draws on', (tester) async {
    final store = await installFakes();
    showLoose = true;
    AppShell.debugStartOnInbox = false;
    tester.view.physicalSize = const Size(390, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: phone(store, const RigsHome())));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final inks = find.descendant(of: find.byType(RigsHome), matching: find.descendant(of: find.byType(AgentRow), matching: find.byType(InkWell)));
    expect(inks, findsWidgets);
    final hidden = <String>[];
    for (final e in inks.evaluate()) {
      var opaque = false;
      e.visitAncestorElements((a) {
        final w = a.widget;
        if (w is Material) return false;
        if (w is DecoratedBox && w.decoration is BoxDecoration && ((w.decoration as BoxDecoration).color?.a ?? 0) == 1) opaque = true;
        return true;
      });
      if (opaque) hidden.add('${e.widget.runtimeType}@${tester.getTopLeft(find.byWidget(e.widget)).dy.round()}');
    }
    expect(hidden, isEmpty, reason: 'rows whose ripple is painted under an opaque card');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
