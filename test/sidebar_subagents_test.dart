import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/subagents.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;

import 'golden/fixtures.dart';

/// The hook feed of one loose agent: `scratch` in tmux, idle at its prompt.
String _hook() => jsonEncode([
      {
        'id': 'sess-scratch',
        'cwd': app,
        'tmux': 'scratch',
        'pane': '%7',
        'transcriptPath': '/Users/me/.claude/projects/-Users-me-code-app/sess-scratch.jsonl',
        'waiting': false,
        'activity': 'idle',
        'firstSeen': DateTime.now().subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
        'activeAt': DateTime.now().subtract(const Duration(minutes: 1)).millisecondsSinceEpoch,
        'at': DateTime.now().millisecondsSinceEpoch,
      },
    ]);

void main() {
  testWidgets('a running subagent is a child row under its agent in the tree, a rig seat or a loose agent, and goes when it finishes', (tester) async {
    final store = await installFakes();
    showLoose = true;
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async => cmd.contains('loose.json') ? _hook() : await fakeShell(cmd));
    addTearDown(() => SshExec.debugConnect = null);
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final feed = fleet.feedFor(homelab);
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: AppShell(key: UniqueKey()))));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Write the parser'), findsNothing, reason: 'nothing running yet');

    // 'attacker' (working) is a seat of the conveyor rig, 'scratch' a loose agent: the feed keys running subagents by session.
    feed.subagents = {
      'sess-attacker': [Subagent(sessionId: 'sess-attacker', agentId: 'a1', description: 'Write the parser', type: 'general-purpose')],
      'sess-scratch': [Subagent(sessionId: 'sess-scratch', agentId: 'a2', type: 'Explore')],
      'sess-nobody': [Subagent(sessionId: 'sess-nobody', agentId: 'a3', description: 'Belongs to no agent here')],
    };
    await feed.refresh();
    await tester.pump(const Duration(milliseconds: 400));

    Offset at(String text) => tester.getTopLeft(find.text(text));
    expect(find.text('Write the parser'), findsOneWidget);
    expect(find.text('Explore'), findsOneWidget, reason: 'no description: its type');
    expect(find.text('Belongs to no agent here'), findsNothing, reason: 'only subagents of an agent in the tree');
    expect(at('Write the parser').dy, greaterThan(at('attacker').dy), reason: 'under its agent');
    expect(at('Write the parser').dx, greaterThan(at('attacker').dx), reason: 'one level in');
    expect(at('Explore').dy, greaterThan(at('scratch').dy));
    expect(at('Explore').dx, greaterThan(at('scratch').dx));

    // A screen reader hears it as a running subagent.
    expect(find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Write the parser, subagent, running'), findsOneWidget);

    // Finished: the scan no longer lists it.
    feed.subagents = {
      'sess-scratch': [Subagent(sessionId: 'sess-scratch', agentId: 'a2', type: 'Explore')],
    };
    await feed.refresh();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Write the parser'), findsNothing);
    expect(find.text('Explore'), findsOneWidget);
  });
}
