import 'package:flutter/material.dart';

import 'theme.dart';

/// "The agent is thinking": three dots that hop in turn and hollow into rings.
/// One controller and one painter; with reduce-motion (or animations off) three static dots.
class ThinkingDots extends StatefulWidget {
  const ThinkingDots({super.key, this.d = 5, this.color});

  /// A dot's diameter; the gaps are 0.5 d.
  final double d;

  /// k.muted by default; pass k.added where the dots mark a working agent.
  final Color? color;

  /// The loop, and the delay between neighbouring dots, in seconds.
  static const loop = 2.87;
  static const stagger = 0.32;

  static const _out = Cubic(0.29, 1, 1, 1);
  static double _seg(double u, double a, double b) => ((u - a) / (b - a)).clamp(0.0, 1.0);

  /// How far a dot is raised, in units of d, at [u] seconds into its own loop: 0.7 d at 0.32 s, 0.5 d at 0.71 s, down at 0.88 s.
  static double rise(double u) {
    if (u < 0.32) return 0.7 * _out.transform(_seg(u, 0, 0.32));
    if (u < 0.71) return 0.7 - 0.2 * _out.transform(_seg(u, 0.32, 0.71));
    return 0.5 * (1 - _out.transform(_seg(u, 0.71, 0.88)));
  }

  /// The centre hole's diameter, in units of d: opens to 0.67 d by 0.45 s, holds, closes by 0.8 s; then a breath
  /// between 1.98 s and 2.83 s opens it again in place and closes it.
  static double hole(double u) {
    const max = 0.67;
    if (u < 0.45) return max * _out.transform(_seg(u, 0, 0.45));
    if (u < 0.6) return max;
    if (u < 0.8) return max * (1 - _out.transform(_seg(u, 0.6, 0.8)));
    if (u >= 1.98 && u < 2.83) {
      final x = _seg(u, 1.98, 2.83);
      return max * (x < 0.5 ? _out.transform(x * 2) : 1 - _out.transform(x * 2 - 1));
    }
    return 0;
  }

  @override
  State<ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<ThinkingDots> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2870));

  bool get _moves => animateStatusSpinners && windowActive.value && !MediaQuery.disableAnimationsOf(context);

  void _sync() {
    if (_moves && !_c.isAnimating) {
      _c.repeat();
    } else if (!_moves) {
      _c
        ..stop()
        ..value = 0;
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
  void dispose() {
    windowActive.removeListener(_sync);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size(4 * d, 1.7 * d),
          painter: _DotsPainter(_c, d, widget.color ?? Tokens.of(context).muted, _moves),
        ),
      ),
    );
  }
}

class _DotsPainter extends CustomPainter {
  _DotsPainter(this.c, this.d, this.color, this.moves) : super(repaint: c);
  final Animation<double> c;
  final double d;
  final Color color;
  final bool moves;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final seconds = c.value * ThinkingDots.loop;
    for (var i = 0; i < 3; i++) {
      final u = moves ? (seconds - i * ThinkingDots.stagger) % ThinkingDots.loop : -1.0;
      final rise = u < 0 ? 0.0 : ThinkingDots.rise(u);
      final hole = u < 0 ? 0.0 : ThinkingDots.hole(u);
      final center = Offset(d / 2 + i * 1.5 * d, size.height - d / 2 - rise * d);
      final path = Path()..addOval(Rect.fromCircle(center: center, radius: d / 2));
      if (hole > 0) path.addOval(Rect.fromCircle(center: center, radius: hole * d / 2));
      canvas.drawPath(path..fillType = PathFillType.evenOdd, paint);
    }
  }

  @override
  bool shouldRepaint(_DotsPainter old) => old.d != d || old.color != color || old.moves != moves;
}
