
import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/rig/graph_layout.dart';
import 'package:pocket_rig/ui/rig/seat_graph.dart' show EdgeInk, EdgesPainter, SeatGraph, arrowSize, edgeVariants, paintEdge;
import 'package:pocket_rig/ui/rig/seats_tab.dart' show graphCardMax;

void main() {
  // Five seats in three pods, every link kind, links that skip a seat (a → e) and that run back up (e → a).
  final input = [
    GraphNodeIn('a', 'lead', 'orchestration'),
    GraphNodeIn('b', 'impl', 'build'),
    GraphNodeIn('c', 'review', 'build'),
    GraphNodeIn('d', 'tests', 'check'),
    GraphNodeIn('e', 'docs', 'check'),
  ];
  final edges = [
    GraphEdgeIn('a', 'b', 'delegates_to'),
    GraphEdgeIn('a', 'e', 'delegates_to'),
    GraphEdgeIn('b', 'c', 'collaborates_with'),
    GraphEdgeIn('c', 'd', 'can_observe'),
    GraphEdgeIn('e', 'a', 'escalates_to'),
    GraphEdgeIn('d', 'b', 'spawned_by'),
  ];
  const widths = [390.0, 800.0, 1280.0];

  test('a card is never wider than 280 at any page width; the page width only moves the lanes', () {
    for (final w in widths) {
      final l = GraphLayout.column(input, edges, w, cardMax: graphCardMax);
      expect(l.nodes.values.every((r) => r.width <= graphCardMax + 0.01), isTrue, reason: 'width $w');
      expect(l.size.width, lessThanOrEqualTo(w), reason: 'the graph fits the page at $w');
    }
  });

  test('every link runs from the edge of its source card to the edge of its target card', () {
    for (final w in widths) {
      final l = GraphLayout.column(input, edges, w, cardMax: graphCardMax);
      for (final e in l.edges) {
        for (final (id, p) in [(e.edge.from, e.start), (e.edge.to, e.end)]) {
          final r = l.nodes[id]!;
          final onSide = (p.dx - r.left).abs() < 1 || (p.dx - r.right).abs() < 1;
          expect(onSide && p.dy >= r.top && p.dy <= r.bottom, isTrue, reason: '${e.edge.kind} $id at $w: $p vs $r');
        }
      }
    }
  });

  test('no link passes under a card that is not one of its ends', () {
    for (final w in widths) {
      final l = GraphLayout.column(input, edges, w, cardMax: graphCardMax);
      for (final e in l.edges) {
        for (final m in e.path.computeMetrics()) {
          for (var d = 0.0; d <= m.length; d += 3) {
            final p = m.getTangentForOffset(d)!.position;
            for (final MapEntry(key: id, value: r) in l.nodes.entries) {
              if (id == e.edge.from || id == e.edge.to) continue;
              expect(r.deflate(1).contains(p), isFalse, reason: '${e.edge.from}→${e.edge.to} crosses $id at $w');
            }
          }
        }
      }
    }
  });

  test('two links never share a lane: on one side, links whose spans overlap run at different x', () {
    for (final w in widths) {
      final l = GraphLayout.column(input, edges, w, cardMax: graphCardMax);
      for (var i = 0; i < l.edges.length; i++) {
        for (var j = i + 1; j < l.edges.length; j++) {
          final a = l.edges[i], b = l.edges[j];
          if (a.edge.hierarchical != b.edge.hierarchical) continue; // the other side
          final ab = a.path.getBounds(), bb = b.path.getBounds();
          final overlap = ab.top < bb.bottom && bb.top < ab.bottom;
          if (!overlap) continue;
          final ax = a.edge.hierarchical ? ab.left : ab.right, bx = b.edge.hierarchical ? bb.left : bb.right;
          expect((ax - bx).abs(), greaterThan(1), reason: '${a.edge.kind} and ${b.edge.kind} share a lane at $w');
        }
      }
    }
  });

  group('swimlanes (a wide page): the same acceptance, links may leave a card by any side', () {
    const wide = [1280.0, 1600.0, 2200.0];
    // Four seats in one pod need 1.4k: at 1280 the column takes over.
    List<double> widthsFor(List<GraphNodeIn> n) => n.length > 5 ? [1600.0, 2200.0] : wide;
    final many = [
      ...input,
      GraphNodeIn('f', 'ops', 'build'),
      GraphNodeIn('g', 'qa', 'build'),
      GraphNodeIn('h', 'sec', 'check'),
    ];
    final manyEdges = [...edges, GraphEdgeIn('b', 'g', 'collaborates_with'), GraphEdgeIn('f', 'b', 'delegates_to'), GraphEdgeIn('a', 'h', 'can_observe'), GraphEdgeIn('h', 'c', 'escalates_to')];
    final cases = [(input, edges), (many, manyEdges)];

    test('pods are bands stacked top to bottom, their cards side by side and inside the band; the graph fits and is no wider than the page', () {
      for (final (n, e) in cases) {
        for (final w in widthsFor(n)) {
          final l = GraphLayout.swimlanes(n, e, w)!;
          expect(l.size.width, lessThanOrEqualTo(w));
          for (final b in l.bands) {
            final inBand = [for (final nd in n) if (nd.podId == b.podId) l.nodes[nd.id]!];
            expect(inBand.every((r) => b.rect.contains(r.topLeft) && b.rect.contains(r.bottomRight)), isTrue, reason: b.podId);
            expect(inBand.map((r) => r.top).toSet().length, 1, reason: 'one row of cards per band');
          }
          for (var i = 1; i < l.bands.length; i++) {
            expect(l.bands[i].rect.top, greaterThan(l.bands[i - 1].rect.bottom));
          }
        }
      }
    });

    test('too narrow: no swimlanes (the column takes over)', () {
      expect(GraphLayout.swimlanes(many, manyEdges, 600), isNull);
    });

    test('every link runs from the edge of its source card to the edge of its target card', () {
      for (final (n, e) in cases) {
        for (final w in widthsFor(n)) {
          for (final o in GraphLayout.swimlanes(n, e, w)!.edges) {
            final l = GraphLayout.swimlanes(n, e, w)!;
            for (final (id, p) in [(o.edge.from, o.start), (o.edge.to, o.end)]) {
              final r = l.nodes[id]!;
              final onEdge = ((p.dx - r.left).abs() < 1 || (p.dx - r.right).abs() < 1) && p.dy >= r.top - 1 && p.dy <= r.bottom + 1 ||
                  ((p.dy - r.top).abs() < 1 || (p.dy - r.bottom).abs() < 1) && p.dx >= r.left - 1 && p.dx <= r.right + 1;
              expect(onEdge, isTrue, reason: '${o.edge.kind} $id at $w: $p vs $r');
            }
          }
        }
      }
    });

    test('no link passes under a card that is not one of its ends, and no two links share a lane', () {
      for (final (n, e) in cases) {
        for (final w in widthsFor(n)) {
          final l = GraphLayout.swimlanes(n, e, w)!;
          final samples = [
            for (final o in l.edges)
              [
                for (final m in o.path.computeMetrics())
                  for (var d = 0.0; d <= m.length; d += 1) m.getTangentForOffset(d)!.position
              ]
          ];
          for (final (i, o) in l.edges.indexed) {
            for (final p in samples[i]) {
              for (final MapEntry(key: id, value: r) in l.nodes.entries) {
                if (id == o.edge.from || id == o.edge.to) continue;
                expect(r.deflate(1).contains(p), isFalse, reason: '${o.edge.from}→${o.edge.to} crosses $id at $w');
              }
            }
            for (var j = i + 1; j < samples.length; j++) {
              // Lines may cross at a right angle (a point or two), never run together.
              var run = 0, longest = 0; // along the line, so two crossings do not add up
              for (final p in samples[i]) {
                run = samples[j].any((q) => (p - q).distance < 1.5) ? run + 1 : 0;
                longest = max(longest, run);
              }
              expect(longest, lessThan(6), reason: '${o.edge.from}→${o.edge.to} and ${l.edges[j].edge.from}→${l.edges[j].edge.to} share a lane at $w');
            }
          }
        }
      }
    });
  });

  test('every kind has an arrowhead of at least 8dp, so its direction reads', () {
    for (final k in ['collaborates_with', 'delegates_to', 'can_observe', 'escalates_to', 'spawned_by', 'anything_else']) {
      expect(arrowSize(k), greaterThanOrEqualTo(8), reason: k);
    }
  });

  test('a kind with no look of its own gets one by its place among the others, so two in one graph differ', () {
    final v = edgeVariants(['hands_off_to', 'reviewed_by', 'delegates_to', 'collaborates_with', 'hands_off_to']);
    expect(v.keys, unorderedEquals(['hands_off_to', 'reviewed_by']), reason: 'the five that have their own look are not in it');
    expect(v['hands_off_to'], isNot(v['reviewed_by']));
    expect(edgeVariants(['reviewed_by', 'hands_off_to']), v, reason: 'the same whatever order the rig lists them in');
  });

  testWidgets('the rig graph draws its pod bands solid (dashes are for links); a stopped seat stays dashed', (tester) async {
    final layout = GraphLayout.column(input, edges, 390, cardMax: graphCardMax);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SeatGraph(layout: layout, names: const {}, byId: const {}, onTap: (_) {}, solidBands: true))));
    final painter = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((c) => c.painter).whereType<EdgesPainter>().single;
    expect(painter.solid, isTrue);
  });

  test('with more than three lanes on a side the lanes are 9dp apart (7 otherwise)', () {
    final many = [for (var i = 0; i < 6; i++) GraphNodeIn('n$i', 'seat$i', 'pod')];
    // Five collaborations that all overlap in span: five right-hand lanes.
    final links = [for (var i = 1; i <= 5; i++) GraphEdgeIn('n0', 'n$i', 'collaborates_with')];
    GraphLayout layoutOf(List<GraphEdgeIn> e) => GraphLayout.column(many, e, 390, cardMax: graphCardMax);
    List<double> lanesX(GraphLayout l) => ([for (final e in l.edges) e.path.getBounds().right]..sort());
    final five = lanesX(layoutOf(links)).toSet().toList()..sort();
    expect(five.length, 5);
    for (var i = 1; i < five.length; i++) {
      expect(five[i] - five[i - 1], closeTo(9, 0.01), reason: 'five lanes: 9dp apart');
    }
    final three = lanesX(layoutOf(links.take(3).toList())).toSet().toList()..sort();
    for (var i = 1; i < three.length; i++) {
      expect(three[i] - three[i - 1], closeTo(7, 0.01), reason: 'three lanes: 7dp apart');
    }
  });

  testWidgets('a spawned link, and its arrowhead, are the blue one', (tester) async {
    final ink = EdgeInk(line: const Color(0xFF888888), ground: const Color(0xFFFFFFFF), spawned: const Color(0xFF2F6DB5));
    expect(ink.spawned, isNot(ink.line));
    await tester.pumpWidget(CustomPaint(
        size: const Size(100, 40), painter: _Spawned(ink)));
    expect(tester.renderObject(find.byType(CustomPaint)),
        paints..path(color: const Color(0xFF2F6DB5))..path(color: const Color(0xFF2F6DB5)));
  });
}

class _Spawned extends CustomPainter {
  _Spawned(this.ink);
  final EdgeInk ink;
  @override
  void paint(Canvas canvas, Size size) => paintEdge(
      canvas, Path()..moveTo(0, 20)..lineTo(80, 20), 'spawned_by', ink, [(const Offset(60, 20), const Offset(80, 20))]);
  @override
  bool shouldRepaint(_Spawned old) => false;
}
