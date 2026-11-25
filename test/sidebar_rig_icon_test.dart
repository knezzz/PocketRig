import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;
import 'package:pocket_rig/ui/status_shape.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';
import 'app_icon_finders.dart';
import 'package:pocket_rig/ui/app_icon.dart';

void main() {
  testWidgets('the rig icon in the sidebar tree and the project folder take the top state of their agents: needs you, working, shell, idle', (tester) async {
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
    final k = Tokens.of(tester.element(find.byType(AppShell)));
    Color? iconOf(String rig) => tester
        .widget<AppIcon>(find.descendant(
            of: find.ancestor(of: find.text(rig), matching: find.byType(InkWell)).first, matching: appIcon(AppIconKind.rig)))
        .color;

    expect(iconOf('solo'), Status.working.color(k), reason: 'one agent working');
    expect(iconOf('duo'), Status.needsYou.color(k), reason: 'one needs you, none working');
    expect(iconOf('six-seat-pipeline'), Status.needsYou.color(k), reason: 'needs you wins over working');
    expect(iconOf('twenty-char-rig-name'), Status.working.color(k), reason: 'working, nothing waiting');
    expect(iconOf('all-idle'), k.muted, reason: 'idle');

    // The project folder takes the top state over its rigs: needs you here (duo and the six-seat rig ask).
    Color? folder() => tester
        .widget<AppIcon>(find.descendant(
            of: find.ancestor(of: find.text('bars'), matching: find.byType(InkWell)).first, matching: appIcon(AppIconKind.folder)))
        .color;
    expect(folder(), Status.needsYou.color(k));

    // An agent waiting on a shell turns an otherwise idle rig the shell colour.
    final seat = fleet.feedFor(homelab).rigs.firstWhere((r) => r.rig.name == 'all-idle').seats.first;
    seat.waitingSubagents = 1;
    fleet.toggleRig('r:${homelab.id}|r-all-idle', allShown: false);
    await tester.pump(const Duration(milliseconds: 400));
    expect(iconOf('all-idle'), Status.shell.color(k), reason: 'one on a shell, none working');

    // The same rule in words, for a screen reader.
    Finder said(String rig, String label) => find.byWidgetPredicate((w) => w is Semantics && (w.properties.label ?? '').startsWith('$rig, $label'));
    expect(said('solo', 'working'), findsOneWidget);
    expect(said('six-seat-pipeline', '1 need you'), findsOneWidget);
    expect(said('duo', '1 need you'), findsOneWidget);
    expect(said('all-idle', 'waiting on shell'), findsOneWidget);

    // Folded, its seats still count.
    fleet.toggleRig('r:${homelab.id}|r-six-seat-pipeline', allShown: true);
    await tester.pump(const Duration(milliseconds: 400));
    expect(iconOf('six-seat-pipeline'), Status.needsYou.color(k), reason: 'folded seats count');
  });
}
