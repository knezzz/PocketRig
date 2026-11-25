import 'dart:math';
import 'dart:ui';

/// A node to place: its id, logical id and pod.
class GraphNodeIn {
  GraphNodeIn(this.id, this.logicalId, this.podId);
  final String id;
  final String logicalId;
  final String podId;
}

/// An edge between two node ids, with OpenRig's kind (`delegates_to`, …).
class GraphEdgeIn {
  GraphEdgeIn(this.from, this.to, this.kind);
  final String from;
  final String to;
  final String kind;

  /// The team's hierarchy, drawn on the left: delegation and spawning.
  /// Collaboration, observation and escalation go on the right.
  bool get hierarchical => kind == 'delegates_to' || kind == 'spawned_by';

  /// (parent, child) of a hierarchy edge. `spawned_by` runs child → parent.
  (String, String) get down => kind == 'spawned_by' ? (to, from) : (from, to);
}

class PodBand {
  PodBand(this.podId, this.rect);
  final String podId;
  final Rect rect;
}

/// A routed edge: its path, and its ends with a point just outside each,
/// for an arrowhead's direction.
class GraphEdgeOut {
  GraphEdgeOut(this.edge, this.path, this.start, this.startFrom, this.end, this.endFrom);
  final GraphEdgeIn edge;
  final Path path;

  /// Where the path leaves [GraphEdgeIn.from], on its side.
  final Offset start;
  final Offset startFrom;

  /// Where the path enters [GraphEdgeIn.to], on its side.
  final Offset end;
  final Offset endFrom;
}

/// The Seats view: one full-width node per seat inside its pod's band, each
/// link a bracket in a side gutter.
///
/// * pods are ordered so delegation and spawning flow downward;
/// * inside a pod, parents come before their children (BFS depth), ties in
///   the order the rig lists its seats;
/// * the hierarchy is bracketed on the left, every other link on the right,
///   shortest spans innermost.
class GraphLayout {
  GraphLayout({required this.nodes, required this.bands, required this.edges, required this.size, required this.rows});
  final Map<String, Rect> nodes;
  final List<PodBand> bands;
  final List<GraphEdgeOut> edges;
  final Size size;

  /// Node ids per row, top to bottom (for tests and accessibility order).
  final List<List<String>> rows;

  static const header = 28.0;
  static const bandPad = 12.0;
  static const bandGap = 16.0;
  static const colH = 92.0;
  static const colSpace = 10.0;
  static const laneGap = 7.0;

  /// The pods in order (delegation flows downward), the seats inside each by depth, and the links that join two listed seats.
  static ({List<GraphEdgeIn> edges, Map<String, String> podOf, List<String> podOrder, List<String> order, Map<String, int> at})
      _arrange(List<GraphNodeIn> input, List<GraphEdgeIn> allEdges) {
    final ids = {for (final n in input) n.id};
    final edges = [
      for (final e in allEdges)
        if (ids.contains(e.from) && ids.contains(e.to) && e.from != e.to) e
    ];
    final podOf = {for (final n in input) n.id: n.podId};
    final listed = {for (var i = 0; i < input.length; i++) input[i].id: i};
    final down = [for (final e in edges.where((e) => e.hierarchical)) e.down];

    // 1. Pod order: Kahn over the pod graph, ties broken by first
    //    appearance; cycles fall back to appearance order.
    final pods = <String>[];
    for (final n in input) {
      if (!pods.contains(n.podId)) pods.add(n.podId);
    }
    final podIn = {for (final p in pods) p: <String>{}};
    for (final (a, b) in down) {
      if (podOf[a] != podOf[b]) podIn[podOf[b]]!.add(podOf[a]!);
    }
    final podOrder = <String>[];
    while (podOrder.length < pods.length) {
      final ready = pods.where((p) => !podOrder.contains(p) && podIn[p]!.every(podOrder.contains)).toList();
      podOrder.add(ready.isNotEmpty ? ready.first : pods.firstWhere((p) => !podOrder.contains(p)));
    }

    // 2. Inside a pod: BFS depth from the seats nothing in the pod points down to.
    final rank = <String, int>{};
    final order = <String>[];
    for (final p in podOrder) {
      final members = input.where((n) => n.podId == p).map((n) => n.id).toList();
      final children = <String, List<String>>{};
      final incoming = <String>{};
      for (final (a, b) in down.where((d) => podOf[d.$1] == p && podOf[d.$2] == p)) {
        children.putIfAbsent(a, () => []).add(b);
        incoming.add(b);
      }
      final queue = members.where((m) => !incoming.contains(m)).toList();
      if (queue.isEmpty && members.isNotEmpty) queue.add(members.first);
      for (final q in queue) {
        rank[q] = 0;
      }
      for (var i = 0; i < queue.length; i++) {
        for (final next in children[queue[i]] ?? const <String>[]) {
          if (rank.containsKey(next)) continue;
          rank[next] = rank[queue[i]]! + 1;
          queue.add(next);
        }
      }
      order.addAll(members
        ..sort((a, b) {
          final r = (rank[a] ?? 0).compareTo(rank[b] ?? 0);
          return r != 0 ? r : listed[a]!.compareTo(listed[b]!);
        }));
    }
    final at = {for (var i = 0; i < order.length; i++) order[i]: i};
    return (edges: edges, podOf: podOf, podOrder: podOrder, order: order, at: at);
  }

  /// The old lane routing. With [cardMax], a seat's card is never wider than that: the layout is made again narrower by
  /// the excess (the lane gutters stay), so a wide page does not stretch the cards and their context bars.
  static GraphLayout column(List<GraphNodeIn> input, List<GraphEdgeIn> allEdges, double width, {double? cardMax}) {
    final first = _column(input, allEdges, width);
    if (cardMax == null) return first;
    final widest = first.nodes.values.fold(0.0, (w, r) => max(w, r.width));
    return widest > cardMax ? _column(input, allEdges, width - (widest - cardMax)) : first;
  }

  static GraphLayout _column(List<GraphNodeIn> input, List<GraphEdgeIn> allEdges, double width) {
    final (:edges, :podOf, :podOrder, :order, :at) = _arrange(input, allEdges);

    // 3. Lanes per side: shortest spans innermost, overlapping spans apart.
    final lane = <GraphEdgeIn, int>{};
    final lanes = {true: 0, false: 0}; // left? → lane count
    for (final left in const [true, false]) {
      final side = edges.where((e) => e.hierarchical == left).toList()
        ..sort((a, b) => (at[a.from]! - at[a.to]!).abs().compareTo((at[b.from]! - at[b.to]!).abs()));
      final taken = <int, List<(int, int)>>{};
      for (final e in side) {
        final lo = min(at[e.from]!, at[e.to]!), hi = max(at[e.from]!, at[e.to]!);
        var k = 0;
        while (taken[k]?.any((s) => s.$1 <= hi && lo <= s.$2) ?? false) {
          k++;
        }
        (taken[k] ??= []).add((lo, hi));
        lane[e] = k;
        lanes[left] = max(lanes[left]!, k + 1);
      }
    }
    // More than three lanes on a side get 9dp between them instead of 7: five side by side were tight.
    double gapFor(bool left) => lanes[left]! > 3 ? 9.0 : laneGap;
    double gutterFor(bool left) => lanes[left]! == 0 ? 0 : 8 + lanes[left]! * gapFor(left);
    final l = gutterFor(true), r = width - gutterFor(false);

    // 4. Place the bands and their seats.
    final rects = <String, Rect>{};
    final bands = <PodBand>[];
    var y = 0.0;
    for (final p in podOrder) {
      var rowY = y + header;
      for (final id in order.where((id) => podOf[id] == p)) {
        rects[id] = Rect.fromLTWH(l + bandPad, rowY, r - l - 2 * bandPad, colH);
        rowY += colH + colSpace;
      }
      final bottom = rowY - colSpace + bandPad;
      bands.add(PodBand(p, Rect.fromLTRB(l, y, r, bottom)));
      y = bottom + bandGap;
    }

    // 5. Ports: a node's links on one side spread down that side, ordered by
    //    where the other end sits so brackets don't cross at the node.
    final ports = <(String, bool), List<(GraphEdgeIn, String)>>{};
    for (final e in edges) {
      ports.putIfAbsent((e.from, e.hierarchical), () => []).add((e, e.to));
      ports.putIfAbsent((e.to, e.hierarchical), () => []).add((e, e.from));
    }
    double portY(String id, GraphEdgeIn e, bool left) {
      final list = ports[(id, left)]!..sort((a, b) => at[a.$2]!.compareTo(at[b.$2]!));
      final i = list.indexWhere((p) => p.$1 == e);
      final rect = rects[id]!;
      return rect.top + rect.height * (i + 1) / (list.length + 1);
    }

    final routed = <GraphEdgeOut>[];
    for (final e in edges) {
      final left = e.hierarchical;
      final a = rects[e.from]!, b = rects[e.to]!;
      final out = left ? -1.0 : 1.0; // towards the gutter
      final x = left ? l - 6 - lane[e]! * gapFor(true) : r + 6 + lane[e]! * gapFor(false);
      final p0 = Offset(left ? a.left : a.right, portY(e.from, e, left));
      final p1 = Offset(left ? b.left : b.right, portY(e.to, e, left));
      final dy = p1.dy > p0.dy ? 1.0 : -1.0;
      const c = 6.0;
      final path = Path()
        ..moveTo(p0.dx, p0.dy)
        ..lineTo(x - out * c, p0.dy)
        ..quadraticBezierTo(x, p0.dy, x, p0.dy + dy * c)
        ..lineTo(x, p1.dy - dy * c)
        ..quadraticBezierTo(x, p1.dy, x - out * c, p1.dy)
        ..lineTo(p1.dx, p1.dy);
      routed.add(GraphEdgeOut(e, path, p0, Offset(p0.dx + out * 6, p0.dy), p1, Offset(p1.dx + out * 6, p1.dy)));
    }
    return GraphLayout(nodes: rects, bands: bands, edges: routed, size: Size(width, max(0, y - bandGap)), rows: [
      for (final id in order) [id]
    ]);
  }

  // ---- Swimlanes (a wide page): a pod is a horizontal band, its cards side by side ----
  static const laneCardH = 92.0;
  /// (card width, gap between cards), tried widest first: the cards narrow before the page runs out.
  static const _laneSizes = [(260.0, 72.0), (230.0, 56.0), (210.0, 44.0)];
  static const _chanMin = 32.0;

  /// The widest page the swimlanes need for [input]: the widest pod's row of cards plus the side margins the links take.
  /// Narrower than that, use [column].
  static GraphLayout? swimlanes(List<GraphNodeIn> input, List<GraphEdgeIn> allEdges, double width) {
    for (final (w, g) in _laneSizes) {
      final l = _swim(input, allEdges, width, w, g);
      if (l != null) return l;
    }
    return null;
  }

  static GraphLayout? _swim(List<GraphNodeIn> input, List<GraphEdgeIn> allEdges, double width, double laneCardW, double laneCardGap) {
    final (:edges, :podOf, :podOrder, :order, :at) = _arrange(input, allEdges);
    if (input.isEmpty) return null;
    final bi = {for (final (i, p) in podOrder.indexed) p: i};
    final members = [for (final p in podOrder) [for (final id in order) if (podOf[id] == p) id]];
    final ci = {for (final m in members) for (final (i, id) in m.indexed) id: i};
    String band(String id) => podOf[id]!;
    final widest = members.map((m) => m.length).reduce(max);
    final bandW = widest * laneCardW + (widest - 1) * laneCardGap + 2 * bandPad;

    // Which lane each link takes: a channel between two bands, the strip under a band's cards, or a side margin.
    final kind = <GraphEdgeIn, String>{}; // side | under | down | up
    final chan = <int, List<GraphEdgeIn>>{};
    final under = <int, List<GraphEdgeIn>>{};
    final marginL = <GraphEdgeIn>[], marginR = <GraphEdgeIn>[];
    final c1 = <GraphEdgeIn, int>{}, c2 = <GraphEdgeIn, int>{};
    for (final e in edges) {
      final a = bi[band(e.from)]!, b = bi[band(e.to)]!;
      if (a == b) {
        if ((ci[e.from]! - ci[e.to]!).abs() == 1) {
          kind[e] = 'side';
        } else {
          kind[e] = 'under';
          (under[a] ??= []).add(e);
        }
        continue;
      }
      final down = a < b;
      kind[e] = down ? 'down' : 'up';
      c1[e] = down ? a : a - 1;
      c2[e] = down ? b - 1 : b;
      (chan[c1[e]!] ??= []).add(e);
      if (c2[e] != c1[e]) {
        (chan[c2[e]!] ??= []).add(e);
        (e.hierarchical ? marginL : marginR).add(e);
      }
    }
    double marginW(List<GraphEdgeIn> m) => m.isEmpty ? 0 : 14 + m.length * laneGap;
    final mL = marginW(marginL), mR = marginW(marginR);
    final total = mL + bandW + mR;
    if (total > width) return null;
    final x0 = mL;
    double chanH(int c) => max(_chanMin, 16 + (chan[c]?.length ?? 0) * laneGap);
    double underH(int b) => under[b] == null ? 0 : 18 + under[b]!.length * laneGap;

    // Place the bands and cards, top to bottom.
    final rects = <String, Rect>{};
    final bands = <PodBand>[];
    final chanTop = <int, double>{}, underTop = <int, double>{};
    var y = 0.0;
    for (final (b, m) in members.indexed) {
      final top = y;
      for (final (i, id) in m.indexed) {
        rects[id] = Rect.fromLTWH(x0 + bandPad + i * (laneCardW + laneCardGap), top + header, laneCardW, laneCardH);
      }
      underTop[b] = top + header + laneCardH;
      final bottom = top + header + laneCardH + underH(b) + bandPad;
      bands.add(PodBand(podOrder[b], Rect.fromLTRB(x0, top, x0 + bandW, bottom)));
      chanTop[b] = bottom;
      y = bottom + (b < members.length - 1 ? chanH(b) : 0);
    }
    double chanY(int c, GraphEdgeIn e) {
      final list = chan[c]!, n = list.length;
      return chanTop[c]! + (chanH(c) - (n - 1) * laneGap) / 2 + list.indexOf(e) * laneGap;
    }

    // Ports: the links on one edge of a card, spread along it by where their other end is, so their lines never share one.
    final ports = <(String, String), List<GraphEdgeIn>>{}; // (card, top|bottom|pair:<key>) → links
    String sideOf(GraphEdgeIn e, String id) {
      final isFrom = e.from == id;
      return switch (kind[e]!) {
        'under' => 'bottom',
        'down' => isFrom ? 'bottom' : 'top',
        'up' => isFrom ? 'top' : 'bottom',
        _ => 'pair:${min(ci[e.from]!, ci[e.to]!)}',
      };
    }
    for (final e in edges) {
      for (final id in [e.from, e.to]) {
        (ports[(id, sideOf(e, id))] ??= []).add(e);
      }
    }
    double centerX(String id) => rects[id]!.center.dx;
    String other(GraphEdgeIn e, String id) => e.from == id ? e.to : e.from;
    double portFrac(String id, GraphEdgeIn e) {
      final list = ports[(id, sideOf(e, id))]!..sort((p, q) => centerX(other(p, id)).compareTo(centerX(other(q, id))));
      return (list.indexOf(e) + 1) / (list.length + 1);
    }
    // Along a top or bottom edge, clear of the pod's name at the band's top left.
    double portX(String id, GraphEdgeIn e) {
      final r = rects[id]!;
      final lo = r.left + 100, hi = r.right - 16;
      return lo + (hi - lo) * portFrac(id, e);
    }

    Path rounded(List<Offset> pts) {
      const c = 6.0;
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var i = 1; i < pts.length - 1; i++) {
        final a = pts[i - 1], b = pts[i], d = pts[i + 1];
        final r1 = min(c, (b - a).distance / 2), r2 = min(c, (d - b).distance / 2);
        final p1 = b + (a - b) / (b - a).distance * r1, p2 = b + (d - b) / (d - b).distance * r2;
        path
          ..lineTo(p1.dx, p1.dy)
          ..quadraticBezierTo(b.dx, b.dy, p2.dx, p2.dy);
      }
      path.lineTo(pts.last.dx, pts.last.dy);
      return path;
    }

    Offset toward(Offset from, Offset to) => from + (to - from) / (to - from).distance * 6;
    final routed = <GraphEdgeOut>[];
    for (final e in edges) {
      final a = rects[e.from]!, b = rects[e.to]!;
      final List<Offset> pts;
      switch (kind[e]!) {
        case 'side':
          final f = portFrac(e.from, e);
          final py = a.top + a.height * f;
          final right = ci[e.from]! < ci[e.to]!;
          pts = [Offset(right ? a.right : a.left, py), Offset(right ? b.left : b.right, py)];
        case 'under':
          final ly = underTop[bi[band(e.from)]!]! + 14 + under[bi[band(e.from)]!]!.indexOf(e) * laneGap;
          final sx = portX(e.from, e), tx = portX(e.to, e);
          pts = [Offset(sx, a.bottom), Offset(sx, ly), Offset(tx, ly), Offset(tx, b.bottom)];
        default:
          final down = kind[e] == 'down';
          final sx = portX(e.from, e), tx = portX(e.to, e);
          final sy = down ? a.bottom : a.top, ty = down ? b.top : b.bottom;
          final l1 = chanY(c1[e]!, e);
          if (c1[e] == c2[e]) {
            pts = [Offset(sx, sy), Offset(sx, l1), Offset(tx, l1), Offset(tx, ty)];
          } else {
            final l2 = chanY(c2[e]!, e);
            final mx = e.hierarchical
                ? x0 - 10 - marginL.indexOf(e) * laneGap
                : x0 + bandW + 10 + marginR.indexOf(e) * laneGap;
            pts = [Offset(sx, sy), Offset(sx, l1), Offset(mx, l1), Offset(mx, l2), Offset(tx, l2), Offset(tx, ty)];
          }
      }
      routed.add(GraphEdgeOut(e, rounded(pts), pts.first, toward(pts.first, pts[1]), pts.last, toward(pts.last, pts[pts.length - 2])));
    }
    return GraphLayout(nodes: rects, bands: bands, edges: routed, size: Size(total, y), rows: [for (final id in order) [id]]);
  }
}
