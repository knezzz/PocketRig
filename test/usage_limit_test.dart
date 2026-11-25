import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/agent_header.dart';
import 'package:pocket_rig/ui/project_tally.dart';
import 'package:pocket_rig/ui/rig/seats_tab.dart' show SeatList, seatTask;
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

Map<String, Object?> node({Map<String, Object?>? limit, String activity = 'unknown'}) => {
      'rigId': 'r',
      'logicalId': 'tests',
      'canonicalSessionName': 'tests@r',
      'runtime': 'claude-code',
      'sessionStatus': 'running',
      'activityState': {
        'activity': activity,
        'display': activity,
        'needsInput': {'count': 0, 'reason': null},
        if (limit != null) 'usageLimit': limit,
      },
    };

void main() {
  final now = DateTime.utc(2026, 11, 25, 12);

  test('OpenRig 0.7.22\'s activityState.usageLimit is parsed; a seat at its limit is neither working nor needs-you', () {
    final s = Seat.fromJson(node(limit: {'rung': 'stop-failure', 'observedAt': '2026-11-25T11:57:00Z', 'resetsAt': '2026-11-25T14:00:00Z'}));
    expect(s.atUsageLimit, isTrue);
    expect(s.usageLimitResetsAt, DateTime.utc(2026, 11, 25, 14));
    expect(s.state, SeatState.idle, reason: 'activity unknown: not working');
    expect(usageLimitLine(s, now), 'at usage limit · resets 2h');
  });

  test('the line without a stated reset, with a passed one, in minutes and days; older daemons have none', () {
    String? line(Object? resetsAt) => usageLimitLine(Seat.fromJson(node(limit: {'rung': 'r', 'observedAt': 'x', 'resetsAt': resetsAt})), now);
    expect(line(null), 'at usage limit', reason: 'the daemon stated no reset');
    expect(line('2026-11-25T11:00:00Z'), 'at usage limit', reason: 'a reset in the past is not shown');
    expect(line('2026-11-25T12:45:00Z'), 'at usage limit · resets 45m');
    expect(line('2026-11-27T13:00:00Z'), 'at usage limit · resets 2d');
    final old = Seat.fromJson(node());
    expect(old.atUsageLimit, isFalse, reason: 'an older daemon never sends the field');
    expect(usageLimitLine(old, now), isNull);
    // A permission prompt outranks it.
    final asking = Seat.fromJson({
      ...node(limit: {'rung': 'r', 'observedAt': 'x', 'resetsAt': null}),
      'arbitratedNeedsInput': true,
    });
    expect(usageLimitLine(asking, now), isNull);
  });

  test('a seat at its limit does not count as working: the folder is not green, the host count leaves it out', () {
    final working = Seat.fromJson(node(activity: 'working'));
    final limited = Seat.fromJson(node(limit: {'rung': 'r', 'observedAt': 'x', 'resetsAt': null}));
    final tally = SeatTally(null, [RigWithSeats(Rig(id: 'r', name: 'r', nodeCount: 1, runningCount: 1, attentionCount: 0, status: 'running'), [limited])], const []);
    expect(tally.working, 0);
    expect(folderColor(Tokens.light, needs: tally.needs, working: tally.working), Tokens.light.muted);
    expect(SeatTally(null, [RigWithSeats(Rig(id: 'r', name: 'r', nodeCount: 1, runningCount: 1, attentionCount: 0, status: 'running'), [working])], const []).working, 1);
  });

  testWidgets('the rig page row and the agent header say it in muted red; the demo seat at its limit shows it on the Agents list', (tester) async {
    final store = await installFakes();
    showUsageLimit = true;
    addTearDown(() => showUsageLimit = false);
    await fleet.feedFor(homelab).refresh();
    final rig = fleet.feedFor(homelab).rigs.firstWhere((r) => r.rig.name == 'conveyor');
    final tests = rig.seats.firstWhere((s) => s.logicalId == 'tests');
    expect(tests.atUsageLimit, isTrue);
    expect(seatTask(tests), startsWith('at usage limit · resets'));
    await tester.pumpWidget(AppScope(
        store: store,
        child: MaterialApp(
            home: Scaffold(
                body: SingleChildScrollView(
                    child: Column(children: [
          SeatList(seats: rig.seats, onOpen: (_) {}, onMore: (_) {}),
          AgentHeader(seat: tests, title: 'tests', subtitle: const Text('meta'), menuTooltip: 'menu', onMenu: () {}),
        ]))))));
    await tester.pump(const Duration(milliseconds: 300));
    final texts = find.textContaining('at usage limit · resets');
    expect(texts, findsNWidgets(2), reason: 'the row and the header');
    for (final t in tester.widgetList<Text>(texts)) {
      expect(t.style?.color, limitColor(Tokens.light), reason: 'muted red');
    }
    expect(find.text('idle'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
