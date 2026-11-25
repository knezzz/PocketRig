import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ui/check_row.dart';
import 'package:pocket_rig/ui/theme.dart';
import 'package:pocket_rig/ui/hosts_screen.dart';

import 'golden/fixtures.dart';

void main() {
  testWidgets('host editor at 390: all ten colour swatches (Auto, eight, Custom) sit on one line, each with a 44dp-tall hit area, and SSH user is as tall as the port beside it',
      (tester) async {
    final store = await installFakes();
    tester.view.physicalSize = const Size(390, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    HostEditor.checkOnOpen = false;
    addTearDown(() => HostEditor.checkOnOpen = true);
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: HostEditor(host: homelab))));
    await tester.pump();

    final swatches = find.byWidgetPredicate((w) => w is Semantics && (w.properties.label ?? '').startsWith('Color ') ||
        (w is Semantics && (w.properties.label == 'Automatic color' || w.properties.label == 'Custom colour')));
    expect(swatches, findsNWidgets(10));
    final tops = {for (final e in swatches.evaluate()) tester.getTopLeft(find.byWidget(e.widget)).dy};
    expect(tops.length, 1, reason: 'one line');
    for (final e in swatches.evaluate()) {
      expect(tester.getSize(find.byWidget(e.widget)).height, greaterThanOrEqualTo(44), reason: 'a tall enough tap area');
    }

    double heightOf(String label) =>
        tester.getSize(find.descendant(of: find.ancestor(of: find.text(label), matching: find.byType(Column)).first, matching: find.byType(TextField))).height;
    expect(heightOf('SSH user'), heightOf('SSH port'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a Health row puts its reason on its own second line at 12, muted; a failure stays red', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Material(
            child: Column(children: [
      CheckRow(CheckState.off, 'SSH', detail: 'Needs an SSH key', layout: CheckLayout.tile),
      CheckRow(CheckState.bad, 'Host key', detail: 'refused: the host key changed', layout: CheckLayout.tile),
      CheckRow(CheckState.off, 'Watcher', detail: '—', layout: CheckLayout.tile),
    ]))));
    const k = Tokens.light;
    for (final (label, reason, color) in [('SSH', 'Needs an SSH key', k.muted), ('Host key', 'refused: the host key changed', k.removed)]) {
      final t = tester.widget<Text>(find.text(reason));
      expect(t.style!.fontSize, 12);
      expect(t.style!.color, color);
      expect(tester.getTopLeft(find.text(reason)).dy, greaterThan(tester.getBottomLeft(find.text(label)).dy - 1),
          reason: 'under the label, not beside it');
    }
    expect(find.text('—'), findsNothing, reason: 'no value, no second line');
    expect(tester.getSize(find.text('Watcher')).height + 16, lessThanOrEqualTo(48));
  });
}
