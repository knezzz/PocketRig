import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/tab_strip.dart';
import 'package:pocket_rig/ui/theme.dart';

void main() {
  testWidgets('TabStrip: the selected tab is ink with a 2dp underline, the others muted with none; a tap selects', (tester) async {
    var on = 0;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => TabStrip<int>(
            values: const [0, 1, 2],
            labels: const ['Info', 'Files 3', 'Images 0'],
            selected: on,
            onChanged: (i) => setState(() => on = i),
          ),
        ),
      ),
    ));
    TextStyle style(String t) => tester.widget<Text>(find.text(t)).style!;
    expect(style('Info').color, Tokens.light.ink);
    expect(style('Files 3').color, Tokens.light.muted);
    BoxDecoration deco(String t) =>
        tester.widget<AnimatedContainer>(find.ancestor(of: find.text(t), matching: find.byType(AnimatedContainer))).decoration! as BoxDecoration;
    expect((deco('Info').border! as Border).bottom.color, Tokens.light.ink);
    await tester.tap(find.text('Files 3'));
    await tester.pumpAndSettle();
    expect(on, 1);
    expect((deco('Files 3').border! as Border).bottom.color, Tokens.light.ink);
    expect((deco('Info').border! as Border).bottom.color, Colors.transparent);
  });
}
