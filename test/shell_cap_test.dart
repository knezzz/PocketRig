import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/agent_jobs.dart';
import 'package:pocket_rig/data/fleet.dart' show fleet;
import 'package:pocket_rig/main.dart' show AppScope;
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell, jobRows;
import 'package:pocket_rig/ui/kit.dart' show AgentRow;
import 'package:pocket_rig/ui/status_shape.dart' show StatusIcon;
import 'package:pocket_rig/ui/rigs_home.dart';
import 'package:pocket_rig/ui/shells_screen.dart' show ShellsScreen;
import 'package:pocket_rig/ui/rig/seats_tab.dart';

import 'golden/fixtures.dart';

List<AgentJob> shells(int n) => AgentJob.parse([
      for (var i = 1; i <= n; i++)
        "J\t$i\tS\t0$i:00\t0\t0\t/bin/zsh -c source /h/.claude/shell-snapshots/s.sh && eval 'job $i' < /dev/null\n",
    ].join());

void main() {
  test('capShells: five shells list three and two more; exactly three list all three and no more', () {
    final five = capShells(shells(5));
    expect([for (final j in five.shown) j.short], ['job 1', 'job 2', 'job 3']);
    expect(five.more, 2);
    final three = capShells(shells(3));
    expect(three.shown, hasLength(3));
    expect(three.more, 0);
    expect(capShells(shells(0)).more, 0);
  });

  Future<void> pump(WidgetTester tester, Widget body) async {
    final store = await installFakes();
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: body)))));
    await tester.pump(const Duration(milliseconds: 300));
  }

  for (final (n, more) in [(5, 2), (3, 0)]) {
    testWidgets('the sidebar: $n shells list ${n - more}${more > 0 ? " and '+$more more'" : ' and no more row'}; each opens the full list', (tester) async {
      final opened = <String?>[];
      await pump(tester, Column(children: jobRows(shells(n), 0, (j) => opened.add(j?.short))));
      for (var i = 1; i <= 3; i++) {
        expect(find.textContaining('job $i', findRichText: true), findsOneWidget);
      }
      expect(find.textContaining('job 4', findRichText: true), findsNothing);
      expect(find.textContaining('more'), more > 0 ? findsOneWidget : findsNothing);
      expect(find.text('+0 more'), findsNothing);
      expect(find.byType(StatusIcon), findsNWidgets(3), reason: 'three shells wear the terminal icon; the +N more row has none');
      for (var i = 1; i <= 3; i++) {
        await tester.tap(find.textContaining('job $i', findRichText: true));
      }
      if (more > 0) await tester.tap(find.text('+$more more'));
      expect(opened, ['job 1', 'job 2', 'job 3', if (more > 0) null]);
    });

    testWidgets('the rig page list: $n shells list ${n - more}${more > 0 ? " and '+$more more'" : ' and no more row'}; each opens the full list', (tester) async {
      final lead = Seat(rigId: 'r', logicalId: 'lead', runtime: 'claude-code', resumeToken: 'sess-lead', activity: 'working')..jobs = shells(n);
      final opened = <String?>[];
      final seats = <String>[];
      await pump(tester, SeatList(seats: [lead], onOpen: (s) => seats.add(s.logicalId), onMore: (_) {}, onShells: (s, j) => opened.add(j?.short)));
      expect(find.textContaining('job 4', findRichText: true), findsNothing);
      expect(find.textContaining('+'), more > 0 ? findsOneWidget : findsNothing);
      expect(find.byType(StatusIcon), findsNWidgets(4), reason: 'the agent and three shells; the +N more row has no icon');
      for (var i = 1; i <= 3; i++) {
        await tester.tap(find.textContaining('job $i', findRichText: true));
      }
      if (more > 0) await tester.tap(find.text('+$more more'));
      expect(opened, ['job 1', 'job 2', 'job 3', if (more > 0) null]);
      expect(seats, isEmpty, reason: 'a shell opens the shells list, not the agent');
    });
  }

  testWidgets('the Rigs home: an agent outside a rig with five shells lists three and \'+2 more\'; a tap opens its shells list', (tester) async {
    final store = await installFakes();
    showLoose = true;
    AppShell.debugStartOnInbox = false;
    tester.view.physicalSize = const Size(390, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: phone(store, const RigsHome())));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final feed = fleet.feedFor(homelab);
    feed.jobs = {'codex-fix': shells(5)};
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    feed.notifyListeners();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('job 3', findRichText: true), findsOneWidget);
    expect(find.textContaining('job 4', findRichText: true), findsNothing);
    expect(find.ancestor(of: find.text('+2 more'), matching: find.byType(AgentRow)), findsOneWidget);
    expect(find.descendant(of: find.ancestor(of: find.text('+2 more'), matching: find.byType(AgentRow)), matching: find.byType(StatusIcon)), findsNothing, reason: 'not a shell: no terminal icon');
    expect(find.descendant(of: find.ancestor(of: find.text('job 3', findRichText: true), matching: find.byType(AgentRow)), matching: find.byType(StatusIcon)), findsOneWidget);
    await tester.tap(find.text('+2 more'));
    await tester.pumpAndSettle();
    expect(find.byType(ShellsScreen), findsOneWidget, reason: '+N more opens the full list');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('job 2', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.byType(ShellsScreen), findsOneWidget, reason: 'a shell opens it too');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
