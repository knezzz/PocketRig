import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/host_color.dart';
import 'package:pocket_rig/ui/kit.dart';
import 'package:pocket_rig/ui/theme.dart';

void main() {
  for (final k in [Tokens.light, Tokens.dark]) {
    final name = k.isDark ? 'dark' : 'light';
    final th = buildTheme(k, k.isDark ? Brightness.dark : Brightness.light);
    double ratio(Color a, Color b) => contrastRatio(a, b);
    const off = {WidgetState.disabled};

    test('$name: the themed buttons read, enabled and disabled', () {
      final f = th.filledButtonTheme.style!, o = th.outlinedButtonTheme.style!, t = th.textButtonTheme.style!;
      expect(ratio(f.foregroundColor!.resolve({})!, f.backgroundColor!.resolve({})!), greaterThanOrEqualTo(4.5), reason: 'filled');
      expect(ratio(f.foregroundColor!.resolve(off)!, f.backgroundColor!.resolve(off)!), greaterThanOrEqualTo(4.5), reason: 'filled, disabled');
      expect(ratio(o.foregroundColor!.resolve(off)!, k.ground), greaterThanOrEqualTo(4.5), reason: 'outlined, disabled');
      expect(ratio(t.foregroundColor!.resolve(off)!, k.ground), greaterThanOrEqualTo(4.5), reason: 'text, disabled');
    });

    test('$name: the destructive fill and red outline read', () {
      expect(ratio(k.onAccent, k.kill), greaterThanOrEqualTo(4.5), reason: 'text on the red fill');
      expect(ratio(outlinedRed(k), k.ground), greaterThanOrEqualTo(4.5), reason: 'red outline text on the ground');
    });
  }
}
