import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/project_tally.dart';
import 'package:pocket_rig/ui/rigs_home.dart' show HostActiveCount;

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

/// 'Active' is one rule: needs you, working, or waiting on a shell (structured questions add to the counts).
void main() {
  test('Fleet.stateActive: needs you, working and on a shell are active; idle and stopped are not', () {
    expect([for (final s in SeatState.values) Fleet.stateActive(s)],
        [for (final s in SeatState.values) s == SeatState.needsYou || s == SeatState.working || s == SeatState.shell]);
    expect(Fleet.stateActive(SeatState.shell), isTrue);
    expect(Fleet.stateActive(SeatState.idle), isFalse);
  });

  testWidgets('the folded host count is one number, the same in the sidebar and on the Rigs home, and an agent on a shell is in it', (tester) async {
    final store = await installFakes();
    await pumpDesktop(tester, store);
    final feed = fleet.feedFor(homelab);
    final shellSeat = Seat.fromJson({
      'rigId': 'rs',
      'logicalId': 'sh',
      'canonicalSessionName': 'sh@rs',
      'runtime': 'claude-code',
      'sessionStatus': 'running',
      'cwd': '/w/shellproj',
      'activityState': {'activity': 'idle-at-prompt', 'display': 'idle', 'needsInput': {'count': 0, 'reason': null}},
    })..waitingSubagents = 1; // waiting on a background task: SeatState.shell
    expect(shellSeat.state, SeatState.shell);
    final before = hostActiveCounts(homelab).active;
    feed.rigs = [...feed.rigs, RigWithSeats(Rig(id: 'rs', name: 'shellrig', nodeCount: 1, runningCount: 1, attentionCount: 0, status: 'running'), [shellSeat])];
    // ignore: invalid_use_of_protected_member
    feed.notifyListeners();
    await tester.pump(const Duration(milliseconds: 300));
    expect(hostActiveCounts(homelab).active, before + 1, reason: 'the agent on a shell counts');
    // Folded: the sidebar header and the Rigs home's show the same text through the same widget.
    fleet.toggleHost(homelab.id);
    await tester.pump(const Duration(milliseconds: 300));
    final texts = find.descendant(of: find.byType(HostActiveCount), matching: find.byType(Text));
    expect(texts, findsWidgets);
    for (final e in texts.evaluate()) {
      expect((e.widget as Text).data, '${before + 1}');
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
