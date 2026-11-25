import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/agent_jobs.dart';
import 'package:pocket_rig/data/git_status.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/agent_details.dart';
import 'package:pocket_rig/ui/answer_bar.dart';
import 'package:pocket_rig/ui/rig/seat_sheet.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

void main() {
  testWidgets('seat details show model, context, usage, code and activity', (tester) async {
    final store = await installFakes();
    final seat = Seat(
      rigId: '', // no daemon call for the permission mode
      logicalId: 'dev.impl',
      sessionName: 'impl@app',
      runtime: 'claude-code',
      cwd: '/w/app/.claude/worktrees/fix-ci',
      model: 'claude-opus-5-5',
      effort: 'high',
      contextUsedPercent: 42,
      inputTokens: 120000,
      outputTokens: 8400,
      costUsd: 1.5,
      lastActivityAt: DateTime.now().subtract(const Duration(minutes: 3)),
    );
    final details = AgentDetails(
      seat: seat,
      contextTokens: 84000,
      now: 'BASH flutter test',
      git: GitStatus(
          branch: 'fix-ci',
          root: '/w/app',
          changedFiles: 2,
          upstream: 'origin/fix-ci',
          ahead: 1,
          pr: PullRequest(number: 7, title: 'Fix CI', state: 'OPEN')),
      files: {'lib/a.dart': (10, 2), 'lib/b.dart': (3, 0)},
      jobs: AgentJob.parse('J\t1\tS\t05:00\t0\t0\t/bin/zsh -c source /h/.claude/shell-snapshots/s.sh && eval '
          "'flutter test' < /dev/null\n"),
    );
    await tester.pumpWidget(
        AppScope(store: store, child: MaterialApp(home: SeatDetailsScreen(details: details, rigName: 'app-rig'))));
    await tester.pump();

    // The page is the seat sheet's content under a header.
    expect(find.byType(SeatSheetBody), findsOneWidget);
    expect(find.text('NOW'), findsOneWidget);
    expect(find.textContaining('BASH flutter test'), findsOneWidget);
    expect(find.textContaining('3m ago'), findsOneWidget);
    expect(find.text('1 monitor'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('MODEL & CONTEXT'), 100);
    await tester.scrollUntilVisible(find.textContaining('in 120k · out 8.4k · ~\$1.50'), 100);
    expect(find.textContaining('42% · 84k'), findsOneWidget);
    expect(find.textContaining('effort high'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('#7 Fix CI'), 100);
    expect(find.text('CODE'), findsOneWidget);
    expect(find.text('fix-ci'), findsOneWidget, reason: 'the worktree');
    expect(find.textContaining('fix-ci · ↑1 ↓0 · 2 changed'), findsOneWidget);
    expect(find.textContaining('2 files', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('working wins over on-shell in the details\' and the sheet\'s Now line: a working agent with a shell says working, an idle one says what it waits on', (tester) async {
    final store = await installFakes();
    final jobs = AgentJob.parse('J\t1\tS\t05:00\t0\t0\t/bin/zsh -c source /h/.claude/shell-snapshots/s.sh && eval '
        "'flutter test' < /dev/null\n");
    Future<void> show(String activity) async {
      final seat = Seat(rigId: '', logicalId: 'dev.impl', sessionName: 'impl@app', runtime: 'claude-code', activity: activity);
      await tester.pumpWidget(AppScope(
          store: store, child: MaterialApp(home: SeatDetailsScreen(details: AgentDetails(seat: seat, jobs: jobs), rigName: 'app-rig'))));
      await tester.pump();
    }

    await show('working');
    expect(find.textContaining('no tokens'), findsNothing, reason: 'working: not the shell line');
    expect(find.text('working'), findsWidgets);
    await show('idle-at-prompt');
    expect(find.textContaining('no tokens'), findsWidgets, reason: 'idle at its prompt with a shell: what it waits on');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the details\' context text takes the shared context colour: grey, red from 80', (tester) async {
    final store = await installFakes();
    Future<Color?> colorAt(double pct) async {
      final details = AgentDetails(
          seat: Seat(rigId: '', logicalId: 'a', sessionName: 'a@x', runtime: 'claude-code', contextUsedPercent: pct));
      await tester.pumpWidget(AppScope(
          store: store, child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: AgentDetailsSections(details))))));
      await tester.pump();
      return tester.widget<Text>(find.textContaining('${pct.round()}% used')).style?.color;
    }

    const k = Tokens.light;
    expect(await colorAt(31), k.muted);
    expect(await colorAt(62), k.muted);
    expect(await colorAt(84), k.removed);
    expect(find.textContaining('compacts soon'), findsOneWidget, reason: 'red says what it means');
    await colorAt(62);
    expect(find.textContaining('compacts soon'), findsNothing);
  });

  testWidgets('the seat sheet\'s three buttons share 390pt by caption length, the longest getting the most', (tester) async {
    final store = await installFakes();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final seat = Seat(
        rigId: 'r1', logicalId: 'dev.impl', nodeId: 'n1', sessionName: 'impl@app', runtime: 'claude-code', resumeToken: 's');
    await tester.pumpWidget(AppScope(
        store: store,
        child: MaterialApp(
            home: Builder(
                builder: (context) =>
                    TextButton(onPressed: () => showSeatSheet(context, 'app-rig', seat), child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    double width(String label) =>
        tester.getSize(find.ancestor(of: find.text(label), matching: find.byType(OutlinedButton)).first).width;
    final (chat, terminal, claude) = (width('Chat'), width('Terminal'), width('Open in Claude'));
    expect(claude, greaterThan(terminal));
    expect(terminal, greaterThan(chat));
    expect(claude, greaterThan(140), reason: 'room for the full caption, not an equal third (~111)');
    // shortcut: the test font (Ahem) is wider than the real one, so this proves the split, not the exact fit.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the seat sheet scrolled to its end keeps Kill session and Remove from rig above the home indicator',
      (tester) async {
    final store = await installFakes();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const inset = 34.0; // an iPhone's home indicator
    final seat = Seat(
        rigId: 'r1', logicalId: 'dev.impl', nodeId: 'n1', sessionName: 'impl@app', runtime: 'claude-code', resumeToken: 's');
    await tester.pumpWidget(AppScope(
        store: store,
        child: MaterialApp(
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(padding: const EdgeInsets.only(bottom: inset), viewPadding: const EdgeInsets.only(bottom: inset)),
                child: child!),
            home: Builder(
                builder: (context) =>
                    TextButton(onPressed: () => showSeatSheet(context, 'app-rig', seat), child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final list = find.descendant(of: find.byType(SeatSheetBody), matching: find.byType(Scrollable)).first;
    for (var i = 0; i < 30 && find.text('Remove from rig…').evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, -200));
      await tester.pump();
    }
    await tester.drag(list, const Offset(0, -2000)); // to the very end
    await tester.pumpAndSettle();
    final bottom = tester.getBottomLeft(find.ancestor(of: find.text('Remove from rig…'), matching: find.byType(OutlinedButton)).first).dy;
    expect(bottom, lessThanOrEqualTo(844 - inset), reason: 'clear of the home indicator at the end of the scroll');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the seat sheet: ways in, the ask with its answers, sections, destructive actions last', (tester) async {
    final store = await installFakes();
    var chats = 0, terminals = 0;
    final seat = Seat(
      rigId: 'r1',
      logicalId: 'dev.impl',
      nodeId: 'n1',
      sessionName: 'impl@app',
      runtime: 'claude-code',
      resumeToken: 'sess-1',
      needsInput: true,
      needsInputReason: 'Bash: npm run test',
      contextUsedPercent: 86,
    );
    await tester.pumpWidget(AppScope(
      store: store,
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSeatSheet(context, 'app-rig', seat,
                queue: [
                  QueueItem(id: 'q', summary: 'Rate limit login', state: 'in-progress', destinationSession: 'impl@app')
                ],
                onChat: () => chats++,
                onTerminal: () => terminals++),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final sheet = find.descendant(of: find.byType(SeatSheetBody), matching: find.byType(Scrollable)).first;
    expect(find.text('dev.impl'), findsOneWidget);
    expect(find.textContaining('app-rig · dev · claude code'), findsOneWidget);
    for (final b in ['Chat', 'Terminal', 'Open in Claude']) {
      expect(find.text(b), findsOneWidget, reason: b);
    }
    // It asks: the one answer bar.
    expect(find.byType(AnswerBar), findsOneWidget);
    expect(find.text('Always'), findsOneWidget);
    expect(find.text('Always allows “npm run”'), findsOneWidget);
    expect(find.text('npm run test'), findsOneWidget);
    expect(find.text('Rate limit login'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('86%'), 200, scrollable: sheet);
    await tester.scrollUntilVisible(find.text('Remove from rig…'), 200, scrollable: sheet);
    expect(find.text('Kill session…'), findsOneWidget);
    expect(find.text('Edit this seat in the spec'), findsOneWidget);
    await tester.drag(sheet, const Offset(0, 2000));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();
    expect(chats, 1);
    expect(find.byType(SeatSheetBody), findsNothing, reason: 'the sheet closes on the way out');
  });

  testWidgets('from the chat the sheet has no Chat button', (tester) async {
    final store = await installFakes();
    final seat = Seat(rigId: '', logicalId: 'impl', sessionName: 'impl@app', runtime: 'claude-code');
    await tester.pumpWidget(AppScope(
      store: store,
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSeatSheet(context, 'app-rig', seat, fromChat: true, details: AgentDetails(seat: seat)),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Chat'), findsNothing);
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.byType(AnswerBar), findsNothing);
  });
}
