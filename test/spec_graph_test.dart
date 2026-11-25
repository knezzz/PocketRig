import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/rig_spec.dart';
import 'package:pocket_rig/ui/kit.dart' show DashedBorder, RuntimeGlyph;
import 'package:pocket_rig/ui/rig/seat_graph.dart' show GraphLegend, SeatGraph;
import 'package:pocket_rig/ui/spec_screen.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

void main() {
  setUp(() => animateStatusSpinners = false);

  testWidgets('the spec graph shows each member\'s role, model and effort', (tester) async {
    final store = await installFakes();
    const spec = '''version: "0.2"
name: pair
pods:
  - id: core
    members:
      - id: lead
        runtime: claude-code
        role: orchestrator
        model: claude-opus-5-5
        effort: high
      - id: impl
        runtime: codex
''';
    await tester.pumpWidget(MaterialApp(
        home: phone(
            store,
            SpecScreen(
                file: RigSpecFile(path: '/p/rig.yaml', projectPath: '/p'), text: spec, projectName: 'p', initialView: 1))));
    await tester.pumpAndSettle();
    expect(find.text('orchestrator'), findsOneWidget);
    expect(find.text('opus-5-5 · effort high'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget, reason: 'no role: the runtime');
    expect(find.text('default model'), findsOneWidget);
  });

  testWidgets('the summary: no valid line, seats by pod, relationships; Edit and Start rig… in the ⋯', (tester) async {
    final store = await installFakes();
    const spec = '''version: "3"
name: web
summary: Ship the marketing site
pods:
  - id: lead
    label: Coordinates the work
    members:
      - id: orchestrator
        runtime: claude-code
  - id: dev
    members:
      - id: builder
        runtime: claude-code
      - id: reviewer
        runtime: codex
    edges:
      - {from: builder, to: reviewer, kind: delegates_to}
''';
    await tester.pumpWidget(MaterialApp(
        home: phone(store, SpecScreen(file: RigSpecFile(path: '/p/rigs/web.yaml', projectPath: '/p'), text: spec, projectName: 'p'))));
    await tester.pumpAndSettle();
    expect(find.text('Ship the marketing site · rigs/web.yaml · v3'), findsOneWidget);
    expect(find.text('● Valid'), findsNothing, reason: 'the validity line shows only when invalid');
    expect(find.text('SEATS · 3 IN 2 PODS'), findsOneWidget);
    expect(find.text('LEAD'), findsOneWidget);
    expect(find.text('Coordinates the work'), findsOneWidget);
    final edge = find.textContaining('dev.builder  delegates_to →  dev.reviewer', findRichText: true);
    await tester.scrollUntilVisible(edge, 200, scrollable: find.byType(Scrollable).last);
    expect(edge, findsOneWidget);
    expect(find.text('Start rig…'), findsNothing, reason: 'the menu item says Start rig…; the bar says Start rig');
    expect(find.widgetWithText(FilledButton, 'Start rig'), findsOneWidget);
    await tester.tap(find.byTooltip('Spec options'));
    await tester.pumpAndSettle();
    expect(find.text('Edit spec'), findsOneWidget);
    expect(find.text('Start rig…'), findsOneWidget);
  });

  testWidgets('the summary: runtime icons not CC/CX tiles, a pod named once, the agent path behind a tap', (tester) async {
    final store = await installFakes();
    const spec = '''version: "3"
name: web
pods:
  - id: release
    label: Release
    members:
      - id: ship
        runtime: claude-code
        agent_ref: local:agents/release/ship
      - id: qa
        runtime: codex
''';
    await tester.pumpWidget(MaterialApp(
        home: phone(store, SpecScreen(file: RigSpecFile(path: '/p/rigs/web.yaml', projectPath: '/p'), text: spec, projectName: 'p'))));
    await tester.pumpAndSettle();
    expect(find.text('CC'), findsNothing);
    expect(find.text('CX'), findsNothing);
    expect(find.byType(RuntimeGlyph), findsNWidgets(2));
    expect(find.text('RELEASE'), findsOneWidget);
    expect(find.text('Release'), findsNothing, reason: 'the pod name once, not "RELEASE Release"');
    expect(find.textContaining('local:agents'), findsNothing);
    await tester.tap(find.text('ship'));
    await tester.pump();
    expect(find.textContaining('local:agents/release/ship'), findsOneWidget);
    await tester.tap(find.text('ship'));
    await tester.pump();
    expect(find.textContaining('local:agents'), findsNothing);
  });

  testWidgets('the spec graph: the live rig legend, solid pods and seats, and a tap on a link names it', (tester) async {
    final store = await installFakes();
    const spec = '''version: "3"
name: web
pods:
  - id: dev
    members:
      - id: builder
        runtime: claude-code
      - id: reviewer
        runtime: codex
    edges:
      - {from: builder, to: reviewer, kind: delegates_to}
''';
    await tester.pumpWidget(MaterialApp(
        home: phone(store, SpecScreen(file: RigSpecFile(path: '/p/rigs/web.yaml', projectPath: '/p'), text: spec, projectName: 'p', initialView: 1))));
    await tester.pumpAndSettle();
    expect(find.byType(GraphLegend), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is DashedBorder), findsNothing, reason: 'solid, not dashed');
    final graph = tester.widget<SeatGraph>(find.byType(SeatGraph));
    final e = graph.layout.edges.single;
    final m = e.path.computeMetrics().first;
    final mid = m.getTangentForOffset(m.length / 2)!.position;
    expect(find.textContaining('delegates  reviewer'), findsNothing);
    await tester.tapAt(tester.getTopLeft(find.byType(SeatGraph)) + mid);
    await tester.pump();
    expect(find.textContaining('builder  delegates  reviewer'), findsOneWidget);
  });
}
