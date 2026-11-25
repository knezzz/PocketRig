import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/kit.dart' show seatLabel;
import 'package:pocket_rig/ui/rigs_home.dart' show seatRowLabel;

/// One wording for a seat's state: seatLabel.
void main() {
  Seat seat({String activity = 'unknown', bool limit = false, int subagents = 0}) => Seat.fromJson({
        'rigId': 'r',
        'logicalId': 'tests',
        'canonicalSessionName': 'tests@r',
        'runtime': 'claude-code',
        'sessionStatus': 'running',
        'activityState': {
          'activity': activity,
          'display': activity,
          'needsInput': {'count': 0, 'reason': null},
          if (limit) 'usageLimit': {'rung': 'r', 'observedAt': 'x'},
        },
      })..waitingSubagents = subagents;

  test('a seat at its usage limit reads "at usage limit" in every label (the screen reader\'s too); other seats keep their state\'s words', () {
    expect(seatLabel(seat(limit: true)), 'at usage limit');
    expect(seatLabel(seat(limit: true, subagents: 1)), 'at usage limit', reason: 'not on subagents');
    expect(seatRowLabel(seat(limit: true)), startsWith('tests, at usage limit'), reason: 'the Rigs home\'s screen-reader label said idle');
    expect(seatLabel(seat()), isNot('at usage limit'));
    expect(seatLabel(seat(subagents: 1)), 'on subagents');
    expect(seatLabel(seat(activity: 'working')), seatLabel(seat(activity: 'working', subagents: 1)), reason: 'working wins over on-shell');
  });
}
