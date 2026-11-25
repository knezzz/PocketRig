import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ui/host_color.dart';
import 'package:pocket_rig/ui/hosts/host_editor.dart';

import 'golden/fixtures.dart';

void main() {
  testWidgets('the Custom swatch opens a picker: the hex field validates, Use colour sets the host colour and the swatch shows it',
      (tester) async {
    final store = await installFakes();
    tester.view.physicalSize = const Size(390, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    HostEditor.checkOnOpen = false;
    addTearDown(() => HostEditor.checkOnOpen = true);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: HostEditor(host: homelab))));
    await tester.pump();

    expect(find.bySemanticsLabel('Custom colour'), findsOneWidget, reason: 'not chosen yet');
    await tester.tap(find.bySemanticsLabel('Custom colour'));
    await tester.pumpAndSettle();
    expect(find.text('Custom colour'), findsOneWidget, reason: 'the picker\'s title');
    final use = find.widgetWithText(FilledButton, 'Use colour');
    final hex = find.descendant(of: find.byType(BottomSheet), matching: find.byType(TextField));
    expect(tester.widget<FilledButton>(use).onPressed, isNotNull);

    // Too short: red note, Use colour off.
    await tester.enterText(hex, 'B458');
    await tester.pump();
    expect(find.text('Use 6 hex digits, like B4581E'), findsOneWidget);
    expect(tester.widget<FilledButton>(use).onPressed, isNull);
    // Pasted with a #, lower case: accepted as 1E88E5.
    await tester.enterText(hex, '#1e88e5');
    await tester.pump();
    expect(find.text('Use 6 hex digits, like B4581E'), findsNothing);
    expect(tester.widget<TextField>(hex).controller!.text, '1E88E5');
    expect(tester.widget<FilledButton>(use).onPressed, isNotNull);

    await tester.tap(use);
    await tester.pumpAndSettle();
    expect(find.text('Custom colour'), findsNothing, reason: 'the picker closed');
    expect(find.bySemanticsLabel('Custom colour, selected'), findsOneWidget, reason: 'the swatch now holds and selects it');

    // Cancel leaves the colour alone.
    await tester.tap(find.bySemanticsLabel('Custom colour, selected'));
    await tester.pumpAndSettle();
    await tester.enterText(hex, 'FF0000');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Custom colour, selected'), findsOneWidget);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    expect(hostColor(homelab), isNotNull);
  });
}
