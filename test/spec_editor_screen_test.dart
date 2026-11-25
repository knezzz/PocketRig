import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/rig_spec.dart';
import 'package:pocket_rig/ui/spec_editor_screen.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'rig_spec_test.dart' show pmSpec;

Future<void> pump(WidgetTester tester,
    {String text = pmSpec, Size size = const Size(800, 2400), double? boxWidth}) async {
  // Tall enough that every row of the pm spec is on screen.
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(Tokens.light, Brightness.light),
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: boxWidth,
        child: SpecEditorScreen(
          file: RigSpecFile(path: '/w/app/rigs/pm/rig.yaml', projectPath: '/w/app'),
          text: text,
          projectName: 'app',
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// What the YAML pane beside the form shows now.
String _yamlText(WidgetTester tester) => tester
    .widgetList<TextField>(find.byType(TextField))
    .map((f) => f.controller!.text)
    .firstWhere((t) => t.contains('version:'));

Future<void> _scrollTo(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
}

Finder _done() => find.widgetWithText(FilledButton, 'Done');

void main() {
  testWidgets('shows departments, their roles with how they run, and relationships', (tester) async {
    await pump(tester);
    expect(find.text('DEPARTMENTS · 2'), findsOneWidget);
    expect(find.text('Product Management'), findsOneWidget);
    expect(find.text('Development Support'), findsOneWidget);
    expect(find.text('lead'), findsOneWidget);
    expect(find.text('Claude Code'), findsNWidgets(2));
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('RELATIONSHIPS · 2'), findsOneWidget);
    expect(find.text('pm.lead  →  dev.build'), findsOneWidget);
    expect(find.text('delegates to'), findsNWidgets(2));
    expect(find.text('YAML'), findsNothing, reason: 'the side pane is showing');
    // Nothing changed yet: Save stays off.
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save')).enabled, isFalse);
  });

  testWidgets('a department and a role can be added, and Save turns on', (tester) async {
    await pump(tester);
    expect(find.text('valid'), findsOneWidget, reason: 'an icon and the word, not a glyph the font may lack');
    expect(find.textContaining('no changes'), findsOneWidget);
    await tester.tap(find.text('Add department'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Label'), 'QA Team');
    await tester.pumpAndSettle();
    // The id follows the label.
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Id')).controller!.text, 'qa-team');
    await tester.tap(_done());
    await tester.pumpAndSettle();
    expect(find.text('DEPARTMENTS · 3'), findsOneWidget);
    expect(find.text('QA Team'), findsOneWidget);

    await tester.tap(find.text('Add role').last);
    await tester.pumpAndSettle();
    expect(find.text('New role in QA Team'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Id'), 'tests');
    await tester.enterText(find.widgetWithText(TextField, 'Role'), 'tester');
    await tester.enterText(find.widgetWithText(TextField, 'Model'), 'claude-sonnet-5-5');
    await tester.tap(_done());
    await tester.pumpAndSettle();
    expect(find.text('tests · tester'), findsOneWidget);
    expect(find.text('Claude Code · claude-sonnet-5-5'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save')).enabled, isTrue);
    expect(find.text('valid'), findsOneWidget);
    expect(find.textContaining('2 changes'), findsOneWidget);
  });

  testWidgets('a role id must be unique within its department', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Add role').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Id'), 'lead');
    await tester.tap(_done());
    await tester.pumpAndSettle();
    expect(find.text('Another role in Product Management uses this id'), findsOneWidget);
    expect(find.text('New role in Product Management'), findsOneWidget, reason: 'the sheet stays open');
  });

  testWidgets('a relationship can be added between two roles and removed again', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Add relationship'));
    await tester.pumpAndSettle();
    expect(find.text('New relationship'), findsOneWidget);
    // Defaults: the first seat to the second.
    await tester.tap(_done());
    await tester.pumpAndSettle();
    expect(find.text('RELATIONSHIPS · 3'), findsOneWidget);
    expect(find.text('pm.lead  →  pm.researcher'), findsNWidgets(2));

    await tester.tap(find.text('pm.lead  →  pm.researcher').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove relationship'));
    await tester.pumpAndSettle();
    expect(find.text('RELATIONSHIPS · 2'), findsOneWidget);
  });

  testWidgets('leaving with unsaved changes asks first', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Add department'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Label'), 'Ops');
    await tester.tap(_done());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Ops'), findsOneWidget);
  });

  testWidgets('rig options: a switch, an environment and a YAML block are set, shown in the YAML, and cleared', (tester) async {
    await pump(tester);
    await _scrollTo(tester, find.text('Non-interruptive'));
    await tester.tap(find.text('Non-interruptive'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('On'));
    await tester.pumpAndSettle();
    expect(_yamlText(tester), contains('non_interruptive: true'));

    await tester.tap(find.text('Environment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add variable'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'log');
    await tester.enterText(find.widgetWithText(TextField, 'Value'), 'info');
    await tester.pumpAndSettle();
    expect(find.textContaining('isn\'t a valid name'), findsOneWidget);
    await tester.tap(_done());
    await tester.pumpAndSettle();
    expect(find.text('Environment'), findsWidgets, reason: 'a bad name keeps the sheet open');
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'LOG_LEVEL');
    await tester.pumpAndSettle();
    await tester.tap(_done());
    await tester.pumpAndSettle();
    expect(find.text('1 variable'), findsOneWidget);
    expect(_yamlText(tester), contains('LOG_LEVEL: info'));

    await _scrollTo(tester, find.text('Services'));
    await tester.tap(find.text('Services'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Services'), 'kind: [compose');
    await tester.pumpAndSettle();
    await tester.tap(_done());
    await tester.pumpAndSettle();
    expect(find.text('Services'), findsWidgets, reason: 'YAML that does not parse keeps the sheet open');
    await tester.enterText(find.widgetWithText(TextField, 'Services'), 'kind: compose\ncompose_file: docker-compose.yaml');
    await tester.pumpAndSettle();
    await tester.tap(_done());
    await tester.pumpAndSettle();
    expect(_yamlText(tester), contains('compose_file: docker-compose.yaml'));
    expect(_yamlText(tester), contains('name: pm'), reason: 'the rest of the spec is untouched');

    await tester.tap(find.text('Services'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Services'), '');
    await tester.pumpAndSettle();
    await tester.tap(_done());
    await tester.pumpAndSettle();
    expect(_yamlText(tester), isNot(contains('services')));
  });

  testWidgets('a role keeps what the form does not show, shows runtime-only options, and sets new ones', (tester) async {
    await pump(tester, text: pmSpec.replaceFirst('runtime: claude-code', 'runtime: claude-code\n        x_future: kept\n        restore_policy: relaunch_fresh'));
    await tester.tap(find.text('lead'));
    await tester.pumpAndSettle();
    expect(find.text('More options'), findsOneWidget);
    // The role already uses an option (restore_policy), so the section starts open.
    await _scrollTo(tester, find.widgetWithText(TextField, 'Advisor model'));
    expect(find.widgetWithText(TextField, 'Advisor model'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Codex profile'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, 'Advisor model'), 'claude-opus-5-5');
    await _scrollTo(tester, find.text('Add variable'));
    await tester.tap(find.text('Add variable'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'REGION');
    await tester.enterText(find.widgetWithText(TextField, 'Value'), 'eu');
    await _scrollTo(tester, _done());
    await tester.tap(_done());
    await tester.pumpAndSettle();
    final y = _yamlText(tester);
    expect(y, contains('advisor: claude-opus-5-5'));
    expect(y, contains('REGION: eu'));
    expect(y, contains('x_future: kept'));
    expect(y, contains('restore_policy: relaunch_fresh'));

    // Switching the runtime to Codex drops the Claude-only option and offers the Codex one.
    await tester.tap(find.text('lead'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(DropdownButtonFormField<String?>, 'Claude Code · Anthropic'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Codex · OpenAI').last);
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.widgetWithText(TextField, 'Codex profile'));
    expect(find.widgetWithText(TextField, 'Advisor model'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, 'Codex profile'), 'lease-impl');
    await _scrollTo(tester, _done());
    await tester.tap(_done());
    await tester.pumpAndSettle();
    final c = _yamlText(tester);
    expect(c, contains('codex_config_profile: lease-impl'));
    expect(c, isNot(contains('advisor:')));
    expect(c, contains('REGION: eu'));
  });

  testWidgets('a department takes a summary and YAML blocks, and says when a block does not parse', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Product Management'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Summary'), 'Decides what to build');
    await tester.enterText(find.widgetWithText(TextField, 'Continuity policy'), 'enabled: [true');
    await tester.pumpAndSettle();
    await tester.tap(_done());
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Continuity policy'), findsOneWidget, reason: 'the sheet stays open');
    await tester.enterText(find.widgetWithText(TextField, 'Continuity policy'), 'enabled: true');
    await tester.pumpAndSettle();
    await tester.tap(_done());
    await tester.pumpAndSettle();
    final y = _yamlText(tester);
    expect(y, contains('summary: Decides what to build'));
    expect(y, contains('enabled: true'));
  });

  testWidgets('on a phone the YAML opens from an action instead of a side pane', (tester) async {
    await pump(tester, size: const Size(400, 2400));
    expect(find.byType(TextField), findsNothing, reason: 'no side pane at phone width');
    // The header: title and Save on one line, YAML under the title; the path shows once, whole.
    final title = tester.getRect(find.textContaining('Edit ').first);
    expect(tester.getRect(find.widgetWithText(FilledButton, 'Save')).center.dy, closeTo(title.center.dy, 12));
    expect(tester.getRect(find.text('YAML')).top, greaterThan(title.bottom - 1), reason: 'under the title');
    expect(find.textContaining('.yaml', findRichText: true), findsOneWidget);
    expect(find.text('Culture file'), findsNothing, reason: 'one Culture row');
    expect(find.text('Culture'), findsOneWidget);
    await tester.tap(find.text('YAML'));
    await tester.pumpAndSettle();
    expect(_yamlText(tester), contains('name: pm'));
    await tester.enterText(
        find.byWidgetPredicate((w) => w is TextField && w.controller!.text.contains('version:')), 'version: "0.2"\nname: typed\npods: []\n');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('typed'), findsWidgets, reason: 'the form follows what was typed');
  });

  testWidgets('a wide window with a narrow editor box gets the YAML action, not a side pane', (tester) async {
    await pump(tester, size: const Size(1100, 2400), boxWidth: 600);
    expect(find.text('YAML'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
