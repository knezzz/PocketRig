import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// The code points a font's cmap maps (formats 4 and 12, the two the bundled fonts use).
Set<int> cmapOf(String path) {
  final b = ByteData.sublistView(Uint8List.fromList(File(path).readAsBytesSync()));
  final tables = b.getUint16(4);
  var cmap = -1;
  for (var i = 0; i < tables; i++) {
    final o = 12 + i * 16;
    if (String.fromCharCodes([for (var k = 0; k < 4; k++) b.getUint8(o + k)]) == 'cmap') cmap = b.getUint32(o + 8);
  }
  final out = <int>{};
  final n = b.getUint16(cmap + 2);
  for (var i = 0; i < n; i++) {
    final sub = cmap + b.getUint32(cmap + 4 + i * 8 + 4);
    final format = b.getUint16(sub);
    if (format == 4) {
      final segs = b.getUint16(sub + 6) ~/ 2;
      final ends = sub + 14, starts = ends + segs * 2 + 2;
      for (var s = 0; s < segs; s++) {
        final end = b.getUint16(ends + s * 2), start = b.getUint16(starts + s * 2);
        if (start != 0xFFFF) out.addAll([for (var c = start; c <= end; c++) c]);
      }
    } else if (format == 12) {
      final groups = b.getUint32(sub + 12);
      for (var g = 0; g < groups; g++) {
        final start = b.getUint32(sub + 16 + g * 12), end = b.getUint32(sub + 20 + g * 12);
        out.addAll([for (var c = start; c <= end; c++) c]);
      }
    }
  }
  return out;
}

void main() {
  test('the bundled terminal fonts cover what agents draw with in real panes (G2)', () {
    final covered = {...cmapOf('assets/fonts/JetBrainsMono-400.ttf'), ...cmapOf('assets/fonts/PocketRigGlyphs.ttf'), ...cmapOf('assets/fonts/PocketRigEmoji.ttf')};
    const wanted = {
      0x23BF: '⎿', 0x273B: '✻', 0x21A9: '↩', 0x22EF: '⋯', 0x23F5: '⏵', 0x203B: '※', 0x279C: '➜', 0x2714: '✔', 0x2717: '✗',
      0x2713: '✓', 0x232B: '⌫', 0x23F4: '⏴', 0x2722: '✢', 0x2733: '✳', 0x238B: '⎋',
      // G1's: the braille spinners, the record and pause marks, the sparkles.
      0x2800: '⠀', 0x28FF: '⣿', 0x23FA: '⏺', 0x23F8: '⏸', 0x2728: '✨',
      // The rest of the real-pane scan.
      0x25CB: '○', 0x25D0: '◐', 0x25E6: '◦', 0x29C9: '⧉', 0x22EE: '⋮',
    };
    final missing = [for (final e in wanted.entries) if (!covered.contains(e.key)) '${e.value} U+${e.key.toRadixString(16)}'];
    expect(missing, isEmpty);
    // The whole ranges that stay small: Arrows, Miscellaneous Technical (bar the emoji-style ⏩-⏰), Dingbats (bar emoji-style marks).
    final glyphs = cmapOf('assets/fonts/PocketRigGlyphs.ttf');
    for (final c in [for (var c = 0x2190; c <= 0x21FF; c++) c]) {
      expect(glyphs.contains(c), isTrue, reason: 'U+${c.toRadixString(16)} (Arrows)');
    }
  });
}
