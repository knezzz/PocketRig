import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/kit.dart' show SectionLabel;
import 'package:pocket_rig/ui/recent_screen.dart';
import 'package:pocket_rig/ui/rig/rig_chat.dart';

import 'golden/fixtures.dart';

void main() {
  testWidgets("the Inbox's section labels are the kit label, as on every other page", (tester) async {
    final store = await installFakes();
    tester.view.physicalSize = const Size(390, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: phone(store, const RecentScreen(), root: true))));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.widgetWithText(SectionLabel, 'NEEDS YOU · 3'), findsOneWidget);
    expect(find.widgetWithText(SectionLabel, 'HANDOFFS'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a handoff with an unknown sender shows only where it went, with its age', (tester) async {
    final item = QueueItem(
        id: 'q', summary: 'Slice 3', state: 'pending', destinationSession: 'impl@conveyor', updated: DateTime.now().subtract(const Duration(minutes: 2)));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: RigChatMessage(item: item, onTap: () {}, withRigs: true))));
    expect(find.textContaining('someone'), findsNothing);
    expect(find.textContaining('→'), findsNothing);
    expect(find.textContaining('impl@conveyor'), findsOneWidget);
    expect(find.textContaining('2m'), findsOneWidget, reason: 'the age, as on the Needs-you cards');
    // A known sender is named as before.
    final from = QueueItem(id: 'q2', summary: 's', state: 'pending', sourceSession: 'lead@conveyor', destinationSession: 'impl@conveyor');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: RigChatMessage(item: from, onTap: () {}, withRigs: true))));
    expect(find.textContaining('lead@conveyor'), findsOneWidget);
  });
}
