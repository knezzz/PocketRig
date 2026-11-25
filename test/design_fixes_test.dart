import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/agent_jobs.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/common.dart';
import 'package:pocket_rig/ui/kit.dart';
import 'package:pocket_rig/ui/stop_rig.dart';

Seat seat(String id, {String activity = 'idle-at-prompt', bool shell = false, bool stopped = false}) {
  final s = Seat.fromJson({
    'rigId': 'r1',
    'logicalId': id,
    'sessionStatus': stopped ? 'stopped' : 'running',
    'activityState': {'activity': activity},
  });
  if (shell) {
    // A Claude Code Bash shell, as `ps` reports it.
    s.jobs = AgentJob.parse('J\t1\tSs\t00:10\t0.0\t0\t/bin/zsh -c eval \'sleep 99\'\nO\t1\t5\tzzz\n');
  }
  return s;
}

Rig rig() => Rig(id: 'r1', name: 'conveyor', nodeCount: 2, runningCount: 2, attentionCount: 0, status: 'running');

void main() {
  group('last activity is always shown', () {
    test('a dash when unknown, else the age', () {
      expect(agoOrDash(null), '—');
      final now = DateTime(2026, 11, 5, 12);
      expect(agoOrDash(now.subtract(const Duration(minutes: 5)), now), '5m');
    });
    test('a loose agent falls back from the last work to the last hook', () {
      final a = DateTime(2026, 11, 5, 10), b = DateTime(2026, 11, 5, 11);
      expect(LooseAgent(id: 'x').lastActivityAt, isNull);
      expect(LooseAgent(id: 'x', heardAt: a).lastActivityAt, a);
      expect(LooseAgent(id: 'x', activeAt: b, heardAt: a).lastActivityAt, b);
    });
  });

  group('confirm sheet', () {
    Future<void> open(WidgetTester t, Future<Object?> Function(BuildContext) ask, ValueChanged<Object?> done) async {
      await t.pumpWidget(MaterialApp(
        home: Builder(builder: (c) => TextButton(onPressed: () async => done(await ask(c)), child: const Text('go'))),
      ));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
    }

    testWidgets('action returns true, cancel false', (t) async {
      Object? got;
      await open(t, (c) => confirmSheet(c, title: 'Kill x?', action: 'Kill'), (v) => got = v);
      expect(find.text('Kill x?'), findsOneWidget);
      await t.tap(find.text('Kill'));
      await t.pumpAndSettle();
      expect(got, true);
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(got, false);
    });

    testWidgets('stop keeps the snapshot choice', (t) async {
      Object? got = 'unset';
      await open(t, (c) => confirmStopRig(c, rig()), (v) => got = v);
      await t.tap(find.byType(CheckboxListTile));
      await t.pump();
      await t.tap(find.text('Stop rig'));
      await t.pumpAndSettle();
      expect(got, false);
    });
  });
}
