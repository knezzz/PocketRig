import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/models.dart';

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

/// The sidebar chevron cycles collapsed > active only > all > collapsed, turning 0, 0.125, 0.25.
void main() {
  testWidgets('three taps on a project chevron and on a rig chevron cycle the three views, the arrow at 0, 0.125 and 0.25 turns', (tester) async {
    final store = await installFakes();
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('app').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final sidebar = find.ancestor(of: find.text('Add project folder').first, matching: find.byType(ListView)).first;
    double turns(String tip) => tester.widget<AnimatedRotation>(
        find.descendant(of: find.descendant(of: sidebar, matching: find.byTooltip(tip)), matching: find.byType(AnimatedRotation))).turns;

    Future<void> cycle(String name, List<String> tips, List<double> rot) async {
      for (var i = 0; i < 3; i++) {
        final tip = tips[i];
        expect(find.descendant(of: sidebar, matching: find.byTooltip(tip)), findsOneWidget, reason: '$name step $i: $tip');
        expect(turns(tip), rot[i], reason: '$name step $i');
        await tester.tap(find.descendant(of: sidebar, matching: find.byTooltip(tip)));
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    // A project starts showing all: collapsed, then active, then all again.
    fleet.setView(Fleet.folderKey(homelab, '/Users/me/code/app'), RigView.collapsed);
    await tester.pump();
    await cycle('project', ['app collapsed', 'app showing active agents', 'app showing all agents'], [0, 0.125, 0.25]);
    expect(find.descendant(of: sidebar, matching: find.byTooltip('app collapsed')), findsOneWidget, reason: 'back to collapsed');
    fleet.setView(Fleet.folderKey(homelab, '/Users/me/code/app'), RigView.all);
    await tester.pump();

    // The conveyor rig has active agents, so it cycles active, all, collapsed, active.
    await cycle('rig', ['conveyor showing active agents', 'conveyor showing all agents', 'conveyor collapsed'], [0.125, 0.25, 0]);
    expect(find.descendant(of: sidebar, matching: find.byTooltip('conveyor showing active agents')), findsOneWidget, reason: 'and round again');
  });

  testWidgets('an idle rig cycles collapsed, active only (one muted line, No active agents), all, collapsed: the middle state is reached', (tester) async {
    final store = await installFakes();
    showBarRigs = true;
    addTearDown(() => showBarRigs = false);
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('all-idle').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final sidebar = find.ancestor(of: find.text('Add project folder').first, matching: find.byType(ListView)).first;
    Finder tip(String t) => find.descendant(of: sidebar, matching: find.byTooltip(t));
    double turns(String t) => tester.widget<AnimatedRotation>(find.descendant(of: tip(t), matching: find.byType(AnimatedRotation))).turns;
    Future<void> tap(String t) async {
      await tester.drag(sidebar, const Offset(0, -300));
      await tester.pump();
      await tester.tap(tip(t));
      await tester.pump(const Duration(milliseconds: 300));
    }
    // bars' all-idle rig has nothing active: it starts folded.
    expect(tip('all-idle collapsed'), findsOneWidget);
    expect(find.text('No active agents'), findsNothing);
    await tap('all-idle collapsed');
    expect(turns('all-idle showing active agents'), 0.125, reason: 'the middle state, with nothing active');
    expect(find.descendant(of: sidebar, matching: find.text('No active agents')), findsOneWidget, reason: 'told apart from folded');
    expect(tester.getTopLeft(find.text('No active agents')).dx - tester.getRect(sidebar).left, 74, reason: 'under a rig: where its agents\' names would start');
    await tap('all-idle showing active agents');
    expect(turns('all-idle showing all agents'), 0.25);
    expect(find.descendant(of: sidebar, matching: find.text('No active agents')), findsNothing);
    await tap('all-idle showing all agents');
    expect(tip('all-idle collapsed'), findsOneWidget, reason: 'and round again');
  });

  testWidgets('an idle project cycles the same way: collapsed, active only with the line, all', (tester) async {
    final store = await installFakes();
    await pumpDesktop(tester, store);
    final feed = fleet.feedFor(homelab);
    feed.rigs = [
      RigWithSeats(Rig(id: 'ri', name: 'idlerig', nodeCount: 1, runningCount: 1, attentionCount: 0, status: 'running'),
          [Seat(rigId: 'ri', logicalId: 'a', cwd: '/w/idleproj', runtime: 'claude-code', sessionName: 'a@idlerig', activity: 'idle')]),
    ];
    // ignore: invalid_use_of_protected_member
    feed.notifyListeners();
    await tester.pump(const Duration(milliseconds: 300));
    final sidebar = find.ancestor(of: find.text('Add project folder').first, matching: find.byType(ListView)).first;
    Finder tip(String t) => find.descendant(of: sidebar, matching: find.byTooltip(t));
    Future<void> tap(String t) async {
      await tester.drag(sidebar, const Offset(0, -300));
      await tester.pump();
      await tester.tap(tip(t));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('idlerig'), findsWidgets, reason: 'a project that starts on all');
    await tap('idleproj showing all agents');
    expect(tip('idleproj collapsed'), findsOneWidget);
    await tap('idleproj collapsed');
    expect(tester.widget<AnimatedRotation>(find.descendant(of: tip('idleproj showing active agents'), matching: find.byType(AnimatedRotation))).turns, 0.125);
    expect(find.descendant(of: sidebar, matching: find.text('No active agents')), findsOneWidget);
    expect(tester.getTopLeft(find.text('No active agents')).dx - tester.getRect(sidebar).left, 53, reason: 'under a project: where its rigs\' names start');
    await tap('idleproj showing active agents');
    expect(tip('idleproj showing all agents'), findsOneWidget);
    expect(find.descendant(of: sidebar, matching: find.text('No active agents')), findsNothing);
  });
}
