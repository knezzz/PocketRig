import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ui/app_icon.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;
import 'package:pocket_rig/ui/project_tally.dart' show folderColor;
import 'package:pocket_rig/ui/theme.dart' show Tokens;

import 'golden/fixtures.dart';
import 'sidebar_fold_helper.dart';

void main() {
  Future<void> pump(WidgetTester tester) async {
    final store = await installFakes();
    showBarRigs = true;
    addTearDown(() => showBarRigs = false);
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(
        store: store,
        child: MediaQuery(
            data: const MediaQueryData(size: Size(1280, 1400)),
            child: MaterialApp(home: AppShell(key: UniqueKey())))));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('a folder row long-press list sets all, fold or active only; active lists only the rigs and loose agents that '
      'work or need you; with nothing active the cycle still reaches it', (tester) async {
    await pump(tester);
    // 'bars' has solo (working), duo and the six-seat rig (need you), all-idle (nothing); starts on all.
    final bars = find.text('bars').first;
    expect(find.text('all-idle'), findsOneWidget);
    await chooseView(tester, bars, 'Fold');
    expect(find.text('solo'), findsNothing, reason: 'collapsed');
    await chooseView(tester, bars, 'Show active only');
    expect(find.text('solo'), findsOneWidget);
    expect(find.text('duo'), findsOneWidget);
    expect(find.text('all-idle'), findsNothing, reason: 'a rig with nothing active is not in the active view');
    await chooseView(tester, bars, 'Show all');
    expect(find.text('all-idle'), findsOneWidget);

    // A folder with nothing active still cycles through active only: all, collapsed, active, all.
    final f = Fleet();
    expect(f.viewOf('k', false, start: RigView.all), RigView.all);
    f.cycle('k', false, start: RigView.all);
    expect(f.viewOf('k', false, start: RigView.all), RigView.collapsed);
    f.cycle('k', false, start: RigView.all);
    expect(f.viewOf('k', false, start: RigView.all), RigView.active, reason: 'kept with nothing active');
    f.cycle('k', false, start: RigView.all);
    expect(f.viewOf('k', false, start: RigView.all), RigView.all);
    // A rig nobody chose a view for opens folded when idle; a chosen active view stays.
    expect(f.viewOf('r', false), RigView.collapsed);
    f.setView('r', RigView.active);
    expect(f.viewOf('r', false), RigView.active);
    f.cycle('k', true, start: RigView.all);
    f.cycle('k', true, start: RigView.all);
    expect(f.viewOf('k', true, start: RigView.all), RigView.active);
  });

  testWidgets('the chevron at the right edge of a folder row cycles collapsed, active only, all; the row text starts at the icon', (tester) async {
    await pump(tester);
    expect(find.text('solo'), findsOneWidget);
    await tester.tap(find.byTooltip('bars showing all agents'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('solo'), findsNothing);
    expect(find.byTooltip('bars collapsed'), findsOneWidget);
    await tester.tap(find.byTooltip('bars collapsed'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('all-idle'), findsNothing, reason: 'the second view is active only');
    await tester.tap(find.byTooltip('bars showing active agents'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('all-idle'), findsOneWidget, reason: 'the third is all');
    // No fold slot: the name sits 47dp in (touch: 16 inset, 6 fill inset, 16 icon, 9 gap); the chevron is at the row's right.
    expect(tester.getTopLeft(find.text('bars').first).dx - tester.getTopLeft(find.byKey(const ValueKey('sidebar'))).dx, 47);
    final chev = tester.getCenter(find.byTooltip('bars showing all agents')).dx;
    expect(chev, greaterThan(tester.getTopLeft(find.byKey(const ValueKey('sidebar'))).dx + 200));
  });

  testWidgets('a sidebar folder is orange when an agent works or waits there, grey when nothing does', (tester) async {
    await pump(tester);
    Color? folder(String name) => tester
        .widget<AppIcon>(find.descendant(
            of: find.ancestor(of: find.text(name).first, matching: find.byType(InkWell)).first,
            matching: find.byWidgetPredicate((w) => w is AppIcon && w.kind == AppIconKind.folder)))
        .color;
    expect(folder('bars'), Tokens.light.accent, reason: 'an agent needs you: orange');
    expect(folder('dotfiles'), Tokens.light.faint, reason: 'nothing runs there: the greyed, kept folder');
  });

  testWidgets('a project lists its rigs needs you, working, then idle, by name inside a tier: never by activity', (tester) async {
    await pump(tester);
    double y(String name) => tester.getTopLeft(find.text(name).first).dy;
    expect(y('duo'), lessThan(y('solo')), reason: 'needs you before working');
    expect(y('six-seat-pipeline'), lessThan(y('solo')));
    expect(y('solo'), lessThan(y('all-idle')), reason: 'working before idle');
  });

  test('folderColor: orange only when an agent needs you, green when some work and none need you, grey otherwise', () {
    const k = Tokens.light;
    expect(folderColor(k, needs: 1, working: 0), k.accent);
    expect(folderColor(k, needs: 2, working: 3), k.accent, reason: 'needs you wins over working');
    expect(folderColor(k, needs: 0, working: 2), k.added);
    expect(folderColor(k, needs: 0, working: 0), k.muted);
  });
}
