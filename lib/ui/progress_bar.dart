import 'package:flutter/material.dart';

import 'theme.dart';
import 'usage_strip.dart' show contextColor;

/// The one bar: a rounded [track] with a [color] fill to [value] (0..1), [height] thick, and optionally a [tick] mark
/// (the pace marker of a usage bar) as tall as the whole [boxHeight]. Usage bars, context bars and the sidebar's bars
/// are all this.
class ProgressBar extends StatelessWidget {
  const ProgressBar(
      {super.key, required this.value, required this.color, this.height = 4, this.boxHeight, this.track, this.tick, this.tickColor});
  final double value;
  final Color color;
  final double height;

  /// The widget's own height when taller than the bar (room for the tick); [height] by default.
  final double? boxHeight;
  final Color? track;

  /// Where the pace tick sits, 0..1; none when null.
  final double? tick;
  final Color? tickColor;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return SizedBox(
      height: boxHeight ?? height,
      child: CustomPaint(
        size: Size.fromHeight(boxHeight ?? height),
        painter: _BarPainter(
            used: value, fill: color, track: track ?? k.divider, barHeight: height, pace: tick, tick: tickColor ?? k.ink),
      ),
    );
  }
}

/// A seat's context window use, grey, red from 80 by [contextColor]. [height] is the bar's thickness; [base] tints the
/// track (and is the fill [onAccent], on the orange needs-you fill); [label] reads it out (off where the row says it).
class ContextBar extends StatelessWidget {
  const ContextBar(this.percent, {super.key, this.height = 8, this.base, this.onAccent = false, this.label = true});
  final double? percent;
  final double height;
  final Color? base;
  final bool onAccent;
  final bool label;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final p = percent;
    final bar = ProgressBar(
      value: p == null ? 0 : (p / 100).clamp(0.0, 1.0),
      color: p == null ? k.ink : (onAccent && base != null ? base! : contextColor(p, k)),
      height: height,
      track: base?.withValues(alpha: 0.2) ?? k.divider,
    );
    return label ? Semantics(label: p == null ? 'context unknown' : 'context ${p.round()} percent used', child: bar) : bar;
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({required this.used, required this.fill, required this.track, required this.barHeight, this.pace, required this.tick});
  final double used;
  final Color fill;
  final Color track;
  final double barHeight;
  final double? pace;
  final Color tick;

  @override
  void paint(Canvas canvas, Size size) {
    final h = barHeight;
    final top = (size.height - h) / 2;
    final r = Radius.circular(h / 2);
    canvas.drawRRect(RRect.fromLTRBR(0, top, size.width, top + h, r), Paint()..color = track);
    final w = size.width * used.clamp(0.0, 1.0);
    if (w > 0) canvas.drawRRect(RRect.fromLTRBR(0, top, w, top + h, r), Paint()..color = fill);
    if (pace != null) {
      final x = (size.width * pace!.clamp(0.0, 1.0)).clamp(1.0, size.width - 1);
      canvas.drawRRect(RRect.fromLTRBR(x - 1, 0, x + 1, size.height, const Radius.circular(1)), Paint()..color = tick);
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.barHeight != barHeight || old.used != used || old.pace != pace || old.fill != fill || old.tick != tick || old.track != track;
}
