import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/agent_jobs.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/subagents.dart';
import 'package:pocket_rig/models.dart' show SeatState;
import 'package:pocket_rig/ui/app_icon.dart';
import 'package:pocket_rig/ui/status_shape.dart';
import 'app_icon_finders.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

/// The agent icon's glyph: a runtime's logo, or the generic agent icon.
final _glyph = find.byWidgetPredicate((w) => w is ImageIcon || (w is AppIcon && w.kind == AppIconKind.agent));

void main() {
  testWidgets('sidebar: an agent row has the robot and its status, no rig badge (the tree nests it), a row keeps 32dp',
      (tester) async {
    final store = await installFakes();
    showLoose = true;
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('scratch').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final sidebar = find.ancestor(of: find.text('Add project folder'), matching: find.byType(ListView));
    Finder iconIn(String name) => find.descendant(
        of: find.ancestor(of: find.descendant(of: sidebar, matching: find.text(name)).first, matching: find.byType(InkWell)).first,
        matching: find.byType(StatusIcon));
    for (final name in ['impl', 'scratch']) {
      final icon = iconIn(name);
      expect(icon, findsOneWidget, reason: name);
      // The runtime's logo (the generic robot for a runtime with no logo) in the state colour; no dot.
      expect(find.descendant(of: icon, matching: _glyph), findsOneWidget);
      expect(find.descendant(of: icon, matching: appIcon(AppIconKind.rig)), findsNothing, reason: name);
      expect(find.descendant(of: icon, matching: find.byType(StatusShape)), findsNothing, reason: 'the state is the icon\'s colour');
      final row = find.ancestor(of: find.descendant(of: sidebar, matching: find.text(name)).first, matching: find.byType(InkWell)).first;
      // A row with a context bar under its name is taller by the bar's line; one without stays 32.
      if (name == 'scratch') expect(tester.getSize(row).height, 32, reason: 'row height unchanged');
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('sidebar icon: an 18dp logo in the state colour and no dot; a subagent is the same row, '
      'one indent in, with its own icon in its state colour and a state dot', (tester) async {
    final store = await installFakes();
    fleet.toggleRig('r:${homelab.id}|r-conveyor', allShown: false);
    fleet.feedFor(homelab).subagents = {
      'sess-lead': [Subagent(sessionId: 'sess-lead', agentId: 'a1', description: 'Write the parser', type: 'general-purpose')],
    };
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('Write the parser').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final sidebar = find.ancestor(of: find.text('Add project folder'), matching: find.byType(ListView));
    final lead = find.ancestor(of: find.descendant(of: sidebar, matching: find.text('lead')).first, matching: find.byType(InkWell)).first;
    final icon = find.descendant(of: lead, matching: find.byType(StatusIcon));
    expect(tester.getSize(icon), const Size(18, 18));
    final glyph = tester.widget(find.descendant(of: icon, matching: _glyph));
    expect(glyph is ImageIcon ? glyph.color : (glyph as AppIcon).color, Status.needsYou.color(Tokens.light),
        reason: 'lead waits on you: its icon is the needs-you colour, not grey');
    expect(find.descendant(of: lead, matching: find.byType(StatusShape)), findsNothing, reason: 'no dot on an agent');

    final sub = find.ancestor(of: find.descendant(of: sidebar, matching: find.text('Write the parser')), matching: find.byType(InkWell)).first;
    final fork = find.descendant(of: sub, matching: appIcon(AppIconKind.subagent));
    expect(tester.widget<AppIcon>(fork).color, Status.working.color(Tokens.light), reason: 'its state colour: it is working');
    expect(tester.widget<AppIcon>(fork).size, 17);
    expect(find.descendant(of: sub, matching: find.byType(StatusShape)), findsOneWidget, reason: 'a subagent keeps its state dot');
    expect(tester.getSize(sub).height, 32, reason: 'the same row as an agent\'s');
    expect(tester.getTopLeft(find.descendant(of: sub, matching: find.text('Write the parser'))).dx,
        closeTo(tester.getTopLeft(find.descendant(of: lead, matching: find.text('lead'))).dx + 12, 0.5), reason: 'one indent');
    // The host's usage line keeps its place.
    final usage = tester.getTopLeft(find.descendant(of: sidebar, matching: find.text('5h')).first).dx;
    expect(usage, tester.getTopLeft(find.descendant(of: sidebar, matching: find.text('HOMELAB')).first).dx, reason: 'the usage line starts at the host name\'s x');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a shell an agent started is nested under it: the same row, one indent in, a blue terminal icon and the command',
      (tester) async {
    final store = await installFakes();
    fleet.toggleRig('r:${homelab.id}|r-conveyor', allShown: false);
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('impl').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final impl = fleet.feedFor(homelab).rigs.firstWhere((r) => r.rig.name == 'conveyor').seats.firstWhere((s) => s.logicalId == 'impl');
    impl.jobs = AgentJob.parse('J\t1\tS\t05:00\t0\t0\t/bin/zsh -c source /h/.claude/shell-snapshots/s.sh && eval \'sleep 99\' < /dev/null && pwd -P >| /tmp/x\n');
    fleet.toggleRig('r:${homelab.id}|r-conveyor', allShown: true);
    fleet.toggleRig('r:${homelab.id}|r-conveyor', allShown: false);
    await tester.pump(const Duration(seconds: 1));
    final sidebar = find.ancestor(of: find.text('Add project folder'), matching: find.byType(ListView));
    final row = find.ancestor(of: find.descendant(of: sidebar, matching: find.text('sleep 99')), matching: find.byType(InkWell)).first;
    final shell = tester.widget<AppIcon>(find.descendant(of: row, matching: appIcon(AppIconKind.shell)));
    expect(shell.color, Tokens.light.terminal);
    final agent = find.ancestor(of: find.descendant(of: sidebar, matching: find.text('impl')).first, matching: find.byType(InkWell)).first;
    expect(tester.getTopLeft(find.descendant(of: row, matching: find.text('sleep 99'))).dx,
        closeTo(tester.getTopLeft(find.descendant(of: agent, matching: find.text('impl'))).dx + 12, 0.5), reason: 'one indent');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an agent waiting on a shell is always listed in the sidebar (never folded away as idle), with its shell under it',
      (tester) async {
    final store = await installFakes();
    await pumpDesktop(tester, store);
    final feed = fleet.feedFor(homelab);
    for (var i = 0; i < 5 && find.text('impl').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final sidebar = find.ancestor(of: find.text('Add project folder'), matching: find.byType(ListView));
    // conveyor's idle 'tests' seat is folded in the active view; once it waits on a shell it is not.
    expect(find.descendant(of: sidebar, matching: find.text('tests')), findsNothing);
    final tests = feed.rigs.firstWhere((r) => r.rig.name == 'conveyor').seats.firstWhere((s) => s.logicalId == 'tests');
    tests.jobs = AgentJob.parse('J\t1\tS\t05:00\t0\t0\t/bin/zsh -c source /h/.claude/shell-snapshots/s.sh && eval \'sleep 99\' < /dev/null && pwd -P >| /tmp/x\n');
    expect(tests.state, SeatState.shell);
    fleet.toggleRig('r:${homelab.id}|r-conveyor', allShown: true);
    fleet.toggleRig('r:${homelab.id}|r-conveyor', allShown: false);
    await tester.pump(const Duration(seconds: 1));
    expect(find.descendant(of: sidebar, matching: find.text('tests')), findsOneWidget);
    expect(find.descendant(of: sidebar, matching: find.text('sleep 99')), findsOneWidget, reason: 'its shell, nested under it');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('in the sidebar the ages are a column of their own: every age ends at one x, left of the ⋯', (tester) async {
    final store = await installFakes();
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('impl').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final sidebar = find.ancestor(of: find.text('Add project folder'), matching: find.byType(ListView));
    final ages = find.descendant(of: sidebar, matching: find.byWidgetPredicate((w) => w is Text && RegExp(r'^(now|\d+[md]|(?!5h$)\d+h)$').hasMatch(w.data ?? '')));
    expect(ages, findsAtLeastNWidgets(2));
    final rights = {for (final e in ages.evaluate()) tester.getTopRight(find.byWidget(e.widget)).dx.round()};
    expect(rights.length, 1, reason: 'one column for every age: $rights');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
