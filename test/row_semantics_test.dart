import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/kit.dart' show AgentRow;
import 'package:pocket_rig/ui/rigs_home.dart' show seatRowLabel;
import 'package:pocket_rig/ui/status_shape.dart';

void main() {
  test('a home row says "read only" for a seat with no session, and not for one with a session', () {
    Seat seat(String? session) =>
        Seat(rigId: 'r', logicalId: 'impl', runtime: 'claude-code', sessionName: session, activity: 'working');
    expect(seatRowLabel(seat(null)), endsWith(', read only'));
    expect(seatRowLabel(seat('impl@r')), isNot(contains('read only')));
  });

  testWidgets('an AgentRow with actions announces what its long press does', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AgentRow(name: 'impl', status: Status.working, onTap: () {}, onMore: () {}, moreTooltip: 'impl details', openLabel: 'impl'),
      ),
    ));
    final node = tester.getSemantics(find.bySemanticsLabel('impl'));
    expect(node.hintOverrides?.onLongPressHint, 'impl details', reason: 'the long press has a name');
    handle.dispose();
  });
}
