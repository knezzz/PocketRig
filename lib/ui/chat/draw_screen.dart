import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../data/attachments.dart';
import '../../data/send_to_seat.dart' show sendToSeat;
import '../../main.dart';
import '../../models.dart';
import '../common.dart';
import '../send_guard.dart';
import '../theme.dart';

/// Draws over an image, then sends the drawing to [seat]: the PNG goes to the host's upload folder and its path,
/// after an optional note, is typed into the agent, which reads it.
class DrawScreen extends StatefulWidget {
  const DrawScreen({super.key, required this.image, required this.name, required this.seat});
  final Uint8List image;
  final String name;
  final Seat seat;

  @override
  State<DrawScreen> createState() => _DrawScreenState();
}

typedef _Stroke = ({Color color, List<Offset> points});

class _DrawScreenState extends State<DrawScreen> {
  static const _colors = [Color(0xFFE53935), Color(0xFFFDD835), Color(0xFF43A047), Color(0xFF1E88E5), Colors.black];
  final _canvas = GlobalKey();
  final _note = TextEditingController();
  final _strokes = <_Stroke>[];
  Color _color = _colors.first;
  ui.Image? _decoded;
  bool _sending = false, _unreadable = false;

  @override
  void initState() {
    super.initState();
    decodeImageFromList(widget.image).then((i) {
      if (mounted) setState(() => _decoded = i);
    }, onError: (Object _) {
      if (mounted) setState(() => _unreadable = true);
    });
  }

  @override
  void dispose() {
    _note.dispose();
    _decoded?.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final host = AppScope.read(context).active, api = AppScope.clientOf(context);
    final session = widget.seat.sessionName, image = _decoded;
    final box = _canvas.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (host == null || session == null || image == null || box == null) return;
    // A question open on the seat would take the drawing's message as its answer: ask first.
    if (await askBeforeSending(context, host, widget.seat, inChat: true) != SendGuard.send || !mounted) return;
    setState(() => _sending = true);
    try {
      // At the image's own resolution, not the screen's.
      final drawn = await box.toImage(pixelRatio: image.width / box.size.width);
      final png = (await drawn.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      drawn.dispose();
      final base = widget.name.contains('.') ? widget.name.substring(0, widget.name.lastIndexOf('.')) : widget.name;
      final [path] = await uploadAttachments(host, [('$base-drawn.png', png)]);
      final note = _note.text.trim();
      final text = note.isEmpty ? path : '$note $path';
      await sendToSeat(host, api, widget.seat, text);
      if (!mounted) return;
      toast(context, 'Sent to ${widget.seat.logicalId}');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t send the drawing: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final image = _decoded;
    return Scaffold(
      appBar: AppBar(
        title: Text('Draw · ${widget.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          for (final c in _colors)
            IconButton(
              tooltip: 'Pen color',
              isSelected: c == _color,
              onPressed: () => setState(() => _color = c),
              icon: Icon(c == _color ? Icons.circle : Icons.circle_outlined, color: c, size: 22),
            ),
          IconButton(
            tooltip: 'Undo',
            onPressed: _strokes.isEmpty ? null : () => setState(_strokes.removeLast),
            icon: const Icon(Icons.undo, size: 22),
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: image == null
              ? Center(
                  child: _unreadable
                      ? Text('Can\'t draw on this image', style: TextStyle(color: k.muted))
                      : const CircularProgressIndicator())
              : Center(
                  child: AspectRatio(
                    aspectRatio: image.width / image.height,
                    child: RepaintBoundary(
                      key: _canvas,
                      child: GestureDetector(
                        onPanStart: (d) =>
                            setState(() => _strokes.add((color: _color, points: [d.localPosition]))),
                        onPanUpdate: (d) => setState(() => _strokes.last.points.add(d.localPosition)),
                        child: CustomPaint(
                          foregroundPainter: _StrokesPainter(_strokes),
                          child: Image.memory(widget.image, fit: BoxFit.fill, gaplessPlayback: true),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _note,
                  decoration: InputDecoration(
                      hintText: 'Note for ${widget.seat.logicalId} (optional)', filled: true, fillColor: k.fill),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _sending || image == null ? null : _send,
                icon: const Icon(Icons.send, size: 18),
                label: const Text('Send'),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _StrokesPainter extends CustomPainter {
  _StrokesPainter(this.strokes);
  final List<_Stroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      final paint = Paint()
        ..color = s.color
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      if (s.points.length == 1) {
        canvas.drawCircle(s.points.first, 2, paint..style = PaintingStyle.fill);
        continue;
      }
      canvas.drawPath(Path()..addPolygon(s.points, false), paint);
    }
  }

  // The stroke lists change in place.
  @override
  bool shouldRepaint(_StrokesPainter old) => true;
}
