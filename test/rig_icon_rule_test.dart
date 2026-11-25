import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/project_tally.dart' show rigIconColor;
import 'package:pocket_rig/ui/status_shape.dart';
import 'package:pocket_rig/ui/theme.dart';

/// One rule for the rig icon's colour, used by the sidebar, the Rigs home card and the rig page.
void main() {
  const k = Tokens.light;
  Seat seat(String id, {String activity = 'idle', String? startup, int subagents = 0}) => Seat.fromJson({
        'rigId': 'r',
        'logicalId': id,
        'canonicalSessionName': '$id@r',
        'runtime': 'claude-code',
        'sessionStatus': 'running',
        if (startup != null) 'startupStatus': startup,
        'activityState': {'activity': activity, 'display': activity, 'needsInput': {'count': 0, 'reason': null}},
      })..waitingSubagents = subagents;
  RigWithSeats rig(List<Seat> seats, {String status = 'running'}) =>
      RigWithSeats(Rig(id: 'r', name: 'r', nodeCount: seats.length, runningCount: seats.length, attentionCount: 0, status: status), seats);

  test('needs you / working / shell / idle / stopped, and a failed launch is red over all of them', () {
    expect(rigIconColor(k, rig([seat('a', activity: 'working')]), null), Status.working.color(k));
    expect(rigIconColor(k, rig([seat('a', subagents: 1)]), null), Status.shell.color(k), reason: 'only on a shell: cyan, on every surface');
    expect(rigIconColor(k, rig([seat('a')]), null), k.muted);
    expect(rigIconColor(k, rig([seat('a', activity: 'working')], status: 'stopped'), null), k.muted, reason: 'stopped');
    expect(rigIconColor(k, rig([seat('a', activity: 'working'), seat('b', startup: 'failed')]), null), k.removed, reason: 'a failed launch is red');
  });
}
