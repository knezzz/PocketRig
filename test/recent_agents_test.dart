import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/project_tally.dart';
import 'package:pocket_rig/ui/rigs_home.dart' show seatVisible;

void main() {
  test('a seat\'s level is its depth in the delegation hierarchy; spawned_by runs child to parent', () {
    final t = RigTopology(nodes: [
      TopoNode(id: '1', logicalId: 'orch.lead'),
      TopoNode(id: '2', logicalId: 'dev.lead'),
      TopoNode(id: '3', logicalId: 'dev.impl'),
      TopoNode(id: '4', logicalId: 'dev.helper'),
      TopoNode(id: '5', logicalId: 'qa.check'),
    ], edges: [
      TopoEdge('1', '2', 'delegates_to'),
      TopoEdge('2', '3', 'delegates_to'),
      TopoEdge('4', '3', 'spawned_by'),
      TopoEdge('5', '1', 'collaborates_with'), // not hierarchy
    ]);
    expect(t.levels, {'orch.lead': 0, 'dev.lead': 1, 'dev.impl': 2, 'dev.helper': 3, 'qa.check': 0});
  });

  test('an agent outside a rig stays listed for 10 minutes after it went idle, the same window as a rig\'s seats', () {
    final now = DateTime.now();
    LooseAgent idle(Duration ago) => LooseAgent(id: 'a', activeAt: now.subtract(ago));
    expect(looseRecent(null, idle(const Duration(minutes: 9)), now), isTrue);
    expect(looseRecent(null, idle(const Duration(minutes: 11)), now), isFalse);
    Seat seat(Duration ago) => Seat(rigId: 'r', logicalId: 'a', runtime: 'claude-code', sessionName: 'a@r', activity: 'idle-at-prompt', lastActivityAt: now.subtract(ago));
    expect(seatVisible(seat(const Duration(minutes: 9)), now), isTrue);
    expect(seatVisible(seat(const Duration(minutes: 11)), now), isFalse);
    expect(idleWindow, const Duration(minutes: 10));
  });

  test('last active is the agent\'s last reply or hook event, not a pane redraw', () {
    Seat seat(Map<String, Object?> extra) => Seat.fromJson({
          'rigId': 'r',
          'logicalId': 'check.qa',
          'lastActivityAt': '2026-11-13T08:32:26.000Z', // a client attached: every idle pane redrew
          'agentActivity': {'state': 'idle'},
          ...extra,
        })..level = 0;
    final idle = seat({
      'modelObservation': {'observedAt': '2026-11-12T16:45:31.498Z'},
    });
    expect(idle.lastActivityAt, DateTime.utc(2026, 11, 12, 16, 45, 31, 498));
    final hooked = seat({
      'modelObservation': {'observedAt': '2026-11-12T16:45:31.498Z'},
      'agentActivity': {'state': 'idle', 'eventAt': '2026-11-13T08:10:00.000Z'},
    });
    expect(hooked.lastActivityAt, DateTime.utc(2026, 11, 13, 8, 10));
    expect(seat({}).lastActivityAt, isNull, reason: 'no evidence of work: no time');
    expect(Seat.fromJson({'rigId': 'r', 'logicalId': 'x', 'lastActivityAt': '2026-11-13T08:32:26Z'}).lastActivityAt,
        isNotNull, reason: 'an older daemon reports only the pane');
  });
}
