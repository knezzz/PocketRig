import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/empty_note.dart';
import 'package:pocket_rig/ui/theme.dart';

void main() {
  testWidgets('EmptyNote: a bold headline over one muted line, centred in whatever space it gets', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: const Scaffold(body: EmptyNote('Nothing needs you', 'Agents that wait for an answer or a permission show up here.')),
    ));
    final head = tester.widget<Text>(find.text('Nothing needs you'));
    expect(head.style!.fontWeight, FontWeight.w700);
    expect(tester.widget<Text>(find.text('Agents that wait for an answer or a permission show up here.')).style!.color, Tokens.light.muted);
    expect(tester.getCenter(find.byType(EmptyNote)).dx, closeTo(tester.getCenter(find.byType(Scaffold)).dx, 1));
    expect(tester.getCenter(find.text('Nothing needs you')).dx, closeTo(400, 1));
  });
}
