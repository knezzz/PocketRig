import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/host_store.dart';
import 'package:pocket_rig/data/subagents.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/kit.dart';
import 'package:pocket_rig/ui/loose_agent_screen.dart';
import 'package:pocket_rig/ui/project_screen.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;
import 'package:pocket_rig/ui/status_shape.dart';

import 'desktop_test.dart' show pumpDesktop;
import 'app_icon_finders.dart';
import 'golden/fixtures.dart';

/// One rule for a loose agent's state (looseState), on every screen that shows it.
/// [idleOnShell]: it idles at its prompt with a subagent running, so it is on shell.
/// [stale]: its `working` flag is 20 minutes old, so it reads idle.
String _hook({required bool stale}) => jsonEncode([
      {
        'id': 'sess-scratch',
        'cwd': app,
        'tmux': 'scratch',
        'pane': '%7',
        'transcriptPath': '/Users/me/.claude/projects/-Users-me-code-app/sess-scratch.jsonl',
        'waiting': false,
        'activity': stale ? 'working' : 'idle',
        'firstSeen': DateTime.now().subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
        'activeAt': DateTime.now().subtract(Duration(minutes: stale ? 20 : 1)).millisecondsSinceEpoch,
        'at': DateTime.now().millisecondsSinceEpoch,
      },
    ]);

Future<HostStore> _setup(WidgetTester tester, {required bool stale}) async {
  final store = await installFakes();
  showLoose = true;
  SshExec.debugConnect = (h) async => SshExec.fake((cmd) async => cmd.contains('loose.json') ? _hook(stale: stale) : await fakeShell(cmd));
  addTearDown(() => SshExec.debugConnect = null);
  return store;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The subagent only the feed knows: it puts an idle agent on shell.
Future<void> _subagent() async {
  final feed = fleet.feedFor(homelab);
  feed.subagents = {
    'sess-scratch': [Subagent(sessionId: 'sess-scratch', agentId: 'a1')],
  };
  await feed.refresh();
}

/// Scrolls the Inbox until [f] is built; false when it never shows.

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  group('a loose agent idle at its prompt with a subagent running is on shell', () {
    testWidgets('on its project page', (tester) async {
      final store = await _setup(tester, stale: false);
      await tester.pumpWidget(MaterialApp(home: phone(store, const ProjectScreen(path: app))));
      await _settle(tester);
      await _subagent();
      await _settle(tester);
      await tester.tap(find.descendant(of: find.byType(Segmented<int>), matching: find.text('Agents')));
      await _settle(tester);
      final row = find.ancestor(of: find.text('scratch'), matching: find.byType(RowTile)).first;
      expect(tester.widget<StatusIcon>(find.descendant(of: row, matching: agentIcon())).status, Status.shell);
      await _close(tester);
    });

    testWidgets('on its own screen', (tester) async {
      final store = await _setup(tester, stale: false);
      await tester.pumpWidget(MaterialApp(home: phone(store, const ProjectScreen(path: app))));
      await _settle(tester);
      await _subagent();
      await _settle(tester);
      final a = fleet.feedFor(homelab).loose.firstWhere((a) => a.name == 'scratch');
      await tester.pumpWidget(MaterialApp(home: phone(store, LooseAgentScreen(agent: a, rigs: const []))));
      await _settle(tester);
      expect(tester.widget<StatusShape>(find.byType(StatusShape).first).status, Status.shell);
      await _close(tester);
    });

    testWidgets('in the sidebar', (tester) async {
      final store = await _setup(tester, stale: false);
      await tester.pumpWidget(MaterialApp(home: phone(store, const AppShell())));
      await _settle(tester);
      await _subagent();
      await _settle(tester);
      await openDrawer(tester);
      final row = find.ancestor(of: find.text('scratch'), matching: find.byType(InkWell)).first;
      expect(tester.widget<StatusIcon>(find.descendant(of: row, matching: agentIcon())).status,
          Status.shell);
      await _close(tester);
    });
  });

  group('a loose agent whose working flag is 20 minutes old is idle', () {
    testWidgets('on its project page', (tester) async {
      final store = await _setup(tester, stale: true);
      await tester.pumpWidget(MaterialApp(home: phone(store, const ProjectScreen(path: app))));
      await _settle(tester);
      await tester.tap(find.descendant(of: find.byType(Segmented<int>), matching: find.text('Agents')));
      await _settle(tester);
      final row = find.ancestor(of: find.text('scratch'), matching: find.byType(RowTile)).first;
      expect(tester.widget<StatusIcon>(find.descendant(of: row, matching: agentIcon())).status, Status.idle);
      await _close(tester);
    });

    testWidgets('and is not listed in the sidebar: idle for 20 minutes is past the 10-minute window, as for a rig\'s seats', (tester) async {
      final store = await _setup(tester, stale: true);
      await tester.pumpWidget(MaterialApp(home: phone(store, const AppShell())));
      await _settle(tester);
      await openDrawer(tester);
      expect(find.descendant(of: find.byType(Drawer), matching: find.text('scratch')), findsNothing);
      await _close(tester);
    });

    testWidgets('and is not counted as working in the desktop sidebar', (tester) async {
      final store = await _setup(tester, stale: true);
      await pumpDesktop(tester, store);
      await _settle(tester);
      // conveyor's impl and tests work, lead and review wait (see the fixtures); the stale agent adds nothing.
      expect(_bar('app · 2 need you · 2 working'), findsOneWidget);
      await _close(tester);
    });
  });
}

/// A sidebar bar, by its tooltip (name and the states under it): the same words its screen-reader label has.
Finder _bar(String startsWith) =>
    find.byWidgetPredicate((w) => w is Semantics && (w.properties.label ?? '').startsWith(startsWith.replaceFirst(' · ', ', ')));
