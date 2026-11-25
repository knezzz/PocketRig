import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/subagents.dart';
import 'package:pocket_rig/ui/theme.dart' show animateStatusSpinners;
import 'package:pocket_rig/ui/kit.dart';
import 'package:pocket_rig/ui/project_screen.dart' show ProjectScreen, WorktreeScreen;
import 'package:pocket_rig/ui/status_shape.dart';

import 'golden/fixtures.dart';

void main() {
  setUp(() => animateStatusSpinners = false);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The conveyor row's badge and tally, as drawn.
  /// "needsYou: needsYou 2, working 1, shell 1".
  String conveyor(WidgetTester tester) {
    final row = find.ancestor(of: find.text('conveyor'), matching: find.byType(RowTile)).first;
    final badge = tester.widget<StatusIcon>(find.descendant(of: row, matching: find.byType(StatusIcon))).status;
    final counts = [
      for (final c in tester.widgetList<StatusCount>(find.descendant(of: row, matching: find.byType(StatusCount))))
        (c.status, c.count),
    ];
    return '${badge.name}: ${counts.map((c) => '${c.$1.name} ${c.$2}').join(', ')}';
  }

  testWidgets('a rig shows the same counts and badge on its project and its worktree', (tester) async {
    final store = await installFakes();
    final feed = fleet.feedFor(homelab);

    // conveyor's idle tests seat waits on a subagent: on shell. Only the feed's seats know it.
    feed.subagents = {
      'sess-tests': [Subagent(sessionId: 'sess-tests', agentId: 'a1')],
    };
    await feed.refresh();
    await tester.pumpWidget(MaterialApp(home: phone(store, const ProjectScreen(path: app))));
    await settle(tester);
    await tester.tap(find.text('Agents'));
    await settle(tester);
    // The rig rows follow the flat list of agents.
    await tester.scrollUntilVisible(find.textContaining('RIGS ·'), 200, scrollable: find.byType(Scrollable).first);
    await settle(tester);
    final home = conveyor(tester);
    expect(home, contains('shell 1'), reason: 'the subagent puts tests on shell');

    final project = feed.projects.firstWhere((p) => p.path == app);
    await tester.pumpWidget(
        MaterialApp(home: phone(store, WorktreeScreen.load(host: homelab, project: project, name: null))));
    await settle(tester);
    // The Changes section is above the rigs now: scroll down to them.
    await tester.scrollUntilVisible(find.text('conveyor'), 200, scrollable: find.byType(Scrollable).first);
    expect(conveyor(tester), home, reason: 'the worktree screen');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a rig in a subfolder belongs to the same project on the card and on ProjectScreen', (tester) async {
    // sub-pair runs in app/packages/api: a folder of its own, not app's main checkout or a worktree.
    rigs.add({'rigId': 'r-sub', 'name': 'sub-pair', 'nodeCount': 1, 'runningCount': 1, 'attentionCount': 0,
        'status': 'running', 'uptime': '5m'});
    nodes['r-sub'] = [
      {...nodes['r-conveyor']!.last, 'nodeId': 'n-sub-tests', 'rigId': 'r-sub', 'rigName': 'sub-pair',
          'canonicalSessionName': 'tests@sub-pair', 'cwd': '$app/packages/api'},
    ];
    addTearDown(() {
      rigs.removeLast();
      nodes.remove('r-sub');
    });
    final store = await installFakes();
    final feed = fleet.feedFor(homelab);
    await tester.pumpWidget(MaterialApp(home: phone(store, const ProjectScreen(path: app))));
    await settle(tester);
    final onCard = feed.projects.firstWhere((p) => p.path == app).rigs.any((r) => r.rig.name == 'sub-pair');
    for (final tab in ['Agents', 'Worktrees']) {
      await tester.tap(find.text(tab));
      await settle(tester);
      if (tab == 'Agents') {
        await tester.scrollUntilVisible(find.textContaining('RIGS ·'), 200, scrollable: find.byType(Scrollable).first);
        await settle(tester);
      }
      expect(find.text('sub-pair').evaluate().isNotEmpty, onCard, reason: '$tab tab agrees with the Projects card');
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
