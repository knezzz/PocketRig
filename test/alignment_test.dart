import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/tab_strip.dart';
import 'package:pocket_rig/ui/theme.dart';

/// The person's rule: things hug the left or the right edge, at the page's margin.
void main() {
  testWidgets('TabStrip: flush puts the first label at the strip\'s left edge; the others keep their own 14', (tester) async {
    Future<double> firstLeft({required bool flush}) async {
      await tester.pumpWidget(MaterialApp(
          theme: buildTheme(Tokens.light, Brightness.light),
          home: Scaffold(
              body: Padding(
                  padding: const EdgeInsets.only(left: 20),
                  child: TabStrip<int>(values: const [0, 1], labels: const ['Agents', 'Graph'], selected: 0, onChanged: (_) {}, flush: flush)))));
      await tester.pump(const Duration(milliseconds: 300)); // the tab's padding animates
      return tester.getTopLeft(find.text('Agents')).dx;
    }

    expect(await firstLeft(flush: false), 34, reason: '20 margin + 14 of the tab');
    expect(await firstLeft(flush: true), 20, reason: 'the label at the margin');
  });
}
