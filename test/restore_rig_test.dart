import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/host_store.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/rig/overview_tab.dart';

import 'golden/fixtures.dart';

void main() {
  late HostStore store;
  Widget overview(Rig rig, {bool busy = false}) => AppScope(
        store: store,
        child: MaterialApp(
          home: Scaffold(
            body: RigBody(
              part: RigPart.seats,
              rig: rig,
              seats: const [],
              queue: const [],
              events: const [],
              busy: busy,
              onRefresh: () async {},
              onOpenSeat: (_) {},
              onSeatMore: (_) {},
            ),
          ),
        ),
      );

  testWidgets('a stopped rig opens on a card that says so, with no button of its own (the green bar is the Restore rig button); a running one has none',
      (tester) async {
    store = await installFakes();
    final stopped =
        Rig.fromJson({'rigId': 'r1', 'name': 'research-team', 'status': 'stopped', 'latestSnapshot': '2d ago'});
    await tester.pumpWidget(overview(stopped));
    expect(find.text('This rig is stopped'), findsOneWidget);
    expect(find.textContaining('snapshot of 2d ago'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing, reason: 'one Restore rig button, in the bar');

    final running = Rig.fromJson({'rigId': 'r2', 'name': 'conveyor', 'status': 'running'});
    await tester.pumpWidget(overview(running));
    expect(find.text('This rig is stopped'), findsNothing);
  });

}
