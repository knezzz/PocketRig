import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/api/sse.dart';
import 'package:pocket_rig/data/host_store.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/data/git_status.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/rig/graph_layout.dart';
import 'package:pocket_rig/ui/rig/seat_graph.dart';
import 'package:pocket_rig/ui/rig/seats_tab.dart';
import 'package:pocket_rig/ui/rig/overview_tab.dart';
import 'package:pocket_rig/ui/common.dart' show compactCount;
import 'package:pocket_rig/ui/rig/work_queue_screen.dart';
import 'package:pocket_rig/ui/rig_screen.dart' show RigStatusLine;
import 'package:pocket_rig/ui/progress_bar.dart' show ProgressBar;
import 'package:pocket_rig/ui/status_shape.dart' show Status;
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

// Node rows shaped like OpenRig 0.7.6 /api/rigs/:id/nodes.
Map<String, Object?> node(String id,
        {String activity = 'idle-at-prompt', int needs = 0, double? ctx, String status = 'running'}) =>
    {
      'nodeId': 'n-$id',
      'rigId': 'r1',
      'logicalId': id,
      'podId': id == 'lead' ? 'core' : 'build',
      'canonicalSessionName': '$id@conveyor',
      'runtime': 'claude-code',
      'sessionStatus': status,
      'lifecycleState': needs > 0 ? 'attention_required' : 'running',
      'activityState': {
        'activity': activity,
        'display': needs > 0 ? 'needs-input' : activity,
        'needsInput': {'count': needs, 'reason': needs > 0 ? 'Bash: npm test' : null},
      },
      'contextUsage': ctx == null
          ? {'availability': 'unknown', 'usedPercentage': null}
          : {'availability': 'known', 'usedPercentage': ctx},
      'pendingWorkCount': 1,
      'inProgressWorkCount': 1,
    };

Rig rig() => Rig(
    id: 'r1',
    name: 'conveyor',
    nodeCount: 4,
    runningCount: 3,
    attentionCount: 1,
    status: 'running',
    uptime: '2h 5m',
    latestSnapshot: '3m ago');

List<Seat> seats() => [
      Seat.fromJson(node('lead', activity: 'working', ctx: 42)),
      Seat.fromJson(node('impl', needs: 1, ctx: 85.4)),
      Seat.fromJson(node('qa')),
      Seat.fromJson(node('docs', status: 'stopped')),
    ];

void main() {
  group('seat state', () {
    test('needs-input wins, then stopped, working, idle', () {
      final s = seats();
      expect(s.map((x) => x.state), [SeatState.working, SeatState.needsYou, SeatState.idle, SeatState.stopped]);
      expect(s[1].contextUsedPercent, 85.4);
      expect(s[2].contextUsedPercent, isNull);
      expect(s[0].nodeId, 'n-lead');
      expect(s[0].activeWorkCount, 2);
      expect(OverviewTab.tally(s), (3, 1, 1, 1, 0));
    });
  });

  test('topology keeps DB-id edges', () {
    final t = RigTopology.fromJson({
      'rig': {'id': 'r1', 'name': 'conveyor'},
      'nodes': [
        {'id': 'n-lead', 'logicalId': 'lead', 'podId': 'core'},
        {'id': 'n-impl', 'logicalId': 'impl', 'podId': 'build'},
      ],
      'edges': [
        {'id': 'e1', 'sourceId': 'n-lead', 'targetId': 'n-impl', 'kind': 'delegates_to'},
        {'id': 'e2', 'sourceId': 'n-impl', 'targetId': 'boss@other', 'targetRef': 'boss@other', 'kind': 'escalates_to'},
      ],
      'representative': null,
    });
    expect(t.nodes.map((n) => n.logicalId), ['lead', 'impl']);
    expect(t.edges.first.targetId, 'n-impl');
    expect(t.edges.length, 2);
  });

  test('queue items use qitemId, summary and destinationSession', () {
    final q = QueueItem.fromJson({
      'qitemId': 'q-1',
      'state': 'in-progress',
      'priority': 'urgent',
      'destinationSession': 'impl@conveyor',
      'summary': 'Fix the flaky test\nmore detail',
      'tsUpdated': '2026-11-01T10:00:00.000Z',
    });
    expect(q.id, 'q-1');
    expect(q.summary, 'Fix the flaky test');
    expect(q.ownerLogicalId, 'impl');
    expect(q.updated, DateTime.utc(2026, 11, 1, 10));
  });

  test('events parse SQLite UTC times and read as sentences', () {
    final e = RigEvent.fromJson({
      'type': 'node.startup_ready',
      'rigId': 'r1',
      'nodeId': 'n-lead',
      'seq': 42,
      'createdAt': '2026-11-01 09:30:00',
    });
    expect(e.at, DateTime.utc(2026, 11, 1, 9, 30));
    expect(e.describe({'n-lead': 'lead'}), 'lead ready');
    expect(RigEvent.fromJson({'type': 'snapshot.created', 'kind': 'manual'}).describe(), 'Snapshot taken (manual)');
    expect(RigEvent.fromJson({'type': 'bootstrap.completed'}).describe(), 'Launch completed');
  });

  test('SSE parser handles ids, multi-line data, comments and CRLF', () async {
    final frames = await Stream.fromIterable([
      ': hello',
      'id: 7',
      'data: {"type":"a",',
      'data: "seq":7}\r',
      '',
      'event: ping',
      'data: x',
      '',
      'data: tail',
    ]).transform(const SseParser()).toList();
    expect(frames.length, 3);
    expect(frames[0].id, '7');
    expect(frames[0].data, '{"type":"a",\n"seq":7}');
    expect(frames[1].event, 'ping');
    expect(frames[2].data, 'tail');
  });

  group('git status', () {
    const out = '''
@@pocketrig-status
# branch.oid 1234
# branch.head feat/graph
# branch.upstream origin/feat/graph
# branch.ab +2 -1
1 .M N... 100644 100644 100644 a b lib/a.dart
1 M. N... 100644 100644 100644 a b lib/b.dart
? notes.txt
@@pocketrig-numstat
10\t2\tlib/a.dart
3\t0\tlib/b.dart
-\t-\tlogo.png
@@pocketrig-pr
{"number":12,"title":"Graph tab","state":"OPEN","url":"https://github.com/o/r/pull/12","reviewDecision":"APPROVED",
 "statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
 {"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":""},
 {"__typename":"StatusContext","state":"SUCCESS"}]}
''';
    test('branch, ahead/behind, files, line counts and PR', () {
      final g = GitStatus.parse(out);
      expect(g.isRepo, isTrue);
      expect(g.branch, 'feat/graph');
      expect((g.ahead, g.behind), (2, 1));
      expect(g.changedFiles, 3);
      expect((g.added, g.deleted), (13, 2));
      expect(g.changes.last.added, isNull);
      expect(g.pr!.number, 12);
      expect(g.pr!.checks, 'pending');
      expect(g.pr!.checksPassed, 2);
      expect(g.pr!.reviewLabel, 'approved');
    });

    test('no repo, no PR', () {
      expect(GitStatus.parse('').isRepo, isFalse);
      final g = GitStatus.parse('@@pocketrig-status\n# branch.head main\n@@pocketrig-numstat\n@@pocketrig-pr\n');
      expect(g.pr, isNull);
      expect(g.changedFiles, 0);
      expect(PullRequest.parse('no pull requests found'), isNull);
    });
  });

  group('graph layout', () {
    void noOverlaps(GraphLayout l, double width) {
      final rects = l.nodes.values.toList();
      for (var i = 0; i < rects.length; i++) {
        for (var j = i + 1; j < rects.length; j++) {
          expect(rects[i].overlaps(rects[j]), isFalse);
        }
        expect(l.bands.any((b) => b.rect.contains(rects[i].center)), isTrue);
        expect(rects[i].left >= 0 && rects[i].right <= width, isTrue);
      }
    }

    test('parents come first, pods follow delegation and spawning, the hierarchy brackets on the left', () {
      final l = GraphLayout.column([
        GraphNodeIn('tests', 'tests', 'build'),
        GraphNodeIn('helper', 'helper', 'build'),
        GraphNodeIn('impl', 'impl', 'build'),
        GraphNodeIn('lead', 'lead', 'orchestration'),
      ], [
        GraphEdgeIn('lead', 'impl', 'delegates_to'),
        GraphEdgeIn('impl', 'tests', 'delegates_to'),
        GraphEdgeIn('helper', 'impl', 'spawned_by'), // helper is impl's child
        GraphEdgeIn('tests', 'lead', 'escalates_to'),
        GraphEdgeIn('impl', 'tests', 'collaborates_with'),
      ], 358);
      // orchestration first although build was listed first: delegation decides.
      expect(l.bands.map((b) => b.podId), ['orchestration', 'build']);
      expect(l.rows, [
        ['lead'],
        ['impl'],
        ['tests'],
        ['helper'],
      ]);
      final lead = l.nodes['lead']!;
      final left = l.edges.where((e) => e.edge.hierarchical).toList();
      expect(left.map((e) => e.edge.kind).toSet(), {'delegates_to', 'spawned_by'});
      expect(left.every((e) => e.path.getBounds().left < lead.left), isTrue);
      final right = l.edges.where((e) => !e.edge.hierarchical).toList();
      expect(right.every((e) => e.path.getBounds().right > lead.right), isTrue);
      // The escalation enters lead from the right gutter.
      final up = right.singleWhere((e) => e.edge.kind == 'escalates_to');
      expect(up.end, Offset(lead.right, up.end.dy));
      expect(up.endFrom.dx, greaterThan(up.end.dx));
      noOverlaps(l, 358);
    });

    test('overlapping links take separate lanes; cycles terminate', () {
      final many = [for (var i = 0; i < 5; i++) GraphNodeIn('n$i', 'seat$i', 'pod')];
      final l = GraphLayout.column(
          many,
          [
            GraphEdgeIn('n0', 'n1', 'delegates_to'),
            GraphEdgeIn('n1', 'n0', 'delegates_to'),
            GraphEdgeIn('n0', 'n3', 'delegates_to'),
          ],
          358);
      expect(l.rows.expand((r) => r).toSet().length, 5);
      final lanes = {for (final e in l.edges) e.path.getBounds().left};
      expect(lanes.length, 3);
      noOverlaps(l, 358);
    });

    test('arrowheads: both ways for peers, at the child for spawning, else at the target', () {
      const a = (Offset(0, 0), Offset(1, 0)), b = (Offset(9, 0), Offset(10, 0));
      expect(edgeHeads('collaborates_with', a, b), [a, b]);
      expect(edgeHeads('spawned_by', a, b), [a]);
      for (final k in ['delegates_to', 'can_observe', 'escalates_to']) {
        expect(edgeHeads(k, a, b), [b]);
      }
    });
  });

  Widget body(HostStore store, Rig r, List<Seat> s,
          {List<QueueItem> queue = const [],
          List<RigEvent> events = const [],
          GitStatus? git,
          RigTopology? topology,
          bool map = false,
          RigPart part = RigPart.seats,
          void Function(Seat)? onMore}) =>
      AppScope(
        store: store,
        child: MaterialApp(
          home: Scaffold(
            body: RigBody(
              part: map ? RigPart.graph : part,
              rig: r,
              seats: s,
              queue: queue,
              events: events,
              git: git,
              topology: topology,
              onRefresh: () async {},
              onOpenSeat: (_) {},
              onSeatMore: onMore ?? (_) {},
            ),
          ),
        ),
      );

  RigTopology topology(List<Seat> s) => RigTopology.fromJson({
        'nodes': [
          for (final x in s) {'id': x.nodeId, 'logicalId': x.logicalId, 'podId': x.podId},
        ],
        'edges': [
          {'sourceId': 'n-lead', 'targetId': 'n-impl', 'kind': 'delegates_to'},
          {'sourceId': 'n-impl', 'targetId': 'n-qa', 'kind': 'escalates_to'},
        ],
      });

  testWidgets('the rig scroll lists seats by pod, then work, code and activity; the map draws them', (tester) async {
    final store = await installFakes();
    final s = seats();
    Seat? more;
    await tester.pumpWidget(body(
      store,
      rig(),
      s,
      queue: [
        QueueItem(id: 'q', summary: 'Fix flaky test', state: 'in-progress', destinationSession: 'impl@conveyor'),
        QueueItem(id: 'q2', summary: 'Long done', state: 'done', destinationSession: 'impl@conveyor'),
      ],
      events: [
        RigEvent.fromJson({'type': 'node.startup_ready', 'nodeId': 'n-qa', 'seq': 1})
      ],
      git: GitStatus(branch: 'main', changedFiles: 2),
      onMore: (x) => more = x,
    ));
    // Pod strips, rows in the List, the ask in its row.
    expect(find.text('CORE'), findsOneWidget);
    expect(find.text('BUILD'), findsOneWidget);
    expect(find.text('Run npm test?'), findsOneWidget);
    expect(find.text('85%'), findsOneWidget);
    await tester.longPress(find.textContaining('impl', findRichText: true).first);
    expect(more?.logicalId, 'impl');
    await tester.pumpWidget(body(
      store,
      rig(),
      s,
      part: RigPart.seats,
      queue: [
        QueueItem(id: 'q', summary: 'Fix flaky test', state: 'in-progress', destinationSession: 'impl@conveyor'),
        QueueItem(id: 'q2', summary: 'Long done', state: 'done', destinationSession: 'impl@conveyor'),
      ],
      events: [
        RigEvent.fromJson({'type': 'node.startup_ready', 'nodeId': 'n-qa', 'seq': 1})
      ],
      git: GitStatus(branch: 'main', changedFiles: 2),
    ));
    // Work counts open items only.
    expect(find.text('WORK · 1 OPEN'), findsOneWidget);
    expect(find.text('Fix flaky test'), findsOneWidget);
    expect(find.text('Long done'), findsNothing);
    expect(find.text('Queue & handoffs'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('ready', findRichText: true), 200);
    expect(tester.takeException(), isNull);
    // The branch is on the Code tab.
    await tester.pumpWidget(body(store, rig(), s, part: RigPart.code, git: GitStatus(branch: 'main', changedFiles: 2)));
    expect(find.text('main'), findsOneWidget);

    await tester.pumpWidget(body(store, rig(), s, topology: topology(s), map: true));
    expect(find.text('impl'), findsOneWidget);
    expect(find.text('Run npm test?'), findsOneWidget);
    // The legend, one row that wraps (never cut): the four states, the context bar, and only the link kinds this rig uses.
    for (final st in ['needs you', 'working', 'idle', 'stopped']) {
      expect(find.descendant(of: find.byType(GraphLegend), matching: find.text(st)), findsOneWidget, reason: st);
    }
    expect(find.descendant(of: find.byType(GraphLegend), matching: find.byType(SingleChildScrollView)), findsNothing);
    expect(find.byTooltip('More legend'), findsNothing, reason: 'nothing is hidden behind an (i) any more');
    expect(find.text('delegates'), findsOneWidget);
    expect(find.text('escalates'), findsOneWidget);
    expect(find.text('collaborates'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('seat rows and map nodes are tinted in their state color; idle stays neutral', (tester) async {
    final store = await installFakes();
    const k = Tokens.light;
    final want = {
      'lead': statusTint(k, Status.working, k.surface),
      'impl': statusTint(k, Status.needsYou, k.surface),
      'qa': k.surface,
      'docs': statusTint(k, Status.stopped, k.surface),
    };
    expect(want['lead'], isNot(k.surface));
    expect(want['impl'], isNot(want['lead']));
    for (final map in [false, true]) {
      await tester.pumpWidget(body(store, rig(), seats(), map: map));
      for (final MapEntry(key: id, value: color) in want.entries) {
        final item =
            find.ancestor(of: find.textContaining(id, findRichText: true), matching: find.byType(map ? SeatNode : SeatRow));
        final fill =
            tester.widget<Material>(find.descendant(of: item.first, matching: find.byType(Material)).first).color;
        expect(fill, color, reason: '$id in the ${map ? 'map' : 'list'}');
      }
    }
  });

  test('on the light tint the colored status lines are pulled toward the ink; dark is unchanged', () {
    for (final (state, base) in [(SeatState.needsYou, Tokens.light.accent), (SeatState.shell, Tokens.light.shell)]) {
      expect(seatLineColor(Tokens.light, state), Color.lerp(base, Tokens.light.ink, 0.25), reason: '$state light');
    }
    expect(seatLineColor(Tokens.light, SeatState.idle), Tokens.light.muted);
    expect(seatLineColor(Tokens.dark, SeatState.needsYou), Tokens.dark.accent);
    expect(seatLineColor(Tokens.dark, SeatState.shell), Tokens.dark.shell);
  });

  testWidgets('the rig scroll totals tokens and shows the last 3 events until expanded', (tester) async {
    final store = await installFakes();
    Map<String, Object?> withUsage(String id, int tin, int tout, double? cost) => {
          ...node(id),
          'contextUsage': {
            'availability': 'known',
            'usedPercentage': 10,
            'totalInputTokens': tin,
            'totalOutputTokens': tout,
            'clientCostEstimateUsd': cost,
          },
        };
    final s = [
      Seat.fromJson(withUsage('lead', 1200000, 30000, 2.5)),
      Seat.fromJson(withUsage('impl', 50000, 20000, null))
    ];
    expect((s[0].inputTokens, s[0].outputTokens, s[0].costUsd), (1200000, 30000, 2.5));
    expect(OverviewTab.usage(s), (1250000, 50000, 2.5));
    expect([compactCount(950), compactCount(1250), compactCount(50000), compactCount(1300000)],
        ['950', '1.3k', '50k', '1.3M']);

    await tester.pumpWidget(body(store, rig(), s, part: RigPart.seats, events: [
      for (var i = 0; i < 5; i++) RigEvent.fromJson({'type': 'node.startup_ready', 'nodeId': 'n-lead', 'seq': i})
    ]));
    await tester.scrollUntilVisible(find.text('Show all 5'), 200);
    expect(find.textContaining('ready', findRichText: true), findsNWidgets(3));
    await tester.tap(find.text('Show all 5'));
    await tester.pump();
    expect(find.textContaining('ready', findRichText: true), findsNWidgets(5));
    await tester.scrollUntilVisible(find.text('1.3M tokens'), 200);
    expect(find.textContaining('~\$2.50'), findsOneWidget);
  });

  testWidgets('seat rows show a context bar when the daemon reports usage', (tester) async {
    Seat seat(String id, String? model) => Seat.fromJson({...node(id), 'model': model});
    expect(seat('a', 'claude-opus-4-5-20250929').shortModel, 'opus-4-5');
    expect(seat('a', 'gpt-5-codex').shortModel, 'gpt-5-codex');
    expect(seat('a', null).shortModel, isNull);

    Widget list(List<Seat> s) => MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: SeatList(seats: s, onOpen: (_) {}, onMore: (_) {}))),
        );
    await tester.pumpWidget(list([seat('lead', 'claude-opus-4-5-20250929'), seat('impl', null)]));
    // The row no longer carries the model line (the seat sheet and the graph do).
    expect(find.text('opus-4-5'), findsNothing);
    // Neither seat reports context here, so no bar.
    expect(find.byType(ProgressBar), findsNothing);

    await tester.pumpWidget(list(seats()));
    // lead (42%) and impl (85.4%) report context; qa and docs don't.
    expect(find.byType(ProgressBar), findsNWidgets(2));
    expect(find.bySemanticsLabel(RegExp('impl, .*context 85 percent used')), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The map's nodes say the same.
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SingleChildScrollView(child: SeatMap(seats: seats(), onTap: (_) {})))));
    expect(find.byType(ProgressBar), findsNWidgets(2));
    expect(find.bySemanticsLabel(RegExp('impl, .*context 85 percent used')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('open queue items are the ones that can still move', () {
    expect(['pending', 'in-progress', 'blocked'].every(isOpenQueueState), isTrue);
    expect(['done', 'handed-off', 'canceled', 'failed'].any(isOpenQueueState), isFalse);
  });

  testWidgets('rig status reads as text, the status word in its status color', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: RigStatusLine(rig()))));
    final text = tester.widget<RichText>(find.byType(RichText).last).text as TextSpan;
    expect(text.toPlainText(), 'Running · up 2h 5m', reason: 'the header line has no snapshot details');
    expect(OverviewTab.snapshotLine(rig()), 'Snapshot 3m ago');
    final every = Rig.fromJson({
      'rigId': 'r',
      'name': 'x',
      'status': 'running',
      'periodicSnapshotActive': true,
      'periodicSnapshotIntervalSeconds': 900
    });
    expect(OverviewTab.snapshotLine(every), 'No snapshot · auto every 15m');
    TextSpan? status;
    text.visitChildren((span) {
      if (span is TextSpan && span.text == 'Running') status = span;
      return status == null;
    });
    expect(status?.style?.color, Tokens.light.added);
  });

  test('agents are counted without terminal seats', () {
    final s = [...seats(), Seat(rigId: 'r1', logicalId: 'sh', runtime: 'terminal')];
    expect(agentsOf(s).length, 4);
  });
}
