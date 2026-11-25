import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/theme.dart';
import 'package:pocket_rig/ui/usage_strip.dart';

void main() {
  test('pace colour: the shared cases', () {
    final cases = (jsonDecode(File('test/fixtures/pace_colour.json').readAsStringSync())['cases'] as List).cast<Map>();
    for (final c in cases) {
      final (from, to, t) = paceStops(c['ahead'] as int);
      expect((from, to), (c['from'], c['to']), reason: 'ahead ${c['ahead']}');
      expect(t, closeTo((c['t'] as num).toDouble(), 1e-9), reason: 'ahead ${c['ahead']}');
    }
  });

  test('pace colour: green at or under -5, gray on pace, red at or over +5, on both themes', () {
    for (final k in [Tokens.light, Tokens.dark]) {
      expect(paceColor(-20, k), k.added);
      expect(paceColor(-5, k), k.added);
      expect(paceColor(0, k), k.muted);
      expect(paceColor(5, k), k.removed);
      expect(paceColor(40, k), k.removed);
      expect(paceColor(3, k), Color.lerp(k.muted, k.removed, 3 / 5));
    }
  });
}
