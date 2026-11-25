import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/kit.dart' show AgentRow;
import 'package:pocket_rig/ui/status_shape.dart';
import 'package:pocket_rig/ui/theme.dart';

void main() {
  testWidgets('AgentRow: with ageOnTitle the age is on the name line; without it, it is centred in the row', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: const Scaffold(
        body: Column(children: [
          AgentRow(name: 'on-title', status: Status.needsYou, task: 'Permission · lead wants to run', age: '2m', ageOnTitle: true),
          AgentRow(name: 'centred', status: Status.needsYou, task: 'Permission · lead wants to run', age: '3m'),
        ]),
      ),
    ));
    double dy(String t) => tester.getCenter(find.text(t, findRichText: true)).dy;
    expect((tester.getCenter(find.text('2m')).dy - dy('on-title')).abs(), lessThan(4), reason: 'one line with the name');
    expect(tester.getCenter(find.text('3m')).dy, greaterThan(dy('centred') + 4), reason: 'centred, between the two lines');
  });
}
