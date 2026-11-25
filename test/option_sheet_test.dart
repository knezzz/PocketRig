import 'dart:ui' show CheckedState;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/option_sheet.dart';

void main() {
  testWidgets('the current row is checked for a screen reader, the others are not, and a tap pops the value', (tester) async {
    final semantics = tester.ensureSemantics();
    String? picked;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => picked = await showModalBottomSheet<String>(
              context: context,
              builder: (_) => const OptionSheet<String>(
                title: 'Effort',
                note: 'How long it thinks',
                current: 'low',
                options: [('low', 'Low', 'Quickest'), ('high', 'High', null)],
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Effort'), findsOneWidget);
    expect(find.text('How long it thinks'), findsOneWidget);
    expect(find.text('Quickest'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget, reason: 'the current one, for the eye');
    final low = tester.getSemantics(find.ancestor(of: find.text('Low'), matching: find.byType(Semantics)).first);
    expect(low.getSemanticsData().flagsCollection.isChecked, isNot(CheckedState.none));
    expect(low.getSemanticsData().flagsCollection.isChecked, CheckedState.isTrue);
    final high = tester.getSemantics(find.ancestor(of: find.text('High'), matching: find.byType(Semantics)).first);
    expect(high.getSemanticsData().flagsCollection.isChecked, CheckedState.isFalse);
    await tester.tap(find.text('High'));
    await tester.pumpAndSettle();
    expect(picked, 'high');
    semantics.dispose();
  });

  testWidgets('wrapped: picking "not set" (null) is an answer, dismissing is not', (tester) async {
    (bool?,)? picked;
    var asked = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              asked = true;
              picked = await showModalBottomSheet<(bool?,)>(
                context: context,
                builder: (_) => const OptionSheet<bool?>(
                  title: 'Switch',
                  current: true,
                  wrap: true,
                  options: [(null, 'Not set', null), (true, 'On', null), (false, 'Off', null)],
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not set'));
    await tester.pumpAndSettle();
    expect(asked, isTrue);
    expect(picked, isNotNull, reason: 'a null pick still comes back');
    expect(picked!.$1, isNull);
    picked = null;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5)); // the barrier
    await tester.pumpAndSettle();
    expect(picked, isNull, reason: 'dismissed: no answer');
  });
}
