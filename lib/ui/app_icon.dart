import 'package:flutter/material.dart';

/// The app's own icons for what a row is: a rig, a project folder, an agent, a subagent, a shell, a worktree; and for the rig
/// page's actions, a room (two conversation bubbles) and a broadcast (one bubble, three lines fanning out: Message all). Drawn on a
/// 24 grid, 1.8 stroke, round caps and joins, one filled node each (the app icon's line and node), tinted with [color].
/// The shapes are the designer's SVGs (icons/*.svg) written out as paths: no asset and no package.
enum AppIconKind { rig, folder, agent, subagent, shell, worktree, room, broadcast, tiles }

/// The rig icon: the designer's three linked agents (rig.svg), or the alternative, two speech bubbles (rigalt.svg).
/// The person picks; flip this one flag to swap it everywhere.
const bool rigIconIsBubbles = false;

class AppIcon extends StatelessWidget {
  const AppIcon(this.kind, {super.key, this.size = 18, this.color});
  final AppIconKind kind;
  final double size;

  /// Defaults to the ambient icon colour.
  final Color? color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SizedBox.square(
          dimension: size,
          child: CustomPaint(painter: _IconPainter(kind, color ?? IconTheme.of(context).color ?? Colors.grey)),
        ),
      );
}

class _IconPainter extends CustomPainter {
  _IconPainter(this.kind, this.color);
  final AppIconKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    final fill = Paint()..color = color;
    RRect box(double x, double y, double w, double h, double r) => RRect.fromLTRBR(x, y, x + w, y + h, Radius.circular(r));
    void seg(double x1, double y1, double x2, double y2) => canvas.drawLine(Offset(x1, y1), Offset(x2, y2), line);
    void node(double x, double y, double r) => canvas.drawCircle(Offset(x, y), r, fill);

    switch (kind) {
      case AppIconKind.agent:
        canvas.drawRRect(box(4.5, 9, 15, 11, 3.5), line);
        seg(12, 9, 12, 5.6);
        seg(2.5, 13, 2.5, 16.2);
        seg(21.5, 13, 21.5, 16.2);
        seg(9, 14.6, 15, 14.6);
        node(12, 4, 1.7);
      case AppIconKind.room:
      case AppIconKind.rig when rigIconIsBubbles:
        const r = Radius.circular(2.5);
        canvas.drawPath(
            Path()
              ..moveTo(3.5, 7)
              ..arcToPoint(const Offset(6, 4.5), radius: r)
              ..lineTo(12, 4.5)
              ..arcToPoint(const Offset(14.5, 7), radius: r)
              ..lineTo(14.5, 10)
              ..arcToPoint(const Offset(12, 12.5), radius: r)
              ..lineTo(8.5, 12.5)
              ..lineTo(5.5, 15)
              ..lineTo(5.5, 12.5)
              ..lineTo(6, 12.5)
              ..arcToPoint(const Offset(3.5, 10), radius: r)
              ..close(),
            line);
        canvas.drawPath(
            Path()
              ..moveTo(17.5, 9.5)
              ..lineTo(18, 9.5)
              ..arcToPoint(const Offset(20.5, 12), radius: r)
              ..lineTo(20.5, 15)
              ..arcToPoint(const Offset(18, 17.5), radius: r)
              ..lineTo(18, 20)
              ..lineTo(15, 17.5)
              ..lineTo(11, 17.5)
              ..arcToPoint(const Offset(8.5, 15), radius: r)
              ..lineTo(8.5, 14.5),
            line);
        node(9.2, 8.7, 1.4);
      case AppIconKind.broadcast:
        const r = Radius.circular(2.4);
        canvas.drawPath(
            Path()
              ..moveTo(3.5, 8.2)
              ..arcToPoint(const Offset(5.9, 5.8), radius: r)
              ..lineTo(11.1, 5.8)
              ..arcToPoint(const Offset(13.5, 8.2), radius: r)
              ..lineTo(13.5, 10.8)
              ..arcToPoint(const Offset(11.1, 13.2), radius: r)
              ..lineTo(8.4, 13.2)
              ..lineTo(5.3, 15.6)
              ..lineTo(5.3, 13.2)
              ..lineTo(5.9, 13.2)
              ..arcToPoint(const Offset(3.5, 10.8), radius: r)
              ..close(),
            line);
        seg(16.6, 6.6, 20.2, 4.8);
        seg(17, 9.5, 21, 9.5);
        seg(16.6, 12.4, 20.2, 14.2);
        node(8.5, 9.5, 1.3);
      case AppIconKind.rig:
        seg(10.3, 8.9, 6.9, 15.1);
        seg(13.7, 8.9, 17.1, 15.1);
        seg(8.6, 18, 15.4, 18);
        canvas.drawRRect(box(9, 3, 6, 6, 2), fill);
        canvas.drawRRect(box(9, 3, 6, 6, 2), line);
        canvas.drawRRect(box(2.5, 15, 6, 6, 2), line);
        canvas.drawRRect(box(15.5, 15, 6, 6, 2), line);
      case AppIconKind.tiles:
        // Four tiles in a 2x2 grid, outlined.
        for (final (x, y) in const [(4.0, 4.0), (14.0, 4.0), (4.0, 14.0), (14.0, 14.0)]) {
          canvas.drawRRect(box(x, y, 6, 6, 1.8), line);
        }
      case AppIconKind.folder:
        const r = Radius.circular(2.5);
        final p = Path()
          ..moveTo(3.5, 8)
          ..arcToPoint(const Offset(6, 5.5), radius: r)
          ..lineTo(9.2, 5.5)
          ..lineTo(11.2, 7.8)
          ..lineTo(18, 7.8)
          ..arcToPoint(const Offset(20.5, 10.3), radius: r)
          ..lineTo(20.5, 17.5)
          ..arcToPoint(const Offset(18, 20), radius: r)
          ..lineTo(6, 20)
          ..arcToPoint(const Offset(3.5, 17.5), radius: r)
          ..close();
        canvas.drawPath(p, line);
        node(8.2, 13.8, 1.5);
      case AppIconKind.subagent:
        final p = Path()
          ..moveTo(6, 6.4)
          ..lineTo(6, 15)
          ..arcToPoint(const Offset(9, 18), radius: const Radius.circular(3), clockwise: false)
          ..lineTo(11.6, 18);
        canvas.drawPath(p, line);
        node(6, 4.5, 1.8);
        canvas.drawRRect(box(12.5, 12.5, 8, 8, 2.6), line);
        node(16.5, 16.5, 1);
      case AppIconKind.shell:
        canvas.drawRRect(box(3.5, 5, 17, 14, 3.6), line);
        canvas.drawPath(
            Path()
              ..moveTo(8, 10.4)
              ..lineTo(11, 13)
              ..lineTo(8, 15.6),
            line);
        node(15.3, 15.4, 1.3);
      case AppIconKind.worktree:
        seg(7, 7, 7, 17);
        canvas.drawPath(
            Path()
              ..moveTo(17, 9)
              ..cubicTo(17, 13, 13.4, 14.4, 7, 15.2),
            line);
        node(7, 5.2, 1.8);
        node(7, 18.8, 1.8);
        canvas.drawCircle(const Offset(17, 7.2), 1.9, line);
    }
  }

  @override
  bool shouldRepaint(_IconPainter old) => old.kind != kind || old.color != color;
}
