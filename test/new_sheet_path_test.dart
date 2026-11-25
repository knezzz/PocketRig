import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/host_store.dart' show HostStore;
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/new_sheet.dart';
import 'package:pocket_rig/ui/theme.dart' show Tokens;

import 'golden/fixtures.dart';

void main() {
  Future<void> open(WidgetTester tester, HostStore store, {String? path}) async {
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
    addTearDown(() => SshExec.debugConnect = null);
    await fleet.feedFor(homelab).refresh();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: phone(store, NewSheet(host: homelab, path: path ?? app)))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> typeAs(WidgetTester tester, String text) async {
    await tester.tap(find.byTooltip('Location'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Type a path…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), text);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 300));
  }

  FilledButton start(WidgetTester tester) => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Start agent'));

  test('a pasted path is trimmed (spaces, quotes) and loses a trailing slash', () {
    expect(cleanTypedPath("  '~/code/foo/'  "), '~/code/foo');
    expect(cleanTypedPath('"/srv/x"'), '/srv/x');
    expect(cleanTypedPath('/'), '/', reason: 'the root stays');
    expect(cleanTypedPath('~/code//'), '~/code');
  });

  testWidgets('Type a path… turns the Location into a text field; a folder that exists gets a ✓ and the Worktree list follows it',
      (tester) async {
    final store = await installFakes();
    await open(tester, store, path: '~/dotfiles');
    await tester.tap(find.byTooltip('Location'));
    await tester.pumpAndSettle();
    expect(find.text('Type a path…'), findsOneWidget, reason: 'a row in the Location menu');
    await tester.tap(find.text('Type a path…'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('~/code/foo or /srv/x'), findsOneWidget, reason: 'the placeholder');
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, isTrue, reason: 'autofocused');

    await tester.enterText(find.byType(TextField), "  '~/code/app/' ");
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Checking…'), findsOneWidget, reason: 'asked after a pause, not at once');
    expect(start(tester).onPressed, isNull, reason: 'Start waits for the ✓');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.text('Checking…'), findsNothing);
    expect(find.textContaining('No folder'), findsNothing, reason: 'a folder that exists says nothing more');
    // The Worktree field follows the folder: app is a git repository with a worktree.
    await tester.tap(find.byTooltip('Worktree'));
    await tester.pumpAndSettle();
    expect(find.text('flaky-ci'), findsOneWidget, reason: 'app\'s worktrees, not dotfiles\'');
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(start(tester).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a missing folder says so on the host, in red; a file says it is a file; Start stays off', (tester) async {
    final store = await installFakes();
    await open(tester, store);
    await typeAs(tester, '~/code/missing');
    expect(find.text('No folder at ~/code/missing on homelab'), findsOneWidget);
    expect(tester.widget<Text>(find.text('No folder at ~/code/missing on homelab')).style!.color, Tokens.light.removed);
    expect(find.byIcon(Icons.priority_high), findsOneWidget);
    expect(start(tester).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '~/afile.txt');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('That is a file, not a folder'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a folder that is not a git repository: a muted note, and no Worktree field', (tester) async {
    final store = await installFakes();
    await open(tester, store);
    await typeAs(tester, '/srv/x');
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.text('Not a git repository: starts in this folder'), findsOneWidget);
    expect(find.byTooltip('Worktree'), findsNothing, reason: 'no disabled worktree field');
    expect(find.text('WORKTREE'), findsNothing);
    expect(start(tester).onPressed, isNotNull, reason: 'it can start in the folder itself');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an unreachable host is not "no folder": its own message and a Retry that asks again', (tester) async {
    final store = await installFakes();
    await open(tester, store);
    SshExec.debugConnect = (h) async => throw 'connection refused';
    await typeAs(tester, '~/code/foo');
    expect(find.text('Can\'t reach homelab: try again'), findsOneWidget);
    expect(find.textContaining('No folder'), findsNothing);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget, reason: 'a different mark from the missing folder\'s !');
    expect(find.byIcon(Icons.priority_high), findsNothing);
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
    await tester.tap(find.text('Retry'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.check), findsOneWidget, reason: 'the retry reached the host');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Escape leaves the typed field for the normal one, and choosing a location from the menu does too', (tester) async {
    final store = await installFakes();
    await open(tester, store);
    await typeAs(tester, '~/code/missing');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('~/code/app'), findsOneWidget, reason: 'the location it had');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the sheet can open already typing a path (the demo\'s screens): checked at once, the state shown', (tester) async {
    final store = await installFakes();
    SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
    addTearDown(() => SshExec.debugConnect = null);
    await fleet.feedFor(homelab).refresh();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: phone(store, NewSheet(host: homelab, path: app, typed: '~/code/missing')))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('No folder at ~/code/missing on homelab'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
