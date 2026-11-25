import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/subagents.dart';
import 'package:pocket_rig/ui/rig/seat_sheet.dart';

void main() {
  testWidgets('with many subagents the sheet scrolls and leaves the scrim showing, so a tap outside closes it', (tester) async {
    final subs = [for (var i = 0; i < 40; i++) Subagent(sessionId: 's', agentId: 'a$i', type: 'Explore', description: 'job $i')];
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(onPressed: () => showSubagentsSheet(context, subs, (_) {}), child: const Text('open')),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Subagents · 40 running'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
    expect(find.text('Subagents · 40 running'), findsNothing);
  });
}
