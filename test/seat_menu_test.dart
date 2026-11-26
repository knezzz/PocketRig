import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart' show fleet;
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/rig/seat_actions.dart';

import 'golden/fixtures.dart';

void main() {
  testWidgets('phone: a rig seat\'s ⋯ list has Rig actions…, which is the rig\'s sheet; a loose agent\'s has none', (tester) async {
    final store = await installFakes();
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: phone(store, Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }), root: true)));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.runAsync(() => fleet.feedFor(store.active!).refresh());
    final lead = seatFromFixture('r-conveyor', 'lead');
    final rows = seatMenuRows(ctx, 'conveyor', lead);
    final rig = [for (final r in rows.items) if (r.$2 == 'Rig actions…') r];
    expect(rig, hasLength(1));
    rig.single.$4!();
    await tester.pumpAndSettle();
    for (final t in ['New', 'Message all', 'Room', 'Reminders', 'Rig details']) {
      expect(find.text(t), findsOneWidget, reason: 'the rig sheet has $t');
    }

    final loose = Seat(rigId: '', logicalId: 'scratch', sessionName: 'scratch', runtime: 'claude-code');
    expect([for (final r in seatMenuRows(ctx, 'no rig', loose).items) r.$2], isNot(contains('Rig actions…')));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
