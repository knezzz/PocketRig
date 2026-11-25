import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/rig_messages.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/rig_screen.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

void main() {
  setUp(() => animateStatusSpinners = false);

  test('a received envelope is one message: newest first, one copy per send, without the reply line', () {
    final ignored = [
      jsonEncode({
        'type': 'user',
        'message': {'content': 'just a question, no envelope'}
      }),
      jsonEncode({
        'type': 'assistant',
        'message': {'content': 'From: a@r\nTo: b@r\nSent: x\n---\nnot received'}
      }),
      'not json',
    ];
    final m = parseRigMessages([...sentLog, ...ignored].join('\n'));
    expect(m.map((x) => x.from), ['lead@conveyor', 'impl@conveyor', 'lead@conveyor'], reason: 'newest first');
    expect(m.first.to, {'review@conveyor', 'tests@conveyor'}, reason: 'two received copies, one message');
    expect(m.last.body, 'Take slice 3: retry 409s with backoff.\nKeep the change in router.ts.');
    expect(m.any((x) => x.body.contains('Reply')), isFalse);
  });

  test('a message that arrived while the seat was busy (queued_command) counts; a quoted reply line stays in the body',
      () {
    final queued = jsonEncode({
      'type': 'attachment',
      'timestamp': '2026-11-09T20:00:00Z',
      'attachment': {
        'type': 'queued_command',
        'prompt': 'From: pm@r\nTo: lead@r\nSent: x\n---\nWhile you work: ship it.'
      },
    });
    final quoting = jsonEncode({
      'type': 'user',
      'timestamp': '2026-11-09T19:00:00Z',
      'message': {
        'content':
            'From: lead@r\nTo: dev@r\nSent: y\n---\nAs pm said:\n---\n↩ Reply: rig send pm@r "..."\nso go.\n---\n↩ Reply: rig send lead@r "..."'
      },
    });
    final m = parseRigMessages('$queued\n$quoting');
    expect(m.first.body, 'While you work: ship it.');
    expect(m.last.body, contains('so go.'), reason: 'cut at the last reply line, not the quoted one');
  });

  test('only received user turns are read, the newest [limit] per seat', () {
    final script = rigMessagesScript(
        [Seat(rigId: 'r', logicalId: 'lead', sessionName: 'lead@r', runtime: 'claude-code')],
        limit: 7);
    expect(script, contains('"type": ?"user"|"queued_command"'));
    expect(script, contains('tail -n 7'));
  });

  Future<void> openProgress(WidgetTester tester, {Future<String> Function(String cmd)? shell}) async {
    final store = await installFakes();
    if (shell != null) SshExec.debugConnect = (_) async => SshExec.fake(shell);
    await tester.pumpWidget(
        MaterialApp(home: phone(store, RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app'))));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Progress'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('Progress lists the rig\'s messages; a tap shows the whole text', (tester) async {
    await openProgress(tester);
    final list = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(find.text('MESSAGES · 3'), 200, scrollable: list);
    await tester.scrollUntilVisible(find.text('lead › impl'), 200, scrollable: list);
    expect(find.text('lead › review, tests'), findsOneWidget, reason: 'the fan-out send shows once');
    await tester.ensureVisible(find.text('lead › impl'));
    await tester.pump();
    await tester.tap(find.text('lead › impl'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<SelectableText>(
                find.descendant(of: find.byType(BottomSheet), matching: find.byType(SelectableText)))
            .data,
        contains('Keep the change in router.ts.'),
        reason: 'the full text, not the 2-line preview');
    await tester.tapAt(const Offset(195, 60));
    await tester.pumpAndSettle();
    await close(tester);
  });

  testWidgets('the newest 50 show first; Show more reads further back', (tester) async {
    final many = [
      for (var i = 0; i < 60; i++)
        jsonEncode({
          'type': 'user',
          'timestamp': DateTime.utc(2026, 11, 9, 10).add(Duration(minutes: i)).toIso8601String(),
          'message': {'content': 'From: lead@conveyor\nTo: impl@conveyor\nSent: x\n---\nstep $i'},
        }),
    ];
    // Like a seat's log: `tail -n` gives the newest [limit] lines.
    await openProgress(tester,
        shell: (cmd) async => cmd.contains("grep -F 'From: '")
            ? many
                .skip(many.length - int.parse(RegExp(r'tail -n (\d+)').firstMatch(cmd)!.group(1)!).clamp(0, 60))
                .join('\n')
            : fakeShell(cmd));
    final list = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(find.text('MESSAGES · 50'), 200, scrollable: list);
    await tester.scrollUntilVisible(find.text('Show more'), 400, scrollable: list);
    // To the top of the list.
    await tester.ensureVisible(find.text('Show more'));
    await tester.pump();
    await tester.tap(find.text('Show more'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.scrollUntilVisible(find.text('MESSAGES · 60'), -400, scrollable: list);
    expect(find.text('Show more'), findsNothing);
    await close(tester);
  });

  testWidgets('the transcripts are read only while Progress is shown', (tester) async {
    var reads = 0;
    final store = await installFakes();
    SshExec.debugConnect = (_) async => SshExec.fake((cmd) async {
          if (cmd.contains("grep -F 'From: '")) reads++;
          return fakeShell(cmd);
        });
    await tester.pumpWidget(
        MaterialApp(home: phone(store, RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app'))));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(reads, 0, reason: 'opened on Agents');
    await tester.tap(find.text('Progress'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.scrollUntilVisible(find.text('MESSAGES · 3'), 200, scrollable: find.byType(Scrollable).last);
    expect(reads, 1);
    await tester.tap(find.text('Agents'));
    await tester.pump(); // the switch lands before the clock runs on
    await tester.pump(const Duration(minutes: 3));
    expect(reads, 1, reason: 'no polling while Progress is hidden');
    await close(tester);
  });
}
