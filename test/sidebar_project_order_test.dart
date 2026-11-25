import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

void main() {
  testWidgets('sidebar: host > project > its rigs (the ones that need you first), then the agents outside a rig directly '
      'under the project', (tester) async {
    final store = await installFakes();
    showBarRigs = true;
    showLoose = true;
    addTearDown(() => showBarRigs = false);
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('all-idle').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    double y(String t) => tester.getTopLeft(find.text(t).first).dy;
    // 'bars': duo and the six-seat rig need you, solo and the 20-char rig work, all-idle has nothing.
    expect(y('bars'), lessThan(y('duo')));
    expect(y('duo'), lessThan(y('solo')), reason: 'needs you before working');
    expect(y('solo'), lessThan(y('all-idle')), reason: 'working before idle');
    // app: its rigs, then scratch (an agent outside a rig) directly under the project, before the next project.
    expect(y('app'), lessThan(y('conveyor')));
    expect(y('adversarial-review'), lessThan(y('scratch')));
    expect(find.text('Loose agents'.toUpperCase()), findsNothing, reason: 'no group for them: they sit under the project');
    expect(find.text('NEEDS YOU'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
