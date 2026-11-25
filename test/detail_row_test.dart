import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/agent_jobs.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/detail_row.dart';

Widget _in(Widget w) => MaterialApp(home: Scaffold(body: SizedBox(width: 360, child: w)));

void main() {
  testWidgets('a fact row: the label in one fixed column, the value beside it, 40 tall; no tap, no chevron', (tester) async {
    await tester.pumpWidget(_in(const DetailRow('Status', Text('idle'))));
    expect(tester.getSize(find.text('Status')).width, lessThanOrEqualTo(DetailRow.labelWidth));
    final label = tester.getTopLeft(find.text('Status')), value = tester.getTopLeft(find.text('idle'));
    expect(value.dx - label.dx, DetailRow.labelWidth);
    expect(tester.getSize(find.byType(DetailRow)).height, 40);
    expect(find.byIcon(Icons.north_east), findsNothing);
  });

  testWidgets('the content sits at the vertical centre of the row, 40 and 48 alike', (tester) async {
    for (final onTap in <VoidCallback?>[null, () {}]) {
      await tester.pumpWidget(_in(DetailRow('Status', const Text('idle'), onTap: onTap)));
      final row = tester.getRect(find.byType(DetailRow));
      for (final t in ['Status', 'idle']) {
        expect(tester.getCenter(find.text(t)).dy, closeTo(row.center.dy, 0.6), reason: '$t in a ${row.height} row');
      }
    }
  });

  testWidgets('a tappable row is 48 tall, taps once and shows › ; external shows ↗', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_in(DetailRow('Task', const Text('ship it'), onTap: () => taps++)));
    expect(tester.getSize(find.byType(DetailRow)).height, 48);
    await tester.tap(find.text('ship it'));
    expect(taps, 1);
    await tester.pumpWidget(_in(DetailRow('Open', null, icon: Icons.terminal, external: true, onTap: () {})));
    expect(find.byIcon(Icons.north_east), findsOneWidget);
    expect(find.text('Open'), findsOneWidget, reason: 'an action row is its label alone');
  });

  group('one rule for "waiting, not idle" (the seat sheet and the details card)', () {
    Seat seat({String? activity, bool asks = false, String status = 'running'}) => Seat(
        rigId: 'r', logicalId: 'x', sessionName: 'x@r', runtime: 'claude-code', rawSessionStatus: status, activity: activity, needsInput: asks);

    test('idle with shells or idle subagents: waiting', () {
      expect(AgentJob.seatWaiting(seat(), jobs: 1, subagents: 0), (waiting: true, idleSubs: 0));
      expect(AgentJob.seatWaiting(seat(), jobs: 0, subagents: 2), (waiting: true, idleSubs: 2));
    });
    test('working is working, whatever it left running', () {
      expect(AgentJob.seatWaiting(seat(activity: 'working'), jobs: 3, subagents: 2), (waiting: false, idleSubs: 0));
    });
    test('nothing running, or asking, or stopped: not waiting', () {
      expect(AgentJob.seatWaiting(seat(), jobs: 0, subagents: 0).waiting, isFalse);
      expect(AgentJob.seatWaiting(seat(asks: true), jobs: 1, subagents: 1).waiting, isFalse);
      expect(AgentJob.seatWaiting(seat(status: 'stopped'), jobs: 1, subagents: 1).waiting, isFalse);
    });
  });
}
