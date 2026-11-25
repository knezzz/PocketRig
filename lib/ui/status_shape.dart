import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'app_icon.dart';

import '../models.dart';
import 'kit.dart' show RuntimeGlyph;
import 'theme.dart';

/// Every state a seat, agent, rig or host can be in, as the redesign shows
/// it: always a circle, told apart by style (fill, outline, dashes, pulse),
/// so the state reads without color too.
enum Status {
  /// Filled accent circle with a pulsing outer ring (a static ring with reduce-motion).
  needsYou,

  /// Solid mint circle: running, spending tokens.
  working,

  /// Cyan outline circle: waiting on a shell or monitor, no tokens.
  shell,

  /// Solid muted-grey circle: up, waiting at the prompt.
  idle,

  /// Dashed outline circle, faint: not running.
  stopped,

  /// Solid pink-red circle: failed, offline.
  failed,

  /// Mint circle, left half filled: up, but degraded (a host reached only over SSH).
  degraded;

  static Status of(SeatState s) => switch (s) {
        SeatState.needsYou => Status.needsYou,
        SeatState.working => Status.working,
        SeatState.shell => Status.shell,
        SeatState.idle => Status.idle,
        SeatState.stopped => Status.stopped,
      };

  String get label => switch (this) {
        Status.needsYou => 'needs you',
        Status.working => 'working',
        Status.shell => 'waiting on shell',
        Status.idle => 'idle',
        Status.stopped => 'stopped',
        Status.failed => 'failed',
        Status.degraded => 'degraded',
      };

  /// The state's color in [k]; null for the uncolored states.
  Color color(Tokens k) => switch (this) {
        Status.needsYou => k.accent,
        Status.working || Status.degraded => k.added,
        Status.shell => k.shell,
        Status.failed => k.removed,
        Status.idle => k.muted,
        Status.stopped => k.faint,
      };

  /// A terminal frame's edge: only the states worth noticing (needs you, working, on a shell) color it; the rest stay neutral.
  Color? edge(Tokens k) => this == Status.needsYou || this == Status.working || this == Status.shell ? color(k) : null;

  /// A terminal's background: [Tokens.termBg] faintly washed with the [edge] color, when there is one.
  Color termBg(Tokens k) => switch (edge(k)) {
        final c? => Color.alphaBlend(c.withValues(alpha: 0.08), k.termBg),
        null => k.termBg,
      };

  /// The color for text and counts: idle and stopped read muted, not their mark's faint color.
  Color textColor(Tokens k) => this == Status.idle || this == Status.stopped ? k.muted : color(k);
}

/// The status shape. Glows in the dark theme; the needs-you ring pulses
/// unless animations are off.
class StatusShape extends StatefulWidget {
  const StatusShape(this.status, {super.key, this.size = 10, this.semantics = true});
  final Status status;
  final double size;


  /// Reads the state out; off where the row already says it in words.
  final bool semantics;

  @override
  State<StatusShape> createState() => _StatusShapeState();
}

class _StatusShapeState extends State<StatusShape> with SingleTickerProviderStateMixin {
  late final _ring = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  bool get _pulses =>
      widget.status == Status.needsYou && animateStatusSpinners && windowActive.value && !MediaQuery.disableAnimationsOf(context);

  void _sync() {
    if (_pulses && !_ring.isAnimating) {
      _ring.repeat();
    } else if (!_pulses) {
      _ring
        ..stop()
        ..value = 0.5;
    }
  }

  @override
  void initState() {
    super.initState();
    windowActive.addListener(_sync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(StatusShape old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    windowActive.removeListener(_sync);
    _ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final shape = SizedBox.square(
      // Stopped's dashes and the failed bar vanish below ~11dp.
      dimension: max(widget.size, 11),
      // Its own layer: the pulse repaints only itself, not the card around it.
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _ring,
          builder: (context, _) => CustomPaint(
            painter: _ShapePainter(widget.status, k, _ring.value, _pulses),
          ),
        ),
      ),
    );
    return widget.semantics ? Semantics(label: widget.status.label, child: shape) : ExcludeSemantics(child: shape);
  }
}

class _ShapePainter extends CustomPainter {
  _ShapePainter(this.status, this.k, this.t, this.pulsing);
  final Status status;
  final Tokens k;

  /// The ring's phase, 0..1.
  final double t;

  /// False with reduce-motion or animations off: needs-you shows a static ring.
  final bool pulsing;

  @override
  void paint(Canvas canvas, Size size) {
    // k.faint is under 3:1 on the card in both themes, so stopped's dashes lean toward muted.
    final c = status == Status.stopped ? Color.lerp(k.faint, k.muted, 0.7)! : status.color(k);
    final d = size.width;
    final center = size.center(Offset.zero);
    Paint stroke(double w, [double alpha = 1]) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..color = c.withValues(alpha: alpha);
    Rect ring(double w) => Rect.fromCircle(center: center, radius: d / 2 - w / 2);
    switch (status) {
      case Status.needsYou:
        canvas.drawCircle(center, d * 0.3, Paint()..color = c);
        final grow = pulsing ? 0.6 + 0.4 * t : 0.9;
        canvas.drawCircle(center, d * grow / 2, stroke(max(1.2, d * 0.1), pulsing ? 0.6 * (1 - t) : 0.45));
      case Status.working:
        canvas.drawCircle(center, d / 2, Paint()..color = c);
      case Status.shell:
        canvas.drawArc(ring(1.5), 0, 2 * pi, false, stroke(1.5));
      case Status.idle:
        // Smaller than working's disc, so the two differ by size as well as hue.
        canvas.drawCircle(center, d * 0.35, Paint()..color = c);
      case Status.stopped:
        canvas.drawCircle(center, d / 2, Paint()..color = c.withValues(alpha: 0.2));
        // Six dashes, each 60% of its slot: the 8 dp tally mark keeps a visible arc.
        const dashes = 6;
        for (var i = 0; i < dashes; i++) {
          canvas.drawArc(ring(1.5), i * 2 * pi / dashes, 0.6 * 2 * pi / dashes, false, stroke(1.5));
        }
      case Status.failed:
        canvas.drawCircle(center, d / 2, Paint()..color = c);
        // A no-entry bar, so red vs green doesn't rest on color alone.
        canvas.drawRect(Rect.fromCenter(center: center, width: d * 0.55, height: 2), Paint()..color = k.ground);
      case Status.degraded:
        canvas.drawArc(Rect.fromCircle(center: center, radius: d / 2), pi / 2, pi, true, Paint()..color = c);
        canvas.drawArc(ring(1.5), 0, 2 * pi, false, stroke(1.5));
    }
  }

  @override
  bool shouldRepaint(_ShapePainter old) =>
      old.status != status || old.t != t || old.k != k || old.pulsing != pulsing;
}

/// What a row's icon says it is; the state dot says how it is.
enum StatusKind { agent, subagent, shell }

/// A rig's or loose agent's icon (a hub vs a single robot), neutral, with its
/// status circle as a badge at the top right (bottom right would read as one run with a row's tally), so the row colors once.
class StatusIcon extends StatelessWidget {
  const StatusIcon.rig(this.status, {super.key, this.ground})
      : icon = AppIconKind.rig,
        runtime = null,
        inRig = false,
        compact = false,
        kind = StatusKind.agent;
  const StatusIcon.agent(this.status, {super.key, this.ground, this.compact = false, this.runtime})
      : icon = AppIconKind.agent,
        inRig = false,
        kind = StatusKind.agent;

  /// A subagent: a fork in blue, with the same state dot as an agent.
  const StatusIcon.subagent(this.status, {super.key, this.ground})
      : icon = AppIconKind.subagent,
        runtime = null,
        inRig = false,
        compact = true,
        kind = StatusKind.subagent;

  /// A shell: a terminal glyph in violet, with the same state dot as an agent.
  const StatusIcon.shell(this.status, {super.key, this.ground})
      : icon = AppIconKind.shell,
        runtime = null,
        inRig = false,
        compact = true,
        kind = StatusKind.shell;

  /// An agent in a rig: the same robot as [StatusIcon.agent] with a small hub badge at its bottom right.
  const StatusIcon.seat(this.status, {super.key, this.ground, this.runtime})
      : icon = AppIconKind.agent,
        inRig = true,
        compact = false,
        kind = StatusKind.agent;
  final AppIconKind icon;
  final Status status;

  /// An agent's runtime ('claude-code', 'codex', ...): its logo is the icon, in the state's colour. One with no logo gets
  /// the generic agent icon.
  final String? runtime;
  final bool inRig;
  final StatusKind kind;

  /// The sidebar's size: an 18dp robot in a lighter grey with an 8dp state dot on a ring in the row's colour, no
  /// border line and no rig badge (the tree already nests rig agents), so a 28dp row keeps its height.
  final bool compact;

  /// The row's background, for the gap ring behind the badge; the card surface by default.
  final Color? ground;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final d = compact ? 18.0 : 28.0, badge = compact ? 11.0 : 16.0;
    final off = compact ? -3.0 : -5.0;
    return SizedBox.square(
      dimension: d,
      child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
        if (kind == StatusKind.agent && icon == AppIconKind.agent)
          // The runtime's logo (srcIn: the PNG is a mask), tinted with the state: orange needs you, green working, grey idle.
          // No dot, so the state is said in the label too.
          Semantics(
            label: '${runtime == null ? 'Agent' : RuntimeGlyph.label(runtime)}, ${status.label}',
            child: ExcludeSemantics(child: _logo(k, compact ? 18 : 22)),
          )
        else
          AppIcon(icon,
              size: kind == StatusKind.agent || icon == AppIconKind.rig ? (compact ? 18 : 22) : 17,
              color: switch (kind) {
                // A subagent takes the state colour of what it is doing; idle and stopped stay grey.
                StatusKind.subagent => status == Status.idle || status == Status.stopped ? k.muted : status.color(k),
                StatusKind.shell => k.terminal,
                StatusKind.agent => k.muted,
              }),
        // A shell has no state dot: its blue icon is enough (the agent that waits on it carries the ring); an agent's state
        // is its icon's colour.
        if (kind == StatusKind.subagent || icon == AppIconKind.rig)
        Positioned(
          right: off,
          top: off,
          child: Container(
            width: badge,
            height: badge,
            alignment: Alignment.center,
            // The thin ring keeps the faint states (stopped's dashes, idle's grey) readable over the glyph's edge.
            decoration: BoxDecoration(
                color: ground ?? k.surface, shape: BoxShape.circle, border: compact ? null : Border.all(color: k.border)),
            child: StatusShape(status, size: compact ? 8 : 12),
          ),
        ),
        if (inRig)
          Positioned(
            right: off,
            bottom: off,
            // An outline disc (muted ring, row-coloured fill), so it never reads as a state dot, which are solid or dashed.
            child: Container(
              width: 16,
              height: 16,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: ground ?? k.surface, shape: BoxShape.circle, border: Border.all(color: k.muted, width: 1.5)),
              child: AppIcon(AppIconKind.rig, size: 10, color: k.muted),
            ),
          ),
      ]),
    );
  }
}

/// A shape with a count next to it ("● 2"), the per-state tally on project and rig rows.
class StatusCount extends StatelessWidget {
  const StatusCount(this.status, this.count, {super.key});
  final Status status;
  final int count;
  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final c = status.textColor(k);
    return Semantics(
      label: '$count ${status.label}',
      excludeSemantics: true,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        StatusShape(status, size: 8, semantics: false),
        const SizedBox(width: 5),
        Text('$count',
            style: TextStyle(
                fontFamily: fontMono,
                fontSize: 12,
                fontWeight: status == Status.needsYou ? FontWeight.w700 : FontWeight.w500,
                color: c)),
      ]),
    );
  }
}

/// The tally row: one [StatusCount] per non-zero state, in needs → working → shell → idle → stopped order.
class StatusTally extends StatelessWidget {
  const StatusTally(this.counts, {super.key, this.spacing = 10});
  final Map<Status, int> counts;
  final double spacing;
  @override
  Widget build(BuildContext context) {
    const order = [Status.needsYou, Status.working, Status.shell, Status.idle, Status.stopped, Status.failed];
    final shown = [
      for (final s in order)
        if ((counts[s] ?? 0) > 0) StatusCount(s, counts[s]!)
    ];
    return Wrap(spacing: spacing, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: shown);
  }
}

/// The runtime logos' files.
const runtimeLogoAssets = ['assets/icons/claude.png', 'assets/icons/openai.png'];

/// Decodes the runtime logos into the image cache at startup. [ImageIcon] loads its image asynchronously and draws nothing
/// until then, so the first Rigs home paint had blank slots where the logos go.
Future<void> warmRuntimeLogos() => Future.wait([
      for (final a in runtimeLogoAssets)
        () {
          final done = Completer<void>();
          final stream = AssetImage(a).resolve(ImageConfiguration.empty);
          late final ImageStreamListener l;
          void finish() {
            if (!done.isCompleted) done.complete();
            stream.removeListener(l);
          }

          l = ImageStreamListener((_, __) => finish(), onError: (_, __) => finish());
          stream.addListener(l);
          return done.future;
        }(),
    ]);

extension on StatusIcon {
  /// The runtime's logo in the state's colour; the generic agent icon when the runtime has none.
  Widget _logo(Tokens k, double size) {
    final color = status.color(k);
    return switch (runtime) {
      'claude-code' => ImageIcon(const AssetImage('assets/icons/claude.png'), size: size, color: color),
      'codex' => ImageIcon(const AssetImage('assets/icons/openai.png'), size: size, color: color),
      _ => AppIcon(AppIconKind.agent, size: size, color: color),
    };
  }
}
