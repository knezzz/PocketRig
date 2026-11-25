import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/common.dart' show agoPhrase;
import 'package:pocket_rig/ui/kit.dart';
import 'package:pocket_rig/ui/permission_card.dart';
import 'package:pocket_rig/ui/rig/seat_actions.dart';
import 'package:pocket_rig/ui/rig/seat_graph.dart';
import 'package:pocket_rig/ui/rig/seats_tab.dart';
import 'package:pocket_rig/ui/status_shape.dart';
import 'package:pocket_rig/ui/theme.dart';

Seat seat(String id, String runtime, {String? activity, bool needs = false, String? reason}) => Seat(
      rigId: 'r1',
      logicalId: id,
      sessionName: '$id@conveyor',
      runtime: runtime,
      activity: activity,
      needsInput: needs,
      needsInputReason: reason,
    );

/// A seat node as wide as the Seats column.
Future<void> pump(WidgetTester tester, Seat s) => tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home:
          Scaffold(body: Center(child: SizedBox(width: 360, height: 92, child: SeatNode(label: s.logicalId, seat: s)))),
    ));

void main() {
  testWidgets('nodes show when they were last active, or since when they ask; narrow width does not overflow',
      (tester) async {
    final at = DateTime.now().subtract(const Duration(minutes: 4));
    Seat s({String? activity, bool stopped = false}) => Seat(
        rigId: 'r1',
        logicalId: 'impl',
        runtime: 'codex',
        activity: activity,
        intentionallyStopped: stopped,
        lastActivityAt: at);
    await pump(tester, s());
    expect(find.text(' · 4m ago'), findsOneWidget);
    await pump(tester, s(stopped: true));
    expect(find.text(' · 4m ago'), findsOneWidget);
    await pump(tester, s(activity: 'working'));
    expect(find.text(' · 4m ago'), findsOneWidget);
    await pump(
        tester,
        Seat(
            rigId: 'r1',
            logicalId: 'lead',
            runtime: 'claude-code',
            needsInput: true,
            needsInputReason: 'Bash: npm test',
            waitingSince: DateTime.now().subtract(const Duration(minutes: 2))));
    expect(find.text(' · asked 2m'), findsOneWidget);

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: Scaffold(body: SizedBox(width: 150, height: 92, child: SeatNode(label: 'impl', seat: s()))),
    ));
    expect(find.text(' · 4m ago'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(agoPhrase(DateTime.now().subtract(const Duration(seconds: 20))), 'just now');
  });

  testWidgets('a seat node: its runtime logo in the state colour, name and runtime, what it is doing, settings; tinted in its state color',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, seat('impl', 'codex', activity: 'working'));
    expect(find.byType(StatusShape), findsNothing, reason: 'no dot: the logo is tinted with the state');
    final icon = tester.widget<StatusIcon>(find.byType(StatusIcon));
    expect((icon.status, icon.runtime), (Status.working, 'codex'));
    expect(find.text('impl  codex', findRichText: true), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('impl, Codex')), findsOneWidget);
    expect(find.text('working'), findsOneWidget);
    expect(find.text('default model'), findsOneWidget);
    // The whole card carries its state's color.
    final card = find.descendant(of: find.byType(SeatNode), matching: find.byType(Material)).first;
    expect(tester.widget<Material>(card).color, statusTint(Tokens.light, Status.working, Tokens.light.surface));

    await pump(tester, seat('lead', 'claude-code', needs: true, reason: 'Bash: npm test'));
    expect(find.bySemanticsLabel(RegExp('lead, Claude Code')), findsOneWidget);
    expect(find.text('Run npm test?'), findsOneWidget);
    expect(
        tester.widget<Text>(find.text('Run npm test?')).style?.color, seatLineColor(Tokens.light, SeatState.needsYou));
    semantics.dispose();
  });

  testWidgets('a terminal seat has no settings line', (tester) async {
    await pump(tester, seat('shell', 'terminal', activity: 'idle-at-prompt'));
    expect(find.text('default model'), findsNothing);
  });

  test('edges are grey line styles only, named as the legend reads them', () {
    expect([
      for (final k in ['collaborates_with', 'delegates_to', 'can_observe', 'escalates_to', 'spawned_by']) edgeLegend(k)
    ], [
      'collaborates',
      'delegates',
      'observes',
      'escalates',
      'spawned'
    ]);
  });

  test('seat rows read model, permission mode and effort', () {
    final s = Seat.fromJson({
      'rigId': 'r',
      'logicalId': 'dev.impl',
      'runtime': 'claude-code',
      'model': 'claude-opus-4-5-20250929',
      'effort': 'high',
    });
    expect(seatSettings(s, 'acceptEdits'), 'opus-4-5 · Accept edits · effort high');
    expect(seatSettings(Seat.fromJson({'rigId': 'r', 'logicalId': 'x', 'runtime': 'codex'}), 'floor'),
        'default model · Ask');
  });

  test('the settings line leaves context out: the node shows it as a bar', () {
    final s = Seat(rigId: 'r', logicalId: 'x', runtime: 'claude-code', contextUsedPercent: 41.6);
    expect(seatSettings(s, null), 'default model');
    expect(contextLabel(Seat(rigId: 'r', logicalId: 'x')), 'unknown');
  });

  testWidgets('clearing context asks first, and warns when the seat is working', (tester) async {
    final s = Seat(rigId: 'r', logicalId: 'impl', runtime: 'claude-code', activity: 'working', contextUsedPercent: 88);
    bool? answer;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) =>
            TextButton(onPressed: () async => answer = await confirmClear(context, s), child: const Text('go')),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.textContaining('88% of its context'), findsOneWidget);
    expect(find.textContaining('working right now'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
  });

  test('status words map to one color each', () {
    expect([statusTone('active'), statusTone('in-progress'), statusTone('running'), statusTone('OPEN')],
        everyElement(Tone.good));
    expect([statusTone('done'), statusTone('MERGED'), statusTone('completed')], everyElement(Tone.done));
    expect([statusTone('blocked'), statusTone('failed'), statusTone('denied')], everyElement(Tone.bad));
    expect([statusTone('permission'), statusTone('question'), statusTone('needs you')], everyElement(Tone.hot));
    expect([statusTone('pending'), statusTone('handed-off')], everyElement(Tone.outline));
    expect(statusTone('canceled'), Tone.light);
  });

  test('OpenRig reason codes: permission_prompt is a permission, the others are questions', () {
    PermissionAsk ask(String r) =>
        PermissionAsk.from(Seat(rigId: 'r', logicalId: 'x', needsInput: true, needsInputReason: r));
    expect(ask('permission_prompt').isPermission, isTrue);
    expect(ask('permission_prompt').tool, isNull);
    expect(ask('selection_prompt').isPermission, isFalse);
    expect(ask('idle_prompt').detail, 'Waiting for your input');
    expect(ask('Bash: npm test').isPermission, isTrue);
    expect(ask('Bash: npm test').detail, 'npm test');
    expect(ask('asked a question').isPermission, isFalse);
    expect(seatLine(Seat(rigId: 'r', logicalId: 'x', needsInput: true, needsInputReason: 'permission_prompt')),
        startsWith('waiting for approval'));
    expect(seatLine(Seat(rigId: 'r', logicalId: 'x', needsInput: true, needsInputReason: 'Bash: npm test')),
        'Run npm test?');
    expect(seatLine(Seat(rigId: 'r', logicalId: 'x', needsInput: true, needsInputReason: 'selection_prompt')),
        'Asked you to pick an option');
  });

  testWidgets('the graph legend shows the logo in each state\'s colour', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: const Scaffold(body: GraphLegend()),
    ));
    final icons = tester.widgetList<StatusIcon>(find.byType(StatusIcon)).toList();
    expect([for (final i in icons) i.status], [Status.needsYou, Status.working, Status.idle, Status.stopped]);
    expect(icons.every((i) => i.runtime == 'claude-code'), isTrue);
    expect(find.byType(StatusShape), findsNothing);
  });
}
