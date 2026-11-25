import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/switch_row.dart';
import 'package:pocket_rig/ui/theme.dart';

void main() {
  testWidgets('the one switch row: title, muted line, and a switch that reports its change', (tester) async {
    var on = false;
    await tester.pumpWidget(MaterialApp(
        home: Material(
            child: StatefulBuilder(
                builder: (context, set) => SwitchRow('Notify me', subtitle: 'Needs a topic', value: on, onChanged: (v) => set(() => on = v))))));
    expect(find.text('Notify me'), findsOneWidget);
    expect(tester.widget<Text>(find.text('Needs a topic')).style!.color, Tokens.light.muted);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(on, isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });
}
