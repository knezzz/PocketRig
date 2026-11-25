import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/answer_bar.dart';
import 'package:pocket_rig/ui/kit.dart';
import 'package:pocket_rig/ui/project_files.dart' show ProjectFilesScreen;
import 'package:pocket_rig/ui/project_screen.dart';
import 'package:pocket_rig/ui/rig_screen.dart' show RigScreen;
import 'package:pocket_rig/ui/seat_leaf.dart' show SeatLeaf;
import 'package:pocket_rig/models.dart' show SeatState;
import 'package:pocket_rig/ui/spec_screen.dart';
import 'package:pocket_rig/ui/status_shape.dart';
import 'package:pocket_rig/ui/terminal_screen.dart' show TerminalScreen;
import 'package:pocket_rig/ui/chat/rig_chat_pager.dart' show RigChatPager;
import 'package:pocket_rig/ui/tiles_screen.dart' show TilesScreen;

import 'app_icon_finders.dart';
import 'package:pocket_rig/ui/app_icon.dart';
import 'golden/fixtures.dart';

Future<void> _open(WidgetTester tester, {String path = app, bool loose = false}) async {
  final store = await installFakes();
  showLoose = loose;
  SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
  addTearDown(() => SshExec.debugConnect = null);
  await tester.pumpWidget(MaterialApp(home: phone(store, ProjectScreen(path: path))));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: find.byType(Segmented<int>), matching: find.text(label)));
  await tester.pump();
}

/// Scrolls the project's one list until [f] is built and on screen.
Future<void> _show(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
  await tester.pump();
}

void main() {
  testWidgets('each tab shows its own section and bottom bar', (tester) async {
    await _open(tester);
    expect(find.byType(Segmented<int>), findsOneWidget);
    expect(find.textContaining('2 worktrees'), findsOneWidget, reason: 'the header counts the worktrees');
    // Overview: needs you, and Files as one row; no sections of the other tabs.
    expect(find.text('NEEDS YOU · 2'), findsOneWidget);
    // The count tiles use the one tally; a tap goes to Agents. Code lists the worktrees, with a jump.
    expect(find.text('RUNNING'), findsOneWidget);
    for (final t in ['rigs', 'agents', 'need you', 'working']) {
      expect(find.bySemanticsLabel(RegExp('^\\d+ $t\$')), findsOneWidget, reason: t);
    }
    expect(find.text('All agents ›'), findsOneWidget);
    await _show(tester, find.text('CODE'));
    expect(find.text('CODE'), findsOneWidget);
    expect(find.text('Worktrees ›'), findsOneWidget);
    expect(find.text('Shell here'), findsNothing, reason: 'no bottom bar: the project ⋯ has it');
    expect(find.text('New agent'), findsNothing);
    expect(find.text('BY WORKTREE'), findsNothing);
    await _show(tester, find.text('Files'));
    expect(find.text('Files'), findsOneWidget);
    expect(find.textContaining('RIG SPECS'), findsNothing);
    // The fixture's shell has no `gh`, so there is no pull request section to show.
    expect(find.textContaining('PULL REQUESTS'), findsNothing);

    await _show(tester, find.text('Worktrees ›'));
    await tester.tap(find.text('Worktrees ›'));
    await tester.pump();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000)); // the list keeps its offset
    await tester.pump();
    expect(find.text('BY WORKTREE'), findsOneWidget, reason: 'the Code jump opens the Worktrees tab');
    await _tab(tester, 'Overview');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
    await tester.pump();
    await tester.tap(find.text('All agents ›'));
    await tester.pump();
    expect(find.textContaining('AGENTS ·'), findsOneWidget, reason: 'the jump opens the Agents tab');
    expect(find.text('NEEDS YOU · 2'), findsNothing);
    expect(find.text('New agent'), findsNothing);

    await _tab(tester, 'Worktrees');
    for (final label in ['BY WORKTREE', 'Main checkout', 'flaky-ci']) {
      await _show(tester, find.text(label));
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await _show(tester, find.text('New worktree'));
    expect(find.text('New worktree'), findsOneWidget, reason: 'the dashed row ends the list (X1)');
    expect(find.descendant(of: find.byType(SeatLeaf), matching: appIcon(AppIconKind.rig)), findsNothing,
        reason: 'a seat on the Worktrees tab has no hub badge, as on the rig page and in the sidebar');

    await _tab(tester, 'Specs');
    await _show(tester, find.text('RIG SPECS · 3'));
    expect(find.textContaining('rig folder'), findsNothing);
    await _close(tester);
  });

  testWidgets('Files opens its own screen', (tester) async {
    await _open(tester);
    await _show(tester, find.text('Files'));
    await tester.tap(find.text('Files'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ProjectFilesScreen), findsOneWidget);
    await _close(tester);
  });

  testWidgets('needs you answers a permission inline and sends a question to its seat', (tester) async {
    await _open(tester);
    // lead asks to run a command: Deny · Allow right on the row; review asked a question: Answer.
    final lead = find.ancestor(of: find.text('lead · conveyor'), matching: find.byType(InkWell)).first;
    expect(find.descendant(of: lead, matching: find.byType(AnswerBar)), findsOneWidget);
    expect(find.descendant(of: lead, matching: find.textContaining('npm run test:integration')), findsOneWidget);
    final review = find.ancestor(of: find.text('review · conveyor'), matching: find.byType(InkWell)).first;
    expect(find.descendant(of: review, matching: find.byType(AnswerBar)), findsNothing);
    expect(find.descendant(of: review, matching: find.text('Answer')), findsOneWidget);
    // The section is outlined in the accent.
    final card = find.ancestor(of: find.text('lead · conveyor'), matching: find.byType(BorderedList)).first;
    expect(tester.widget<BorderedList>(card).borderColor, isNotNull);
    await _close(tester);
  });

  testWidgets('a rig row shows its state shape and tally and opens the running rig\'s details on tap, never its tiles', (tester) async {
    await _open(tester);
    await _tab(tester, 'Agents');
    await _show(tester, find.text('conveyor'));
    final row = find.ancestor(of: find.text('conveyor'), matching: find.byType(RowTile)).first;
    expect(tester.widget<StatusShape>(find.descendant(of: row, matching: find.byType(StatusShape)).first).status,
        Status.needsYou);
    final tally = tester.widget<StatusTally>(find.descendant(of: row, matching: find.byType(StatusTally)));
    expect(tally.counts[Status.needsYou], 2);
    expect(tally.counts[Status.working], 1);
    expect(tally.counts[Status.idle], 1);
    await tester.tap(find.text('conveyor'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(RigScreen), findsOneWidget, reason: 'the phone opens a running rig as its details');
    expect(find.byType(RigChatPager), findsNothing);
    expect(find.byType(TilesScreen), findsNothing);
    await _close(tester);
  });

  testWidgets('the Agents tab is one flat list: the ones waiting on you first, each with its worktree as a muted tag',
      (tester) async {
    await _open(tester, loose: true);
    await _tab(tester, 'Agents');
    final leaves = tester.widgetList<SeatLeaf>(find.byType(SeatLeaf)).toList();
    expect(leaves.length, greaterThan(3));
    expect(leaves.first.seat.state, SeatState.needsYou, reason: 'needs you first');
    final order = [for (final l in leaves) l.seat.state.index];
    expect(order, [...order]..sort(), reason: 'then working, shell, idle, stopped');
    expect(leaves.every((l) => l.flat), isTrue, reason: 'no rig nesting');
    for (final l in leaves.where((l) => l.seat.cwd != null)) {
      expect(l.tag, isNotNull, reason: '${l.seat.logicalId} carries its worktree');
    }
    expect(find.text('main'), findsWidgets);
    // Right-aligned: rows with a chevron end their tag at one x (a read-only row has its own badge there).
    final rights = {
      for (final l in leaves.where((l) => l.seat.sessionName != null && l.tag == 'main'))
        tester
            .getTopRight(find.descendant(
                of: find.byWidgetPredicate((w) => w is SeatLeaf && w.seat == l.seat), matching: find.text('main')))
            .dx
            .round()
    };
    await _show(tester, find.textContaining('RIGS ·')); // the loose agents are the last rows above it
    final looseRights = {
      for (final e in find.textContaining('no rig').evaluate())
        tester.getTopRight(find.descendant(of: find.ancestor(of: find.byWidget(e.widget), matching: find.byType(RowTile)).first, matching: find.text('main'))).dx.round()
    };
    expect(looseRights, isNotEmpty);
    expect({...rights, ...looseRights}.length, 1, reason: 'one x for every row, loose agents too (they have the chevron): $rights $looseRights');
    await _close(tester);
  });

  testWidgets('Agents list: every robot starts at one x (loose agents too), a rig agent names its rig at the end of its second line and a loose one says '
      '"no rig", and no row has the hub badge', (tester) async {
    await _open(tester, loose: true);
    await _tab(tester, 'Agents');
    await _show(tester, find.textContaining('RIGS ·'));
    final robots = agentIcon(skipOffstage: false);
    expect(robots, findsAtLeastNWidgets(4));
    final xs = {for (final e in robots.evaluate()) tester.getTopLeft(find.byWidget(e.widget)).dx.round()};
    expect(xs.length, 1, reason: 'one x for every robot, rig and loose: $xs');
    expect(find.descendant(of: find.byType(SeatLeaf), matching: appIcon(AppIconKind.rig)), findsNothing,
        reason: 'no rig badge on an agent row of the Agents page');
    final leaf = find.byType(SeatLeaf).first;
    final rig = tester.widget<SeatLeaf>(leaf).rigName;
    // The rig name ends the second line, muted, never beside the name and the worktree tag.
    final line = find.descendant(of: leaf, matching: find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().endsWith(' · $rig')));
    expect(line, findsOneWidget, reason: 'the rig name ends the second line');
    expect(find.descendant(of: leaf, matching: find.text('  $rig')), findsNothing, reason: 'not beside the name');
    expect(find.textContaining('no rig'), findsWidgets);
    await _close(tester);
  });

  testWidgets('the rig ⋯ has Stop as a red button, and no Delete while it runs; Stop asks with the shared stop sheet', (tester) async {
    await _open(tester);
    await _tab(tester, 'Agents');
    await _show(tester, find.textContaining('RIGS ·'));
    await tester.tap(find.byTooltip('Rig actions').first);
    await tester.pumpAndSettle();
    expect(find.text('Snapshot'), findsOneWidget);
    final b = tester.widget<FilledButton>(find.ancestor(of: find.text('Stop rig…'), matching: find.byType(FilledButton)));
    expect(b.style?.backgroundColor?.resolve({}), isNot(Colors.transparent));
    expect(find.text('Delete rig…'), findsNothing);
    await tester.tap(find.text('Stop rig…'));
    await tester.pumpAndSettle();
    expect(find.text('Stop conveyor?'), findsOneWidget);
    expect(find.text('Take a snapshot first'), findsOneWidget);
    expect(find.text('Snapshot & stop'), findsOneWidget);
    final box = tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));
    expect(box.value, isTrue, reason: 'snapshot first is on by default');
    await _close(tester);
  });

  testWidgets('a long press on a rig row, and a right click on a worktree header, open the same lists as their ⋯',
      (tester) async {
    await _open(tester);
    await _tab(tester, 'Agents');
    await _show(tester, find.textContaining('RIGS ·'));
    await tester.longPress(find.text('conveyor').first);
    await tester.pumpAndSettle();
    expect(find.text('Stop rig…'), findsOneWidget);
    expect(find.text('Rename label'), findsOneWidget);
    await tester.tapAt(const Offset(200, 20)); // the scrim
    await tester.pumpAndSettle();

    await _tab(tester, 'Worktrees');
    await _show(tester, find.text('flaky-ci'));
    final at = tester.getCenter(find.text('flaky-ci'));
    final mouse = await tester.startGesture(at, kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await mouse.up();
    await tester.pumpAndSettle();
    expect(find.text('Delete worktree…'), findsOneWidget);
    expect(find.text('Start a rig here…'), findsOneWidget);
    await _close(tester);
  });

  testWidgets('a worktree ⋯ starts a rig there from the chosen spec', (tester) async {
    await _open(tester);
    await _tab(tester, 'Worktrees');
    await _show(tester, find.text('flaky-ci'));
    await tester.tap(find.byTooltip('Worktree actions').last);
    await tester.pumpAndSettle();
    expect(find.text('Delete worktree…'), findsOneWidget);
    await tester.tap(find.text('Start a rig here…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('conveyor').last); // in the picker, over the rig row
    await tester.pumpAndSettle();
    final screen = tester.widget<SpecScreen>(find.byType(SpecScreen));
    expect(screen.cwd, '$app/.claude/worktrees/flaky-ci');
    expect(screen.rigName, 'conveyor-flaky-ci');
    await _close(tester);
  });

  testWidgets('the worktree header ⋯ sits in the rig rows\' right column, the hairline filling up to it',
      (tester) async {
    await _open(tester);
    await _tab(tester, 'Worktrees');
    final head = find.byTooltip('Worktree actions').first;
    final rig = find.byTooltip('Rig actions').first;
    expect(tester.getRect(head).right, tester.getRect(rig).right);
    final rule = find.descendant(
        of: find.ancestor(of: head, matching: find.byType(InkWell)).first, matching: find.byType(Divider));
    expect(tester.getRect(rule.first).right, closeTo(tester.getRect(head).left - 8, 2.5),
        reason: '8dp before the ⋯ (its tap box has a little padding)');
  });

  testWidgets('a worktree card header shows branch and push state, and opens the worktree', (tester) async {
    await _open(tester);
    await _tab(tester, 'Worktrees');
    expect(find.text('feat/409-retry · 2 to push · 3 changed · no PR'), findsOneWidget);
    await _show(tester, find.text('flaky-ci'));
    expect(find.textContaining('fix/flaky-ci · '), findsOneWidget);
    await tester.tap(find.text('flaky-ci'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(WorktreeScreen), findsOneWidget);
    await _close(tester);
  });

  testWidgets('an agent outside a rig sits in its worktree card, with no Adopt… button', (tester) async {
    await _open(tester, loose: true);
    await _tab(tester, 'Worktrees');
    // scratch is also in Needs you (its hook says it waits); its worktree card row is the last.
    await _show(tester, find.text('scratch').last);
    final row = find.ancestor(of: find.text('scratch').last, matching: find.byType(RowTile)).first;
    expect(find.descendant(of: row, matching: find.text('Adopt…')), findsNothing);
    // The single-agent icon carries its status instead; Adopt stays on the agent's own screen.
    expect(find.descendant(of: row, matching: agentIcon()), findsOneWidget);
    await _close(tester);
  });

  testWidgets('spec rows open the spec; the project ⋯ has GitHub, the spec folder and nothing else here',
      (tester) async {
    await _open(tester);
    await tester.tap(find.byTooltip('Project options'));
    await tester.pumpAndSettle();
    final labels = ['New agent', 'Shell here', 'New worktree…', 'Open on GitHub'];
    for (final l in labels) {
      expect(find.text(l), findsOneWidget, reason: l);
    }
    expect(tester.getTopLeft(find.text('New agent')).dy, lessThan(tester.getTopLeft(find.text('Shell here')).dy),
        reason: 'New agent is the first row');
    expect(find.text('Connect spec folder…'), findsOneWidget);
    expect(find.text('Unpin'), findsNothing, reason: 'app is not pinned');
    await tester.tapAt(const Offset(200, 60)); // dismiss
    await tester.pumpAndSettle();
    await _tab(tester, 'Specs');
    await _show(tester, find.textContaining('rigs/release'));
    expect(find.text('Open'), findsNothing, reason: 'no Open button: the whole row opens');
    final live = find.byWidgetPredicate((w) => w is Pill && w.text.startsWith('running as')).first;
    final row = find.ancestor(of: live, matching: find.byType(RowTile)).first;
    final name = find.descendant(of: row, matching: find.byType(Text)).first;
    expect(tester.getTopLeft(live).dx, tester.getTopLeft(name).dx, reason: 'in the text column');
    expect(tester.getTopLeft(live).dy, greaterThan(tester.getBottomLeft(name).dy), reason: 'the status pill is on its own line');
    await tester.tap(find.textContaining('rigs/release'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SpecScreen), findsOneWidget);
    await _close(tester);
  });

  testWidgets('Shell opens a terminal in the folder', (tester) async {
    await _open(tester);
    await tester.tap(find.byTooltip('Project options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shell here'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TerminalScreen), findsOneWidget);
    await _close(tester);
  });
}
