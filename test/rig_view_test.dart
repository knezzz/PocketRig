import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;

import 'golden/fixtures.dart';
import 'sidebar_fold_helper.dart';

void main() {
  testWidgets('a rig row long-press list sets active only, all or fold, and offers no active step when no agent '
      'works or waits', (tester) async {
    final store = await installFakes();
    showBarRigs = true;
    addTearDown(() => showBarRigs = false);
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: AppShell(key: UniqueKey()))));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final rigs = fleet.feedFor(homelab).rigs;
    Iterable<String> idsOf(String rig, bool Function(Seat) f) =>
        rigs.firstWhere((r) => r.rig.name == rig).seats.where((s) => s.isAgent && f(s)).map((s) => s.logicalId);
    // Only the rig's own rows: the label under the sidebar's list.
    int shown(Iterable<String> ids) => ids.where((i) => find.text(i).evaluate().isNotEmpty).length;
    // 'six-seat-pipeline': some seats work or wait, the rest idle.
    final active = idsOf('six-seat-pipeline', Fleet.seatActive).toList();
    final idle = idsOf('six-seat-pipeline', (s) => !Fleet.seatActive(s)).toList();
    expect(active, isNotEmpty);
    expect(idle, isNotEmpty);
    // Starts on active: only the working and waiting seats, the way the row's dot reads.
    final six = find.text('six-seat-pipeline').first;
    expect(shown(active), active.length);
    expect(shown(idle), 0, reason: 'idle seats are not in the active view');
    await chooseView(tester, six, 'Show all');
    expect(shown(active) + shown(idle), active.length + idle.length, reason: 'all');
    await chooseView(tester, six, 'Fold');
    expect(shown(active) + shown(idle), 0, reason: 'collapsed');
    await chooseView(tester, six, 'Show active only');
    expect(shown(active), active.length, reason: 'back to active');

    // 'all-idle': nothing active, so the list has no Show active only.
    final all = idsOf('all-idle', (_) => true).toList();
    final idleRig = find.text('all-idle').first;
    expect(shown(all), 0, reason: 'an active view with no active agent is collapsed');
    await tester.longPress(idleRig);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Show active only'), findsNothing);
    expect(find.text('Fold'), findsNothing, reason: 'already collapsed');
    await tester.tap(find.text('Show all'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(shown(all), all.length);

    // An agent that goes idle in the active view drops out; with none left the rig shows collapsed.
    final f = Fleet();
    final w = Seat(rigId: 'r', logicalId: 'w', activity: 'working'), q = Seat(rigId: 'r', logicalId: 'q');
    expect(f.rigSeatsShown('k', [w, q]), [w]);
    expect(f.rigView('k', [Seat(rigId: 'r', logicalId: 'w'), q]), RigView.collapsed);
    final busy = Seat(rigId: 'r', logicalId: 'b')..waitingSubagents = 1;
    expect(f.rigSeatsShown('k', [busy, q]), [busy], reason: 'idle while its subagents run: active');
    f.cycleRig('k', [w, q]);
    f.cycleRig('k', [w, q]);
    expect(f.rigView('k', [w, q]), RigView.collapsed, reason: 'active > all > collapsed');
  });
}
