import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/host_store.dart';
import 'package:pocket_rig/data/rig_spec.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/kit.dart';
import 'package:pocket_rig/ui/project_screen.dart';
import 'package:pocket_rig/ui/recent_screen.dart';
import 'package:pocket_rig/ui/rigs_home.dart';
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/spec_editor_screen.dart';
import 'package:pocket_rig/ui/theme.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/desktop_shell.dart';
import 'package:pocket_rig/ui/hosts_screen.dart' show HostsScreen;

import 'golden/fixtures.dart';

void main() {
  desktopShellTests();
  test('the local host runs commands and files without SSH', () async {
    SshExec.debugConnect = null;
    final host = Host.local('me');
    expect(host.isLocal, isTrue);
    expect(host.privateKeyPem, isNull, reason: 'no key: the daemon route never tries SSH');
    final exec = await SshExec.connect(host);
    expect((await exec.run('echo "a b" | tr a-z A-Z')).trim(), 'A B');
    final dir = Directory.systemTemp.createTempSync('pocketrig');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/spec.yaml');
    await exec.writeFile(f.path, 'name: it\'s\n');
    expect(f.readAsStringSync(), 'name: it\'s\n');
    expect(await exec.download(f.path), 'name: it\'s\n'.codeUnits);
  });

  testWidgets('a list opens into the detail pane, keeping a screen that refuses to close', (tester) async {
    final detail = GlobalKey<NavigatorState>();
    late BuildContext list;
    await tester.pumpWidget(MaterialApp(
      home: DetailPane(
        nav: detail,
        child: Row(children: [
          SizedBox(width: 200, child: Builder(builder: (c) {
            list = c;
            return const SizedBox();
          })),
          Expanded(child: Navigator(key: detail, onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => const Text('empty')))),
        ]),
      ),
    ));
    detailNavigator(list).push(MaterialPageRoute(builder: (_) => const Text('one')));
    await tester.pumpAndSettle();
    detailNavigator(list).push(MaterialPageRoute(builder: (_) => const Text('two')));
    await tester.pumpAndSettle();
    expect(find.text('two'), findsOneWidget);
    expect(find.text('one'), findsNothing, reason: 'the previous detail was cleared');

    detailNavigator(list).push(MaterialPageRoute(builder: (_) => const PopScope(canPop: false, child: Text('dirty'))));
    await tester.pumpAndSettle();
    detailNavigator(list).push(MaterialPageRoute(builder: (_) => const Text('three')));
    await tester.pumpAndSettle();
    detail.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('dirty'), findsOneWidget, reason: 'unsaved edits stay under the new screen');
  });
}

/// The wide desktop window over the golden fixtures' fake host.
Future<void> pumpDesktop(WidgetTester tester, HostStore store) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  isDesktop = true;
  addTearDown(() => isDesktop = false);
  // The real load always lists this Mac.
  if (!store.all.any((h) => h.isLocal)) store.all.insert(0, Host.local('me'));
  await tester.pumpWidget(AppScope(
    store: store,
    child: MaterialApp(theme: buildTheme(Tokens.light, Brightness.light), home: const AppShell()),
  ));
  await tester.pump(const Duration(seconds: 1));
}

void desktopShellTests() {
  testWidgets('desktop: a project in the sidebar fills the content panel, a seat opens over it', (tester) async {
    final store = await installFakes();
    await pumpDesktop(tester, store);
    expect(find.byType(RecentScreen), findsOneWidget, reason: 'the panel opens on the Inbox');
    expect(find.text('Add project folder'), findsWidgets);
    for (final gone in ['Active', 'Sessions']) {
      expect(find.text(gone), findsNothing, reason: 'desktop shows only projects');
    }

        // The sidebar comes first in the row, so its project row is the first match.
    for (var i = 0; i < 5 && find.text('app').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    // conveyor: lead and review wait on you, impl and tests work (see the fixtures).
    expect(_bar('app · 2 need you · 2 working'), findsOneWidget);
    expect(find.text('Inbox'), findsWidgets, reason: 'the Inbox heads the sidebar');
    await tester.tap(find.text('app').first);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ProjectScreen), findsOneWidget);

    final inList = find.descendant(of: find.byType(ProjectScreen), matching: find.text('lead · conveyor'));
    for (var i = 0; i < 5 && inList.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.tap(inList.first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byType(ProjectScreen, skipOffstage: false), findsOneWidget, reason: 'Back returns to the project');
  });

  testWidgets('desktop: saved hosts survive a load and a save, with this Mac first', (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    final again = HostStore();
    await again.load();
    expect(again.hosts.first.isLocal, isTrue);
    expect([for (final h in again.hosts) h.id], containsAll([homelab.id, macbook.id]));
    await again.select(homelab.id);
    final third = HostStore();
    await third.load();
    expect(third.hosts.length, store.hosts.length + 1, reason: 'a desktop save kept the remote hosts');
    expect(third.active?.id, homelab.id);
    await third.remove(Host.localId);
    expect(third.hosts.first.isLocal, isTrue, reason: 'this Mac cannot be removed');
  });

  testWidgets('desktop: a remote host and its projects sit in the sidebar next to this Mac', (tester) async {
    final store = await installFakes();
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('app').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text(homelab.name.toUpperCase()), findsWidgets);
    expect(find.text('THIS MAC'), findsWidgets);
    expect(find.text('app'), findsWidgets, reason: 'the remote host lists its projects');
    // The footer, pinned under the list: the whole row opens Hosts and settings.
    final settings = find.byTooltip('Hosts and settings');
    expect(settings, findsOneWidget);
    await tester.tap(settings);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(HostsScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('desktop: the Inbox opens in the content panel', (tester) async {
    final store = await installFakes();
    await pumpDesktop(tester, store);
    await tester.tap(find.text('Inbox').first);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1)); // the replaced route leaves
    expect(find.byType(RecentScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('desktop: an added folder can be removed; a project found from its agents cannot', (tester) async {
    final store = await installFakes();
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('dotfiles').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.longPress(find.text('app').first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Unpin'), findsNothing, reason: 'listed because its rigs run there');
    await tester.tapAt(const Offset(5, 5)); // closes the sheet
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('dotfiles'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ProjectScreen), findsOneWidget);

    await tester.longPress(find.descendant(of: find.byKey(const ValueKey('sidebar')), matching: find.text('dotfiles')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Unpin'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    final sidebar = find.byKey(const ValueKey('sidebar'));
    expect(find.descendant(of: sidebar, matching: find.text('dotfiles')), findsNothing);
    expect(store.active!.pinnedFolders, isNot(contains('~/dotfiles')), reason: 'saved, not just hidden');
    expect(find.byType(RigsHome), findsOneWidget, reason: 'its open project closed: back to the Rigs home');
    expect(find.text('Unpinned dotfiles'), findsOneWidget, reason: 'the toast outlives the row');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('desktop: Rigs, Inbox and Hosts and settings have their title at one x and y and one size, with no back arrow', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    await pumpDesktop(tester, store);
    await tester.pump(const Duration(seconds: 1));
    final sidebar = find.byKey(const ValueKey('sidebar'));
    final seen = <(String, Offset, double?)>[];
    for (final (row, title) in [('Rigs', 'Rigs'), ('Inbox', 'Inbox'), (null, 'Hosts and settings')]) {
      await tester.tap(row == null ? find.byTooltip('Hosts and settings') : find.descendant(of: sidebar, matching: find.text(row)));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      final t = find.descendant(of: find.byType(PageHeader), matching: find.textContaining(title));
      seen.add((title, tester.getTopLeft(t), tester.widget<Text>(t).style?.fontSize ?? Theme.of(tester.element(t)).textTheme.headlineSmall?.fontSize));
      expect(find.descendant(of: find.byType(PageHeader), matching: find.byTooltip('Back')), findsNothing, reason: '$title: no back arrow');
    }
    expect({for (final s in seen) s.$2}.length, 1, reason: 'one x and y: $seen');
    expect({for (final s in seen) s.$3}.length, 1, reason: 'one size: $seen');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('desktop: an agent row shows its dots button only while the mouse is over it', (tester) async {
    final store = await installFakes();
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('impl').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    double dots() => tester.widget<Opacity>(find.ancestor(of: find.byTooltip('Actions for impl'), matching: find.byType(Opacity)).first).opacity;
    expect(dots(), 0);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('impl').first));
    await tester.pump();
    expect(dots(), 1);
    await mouse.moveTo(const Offset(700, 400));
    await tester.pump();
    expect(dots(), 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('desktop: an agent outside a rig opens its chat in the content panel', (tester) async {
    final store = await installFakes();
    showLoose = true;
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('app').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.tap(find.text('app').first);
    await tester.pump(const Duration(seconds: 1));
    // One scroll: the agent outside a rig is in its worktree card, no tab to switch to.
    final row = find.descendant(of: find.byType(ProjectScreen), matching: find.text('scratch'));
    for (var i = 0; i < 5 && row.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.tap(row.first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byType(ProjectScreen, skipOffstage: false), findsOneWidget, reason: 'the project is under it');
  });

  testWidgets('wide spec editor: typed YAML redraws the form, broken YAML blocks Save', (tester) async {
    final store = await installFakes();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const text = 'version: "0.2"\nname: crew\npods:\n  - id: core\n    members:\n      - id: lead\n        runtime: claude-code\n';
    await tester.pumpWidget(AppScope(
      store: store,
      child: MaterialApp(
        theme: buildTheme(Tokens.light, Brightness.light),
        home: SpecEditorScreen(file: RigSpecFile(path: '/w/crew.yaml', projectPath: '/w'), text: text, projectName: 'w'),
      ),
    ));
    final yaml = find.descendant(of: find.bySemanticsLabel('Spec YAML'), matching: find.byType(TextField));
    expect(yaml, findsOneWidget);
    await tester.enterText(yaml, text.replaceFirst('name: crew', 'name: renamed'));
    await tester.pump();
    expect(find.text('renamed'), findsWidgets, reason: 'the form shows the typed name');

    await tester.enterText(yaml, 'pods: [');
    await tester.pump();
    expect(find.textContaining('doesn\'t parse'), findsOneWidget);
    final save = tester.widget<PillButton>(find.widgetWithText(PillButton, 'Save'));
    expect(save.onPressed, isNull);
  });

  testWidgets('desktop chat: Enter sends, Shift+Enter does not', (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    // impl is working (lead waits on a permission, which takes the composer's place).
    await tester.pumpWidget(
        MaterialApp(home: phone(store, ChatScreen(rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'impl'), asChat: true))));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final box = find.byType(TextField).last;
    String typed() => tester.widget<TextField>(box).controller!.text;

    await tester.enterText(box, 'first line');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(typed(), 'first line', reason: 'Shift+Enter is left to the field (a newline), not sent');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(typed(), isEmpty, reason: 'Enter sent it');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 2));
  });
}

/// A sidebar bar, by its tooltip (name and the states under it): the same words its screen-reader label has.
Finder _bar(String startsWith) =>
    find.byWidgetPredicate((w) => w is Semantics && (w.properties.label ?? '').startsWith(startsWith.replaceFirst(' · ', ', ')));
