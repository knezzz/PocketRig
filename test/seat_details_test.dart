import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/agent_details.dart';
import 'package:pocket_rig/ui/progress_bar.dart' show ContextBar;

import 'golden/fixtures.dart';

void main() {
  testWidgets('seat details: a waiting seat\'s Status says the state, not the request again; Context is a row with its bar under it',
      (tester) async {
    final store = await installFakes();
    final lead = seatFromFixture('r-conveyor', 'lead'); // waits on a permission, 62% context
    await tester.pumpWidget(MaterialApp(
        home: phone(
            store,
            SeatDetailsScreen(details: AgentDetails(seat: lead, jobs: const []), rigName: 'conveyor', onJobs: () {}),
            root: true)));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('lead wants to run'), findsOneWidget, reason: 'the card says what it wants');
    expect(find.textContaining('Run npm run test:integration?'), findsNothing, reason: 'Status does not say it again');
    expect(find.text('needs you'), findsOneWidget, reason: 'Status is the state');

    final label = tester.getTopLeft(find.text('Context')), value = tester.getTopLeft(find.text('62%'));
    expect(value.dy, closeTo(label.dy, 3), reason: 'its value is on the row, to the right, like the other rows');
    expect(value.dx, greaterThan(label.dx));
    expect(tester.getTopLeft(find.byType(ContextBar)).dy, greaterThan(label.dy), reason: 'the bar is under the row');
    final item = find.ancestor(of: find.byType(ContextBar), matching: find.byType(Column)).first;
    expect(find.descendant(of: item, matching: find.text('Context')), findsOneWidget,
        reason: 'the bar and its row are one list item: no divider between them');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
