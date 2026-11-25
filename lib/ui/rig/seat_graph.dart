import '../progress_bar.dart' show ContextBar;
import '../usage_strip.dart' show contextColor, contextWeight;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OrdinalSortKey;

import '../../models.dart';
import '../common.dart' show ago, agoPhrase, minuteTick;
import '../kit.dart';
import '../status_shape.dart';
import '../theme.dart';
import 'graph_layout.dart';
import 'seats_tab.dart' show seatLine, seatSettings;

/// The nodes to place: the topology's, else one per seat.
List<GraphNodeIn> graphInput(List<Seat> seats, RigTopology? topo) {
  final byId = {for (final s in seats) s.nodeId ?? s.logicalId: s};
  return [
    if (topo != null && topo.nodes.isNotEmpty)
      for (final n in topo.nodes) GraphNodeIn(n.id, n.logicalId, byId[n.id]?.podLabel ?? n.podId ?? 'seats')
    else
      for (final s in seats) GraphNodeIn(s.nodeId ?? s.logicalId, s.logicalId, s.podLabel ?? 'seats'),
  ];
}

/// The seats drawn: pod bands, each link in its kind's grey line, and a
/// [SeatNode] per seat at the spots [layout] gives.
class SeatGraph extends StatelessWidget {
  const SeatGraph({
    super.key,
    required this.layout,
    required this.names,
    required this.byId,
    required this.onTap,
    this.onLongPress,
    this.modes = const {},
    this.lines = const {},
    this.solid = false,
    this.solidBands = false,
    this.onEdge,
  });

  /// Pod bands as a solid hairline (the rig's graph); dashes are for links only. [solid] does the bands and the seats.
  final bool solidBands;
  final GraphLayout layout;
  final Map<String, String> names;
  final Map<String, Seat> byId;
  final void Function(String id) onTap;

  /// Only offered for nodes with a live seat.
  final void Function(String id)? onLongPress;

  /// Replaces a node's status line, e.g. a spec member's role before launch.
  final Map<String, String> lines;

  /// Permission mode by session name (or logical id), once loaded.
  final Map<String, String?> modes;

  /// Pods and seats drawn with solid outlines, not dashed (a spec's, which is not "stopped").
  final bool solid;

  /// A tap on a link (not on a seat): the link nearest to it.
  final ValueChanged<GraphEdgeIn>? onEdge;

  /// The link whose line passes within [slop] of [p], else null.
  GraphEdgeIn? _edgeAt(Offset p, {double slop = 16}) {
    GraphEdgeIn? best;
    var bestD = slop;
    for (final e in layout.edges) {
      for (final m in e.path.computeMetrics()) {
        for (var d = 0.0; d <= m.length; d += 4) {
          final t = m.getTangentForOffset(d);
          if (t != null && (t.position - p).distance < bestD) {
            bestD = (t.position - p).distance;
            best = e.edge;
          }
        }
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return SizedBox(
      width: layout.size.width,
      height: layout.size.height,
      child: Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: onEdge == null
                ? null
                : (d) {
                    final e = _edgeAt(d.localPosition);
                    if (e != null) onEdge!(e);
                  },
            child: CustomPaint(
            painter: EdgesPainter(
              layout: layout,
              ink: EdgeInk.of(context),
              solid: solid || solidBands,
              band: k.faint,
              podLabel: TextStyle(
                  fontFamily: fontMono, fontSize: 10, fontWeight: FontWeight.w500, letterSpacing: 0.6, color: k.muted),
            ),
          ),
          ),
        ),
        for (final (i, id) in [for (final row in layout.rows) ...row].indexed)
          Positioned.fromRect(
            rect: layout.nodes[id]!,
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.2,
              child: Semantics(
                sortKey: OrdinalSortKey(i.toDouble()),
                child: SeatNode(
                  label: names[id] ?? '?',
                  seat: byId[id],
                  mode: byId[id] == null ? null : modes[byId[id]!.sessionName ?? byId[id]!.logicalId],
                  status: lines[id],
                  solid: solid,
                  onTap: () => onTap(id),
                  onLongPress: byId[id] == null || onLongPress == null ? null : () => onLongPress!(id),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// A seat as a map node, four lines on a grey card: its state's shape and
/// name (with its worktree, or its runtime when it isn't Claude), what it's
/// doing or asking, "model · mode · last active", and its context bar with
/// the percent. The whole card is tinted by its state (needs you accent, working green, idle neutral, stopped muted and
/// dashed) with a 1.5dp border for the first two; the shape and status words stay.
class SeatNode extends StatelessWidget {
  const SeatNode({
    super.key,
    required this.label,
    required this.seat,
    this.mode,
    this.status,
    this.onTap,
    this.onLongPress,
    this.solid = false,
  });
  final String label;
  final Seat? seat;

  /// A stopped seat with a solid outline, not dashed.
  final bool solid;
  final String? mode;

  /// Shown instead of what the seat is doing.
  final String? status;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final seat = this.seat;
    final state = seat?.state ?? SeatState.stopped;
    final shape = Status.of(state);
    final radius = BorderRadius.circular(kRadius);
    final starting = seat?.notReady ?? false;
    final ctx = starting ? null : seat?.contextUsedPercent;
    final agent = seat?.isAgent ?? false;
    final extra = seatExtra(seat);
    final line = status ?? (seat == null ? null : seatLine(seat));
    final atLimit = seat != null && usageLimitLine(seat) != null;
    final lineColor = status != null ? k.muted : (atLimit ? limitColor(k) : seatLineColor(k, state));
    Widget text(String t, TextStyle style) =>
        Text(t, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: style);
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child:
          Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          // An agent: its runtime's logo in the state colour, as on every row; anything else keeps the state shape.
          if (agent)
            StatusIcon.agent(shape, runtime: seat!.runtime, compact: true)
          else
            StatusShape(shape, size: 10, semantics: false),
          SizedBox(width: agent ? 6 : 8),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: label, style: TextStyle(color: k.ink, fontWeight: FontWeight.w600, fontSize: 14)),
                if (extra != null)
                  TextSpan(text: '  $extra', style: TextStyle(fontFamily: fontMono, fontSize: 10, color: k.muted)),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: const TextStyle(height: 1.25),
            ),
          ),
        ]),
        if (line != null)
          text(
              line,
              TextStyle(
                  color: lineColor,
                  fontSize: 12,
                  height: 1.35,
                  fontWeight: state == SeatState.needsYou && status == null ? FontWeight.w500 : null)),
        if (seat != null && (agent || seat.lastActivityAt != null))
          // The settings ellipsize; the time doesn't.
          Row(children: [
            if (agent)
              Flexible(
                child: text(seatSettings(seat, mode),
                    TextStyle(fontFamily: fontMono, color: k.muted, fontSize: 10, height: 1.4)),
              ),
            if (_lastActive(seat) case final at?)
              ListenableBuilder(
                listenable: minuteTick,
                builder: (context, _) => Text('${agent ? ' · ' : ''}$at',
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(fontFamily: fontMono, color: k.muted, fontSize: 10, height: 1.4)),
              ),
          ]),
        if (ctx != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              Expanded(child: ContextBar(ctx, height: 3, base: k.muted, label: false)),
              const SizedBox(width: 8),
              Text('${ctx.round()}%',
                  style: TextStyle(
                      fontFamily: fontMono,
                      fontSize: 10,
                      color: contextColor(ctx, k),
                      fontWeight: contextWeight(ctx))),
            ]),
          ),
      ]),
    );
    final needs = state == SeatState.needsYou;
    return Opacity(
      opacity: starting ? 0.55 : 1,
      child: Semantics(
      button: true,
      label: '$label, ${agent ? '${RuntimeGlyph.label(seat!.runtime)}, ' : ''}'
          '${seat?.model != null ? '${seat!.model}, ' : ''}${status ?? (seat == null ? labelFor(state) : seatLabel(seat))}'
          '${ctx != null ? ', context ${ctx.round()} percent used' : ''}',
      onTap: onTap,
      onLongPress: onLongPress,
      onLongPressHint: 'seat actions',
      excludeSemantics: true,
      child: Material(
        color: statusTint(k, shape, k.surface),
        shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: state == SeatState.stopped && !solid
                ? BorderSide.none
                : BorderSide(
                    color: needs
                        ? k.accent
                        : state == SeatState.working
                            ? shape.color(k)
                            : k.border,
                    width: needs || state == SeatState.working ? 1.5 : 1)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTap: onLongPress,
          child: state == SeatState.stopped && !solid
              ? CustomPaint(painter: DashedBorder(k.faint, radius: kRadius), child: content)
              : content,
        ),
      ),
    ));
  }

  /// "asked 2m" while it waits on you, else when it last did something ("12s ago", "just now").
  static String? _lastActive(Seat seat) => seat.state == SeatState.needsYou && seat.waitingSince != null
      ? 'asked ${ago(seat.waitingSince)}'
      : seat.lastActivityAt == null
          ? null
          : agoPhrase(seat.lastActivityAt!);
}

/// What follows a seat's name: its worktree, else its runtime when it isn't
/// Claude Code ("codex"), else nothing.
String? seatExtra(Seat? seat) {
  if (seat == null) return null;
  if (worktreeName(seat.cwd) case final w?) return w;
  if (seat.runtime == null || seat.isClaude) return null;
  return seat.runtime;
}

/// The whole seat item in its state's color: [base] with the state's [Status.color] washed over it, light enough
/// that the ink and muted text on it keep their contrast in light and dark. Idle is left neutral.
Color statusTint(Tokens k, Status st, Color base) =>
    st == Status.idle ? base : Color.alphaBlend(st.color(k).withValues(alpha: 0.14), base);

/// The status line's color: the accent while it asks, cyan on a shell, grey otherwise. On the light theme's tint
/// the colored ones are pulled a quarter toward the ink, to keep their contrast (about 6:1).
Color seatLineColor(Tokens k, SeatState state) {
  final c = switch (state) {
    SeatState.needsYou => k.accent,
    SeatState.shell => k.shell,
    _ => k.muted,
  };
  return k.isDark || c == k.muted ? c : Color.lerp(c, k.ink, 0.25)!;
}

/// The color links are drawn in: grey only, so color stays with state. The
/// kinds differ by line style.
class EdgeInk {
  EdgeInk({required this.line, required this.ground, Color? spawned}) : spawned = spawned ?? line;
  final Color line;

  /// A spawned-by link is the one blue one (the shell icon's blue: a kind, never a state).
  final Color spawned;

  /// Down the middle of the escalation's double line.
  final Color ground;

  factory EdgeInk.of(BuildContext context) {
    final k = Tokens.of(context);
    // The dark ground swallows the muted grey: the lanes there are halfway to the ink.
    return EdgeInk(line: k.isDark ? Color.lerp(k.muted, k.ink, .45)! : k.muted, ground: k.ground, spawned: k.terminal);
  }
}

/// How each link kind reads, for the legend: the arrow points at the
/// second seat ("lead delegates to impl").
String edgeLegend(String kind) => switch (kind) {
      'collaborates_with' => 'collaborates',
      'delegates_to' => 'delegates',
      'can_observe' => 'observes',
      'escalates_to' => 'escalates',
      'spawned_by' => 'spawned',
      final k => k.replaceAll('_', ' '),
    };

const _knownKinds = {'collaborates_with', 'delegates_to', 'can_observe', 'escalates_to', 'spawned_by'};

/// Which look each link kind a rig uses gets beyond the five that have their own: its place among the others, sorted, so two
/// kinds in one graph (and its legend) never share a look. 0 solid, 1 long dashes, 2 dash and dot; more wrap round.
Map<String, int> edgeVariants(Iterable<String> kinds) {
  final others = ({...kinds}..removeAll(_knownKinds)).toList()..sort();
  return {for (final (i, k) in others.indexed) k: i};
}

/// An arrowhead's length for [kind]: never under 8dp, so its direction reads at 1x.
double arrowSize(String kind) => kind == 'collaborates_with' ? 10 : 8;

/// Draws [path] in [kind]'s grey line with arrowheads at [heads] (from → tip):
///
/// * collaborates_with: thick, both ways;
/// * delegates_to: dashed, at the seat doing the work;
/// * can_observe: dotted, at the seat being observed;
/// * escalates_to: a double line;
/// * spawned_by: thin, at the spawned seat.
void paintEdge(Canvas canvas, Path path, String kind, EdgeInk ink, List<(Offset, Offset)> heads, {int variant = 0}) {
  Paint stroke(Color c, double w) => Paint()
    ..color = c
    ..strokeWidth = w
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  final size = arrowSize(kind);
  switch (kind) {
    case 'collaborates_with':
      canvas.drawPath(path, stroke(ink.line, 2.8));
    case 'delegates_to':
      DashedLine.draw(canvas, path, stroke(ink.line, 1.5)..strokeCap = StrokeCap.butt, dash: 5, gap: 3);
    case 'can_observe':
      DashedLine.draw(canvas, path, stroke(ink.line, 2), dash: 0.01, gap: 4);
    case 'escalates_to':
      // Two lines: a wide stroke with the ground drawn down its middle.
      canvas
        ..drawPath(path, stroke(ink.line, 4.6)..strokeCap = StrokeCap.butt)
        ..drawPath(path, stroke(ink.ground, 2.2));
    case 'spawned_by':
      canvas.drawPath(path, stroke(ink.spawned, 1.4));
    default:
      switch (variant % 3) {
        case 1:
          DashedLine.draw(canvas, path, stroke(ink.line, 1.5)..strokeCap = StrokeCap.butt, dash: 10, gap: 5);
        case 2:
          // Dash, dot: a dash of 8, then a dot, the gaps 3.
          final dash = stroke(ink.line, 1.5)..strokeCap = StrokeCap.butt;
          for (final m in path.computeMetrics()) {
            for (var d = 0.0; d < m.length; d += 17) {
              canvas.drawPath(m.extractPath(d, min(d + 8, m.length)), dash);
              if (d + 11 < m.length) canvas.drawPath(m.extractPath(d + 11, min(d + 12.5, m.length)), stroke(ink.line, 2.2));
            }
          }
        default:
          canvas.drawPath(path, stroke(ink.line, 1.5));
      }
  }
  for (final (from, tip) in heads) {
    final d = tip - from;
    if (d.distance == 0) continue;
    final u = d / d.distance, n = Offset(-u.dy, u.dx);
    final base = tip - u * size;
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo((base + n * size / 2).dx, (base + n * size / 2).dy)
        ..lineTo((base - n * size / 2).dx, (base - n * size / 2).dy)
        ..close(),
      Paint()..color = kind == 'spawned_by' ? ink.spawned : ink.line,
    );
  }
}

/// Where [kind]'s arrowheads go on a link from `start` to `end`.
List<(Offset, Offset)> edgeHeads(String kind, (Offset from, Offset tip) start, (Offset from, Offset tip) end) =>
    switch (kind) {
      'collaborates_with' => [start, end],
      'spawned_by' => [start], // the edge runs child → parent; the arrow points at the child
      _ => [end],
    };

class EdgesPainter extends CustomPainter {
  EdgesPainter({required this.layout, required this.ink, required this.band, required this.podLabel, this.solid = false})
      : variants = edgeVariants([for (final e in layout.edges) e.edge.kind]);
  final Map<String, int> variants;
  final GraphLayout layout;
  final EdgeInk ink;
  final Color band;
  final TextStyle podLabel;
  final bool solid;

  @override
  void paint(Canvas canvas, Size size) {
    for (final b in layout.bands) {
      canvas
        ..save()
        ..translate(b.rect.left, b.rect.top);
      if (solid) {
        canvas.drawRRect(
            RRect.fromRectAndRadius((Offset.zero & b.rect.size).deflate(0.5), const Radius.circular(kRadius)),
            Paint()
              ..color = band
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1);
      } else {
        DashedBorder(band, radius: kRadius).paint(canvas, b.rect.size);
      }
      canvas.restore();
      final tp =
          TextPainter(text: TextSpan(text: b.podId.toUpperCase(), style: podLabel), textDirection: TextDirection.ltr)
            ..layout(maxWidth: b.rect.width - 20);
      tp.paint(canvas, b.rect.topLeft + const Offset(12, 8));
    }
    for (final e in layout.edges) {
      paintEdge(canvas, e.path, e.edge.kind, ink, edgeHeads(e.edge.kind, (e.startFrom, e.start), (e.endFrom, e.end)),
          variant: variants[e.edge.kind] ?? 0);
    }
  }

  @override
  bool shouldRepaint(EdgesPainter old) => old.layout != layout || old.ink.line != ink.line || old.band != band || old.solid != solid;
}

class DashedLine {
  static void draw(Canvas canvas, Path path, Paint paint, {double dash = 4, double gap = 3}) {
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += dash + gap) {
        canvas.drawPath(m.extractPath(d, min(d + dash, m.length)), paint);
      }
    }
  }
}

/// What the shapes and lines mean, in one row that wraps rather than cuts: the states (needs you, working, idle,
/// stopped), the context bar, and the link kinds this rig uses.
class GraphLegend extends StatelessWidget {
  const GraphLegend({super.key, this.kinds = const []});
  final List<String> kinds;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final ink = EdgeInk.of(context);
    final style = TextStyle(fontSize: 11, color: k.muted);
    Widget item(Widget mark, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
          mark,
          const SizedBox(width: 5),
          Text(label, style: style),
        ]);
    // The legend shows what a node shows: the agent's logo in each state's colour.
    Widget state(Status s) => item(StatusIcon.agent(s, runtime: 'claude-code', compact: true), s.label);
    final variants = edgeVariants(kinds);
    return Wrap(spacing: 12, runSpacing: 6, children: [
      for (final s in const [Status.needsYou, Status.working, Status.idle, Status.stopped]) state(s),
      item(
          Container(
              width: 18, height: 3, decoration: BoxDecoration(color: k.muted, borderRadius: BorderRadius.circular(2))),
          'context used'),
      for (final kind in kinds)
        item(SizedBox(width: 28, height: 12, child: CustomPaint(painter: _LegendLine(kind, ink, variants[kind] ?? 0))), edgeLegend(kind)),
    ]);
  }
}

class _LegendLine extends CustomPainter {
  _LegendLine(this.kind, this.ink, this.variant);
  final String kind;
  final int variant;
  final EdgeInk ink;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final a = Offset(1, y), b = Offset(size.width - 1, y);
    // Read left to right: the arrow points at the second seat (for spawned_by, the spawned one).
    final start = (a + const Offset(6, 0), a), end = (b - const Offset(6, 0), b);
    final heads = switch (kind) {
      'collaborates_with' => [start, end],
      _ => [end],
    };
    paintEdge(
        canvas,
        Path()
          ..moveTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy),
        kind,
        ink,
        heads,
        variant: variant);
  }

  @override
  bool shouldRepaint(_LegendLine old) => old.kind != kind || old.ink.line != ink.line || old.variant != variant;
}
