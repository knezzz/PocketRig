import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/rig_spec.dart';
import 'package:pocket_rig/ui/kit.dart' show KillBar;
import 'package:pocket_rig/ui/launch_sheet.dart' show LaunchSheet;
import 'package:pocket_rig/ui/rig_screen.dart';
import 'package:pocket_rig/ui/spec_screen.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

const _spec = '''version: "3"
name: web
pods:
  - id: dev
    members:
      - id: builder
        runtime: claude-code
''';

void main() {
  setUp(() => animateStatusSpinners = false);

  testWidgets('the spec screen pins a green Start rig bar that opens the launch sheet', (tester) async {
    final store = await installFakes();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
        home: phone(store, SpecScreen(file: RigSpecFile(path: '/p/rigs/web.yaml', projectPath: '/p'), text: _spec, projectName: 'p'))));
    await tester.pumpAndSettle();
    final bar = find.widgetWithText(FilledButton, 'Start rig');
    expect(bar, findsOneWidget);
    expect(tester.getSize(bar).height, greaterThanOrEqualTo(44));
    expect(tester.getBottomLeft(bar).dy, greaterThan(760), reason: 'pinned at the bottom');
    final style = tester.widget<FilledButton>(bar).style!;
    expect(style.backgroundColor!.resolve({}), Tokens.light.added, reason: 'the success green');
    expect(tester.getSemantics(bar).getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    await tester.tap(bar);
    await tester.pumpAndSettle();
    expect(find.byType(LaunchSheet), findsOneWidget);
    handle.dispose();
  });

  testWidgets('an invalid spec disables the bar and says why', (tester) async {
    final store = await installFakes();
    await tester.pumpWidget(MaterialApp(
        home: phone(store, SpecScreen(file: RigSpecFile(path: '/p/rigs/bad.yaml', projectPath: '/p'), text: 'name: [', projectName: 'p'))));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Start rig')).onPressed, isNull);
    expect(find.textContaining('fix it before starting'), findsOneWidget);
  });

  testWidgets('a stopped rig has the green Restore rig bar beside the red Delete; a running one only Stop',
      (tester) async {
    final store = await installFakes();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await fleet.feedFor(homelab).refresh();
    final rigs = fleet.feedFor(homelab).rigs.map((r) => r.rig);
    for (final (name, green) in [('research-team', true), ('conveyor', false)]) {
      await tester.pumpWidget(MaterialApp(
          home: phone(store, RigScreen(rig: rigs.firstWhere((r) => r.name == name), projectName: 'app'))));
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // A stopped rig keeps its green Restore at the foot (alone: Delete is in the Danger zone); a running one has no bar.
      if (green) {
        expect(find.descendant(of: find.byType(KillBar), matching: find.text('Restore rig')), findsOneWidget);
        expect(find.descendant(of: find.byType(KillBar), matching: find.byType(OutlinedButton)), findsNothing);
        expect(find.descendant(of: find.byType(KillBar), matching: find.byType(FilledButton)), findsOneWidget);
      } else {
        expect(find.byType(KillBar), findsNothing, reason: 'Stop is in the header ⋯ and the Agents tab\'s Danger zone');
      }
      await tester.pumpWidget(const SizedBox());
    }
  });
}
