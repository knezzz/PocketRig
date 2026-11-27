import 'package:flutter/material.dart';

import '../models.dart';
import 'theme.dart';

/// Colors a host's name can take: none of them the agents' status colors (green, blue, orange), so a host never reads
/// as a state.
const hostPalette = <Color>[
  Color(0xFF8E44AD), // purple
  Color(0xFFC2185B), // magenta
  Color(0xFF00897B), // teal
  Color(0xFF3949AB), // indigo
  Color(0xFF8D6E63), // brown
  Color(0xFF0097A7), // cyan
  Color(0xFF7C8A1E), // olive
  Color(0xFF546E7A), // slate
];

/// [host]'s color: the one picked in its settings, else one fixed by its id, so two hosts differ without setup.
/// With [k], a square or dot drawn on its ground is lifted to 3:1 (the saved value stays); without, the raw colour.
Color hostColor(Host host, [Tokens? k]) {
  final c = host.color != null ? Color(host.color!) : hostPalette[host.id.codeUnits.fold(0, (a, b) => a + b) % hostPalette.length];
  return k == null ? c : readableOn(c, k.ground, minContrast: 3);
}

/// WCAG contrast of [a] over [b].
double contrastRatio(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (x > y ? x + .05 : y + .05) / (x > y ? y + .05 : x + .05);
}

/// [c] as text on [ground]: when it is too close to the ground to read, its lightness moves (up on a dark ground, down on
/// a light one) until it reaches [minContrast]; hue and saturation stay, so it is still the colour that was picked.
Color readableOn(Color c, Color ground, {double minContrast = 4.5}) {
  if (contrastRatio(c, ground) >= minContrast) return c;
  final hsl = HSLColor.fromColor(c);
  final up = ground.computeLuminance() < .5;
  var l = hsl.lightness;
  while (contrastRatio(hsl.withLightness(l).toColor(), ground) < minContrast && (up ? l < 1 : l > 0)) {
    l = (up ? l + .01 : l - .01).clamp(0.0, 1.0);
  }
  return hsl.withLightness(l).toColor();
}

/// The color [host]'s name is drawn in on [k]'s ground: its own, pulled toward readable when it is not.
Color hostTextColor(Host host, Tokens k) => readableOn(hostColor(host), k.ground);

/// [host]'s name in its color, for a header's overline, with [rest] after it (" · project") in [style].
Widget hostOverline(Host host, TextStyle? style, {String? rest, int maxLines = 1}) => Builder(
      builder: (context) => Text.rich(
        TextSpan(style: style, children: [
          TextSpan(text: host.name, style: TextStyle(color: hostTextColor(host, Tokens.of(context)), fontWeight: FontWeight.w600)),
          if (rest != null) TextSpan(text: ' · $rest'),
        ]),
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
      ),
    );
