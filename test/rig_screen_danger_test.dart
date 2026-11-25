import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell, shownDetailPane;
import 'package:pocket_rig/ui/recent_screen.dart' show RecentScreen;
import 'package:pocket_rig/ui/rig/overview_tab.dart' show RigBody;
import 'package:pocket_rig/ui/rig_screen.dart';

import 'golden/fixtures.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    for (final (name, label, other, confirm) in [
      ('conveyor', 'Stop rig…', 'Delete rig…', 'Snapshot & stop'),
      ('research-team', 'Delete rig…', 'Stop rig…', 'Delete research-team?'),
    ]) {
      testWidgets('the Agents tab ends with the Danger zone: $label, stacked under its text, for $name at $size, tappable, and it asks before it acts; Progress has none; the header ⋯ ends with it too', (tester) async {
        final store = await installFakes();
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await fleet.feedFor(homelab).refresh();
        final rig = fleet.feedFor(homelab).rigs.map((r) => r.rig).firstWhere((r) => r.name == name);
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(MaterialApp(home: phone(store, RigScreen(rig: rig, projectName: 'app'))));
        for (var i = 0; i < 25; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        // The header's ⋯: the last entry is the red Stop (Delete once stopped), the same one-tap way in.
        await tester.tap(find.byTooltip('Rig options'));
        await tester.pumpAndSettle();
        final sheet = find.byType(BottomSheet);
        expect(find.descendant(of: sheet, matching: find.text(label)), findsOneWidget, reason: 'the header ⋯ lists $label');
        expect(find.descendant(of: sheet, matching: find.text(other)), findsNothing);
        await tester.tapAt(const Offset(5, 5)); // closes the sheet
        await tester.pumpAndSettle();

        final button = find.widgetWithText(OutlinedButton, label);
        final list = tester.state<ScrollableState>(find.descendant(of: find.byType(RigBody), matching: find.byType(Scrollable)).first).position;
        for (var i = 0; i < 3; i++) {
          list.jumpTo(list.maxScrollExtent); // to the foot of the tab (its extent firms up as rows build)
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Danger zone'), findsOneWidget);
        expect(tester.getTopLeft(button).dy, greaterThan(tester.getBottomLeft(find.text('Danger zone')).dy), reason: 'the text, then the button');
        expect(find.widgetWithText(OutlinedButton, other), findsNothing, reason: 'Stop while it runs, Delete once stopped');
        expect(tester.getSemantics(button).getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
        await tester.tap(find.text('Progress'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Danger zone'), findsNothing, reason: 'one card: it moved from Progress to the Agents tab');
        await tester.tap(find.text('Agents'));
        await tester.pump(const Duration(milliseconds: 300));

        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.text(confirm), findsOneWidget, reason: 'the same confirm as the list');
        handle.dispose();
      });
    }
  }

  testWidgets('deleting a rig from its page at the root of the content panel leaves the panel on the Inbox, not empty', (tester) async {
    final store = await installFakes();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await fleet.feedFor(homelab).refresh();
    final rig = fleet.feedFor(homelab).rigs.map((r) => r.rig).firstWhere((r) => r.name == 'research-team');
    // The fake daemon has no /api/down: this one deletes.
    final inner = OpenRigClient.factory;
    OpenRigClient.factory = (h) => OpenRigClient(h,
        httpClient: MockClient((req) async => req.url.path == '/api/down'
            ? http.Response(jsonEncode({'deleted': true}), 200, headers: {'content-type': 'application/json'})
            : fakeDaemon(h).get(req.url)));
    addTearDown(() => OpenRigClient.factory = inner);
    AppScope.resetClients();
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: AppShell(key: UniqueKey()))));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The rig's page as the only route of the panel, as the shell shows a rig on the phone's drawer path.
    final pane = shownDetailPane()!;
    pane.pushReplacement(MaterialPageRoute<void>(builder: (_) => RigScreen(rig: rig, projectName: 'loyalty')));
    await tester.pumpAndSettle();
    expect(pane.canPop(), isFalse);
    expect(find.byType(RigScreen), findsOneWidget);

    final list2 = tester.state<ScrollableState>(find.descendant(of: find.byType(RigBody), matching: find.byType(Scrollable)).first).position;
    for (var i = 0; i < 3; i++) {
      list2.jumpTo(list2.maxScrollExtent);
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete rig…'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('Continue')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('Delete rig')));
    await tester.pumpAndSettle();
    expect(find.byType(RigScreen), findsNothing, reason: 'the deleted rig is gone from the panel');
    expect(find.byType(RecentScreen), findsOneWidget, reason: 'and the panel shows what it shows with nothing selected');
  });
}
