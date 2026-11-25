import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/kit.dart' show Segmented;
import 'package:pocket_rig/ui/theme.dart';

void main() {
  testWidgets('sheetAction is 48 tall; a compactAction button looks 32 but its tap target is at least 48, on a phone and on a Mac', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: Scaffold(
        body: Column(children: [
          FilledButton(onPressed: () {}, style: sheetAction, child: const Text('Sheet')),
          TextButton(onPressed: () {}, style: compactAction, child: const Text('Compact')),
        ]),
      ),
    ));
    expect(tester.getSize(find.widgetWithText(FilledButton, 'Sheet')).height, 48);
    final compact = find.widgetWithText(TextButton, 'Compact');
    expect(tester.getSize(compact).height, greaterThanOrEqualTo(48), reason: 'the hit area pads out to 48');
    expect(tester.getSize(find.descendant(of: compact, matching: find.byType(Material)).first).height, 32,
        reason: 'what you see is 32');
  }, variant: const TargetPlatformVariant({TargetPlatform.android, TargetPlatform.macOS}));

  testWidgets('Segmented: every label takes one shared size, so a long one does not shrink alone', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const labels = ['Files 3', 'Images 12', 'Artifacts 2', 'Subagents 0', 'Shells 0'];
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(12),
          child: Segmented<int>(values: const [0, 1, 2, 3, 4], labels: labels, selected: 0, onChanged: (_) {}),
        ),
      ),
    ));
    final sizes = {for (final l in labels) tester.widget<Text>(find.text(l)).style!.fontSize};
    expect(sizes.length, 1, reason: 'one size for all five');
    expect(sizes.single, lessThan(13), reason: 'and it is shrunk to fit the phone');
  });
}
