import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/rig_spec.dart';
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/launch_sheet.dart';
import 'package:pocket_rig/ui/project_screen.dart';
import 'package:pocket_rig/ui/seat_leaf.dart' show SeatLeaf;
import 'package:pocket_rig/ui/rig/seat_sheet.dart';
import 'package:pocket_rig/ui/rig_screen.dart';
import 'package:pocket_rig/ui/terminal_screen.dart';
import 'package:pocket_rig/ui/tiles_screen.dart';

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';
import 'sidebar_fold_helper.dart';

void main() {
  testWidgets('desktop: a screen opened from a sheet lands in the content panel, the sidebar stays', (tester) async {
    final store = await installFakes();
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('app').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.tap(find.text('app').first);
    await tester.pump(const Duration(seconds: 1));
    final inProject = tester.element(find.byType(ProjectScreen));

    // The seat sheet's own Chat button, as any screen offering it without its own opener gets it.
    unawaited(showSeatSheet(inProject, 'conveyor', seatFromFixture('r-conveyor', 'lead')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.tap(find.text('Chat').last);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.text('Add project folder'), findsWidgets, reason: 'the sidebar is still there');
    expect(find.byType(ProjectScreen, skipOffstage: false), findsOneWidget, reason: 'the project is under it');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('desktop: Open rig in the launch dialog opens it in the content panel, the sidebar stays', (tester) async {
    final store = await installFakes();
    // The fake daemon, plus a launch that comes up as conveyor.
    OpenRigClient.factory = (h) {
      final daemon = fakeDaemon(h);
      return OpenRigClient(h,
          eventSource: ({rigId, replay, lastEventId}) => const Stream.empty(),
          httpClient: MockClient((req) async {
            if (req.url.path == '/api/up') {
              final plan = (jsonDecode(req.body) as Map)['plan'] == true;
              return http.Response(
                  jsonEncode(plan
                      ? {
                          'status': 'planned',
                          'stages': [
                            {'stage': 'resolve_spec', 'status': 'ok'}
                          ]
                        }
                      : {'status': 'completed', 'rigId': 'r-conveyor'}),
                  200);
            }
            final copy = http.Request(req.method, req.url)
              ..headers.addAll(req.headers)
              ..bodyBytes = req.bodyBytes;
            return http.Response.fromStream(await daemon.send(copy));
          }));
    };
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('app').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.tap(find.text('app').first);
    await tester.pump(const Duration(seconds: 1));

    unawaited(showLaunchSheet(tester.element(find.byType(ProjectScreen)),
        file: RigSpecFile(path: '/p/rig.yaml', projectPath: '/p'),
        spec: RigSpecSummary.parse('version: "0.2"\nname: conveyor\npods:\n  - id: core\n    members:\n      - id: lead\n        runtime: claude-code\n'),
        projectName: 'app'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.tap(find.text('Start rig'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.tap(find.widgetWithText(FilledButton, 'Open rig'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    expect(find.byType(RigScreen), findsOneWidget);
    // The rig header's line under the title names the project and the host (in its colour).
    expect(find.descendant(of: find.byType(RigScreen), matching: find.text('app')), findsOneWidget, reason: 'the project');
    expect(find.descendant(of: find.byType(RigScreen), matching: find.text(homelab.name)), findsOneWidget, reason: 'the host');
    expect(find.text('Add project folder'), findsWidgets, reason: 'the sidebar is still there');
    expect(find.byType(ProjectScreen, skipOffstage: false), findsOneWidget, reason: 'the project is under it');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('desktop: the sidebar lists a busy agent outside a rig under its project, and opens it', (tester) async {
    final store = await installFakes();
    showLoose = true; // scratch waits on a permission in app
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('scratch').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final sidebar = find.ancestor(of: find.text('Add project folder').first, matching: find.byType(ListView));
    final scratch = find.descendant(of: sidebar, matching: find.text('scratch'));
    expect(scratch, findsOneWidget);
    await tester.tap(scratch);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TerminalScreen), findsOneWidget, reason: 'it opens in the content panel, as its terminal');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('desktop: the sidebar lists running rigs with their working seats; unfold shows all, a seat opens in the panel',
      (tester) async {
    final store = await installFakes();
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('app').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final sidebar = find.ancestor(of: find.text('Add project folder').first, matching: find.byType(ListView));
    Finder side(String text) => find.descendant(of: sidebar, matching: find.text(text));
    // app runs conveyor (impl working; lead and review need you, tests idle) and adversarial-review (attacker working).
    expect(side('conveyor'), findsOneWidget);
    expect(side('attacker'), findsOneWidget, reason: 'working: listed unasked');
    expect(side('review'), findsOneWidget, reason: 'needs you: listed unasked');
    expect(side('tests'), findsNothing, reason: 'idle: only after Unfold');
    // The rig row's long-press list (no chevron) sets the view: all, fold, active only.
    final rig = side('conveyor');
    await chooseView(tester, rig, 'Show all');
    expect(side('review'), findsOneWidget);
    expect(side('tests'), findsOneWidget);
    await chooseView(tester, rig, 'Fold');
    expect(side('review'), findsNothing);
    expect(side('tests'), findsNothing);
    await chooseView(tester, rig, 'Show active only');
    expect(side('review'), findsOneWidget);
    expect(side('tests'), findsNothing);
    await chooseView(tester, rig, 'Fold');
    expect(side('review'), findsNothing, reason: 'left collapsed, as the project tab below expects');

    await tester.tap(side('attacker'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final tiles = tester.widget<TilesScreen>(find.byType(TilesScreen));
    expect((tiles.rig.name, tiles.enlarge), ('adversarial-review', 'attacker'),
        reason: 'the seat opens as a double click in its tiles does: enlarged');
    expect(find.byType(TerminalScreen), findsNothing, reason: 'no separate terminal screen');
    await tester.pump();
    expect(tester.widget<Text>(side('attacker')).style?.fontWeight, FontWeight.w600, reason: 'the agent on show is marked');
    expect(tester.widget<Text>(side('adversarial-review').first).style?.fontWeight, FontWeight.w600, reason: 'its rig holds it');
    expect(tester.widget<Text>(side('app').first).style?.fontWeight, FontWeight.w800, reason: 'so does its project');
    expect(tester.widget<Text>(side('conveyor')).style?.fontWeight, FontWeight.w400, reason: 'not the other rig (folded: a plain row)');
    expect(find.descendant(of: find.byType(TilesScreen), matching: find.textContaining(homelab.name, findRichText: true)), findsOneWidget,
        reason: 'the tiles name the host');

    await tester.tap(find.text('app').first);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ProjectScreen), findsOneWidget, reason: 'a project fills the content panel');
    expect(tester.widget<Text>(side('attacker')).style?.fontWeight, FontWeight.w400);
    expect(find.byType(TilesScreen), findsNothing);
    expect(find.descendant(of: find.byType(ProjectScreen), matching: find.text(homelab.name)), findsOneWidget);

    // The project's Agents tab is one flat list of agents (not folded by rig), each tagged with its worktree.
    await tester.tap(find.descendant(of: find.byType(ProjectScreen), matching: find.text('Agents')));
    await tester.pump(const Duration(milliseconds: 500));
    Finder seatsOf(String rig) => find.descendant(
        of: find.byType(ProjectScreen), matching: find.byWidgetPredicate((w) => w is SeatLeaf && w.rigName == rig));
    expect(seatsOf('conveyor'), findsWidgets);
    expect(seatsOf('adversarial-review'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('desktop: a rig in the sidebar opens its tiles; another rig switches the panel to its tiles', (tester) async {
    final store = await installFakes();
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('app').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final sidebar = find.ancestor(of: find.text('Add project folder').first, matching: find.byType(ListView));
    Finder side(String text) => find.descendant(of: sidebar, matching: find.text(text));

    await tester.tap(side('conveyor'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TilesScreen), findsOneWidget);
    expect(tester.widget<TilesScreen>(find.byType(TilesScreen)).rig.name, 'conveyor');
    expect(find.byType(RigScreen), findsNothing, reason: 'the rig screen opens from the tiles, not first');
    expect(find.text('Add project folder'), findsWidgets, reason: 'the sidebar stays beside the tiles');
    await tester.pump(); // the panel reports what it shows after its frame
    FontWeight? weight(String text) => tester.widget<Text>(side(text)).style?.fontWeight;
    expect(weight('conveyor'), FontWeight.w600, reason: 'the sidebar marks the rig on show');
    expect(weight('app'), FontWeight.w800, reason: 'the project holding it');

    await tester.tap(side('adversarial-review'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TilesScreen), findsOneWidget);
    expect(tester.widget<TilesScreen>(find.byType(TilesScreen)).rig.name, 'adversarial-review');
    await tester.pump();
    expect(weight('adversarial-review'), FontWeight.w600);
    expect(weight('conveyor'), FontWeight.w400);

    // Another agent of the rig on show enlarges in the same tiles: no new screen, no reconnect.
    final shown = tester.state(find.byType(TilesScreen));
    await tester.tap(side('attacker'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(tester.state(find.byType(TilesScreen)), same(shown));
    expect(weight('attacker'), FontWeight.w600, reason: 'the enlarged agent is marked');
    expect(weight('adversarial-review'), FontWeight.w600, reason: 'its rig, on the path');

    await tester.tap(find.descendant(of: find.byType(TilesScreen), matching: find.text('Rig details')));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(RigScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
