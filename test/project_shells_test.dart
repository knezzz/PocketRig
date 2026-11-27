import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/agent_jobs.dart';
import 'package:pocket_rig/data/fleet.dart' show fleet;
import 'package:pocket_rig/data/host_store.dart' show isDesktop;
import 'package:pocket_rig/data/projects.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;
import 'package:pocket_rig/ui/project_screen.dart' show ProjectScreen;
import 'package:pocket_rig/ui/terminal_screen.dart' show TerminalScreen;

import 'golden/fixtures.dart';
import 'app_icon_finders.dart';
import 'package:pocket_rig/ui/app_icon.dart';

void main() {
  test('the scan gives each tmux session with its folder, and only rp-* ones are project shells', () {
    const out = '@@jobs\trp-app:/Users/me/code/app\n'
        '@@jobs\tdev@conveyor:/Users/me/code/app\n'
        '@@jobs\trp-gone:\n'
        '@@jobs\trp-my notes:/Users/me/my:notes\n';
    final sessions = AgentJob.parseSessions(out);
    expect(sessions.map((s) => s.$1), ['rp-app', 'dev@conveyor', 'rp-gone', 'rp-my notes']);
    expect(AgentJob.parseAll(out).keys, ['rp-app', 'dev@conveyor', 'rp-gone', 'rp-my notes']);
    expect(projectShells(sessions).map((s) => '${s.name} ${s.cwd}'),
        ['rp-app /Users/me/code/app', 'rp-my notes /Users/me/my:notes']);
  });

  test('a shell session an agent runs in is one row, the agent\'s; with the agent gone it is a shell again', () {
    const repo = '/Users/me/code/app';
    final agent = LooseAgent(id: 'rp-app', runtime: 'claude-code', cwd: repo, tmuxSession: 'rp-app', tmuxPane: '%1');
    const shells = [ProjectShell('rp-app', repo), ProjectShell('rp-other', repo)];
    final both = groupIntoProjects(const [], [repo], [agent], const [], shells).single;
    expect(both.loose.map((a) => a.id), ['rp-app']);
    expect(both.shells.map((s) => s.name), ['rp-other'], reason: 'a different session stays a shell');
    final gone = groupIntoProjects(const [], [repo], const [], const [], shells).single;
    expect(gone.shells.map((s) => s.name), ['rp-app', 'rp-other']);
  });

  test('a shell joins the project of its folder, a worktree joins its main checkout, a bare folder gets a card', () {
    const repo = '/Users/me/code/app';
    final projects = groupIntoProjects(const [], [repo], const [], const [], [
      const ProjectShell('rp-app', repo),
      const ProjectShell('rp-fix', '$repo/.worktrees/fix'),
      const ProjectShell('rp-solo', '/Users/me/code/solo'),
    ]);
    final byName = {for (final p in projects) p.name: p};
    expect(byName['app']!.shells.map((s) => s.name), ['rp-app', 'rp-fix']);
    expect(byName['solo']!.shells.map((s) => s.name), ['rp-solo']);
  });

  test('the scan script lists real tmux sessions with their folder', () async {
    if ((await Process.run('which', ['tmux'])).exitCode != 0) return;
    final dir = Directory.systemTemp.createTempSync('rp-shells');
    final name = 'rp-test-$pid';
    addTearDown(() {
      Process.runSync('tmux', ['kill-session', '-t', '=$name']);
      dir.deleteSync(recursive: true);
    });
    expect(Process.runSync('tmux', ['new-session', '-d', '-s', name, '-c', dir.path]).exitCode, 0);
    // No UTF-8 locale, as over a bare SSH login: tmux would print a tab as '_'.
    final out = (await Process.run('sh', ['-c', AgentJob.allSessionsScript],
            environment: {'PATH': Platform.environment['PATH']!}, includeParentEnvironment: false))
        .stdout as String;
    expect(AgentJob.parseAll(out).keys, contains(name));
    final mine = projectShells(AgentJob.parseSessions(out)).where((s) => s.name == name);
    expect(mine.single.cwd, endsWith(dir.path.split('/').last), reason: 'macOS temp is under /private');
  }, timeout: const Timeout(Duration(minutes: 2))); // the script reads every session on the machine

  testWidgets('a running shell is a terminal row under its project: tap opens it, Close shell kills the session',
      (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    final ran = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          ran.add(cmd);
          if (cmd.contains('kill-session')) return 'pocketrig-closed\n';
          final base = await fakeShell(cmd);
          return cmd.contains('@@pocketrig-jobs') ? '$base\n@@pocketrig-jobs\n@@jobs\trp-app:$app\n' : base;
        });
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(store: store, child: const MaterialApp(home: AppShell())));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('rp-app'), findsOneWidget, reason: 'listed under app');
    expect(appIcon(AppIconKind.shell), findsWidgets, reason: 'the shell kind\'s icon');

    await tester.tap(find.text('rp-app'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(TerminalScreen), findsOneWidget);

    final at = tester.getCenter(find.text('rp-app').first);
    await tester.longPressAt(at);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close shell…'));
    await tester.pumpAndSettle();
    expect(find.text('Close rp-app?'), findsOneWidget);
    expect(ran.where((c) => c.contains('kill-session')), isEmpty, reason: 'not before the confirm');
    await tester.tap(find.text('Close shell'));
    await tester.pumpAndSettle();
    expect(ran.where((c) => c.contains('kill-session') && c.contains('=rp-app')), hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Rename… gives a shell an app-side label: on the row and the terminal title, kept across refreshes, '
      'cleared by an empty name, dropped when the shell is closed; the tmux session is never renamed', (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    addTearDown(() => homelab.rigNames.remove('rp-app'));
    final ran = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          ran.add(cmd);
          if (cmd.contains('kill-session')) return 'pocketrig-closed\n';
          final base = await fakeShell(cmd);
          return cmd.contains('@@pocketrig-jobs') ? '$base\n@@pocketrig-jobs\n@@jobs\trp-app:$app\n' : base;
        });
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(store: store, child: const MaterialApp(home: AppShell())));
    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await settle();
    Future<void> rename(String to) async {
      await tester.longPressAt(tester.getCenter(find.text(homelab.shellLabel('rp-app')).first));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.descendant(of: find.byType(BottomSheet), matching: find.byType(TextField)), to);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
    }

    await rename('App dev server');
    expect(find.text('App dev server'), findsOneWidget);
    expect(find.text('rp-app'), findsNothing);
    expect(homelab.rigNames['rp-app'], 'App dev server');
    await fleet.feedFor(homelab).refresh();
    await settle();
    expect(find.text('App dev server'), findsOneWidget, reason: 'a refresh keeps it');

    await tester.tap(find.text('App dev server'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.descendant(of: find.byType(TerminalScreen), matching: find.text('App dev server')), findsOneWidget,
        reason: 'the terminal title');

    await rename('');
    expect(find.text('rp-app'), findsWidgets, reason: 'an empty name restores the session name');
    expect(homelab.rigNames.containsKey('rp-app'), isFalse);

    await rename('Again');
    await tester.longPressAt(tester.getCenter(find.text('Again').first));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close shell…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close shell'));
    await tester.pumpAndSettle();
    expect(ran.where((c) => c.contains('kill-session') && c.contains('=rp-app')), hasLength(1));
    expect(ran.any((c) => c.contains('rename-session')), isFalse, reason: 'tmux is never renamed');
    expect(homelab.rigNames.containsKey('rp-app'), isFalse, reason: 'closing drops the label');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the project page lists only its shells under a Shells tab; Close shell asks, then the shell is gone', (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    final closed = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          final base = await fakeShell(cmd);
          if (cmd.contains('kill-session')) {
            closed.add(RegExp(r'=(rp-[a-z]+)').firstMatch(cmd)!.group(1)!);
            return 'pocketrig-closed\n';
          }
          if (!cmd.contains('@@pocketrig-jobs')) return base;
          // Two shells in app, minus whatever was closed.
          return '$base\n@@pocketrig-jobs\n'
              '${closed.contains('rp-one') ? '' : '@@jobs\trp-one:$app\n'}'
              '${closed.contains('rp-two') ? '' : '@@jobs\trp-two:$app\n'}';
        });
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(store: store, child: const MaterialApp(home: AppShell())));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('sidebar')), matching: find.text('app')).first);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1)); // the page slides in
    expect(find.byType(ProjectScreen), findsOneWidget);
    await tester.tap(find.text('Shells 2'));
    await tester.pump(const Duration(milliseconds: 300));
    final page = find.byType(ProjectScreen);
    expect(find.descendant(of: page, matching: find.text('rp-one')), findsOneWidget);
    expect(find.descendant(of: page, matching: find.text('rp-two')), findsOneWidget);
    expect(find.descendant(of: page, matching: find.text('conveyor')), findsNothing, reason: 'only the shells, no agents or rigs');
    await tester.tap(find.byTooltip('Close rp-one'));
    await tester.pumpAndSettle();
    expect(closed, isEmpty, reason: 'not before the confirm');
    await tester.tap(find.text('Close shell'));
    await tester.pumpAndSettle();
    expect(closed, ['rp-one']);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.descendant(of: page, matching: find.text('rp-one')), findsNothing, reason: 'gone');
    expect(find.descendant(of: page, matching: find.text('rp-two')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
