import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/rig_screen.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

void main() {
  setUp(() => animateStatusSpinners = false);

  testWidgets('renaming a rig shows the new name and keeps the real one in the overline', (tester) async {
    final store = await installFakes();
    await tester.pumpWidget(MaterialApp(home: phone(store, RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app'))));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tester.tap(find.byTooltip('Rig options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename label'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Billing');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(store.active!.rigNames, {'conveyor': 'Billing'});
    expect(find.text('Billing'), findsOneWidget);
    expect(find.textContaining('app · conveyor'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
