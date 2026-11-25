import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart' show fleet;
import 'package:pocket_rig/data/host_store.dart';
import 'package:pocket_rig/data/needs_you.dart' show needsYouCount;
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/data/usage_rings.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/chat_screen.dart' show ChatScreen;
import 'package:pocket_rig/ui/deep_links.dart' show DeepLinks;
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;
import 'package:pocket_rig/ui/terminal_screen.dart' show TerminalScreen;
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/hosts_screen.dart';

import 'golden/fixtures.dart';

void main() {
  test('an off host is absent from hosts and active, but saved whole and restored; on again returns it', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = HostStore();
    await store.load();
    final lab = Host(
      id: 'a',
      name: 'lab',
      address: 'lab.ts.net',
      sshUser: 'me',
      privateKeyPem: 'PEM',
      pinnedFolders: ['/code/x'],
      ntfyTopic: 'topic_1',
      hostKeyType: 'ssh-ed25519',
      hostKeyFingerprint: 'SHA256:abc',
      notifyKinds: {'permission'},
      agentNames: {'s': 'Sam'},
      rigNames: {'r': 'Rig'},
      color: 0xFF112233,
    );
    final other = Host(id: 'b', name: 'other', address: 'other.ts.net', sshUser: 'me');
    await store.upsert(lab);
    await store.upsert(other);
    await store.select('a');
    expect(store.active?.id, 'a');

    await store.setEnabled(lab, false);
    expect(store.hosts.map((h) => h.id), ['b']);
    expect(store.active?.id, 'b', reason: 'the active host moves to the next one that is on');
    expect(store.all.map((h) => h.id), ['a', 'b'], reason: 'the Hosts screen still lists it');

    final again = HostStore();
    await again.load();
    expect(again.hosts.map((h) => h.id), ['b'], reason: 'off survives a restart');
    final saved = again.all.firstWhere((h) => h.id == 'a');
    expect(saved.enabled, isFalse);
    expect([saved.privateKeyPem, saved.ntfyTopic, saved.hostKeyFingerprint, saved.color],
        ['PEM', 'topic_1', 'SHA256:abc', 0xFF112233]);
    expect(saved.pinnedFolders, ['/code/x']);
    expect(saved.notifyKinds, {'permission'});
    expect(saved.agentNames, {'s': 'Sam'});
    expect(saved.rigNames, {'r': 'Rig'});

    await again.setEnabled(saved, true);
    expect(again.hosts.map((h) => h.id), ['a', 'b']);
    await again.select('a');
    expect(again.active?.id, 'a');

    await again.setEnabled(again.all[0], false);
    await again.setEnabled(again.all[1], false);
    expect(again.hosts, isEmpty);
    expect(again.active, isNull, reason: 'with every host off there is no active one');
  });

  test('saved JSON without the flag is on', () {
    final j = Host(id: 'a', name: 'a', address: 'a', sshUser: 'u').toJson()..remove('enabled');
    expect(Host.fromJson(j).enabled, isTrue);
  });

  testWidgets('the host editor\'s Enabled switch turns the host off and on, and the watcher gets no kinds while it '
      'is off', (tester) async {
    final store = await installFakes();
    addTearDown(() => homelab.enabled = true);
    final ran = <String>[];
    // homelab has a topic; give it a key so the watcher is written.
    homelab.privateKeyPem = 'PEM';
    addTearDown(() => homelab.privateKeyPem = null);
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          ran.add(cmd);
          return '';
        });
    HostEditor.checkOnOpen = false;
    addTearDown(() => HostEditor.checkOnOpen = true);
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: HostEditor(host: homelab))));
    await tester.pump(const Duration(seconds: 1));

    final sw = find.descendant(of: find.widgetWithText(SwitchListTile, 'Enabled'), matching: find.byType(Switch));
    expect(sw, findsOneWidget);
    expect(tester.widget<Switch>(sw).value, isTrue);
    await tester.tap(sw);
    await tester.pump(const Duration(seconds: 1));
    expect(homelab.enabled, isFalse);
    expect(tester.widget<Switch>(sw).value, isFalse);
    expect(store.hosts.map((h) => h.id), ['h2']);
    expect(ran.where((c) => c.contains('watcher.json') && c.contains('"kinds":[]')), isNotEmpty,
        reason: 'no kinds while off');
    expect(homelab.notifyKinds, isNotEmpty, reason: 'the stored kinds stay');

    ran.clear();
    await tester.tap(sw);
    await tester.pump(const Duration(seconds: 1));
    expect(homelab.enabled, isTrue);
    expect(store.hosts.map((h) => h.id), ['h1', 'h2']);
    expect(ran.where((c) => c.contains('watcher.json') && c.contains('permission')), isNotEmpty,
        reason: 'turning on writes the real kinds back');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Settings lists hosts in Enabled and Disabled groups, hides an empty one, and has no switch on the rows',
      (tester) async {
    final store = await installFakes();
    addTearDown(() {
      homelab.enabled = true;
      macbook.enabled = true;
    });
    Future<void> show() async {
      await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: HostsScreen(key: UniqueKey()))));
      await tester.pump(const Duration(seconds: 1));
    }

    Finder under(String label, String host) => find.descendant(
        of: find.ancestor(of: find.text(label), matching: find.byType(Column)).first, matching: find.text(host));
    await show();
    expect(find.text('ENABLED'), findsOneWidget);
    expect(find.text('DISABLED'), findsNothing, reason: 'an empty group is hidden');
    expect(under('ENABLED', 'homelab'), findsOneWidget);
    expect(under('ENABLED', 'macbook'), findsOneWidget);
    expect(find.descendant(of: find.byType(HostStateTile), matching: find.byType(Switch)), findsNothing);

    await store.setEnabled(macbook, false);
    await show();
    expect(find.text('ENABLED'), findsOneWidget);
    expect(find.text('DISABLED'), findsOneWidget);
    expect(under('ENABLED', 'homelab'), findsOneWidget);
    expect(under('DISABLED', 'macbook'), findsOneWidget);
    expect(find.text('+ Add host'), findsOneWidget, reason: 'once, on the first group');

    await store.setEnabled(homelab, false);
    await show();
    expect(find.text('ENABLED'), findsNothing, reason: 'no enabled host: the group is hidden');
    expect(find.text('DISABLED'), findsOneWidget);
    expect(find.text('+ Add host'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a link from an off host opens nothing and says so; it does not fall back to the active host',
      (tester) async {
    final store = await installFakes();
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(AppScope(
        store: store,
        child: MaterialApp(navigatorKey: key, home: const Scaffold(body: SizedBox()))));
    addTearDown(() => macbook.enabled = true); // the fixtures are shared objects
    await store.setEnabled(macbook, false);
    expect(store.active?.id, 'h1');
    final before = key.currentState!.widget.pages.length;
    final links = DeepLinks(store, key);
    await links.handle(Uri.parse('pocketrig://seat/lead@conveyor?host=macbook'));
    await tester.pump();
    expect(find.text('macbook is off'), findsOneWidget);
    expect(store.active?.id, 'h1', reason: 'the active host is not touched');
    expect(find.byType(ChatScreen), findsNothing);
    expect(find.byType(TerminalScreen), findsNothing);
    expect(key.currentState!.widget.pages.length, before);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the editor\'s switch is disabled while its watcher write runs, so a quick off/on cannot land out of order',
      (tester) async {
    final store = await installFakes();
    homelab.privateKeyPem = 'PEM';
    addTearDown(() => homelab.privateKeyPem = null);
    addTearDown(() => homelab.enabled = true);
    final gate = Completer<void>();
    final writes = <bool>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          // Only the write: writeWatcherConfig first reads watcher.json to keep the phones' tokens.
          if (cmd.contains('watcher.json') && cmd.contains('printf')) {
            writes.add(cmd.contains('"kinds":[]'));
            await gate.future;
          }
          return '';
        });
    HostEditor.checkOnOpen = false;
    addTearDown(() => HostEditor.checkOnOpen = true);
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: HostEditor(host: homelab))));
    await tester.pump(const Duration(seconds: 1));
    final sw = find.descendant(of: find.widgetWithText(SwitchListTile, 'Enabled'), matching: find.byType(Switch));
    await tester.tap(sw);
    await tester.pump();
    expect(tester.widget<Switch>(sw).onChanged, isNull, reason: 'busy until the write finishes');
    expect(homelab.enabled, isFalse);
    gate.complete();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<Switch>(sw).onChanged, isNotNull);
    expect(writes, [true], reason: 'one write, no kinds');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  test('turning a host off or on reads usage again at once, so the strip and widget drop or add it', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final store = await installFakes();
    addTearDown(() => macbook.enabled = true);
    final refresher = UsageRingsRefresher(store);
    await refresher.start();
    addTearDown(refresher.dispose);
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 300));
    await settle();
    expect(usageNow.value.map((r) => r.$1.id), containsAll(['h1', 'h2']));
    await store.setEnabled(macbook, false);
    await settle();
    expect(usageNow.value.map((r) => r.$1.id), ['h1']);
    await store.setEnabled(macbook, true);
    await settle();
    expect(usageNow.value.map((r) => r.$1.id), containsAll(['h1', 'h2']));
  });

  testWidgets('turning hosts off drops their asks from the Inbox count at once, with no other host reporting',
      (tester) async {
    final store = await installFakes();
    addTearDown(() {
      homelab.enabled = true;
      macbook.enabled = true;
      needsYouCount.value = 0;
    });
    await tester.pumpWidget(AppScope(store: store, child: const MaterialApp(home: AppShell())));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final both = needsYouCount.value;
    expect(both, greaterThan(0), reason: 'the fixtures have asks waiting');

    final homelabAsks = fleet.feedFor(homelab).needsYou;
    await store.setEnabled(homelab, false);
    fleet.sync(store.hosts);
    expect(needsYouCount.value, both - homelabAsks, reason: 'the off host\'s asks leave the count');
    await store.setEnabled(macbook, false);
    fleet.sync(store.hosts);
    expect(needsYouCount.value, 0, reason: 'no host left to report: it must not keep the old number');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
