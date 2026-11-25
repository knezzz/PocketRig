import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;
import 'package:pocket_rig/ui/folder_browser.dart';
import 'package:pocket_rig/ui/new_sheet.dart';

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

void main() {
  // The fixtures' hosts are shared objects: a pin made in one test must not show in the next.
  setUp(() => homelab.pinnedFolders = ['~/dotfiles']);

  Finder inBrowser(String text) => find.descendant(of: find.byType(FolderBrowser), matching: find.text(text));

  test('a listing is parsed: the absolute path, each folder with its git mark; and why it failed', () {
    final ok = parseFolderListing('@@pocketrig-folders\n/Users/me/code\ng app\n- notes\n');
    expect(ok.state, ListingState.ok);
    expect(ok.path, '/Users/me/code');
    expect(ok.folders, [('app', true), ('notes', false)]);
    expect(parseFolderListing('@@pocketrig-nodir\n').state, ListingState.missing);
    expect(parseFolderListing('@@pocketrig-file\n').state, ListingState.file);
    expect(parseFolderListing('@@pocketrig-unreadable\n').state, ListingState.unreadable);
    expect(parseFolderListing('@@pocketrig-folders\n/x\n').folders, isEmpty);
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// The sidebar of the Mac app with the browser open on the host that is up (listed first).
  Future<dynamic> openBrowser(WidgetTester tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    await pumpDesktop(tester, store);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final add = find.text('Add project folder');
    expect(add, findsNWidgets(store.hosts.length), reason: 'a button row per host');
    await tester.ensureVisible(add.first);
    await tester.pump();
    await tester.tap(add.first);
    await settle(tester);
    expect(find.text('Choose a project folder'), findsOneWidget);
    return store;
  }

  testWidgets('the browser starts at ~, opens folders, marks repositories, and Choose pins the selected folder on that host',
      (tester) async {
    final store = await openBrowser(tester);
    final host = store.hosts.firstWhere((h) => h.name == 'homelab');
    expect(find.text('HOMELAB'), findsWidgets);
    for (final n in ['code', 'Documents', 'notes']) {
      expect(find.text(n), findsOneWidget);
    }
    // Tap selects: the footer names it; nothing opens.
    await tester.tap(inBrowser('code'));
    await tester.pump(const Duration(milliseconds: 400)); // a double-click listener waits to tell a single click
    expect(find.text('~/code'), findsOneWidget, reason: 'the footer shows the chosen path');
    expect(inBrowser('app'), findsNothing);
    // The chevron opens it.
    await tester.tap(find.byTooltip('Open code'));
    await settle(tester);
    expect(inBrowser('app'), findsOneWidget);
    expect(inBrowser('git'), findsNWidgets(3), reason: 'app, site and pocketrig are repositories');
    expect(find.text('~/code'), findsWidgets, reason: 'nothing selected: the folder you are in');
    // The git mark and the chevron sit at the row's right edge, not after the name.
    final dialog = tester.getRect(find.byType(FolderBrowser));
    expect(tester.getTopRight(find.byTooltip('Open app')).dx, greaterThan(dialog.right - 48), reason: 'the chevron at the right edge');
    expect(tester.getTopRight(inBrowser('git').first).dx, greaterThan(dialog.right - 110), reason: 'the git mark just left of the chevron');
    // Select a repo and choose it.
    await tester.tap(inBrowser('app'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Choose this folder'));
    await settle(tester);
    expect(host.pinnedFolders, contains('$fakeHome/code/app'), reason: 'pinned on the host it was browsed on');
    for (final h in store.hosts.where((h) => h != host)) {
      expect(h.pinnedFolders, isNot(contains('$fakeHome/code/app')));
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('with nothing selected Choose takes the folder you are in; Up and the breadcrumb go back', (tester) async {
    final store = await openBrowser(tester);
    final host = store.hosts.firstWhere((h) => h.name == 'homelab');
    await tester.tap(find.byTooltip('Open code'));
    await settle(tester);
    await tester.tap(find.text('Up'));
    await settle(tester);
    expect(find.text('Documents'), findsOneWidget, reason: 'Up is ~ again');
    await tester.tap(find.byTooltip('Open code'));
    await settle(tester);
    await tester.tap(find.text('~')); // the breadcrumb's ~
    await settle(tester);
    expect(find.text('Documents'), findsOneWidget);
    await tester.tap(find.byTooltip('Open code'));
    await settle(tester);
    await tester.tap(find.text('Choose this folder'));
    await settle(tester);
    expect(host.pinnedFolders, contains('$fakeHome/code'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an empty folder, an unreadable one and a pasted path that is not a folder each say so', (tester) async {
    await openBrowser(tester);
    await tester.tap(find.byTooltip('Open code'));
    await settle(tester);
    await tester.tap(find.byTooltip('Open scratch'));
    await settle(tester);
    expect(find.text('No folders here'), findsOneWidget);
    await tester.tap(find.text('Up'));
    await settle(tester);
    await tester.tap(find.byTooltip('Open archive'));
    await settle(tester);
    expect(find.text('Can\'t open this folder'), findsOneWidget);
    expect(find.textContaining('no permission'), findsOneWidget);
    // The path field: Enter jumps there and checks it; a bad one says why under the field and stays put.
    await tester.enterText(find.byType(TextField), '~/code/missing');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(find.text('No such folder on homelab.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '~/afile.txt');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(find.text('That is a file, not a folder.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '~/code/app/');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(find.text('No such folder on homelab.'), findsNothing);
    expect(find.text('rigs'), findsOneWidget, reason: 'the pasted path is a folder: listed');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an offline host shows its Add project folder button muted, says "host offline", and does nothing', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    OpenRigClient.factory = (h) => OpenRigClient(h,
        httpClient: MockClient((req) async {
          if (h.id == homelab.id) throw Exception('connection refused');
          return http.Response(req.url.path.startsWith('/api/discovery') ? '{"sessions": []}' : '[]', 200);
        }),
        eventSource: ({rigId, replay, lastEventId}) => const Stream.empty());
    await pumpDesktop(tester, store);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final side = find.ancestor(of: find.text('Add project folder').first, matching: find.byType(ListView));
    expect(find.descendant(of: side, matching: find.textContaining('host offline')), findsOneWidget);
    await tester.ensureVisible(find.textContaining('host offline'));
    await tester.tap(find.textContaining('host offline'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsNothing, reason: 'an offline host cannot check a path');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  group('the New sheet', () {
    Future<void> open(WidgetTester tester, dynamic store) async {
      SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
      addTearDown(() => SshExec.debugConnect = null);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: phone(store, NewSheet(host: homelab, path: app)))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Location'));
      await tester.pumpAndSettle();
      expect(find.text('Choose another folder…'), findsOneWidget, reason: 'on a remote host too');
      await tester.tap(find.text('Choose another folder…'));
      await settle(tester);
      expect(find.text('Choose a project folder'), findsNothing, reason: 'the sheet asks for "Choose a folder"');
      await tester.tap(find.text('notes'));
      await tester.pump();
      await tester.tap(find.text('Choose this folder'));
      await tester.pumpAndSettle();
    }

    testWidgets('Choose another folder… on a remote host returns with the location set and Add as a project on, which pins it', (tester) async {
      final store = await installFakes();
      await open(tester, store);
      expect(find.text('~/notes'), findsWidgets, reason: 'the location is the folder chosen');
      expect(find.text('Add ~/notes as a project'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue, reason: 'on by default');
      expect(homelab.pinnedFolders, isNot(contains('$fakeHome/notes')), reason: 'choosing alone pins nothing');
      await tester.tap(find.text('Start agent'));
      await tester.pumpAndSettle();
      expect(homelab.pinnedFolders, contains('$fakeHome/notes'));
    });

    testWidgets('with the toggle off the folder is used but not added', (tester) async {
      final store = await installFakes();
      await open(tester, store);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.tap(find.text('Start agent'));
      await tester.pumpAndSettle();
      expect(homelab.pinnedFolders, isNot(contains('$fakeHome/notes')));
    });

    testWidgets('a folder the browser marks git is a git repository to the sheet too (no \'Not a git repository\')', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = await installFakes();
      SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
      addTearDown(() => SshExec.debugConnect = null);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: phone(store, NewSheet(host: homelab, path: app)))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Location'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose another folder…'));
      await settle(tester);
      await tester.tap(find.byTooltip('Open code'));
      await settle(tester);
      expect(find.text('git'), findsNWidgets(3));
      await tester.ensureVisible(find.text('pocketrig'));
      await tester.tap(find.text('pocketrig'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Choose this folder'));
      await tester.pumpAndSettle();
      expect(find.text('~/code/pocketrig'), findsWidgets);
      expect(find.textContaining('Not a git repository'), findsNothing);
      expect(find.text('WORKTREE'), findsOneWidget);
    });

    testWidgets('in the Location menu every row\'s host chip ends at the same x, the checked row\'s too', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = await installFakes();
      SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
      addTearDown(() => SshExec.debugConnect = null);
      await fleet.feedFor(homelab).refresh();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: phone(store, NewSheet(host: homelab, path: app)))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Location'));
      await tester.pumpAndSettle();
      final chips = find.descendant(of: find.byType(PopupMenuItem<Object>), matching: find.text('homelab'));
      expect(chips.evaluate().length, greaterThan(1), reason: 'several locations');
      final right = {for (final e in chips.evaluate()) tester.getTopRight(find.byWidget(e.widget)).dx.round()};
      expect(right, hasLength(1), reason: 'the chips are right-aligned at one x, the checked row included');
    });
  });
}
