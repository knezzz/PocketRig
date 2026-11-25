import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/kit.dart';
import 'package:pocket_rig/ui/theme.dart';

void main() {
  testWidgets('a SectionLabel is mono, caps, spaced and muted: the one caps-label style', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SectionLabel('Agents · 4'))));
    final t = tester.widget<Text>(find.text('AGENTS · 4'));
    expect(t.style?.fontFamily, mono(tester.element(find.byType(SectionLabel))).fontFamily);
    expect(t.style?.color, Tokens.light.muted);
    expect(t.style?.letterSpacing, 0.8);
  });
}
