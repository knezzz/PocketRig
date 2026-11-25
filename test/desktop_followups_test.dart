import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/recent_screen.dart' show RecentScreen;
import 'package:pocket_rig/data/host_store.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/terminal/transport.dart' show debugOpenTerminal;
import 'package:pocket_rig/ui/needs_you_banner.dart';
import 'package:pocket_rig/ui/status_shape.dart';
import 'package:pocket_rig/ui/theme.dart';
import 'package:pocket_rig/ui/tiles_screen.dart';
import 'package:xterm/xterm.dart';

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

class _Typed extends FakeTerminal {
  _Typed(this.sent) : super('typed');
  final List<String> sent;
  @override
  void sendRaw(String data) => sent.add(data);
}

void main() {
  setUp(() => animateStatusSpinners = false);

  testWidgets('desktop: the sidebar folds away and come back', (tester) async {
    final store = await installFakes();
    await pumpDesktop(tester, store);
    expect(find.text('Add project folder'), findsWidgets);

    await tester.tap(find.byTooltip('Hide sidebar (⌘\\)'));
    await tester.pump();
    expect(find.text('Add project folder'), findsNothing);
    expect(find.byType(RecentScreen), findsOneWidget, reason: 'the content panel stays, now wider');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.backslash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(find.text('Add project folder'), findsWidgets, reason: '⌘\\ brings it back');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  test('a terminal frame is colored only while the agent needs you, works or waits on its shell', () {
    const k = Tokens.light;
    expect(Status.needsYou.edge(k), k.accent);
    expect(Status.working.edge(k), k.added);
    expect(Status.shell.edge(k), k.shell);
    for (final s in [Status.idle, Status.stopped]) {
      expect(s.edge(k), isNull, reason: s.label);
    }
  });

  testWidgets('Shift+Enter types ESC CR into a tile; Enter stays a plain CR', (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    final sent = <String>[];
    debugOpenTerminal = (h, t) async => _Typed(sent);
    final rig = rigFromFixture('r-conveyor');
    final seats = [for (final n in nodes['r-conveyor']!) Seat.fromJson(n)];
    await tester.pumpWidget(MaterialApp(home: phone(store, TilesScreen(rig: rig, seats: seats, projectName: 'app'))));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tapAt(tester.getCenter(find.byType(TerminalView).first));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(sent, ['\x1b\r']);

    sent.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sent, ['\r']);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the needs-you banner floats over the phone, not the desktop', (tester) async {
    for (final desktop in [false, true]) {
      final store = await installFakes();
      isDesktop = desktop;
      addTearDown(() => isDesktop = false);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      if (desktop && !store.all.any((h) => h.isLocal)) store.all.insert(0, Host.local('me'));
      needsYouAlerts.reset();
      needsYouAlerts.show(SeatAlert(
          host: store.hosts.first,
          rig: rigFromFixture('r-conveyor'),
          seat: Seat(rigId: 'r1', logicalId: 'lead', sessionName: 'lead@conveyor', runtime: 'claude-code', needsInput: true),
          project: 'app'));
      await tester.pumpWidget(PocketRigApp(store: store, deepLinks: false));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(NeedsYouBanner), desktop ? findsNothing : findsOneWidget, reason: 'desktop: $desktop');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('the wheel scrolls a tile\'s tmux history, and typing leaves copy mode first', (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    final ran = <String>[];
    final sent = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          if (cmd.contains('window_width')) return '120 40';
          ran.add(cmd);
          return '1';
        });
    addTearDown(() => SshExec.debugConnect = null);
    debugOpenTerminal = (h, t) async => _Typed(sent);
    final rig = rigFromFixture('r-conveyor');
    final seats = [for (final n in nodes['r-conveyor']!) Seat.fromJson(n)];
    await tester.pumpWidget(MaterialApp(home: phone(store, TilesScreen(rig: rig, seats: seats, projectName: 'app'))));
    await tester.pump(const Duration(milliseconds: 200));
    final at = tester.getCenter(find.byType(TerminalView).first);

    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(at));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -200)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(ran.where((c) => c.contains('scroll-up')), isNotEmpty, reason: 'wheel up: older lines');

    ran.clear();
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 100));
    expect(ran.where((c) => c.contains('cancel')), isNotEmpty, reason: 'typing leaves copy mode');
    expect(sent, isNotEmpty, reason: 'and the key still arrives');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
