import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/host_store.dart';
import 'package:pocket_rig/ui/agent_view_switch.dart' show AgentView;
import 'package:pocket_rig/ui/appearance.dart';
import 'package:pocket_rig/ui/open_agents_on.dart';
import 'package:pocket_rig/ui/debug_overlay_setting.dart';
import 'package:pocket_rig/ui/hosts_screen.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

Finder get _page => find.byType(Scrollable).first;

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() => animateStatusSpinners = false);
  tearDown(() => hostLastSeen.clear());

  testWidgets('Settings, wide: the list and the selected host\'s editor sit side by side; the tile\'s switch turns a host off', (tester) async {
    final store = await installFakes();
    HostEditor.checkOnOpen = false;
    addTearDown(() => HostEditor.checkOnOpen = true);
    addTearDown(() => macbook.enabled = true); // the fixture host is shared between tests
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: phone(store, const HostsScreen(), root: true)));
    await _settle(tester);
    expect(tester.widget<HostEditor>(find.byType(HostEditor)).host?.id, homelab.id, reason: 'the active host\'s editor is beside the list');
    expect(find.text('Usage'), findsNothing, reason: 'the usage card is gone from a wide Settings');
    await tester.tap(find.descendant(of: find.byKey(ValueKey(macbook.id)), matching: find.text(macbook.name)));
    await _settle(tester);
    expect(tester.widget<HostEditor>(find.byType(HostEditor)).host?.id, macbook.id, reason: 'selected, not pushed');
    expect(find.byType(HostEditor), findsOneWidget);
    await tester.tap(find.descendant(of: find.byKey(ValueKey(macbook.id)), matching: find.byType(Switch)));
    await _settle(tester);
    expect(store.hosts.any((h) => h.id == macbook.id), isFalse, reason: 'off: hidden from the app, its rigs with it');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Settings: + Add host in a narrow pane (a wide window with the sidebar open) pushes the editor', (tester) async {
    final store = await installFakes();
    HostEditor.checkOnOpen = false;
    addTearDown(() => HostEditor.checkOnOpen = true);
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The window is wide, the pane (what the sidebar leaves) is 800.
    await tester.pumpWidget(MaterialApp(
        home: phone(store, const Row(children: [SizedBox(width: 480), Expanded(child: HostsScreen())]), root: true)));
    await _settle(tester);
    expect(find.byType(HostEditor), findsNothing, reason: 'the narrow layout has no pane editor');
    await tester.tap(find.text('+ Add host'));
    await _settle(tester);
    expect(find.byType(HostEditor), findsOneWidget, reason: 'pushed, as on a phone');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Settings: each host has one honest state line; App holds appearance and the debug overlay',
      (tester) async {
    final store = await installFakes();
    await tester.pumpWidget(MaterialApp(home: phone(store, const HostsScreen(), root: true)));
    await _settle(tester);

    expect(find.text('Hosts and settings'), findsOneWidget);
    expect(find.text('ENABLED'), findsOneWidget);
    expect(find.text('DISABLED'), findsNothing);
    expect(find.text('+ Add host'), findsOneWidget);
    // homelab answers: online, its running rigs, the version. macbook doesn't: offline, in red, with Retry.
    expect(find.textContaining(RegExp(r'^online · \d+ rigs? · OpenRig 0\.7\.6$')), findsOneWidget);
    final offline = tester.widget<Text>(find.text('offline'));
    expect(offline.style?.color, Tokens.light.removed);
    expect(find.text('Retry'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Debug overlay'), 200, scrollable: _page);
    expect(find.text('Pinned folders'), findsOneWidget);
    expect(find.text('1'), findsOneWidget, reason: 'homelab pins ~/dotfiles');

    addTearDown(() => debugOverlay.value = true);
    expect(debugOverlay.value, isTrue);
    // The debug overlay's switch is the one outside the host rows (each of those has its own on/off).
    final overlay = find.byWidgetPredicate((w) => w is Switch && w.value == debugOverlay.value).last;
    await tester.ensureVisible(overlay);
    await tester.pumpAndSettle();
    await tester.tap(overlay);
    await tester.pumpAndSettle();
    expect(debugOverlay.value, isFalse);

    addTearDown(() => appearance.value = ThemeMode.dark);
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(appearance.value, ThemeMode.light);
    expect(find.text('Light'), findsOneWidget, reason: 'the row shows the choice');

    addTearDown(() => openAgentsOn.value = AgentView.terminal);
    expect(find.text('Open agents on'), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget, reason: 'the default');
    await tester.tap(find.text('Open agents on'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();
    expect(openAgentsOn.value, AgentView.chat);
    expect(find.text('Chat'), findsOneWidget, reason: 'the row shows the choice');

    // An offline host seen earlier says when.
    hostLastSeen[macbook.id] = DateTime.now().subtract(const Duration(hours: 3));
    await tester.scrollUntilVisible(find.text('Retry'), -200, scrollable: _page);
    await tester.tap(find.text('Retry'));
    await _settle(tester);
    expect(find.text('offline · last seen 3h ago'), findsOneWidget);
  });

  testWidgets('first run: four steps, each saying what it still needs, then the editor with what was filled in',
      (tester) async {
    await installFakes();
    FlutterSecureStorage.setMockInitialValues({});
    final store = HostStore();
    await store.load();
    HostEditor.checkOnOpen = false;
    addTearDown(() => HostEditor.checkOnOpen = true);
    await tester.binding.setSurfaceSize(const Size(390, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: phone(store, const HostsScreen(), root: true)));
    await tester.pump();

    expect(find.text('Connect your first host'), findsOneWidget);
    expect(find.text('ENABLED'), findsNothing);
    await tester.tap(find.text('It\'s on'));
    await tester.pump();

    expect(find.text('Type the computer\'s name to go on'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue')).onPressed, isNull);
    await tester.enterText(find.widgetWithText(TextField, 'Host address'), 'mini.tail1234.ts.net');
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(find.text('Type your user name on the computer to go on'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Your user on the computer'), 'me');
    await tester.pump();
    expect(find.text('Make a key to go on'), findsOneWidget);
    await tester.tap(find.text('Make a key'));
    await tester.pump();
    expect(find.textContaining('ssh-ed25519 '), findsOneWidget, reason: 'the line for authorized_keys');
    await tester.tap(find.text('Continue'));
    await tester.pump();

    await tester.tap(find.text('Continue to test and save'));
    await tester.pumpAndSettle();
    expect(find.byType(HostEditor), findsOneWidget);
    expect(find.text('mini'), findsWidgets, reason: 'named after the address');
    expect(find.text('mini.tail1234.ts.net'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('ntfy topic'), 300, scrollable: _page);
    expect(find.textContaining('pocketrig-'), findsWidgets, reason: 'notifications on: a topic was made');
    expect(store.hosts, isEmpty, reason: 'nothing saved until Save');
  });

  testWidgets('host editor: health on open, one Save, and tools that say what they need', (tester) async {
    final store = await installFakes();
    await tester.pumpWidget(MaterialApp(home: phone(store, HostEditor(host: homelab))));
    await _settle(tester);

    expect(find.text('Online · tailnet · OpenRig 0.7.6'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget, reason: 'one Save, in the header');
    expect(find.text('direct · :7433'), findsOneWidget);
    expect(find.text('Needs an SSH key'), findsWidgets, reason: 'homelab has no key yet');
    expect(find.text('Test again'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Restart daemon…'), 300, scrollable: _page);
    final restart = find.ancestor(of: find.text('Restart daemon…'), matching: find.byType(InkWell)).first;
    expect(tester.widget<InkWell>(restart).onTap, isNull, reason: 'disabled, with the reason under it');

    await tester.scrollUntilVisible(find.text('Permission requests'), 300, scrollable: _page);
    expect(find.text('Permission requests'), findsOneWidget);
    expect(find.text('From a notification you can allow once or deny. Always-allow stays in the app.'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Remove host from this device…'), 300, scrollable: _page);
    expect(find.text('Remove host from this device…'), findsOneWidget);
  });
}
