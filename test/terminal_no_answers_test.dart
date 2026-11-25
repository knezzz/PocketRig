import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/terminal/transport.dart' show SeatTarget;
import 'package:pocket_rig/ui/chat/rig_chat_pager.dart' show RigChatPager;
import 'package:pocket_rig/ui/needs_you_banner.dart';
import 'package:pocket_rig/ui/terminal_screen.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';
import 'notify_test.dart' show alert, host, seat;

Future<void> _pump(WidgetTester tester, Widget screen) async {
  final store = await installFakes();
  await tester.pumpWidget(MaterialApp(home: phone(store, screen, root: true)));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(needsYouAlerts.reset);

  testWidgets('over a terminal the banner has no answer buttons and its top line opens the chat; elsewhere it keeps them',
      (tester) async {
    final semantics = tester.ensureSemantics();
    needsYouAlerts.show(alert(host(), seat('lead')));
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [topRoute],
      theme: buildTheme(Tokens.light, Brightness.light),
      home: const Scaffold(body: Align(alignment: Alignment.topCenter, child: NeedsYouBanner())),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Allow once'), findsOneWidget, reason: 'not over a terminal');
    expect(find.text('Deny'), findsOneWidget);

    terminalRoutes.add(topRoute.current!);
    addTearDown(terminalRoutes.clear);
    topRoute.refresh();
    await tester.pumpAndSettle();
    expect(find.text('Allow once'), findsNothing);
    expect(find.text('Deny'), findsNothing);
    expect(find.textContaining('Always'), findsNothing);
    expect(find.text('Bash · npm test'), findsOneWidget, reason: 'it still says what is asked');
    expect(find.bySemanticsLabel('Open lead'), findsOneWidget, reason: 'the top line is the way in');
    expect(find.bySemanticsLabel('Dismiss'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a terminal whose agent waits shows one "Needs you · Answer in Chat" line that opens the chat; one that does not, none',
      (tester) async {
    final lead = seatFromFixture('r-conveyor', 'lead');
    await _pump(tester, TerminalScreen(target: SeatTarget('conveyor', lead)));
    expect(find.text('Needs you · Answer in Chat'), findsOneWidget);
    expect(find.text('Allow once'), findsNothing, reason: 'the answers are in the chat');
    expect(tester.getSize(find.byType(InkWell).last).height, greaterThanOrEqualTo(44), reason: 'a finger target');
    await tester.tap(find.text('Needs you · Answer in Chat'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(RigChatPager), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));

    final impl = seatFromFixture('r-conveyor', 'impl');
    await _pump(tester, TerminalScreen(target: SeatTarget('conveyor', impl)));
    expect(find.text('Needs you · Answer in Chat'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
