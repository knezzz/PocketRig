import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../kit.dart' show showDialogOrSheet;
import '../host_color.dart';
import '../theme.dart';

/// A host's own colour: a saturation/value square, a hue slider, a hex field and a preview of the name as a page header
/// draws it. A bottom sheet on a phone, a 360dp dialog on the Mac. The colour picked, or null when cancelled.
Future<Color?> pickCustomColour(BuildContext context, {required Color initial, required String hostName}) {
  final body = CustomColourPicker(initial: initial, hostName: hostName);
  return showDialogOrSheet<Color>(context, child: body, maxWidth: 360);
}

/// "B4581E" for [c].
String hexOf(Color c) => (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

/// The picker's body (the sheet and the dialog both hold it).
class CustomColourPicker extends StatefulWidget {
  const CustomColourPicker({super.key, required this.initial, required this.hostName});
  final Color initial;
  final String hostName;

  @override
  State<CustomColourPicker> createState() => _CustomColourPickerState();
}

class _CustomColourPickerState extends State<CustomColourPicker> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);
  late final _hex = TextEditingController(text: hexOf(widget.initial));
  bool _valid = true;

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _drag(HSVColor hsv) {
    setState(() {
      _hsv = hsv;
      _valid = true;
      _hex.text = hexOf(hsv.toColor());
    });
  }

  void _typed(String text) {
    setState(() {
      _valid = text.length == 6;
      if (_valid) _hsv = HSVColor.fromColor(Color(0xFF000000 | int.parse(text, radix: 16)));
    });
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final picked = _hsv.toColor();
    final shown = readableOn(picked, k.ground);
    final pulled = shown != picked;
    final red = BorderSide(color: k.removed);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Custom colour', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 14),
        _Area(
          height: 220,
          label: 'Saturation and brightness',
          onChange: (dx, dy) => _drag(_hsv.withSaturation(dx).withValue(1 - dy)),
          paint: (canvas, size) {
            final rect = Offset.zero & size;
            canvas.drawRect(
                rect,
                Paint()
                  ..shader = LinearGradient(colors: [Colors.white, HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor()])
                      .createShader(rect));
            canvas.drawRect(
                rect,
                Paint()
                  ..shader = const LinearGradient(
                          begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black])
                      .createShader(rect));
          },
          x: _hsv.saturation,
          y: 1 - _hsv.value,
          handleColor: picked,
        ),
        const SizedBox(height: 14),
        _Area(
          height: 28,
          label: 'Hue',
          onChange: (dx, _) => _drag(_hsv.withHue((dx * 360).clamp(0, 359.99))),
          paint: (canvas, size) {
            final rect = Offset.zero & size;
            canvas.drawRect(
                rect,
                Paint()
                  ..shader = LinearGradient(colors: [
                    for (var i = 0; i <= 6; i++) HSVColor.fromAHSV(1, i * 60.0, 1, 1).toColor(),
                  ]).createShader(rect));
          },
          x: _hsv.hue / 360,
          y: .5,
          handleColor: HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor(),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _hex,
          onChanged: _typed,
          textCapitalization: TextCapitalization.characters,
          autocorrect: false,
          enableSuggestions: false,
          style: mono(context, size: 14, color: k.ink),
          inputFormatters: [
            // "#B4581E", "b4581e" and "B4581E " all paste as B4581E.
            TextInputFormatter.withFunction((old, v) {
              final t = v.text.toUpperCase().replaceAll(RegExp('[^0-9A-F]'), '');
              final cut = t.length > 6 ? t.substring(0, 6) : t;
              return TextEditingValue(text: cut, selection: TextSelection.collapsed(offset: cut.length));
            }),
          ],
          decoration: InputDecoration(
            isDense: true,
            prefixText: '#',
            prefixStyle: mono(context, size: 14, color: k.muted),
            labelText: 'Hex',
            enabledBorder: OutlineInputBorder(borderSide: _valid ? BorderSide(color: k.border) : red),
            focusedBorder: OutlineInputBorder(borderSide: _valid ? BorderSide(color: k.accent) : red),
          ),
        ),
        if (!_valid)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Use 6 hex digits, like B4581E', style: TextStyle(fontSize: 12, color: k.removed)),
          ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: k.ground, border: Border.all(color: k.border), borderRadius: BorderRadius.circular(kRadius)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.hostName, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: shown, fontWeight: FontWeight.w600)),
            if (pulled)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(k.isDark ? 'Lightened to stay readable' : 'Darkened to stay readable',
                    style: TextStyle(fontSize: 12, color: k.muted)),
              ),
          ]),
        ),
        const SizedBox(height: 14),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          const SizedBox(width: 8),
          FilledButton(onPressed: _valid ? () => Navigator.of(context).pop(picked) : null, child: const Text('Use colour')),
        ]),
      ]),
    );
  }
}

/// A drag area that reports the pointer as 0..1 across and down, painted by [paint], with the round handle at [x], [y].
class _Area extends StatelessWidget {
  const _Area(
      {required this.height,
      required this.label,
      required this.onChange,
      required this.paint,
      required this.x,
      required this.y,
      required this.handleColor});
  final double height;
  final String label;
  final void Function(double dx, double dy) onChange;
  final void Function(Canvas, Size) paint;
  final double x, y;
  final Color handleColor;

  @override
  Widget build(BuildContext context) => Semantics(
        label: label,
        child: LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth;
          void at(Offset p) => onChange((p.dx / w).clamp(0.0, 1.0), (p.dy / height).clamp(0.0, 1.0));
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanDown: (d) => at(d.localPosition),
            onPanUpdate: (d) => at(d.localPosition),
            child: SizedBox(
              width: w,
              height: height,
              child: Stack(clipBehavior: Clip.none, children: [
                Positioned.fill(
                  child: ClipRRect(
                      borderRadius: BorderRadius.circular(4), child: CustomPaint(painter: _Painter(paint, x, y, handleColor))),
                ),
                Positioned(
                  left: x * w - 12,
                  top: y * height - 12,
                  child: IgnorePointer(
                    // A white ring on the picked colour, and a hairline outside it: seen on every colour.
                    child: Container(
                      width: 24,
                      height: 24,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0x40000000))),
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle, color: handleColor, border: Border.all(color: Colors.white, width: 2)),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          );
        }),
      );
}

class _Painter extends CustomPainter {
  _Painter(this.draw, this.x, this.y, this.color);
  final void Function(Canvas, Size) draw;
  final double x, y;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => draw(canvas, size);

  // The gradient depends on the hue: repaint whenever the picker's state moves.
  @override
  bool shouldRepaint(_Painter old) => true;
}
