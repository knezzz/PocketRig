import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/rig/overview_tab.dart' show StartingCard;
import 'package:pocket_rig/ui/rig/seats_tab.dart';
import 'package:pocket_rig/ui/theme.dart' show Tokens, animateStatusSpinners;

import 'golden/fixtures.dart';

Seat _seat(String id, {String? startup}) => Seat.fromJson({
      ...nodes['r-conveyor']!.firstWhere((n) => n['logicalId'] == 'impl'),
      'logicalId': id,
      'startupStatus': startup,
    });

void main() {
  setUp(() => animateStatusSpinners = false);

  test('a seat is not ready while its startup is pending', () {
    expect(_seat('a', startup: 'pending').notReady, isTrue);
    expect(_seat('a', startup: 'ready').notReady, isFalse);
    expect(_seat('a').notReady, isFalse);
    expect(seatLine(_seat('a', startup: 'pending')), 'not ready');
  });

  testWidgets('a starting seat row is dimmed, says "not ready", shows no context and opens nothing; the card counts the seats up',
      (tester) async {
    final store = await installFakes();
    var opened = 0;
    final seats = [_seat('lead', startup: 'ready'), _seat('impl', startup: 'pending')];
    await tester.pumpWidget(MaterialApp(
        home: phone(
            store,
            SingleChildScrollView(
                child: Column(children: [
              StartingCard(agents: seats),
              SeatList(seats: seats, onOpen: (_) => opened++, onMore: (_) {}),
            ])))));
    await tester.pump();
    expect(find.text('STARTING…'), findsOneWidget);
    expect(find.text('Setting up the rig · 1 of 2 seats up · not ready yet'), findsOneWidget);
    expect(find.text('not ready'), findsOneWidget);
    await tester.tap(find.textContaining('impl', findRichText: true).first);
    await tester.pump();
    expect(opened, 0, reason: 'nothing to open until the seat is up');
    await tester.tap(find.textContaining('lead', findRichText: true).first);
    await tester.pump();
    expect(opened, 1, reason: 'a ready seat opens');
  });

  testWidgets('the starting card is neutral (an ink badge, no accent) and its bar moves; with reduce-motion it is still', (tester) async {
    final store = await installFakes();
    final seats = [_seat('lead', startup: 'ready'), _seat('impl', startup: 'pending')];
    Widget card({bool reduce = false}) => MaterialApp(
        home: phone(store, MediaQuery(data: MediaQueryData(disableAnimations: reduce), child: Scaffold(body: StartingCard(agents: seats)))));
    animateStatusSpinners = true;
    await tester.pumpWidget(card());
    await tester.pump(const Duration(milliseconds: 100));
    final badge = tester.widget<Container>(find.ancestor(of: find.text('STARTING…'), matching: find.byType(Container)).first);
    expect((badge.decoration as BoxDecoration).color, Tokens.light.ink, reason: 'ink, not the needs-you accent');
    expect(tester.hasRunningAnimations, isTrue, reason: 'the stripes move');
    await tester.pumpWidget(card(reduce: true));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.hasRunningAnimations, isFalse, reason: 'still with reduce-motion');
  });
}
