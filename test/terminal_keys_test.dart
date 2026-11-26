import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart' show LogicalKeyboardKey, SystemChannels;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/host_store.dart' show isDesktop;
import 'package:pocket_rig/models.dart' show LooseAgent;
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/terminal/keys.dart';
import 'package:pocket_rig/terminal/transport.dart';
import 'package:pocket_rig/ui/answer_bar.dart';
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/permission_card.dart';
import 'package:pocket_rig/ui/chat/seat_switcher.dart';
import 'package:pocket_rig/ui/terminal_screen.dart';
import 'package:pocket_rig/ui/theme.dart';
import 'package:pocket_rig/ui/tiles_screen.dart';
import 'package:xterm/xterm.dart' show TerminalView;

import 'golden/fixtures.dart';

void main() {
  testWidgets('a seat that needs you still has the neutral terminal background (the state shows in the frame, not a wash)', (tester) async {
    final store = await installFakes();
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: phone(store, TerminalScreen(target: SeatTarget('conveyor', seatFromFixture('r-conveyor', 'lead'))))));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<Scaffold>(find.descendant(of: find.byType(TerminalScreen), matching: find.byType(Scaffold)).first).backgroundColor,
        Tokens.light.termBg);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
      'desktop: a seat opens as its bare terminal (no keys, line field or prompt strip); Chat still opens the chat',
      (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    // lead waits on a permission: on a phone that brings the answer card.
    final lead = seatFromFixture('r-conveyor', 'lead');
    await tester.pumpWidget(MaterialApp(home: phone(store, ChatScreen(rigName: 'conveyor', seat: lead))));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(TerminalScreen), findsOneWidget, reason: 'the terminal is the default view');
    expect(find.byType(TerminalKeyBar), findsNothing);
    expect(find.byTooltip('Send line'), findsNothing);
    expect(find.text('Keyboard'), findsNothing);
    expect(find.byType(PermissionCard), findsNothing, reason: 'answered in the terminal itself');
    // review asked a question: on a phone that brings the Prompt detected strip.
    await tester.pumpWidget(MaterialApp(
        home: phone(store, ChatScreen(rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'review')))));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(TerminalScreen), findsOneWidget);
    expect(find.text('Prompt detected'), findsNothing);

    await tester.pumpWidget(MaterialApp(home: phone(store, ChatScreen(rigName: 'conveyor', seat: lead, asChat: true))));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(TerminalScreen), findsNothing, reason: 'an explicit Chat is the chat');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('desktop: an agent outside a rig opens as its terminal, which keeps the agent for its chat',
      (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    final a = LooseAgent(id: 't', tmuxSession: 't', claudeSessionId: 's', runtime: 'claude-code');
    await tester.pumpWidget(
        MaterialApp(home: phone(store, ChatScreen(rigName: 'no rig', seat: a.toSeat(), loose: a, rigs: const []))));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<TerminalScreen>(find.byType(TerminalScreen)).loose, same(a));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('desktop: no agent tabs; a double click on a rig agent\'s terminal opens its rig\'s tiles',
      (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: phone(store, TerminalScreen(target: SeatTarget('conveyor', seatFromFixture('r-conveyor', 'impl'))))));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SeatSwitcher), findsNothing, reason: 'the tiles replace the agent tabs');

    final at = tester.getCenter(find.byType(TerminalView));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(TilesScreen), findsOneWidget);
    expect(find.byType(TerminalScreen), findsNothing, reason: 'replaced, so the agent keeps one client');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a rig seat\'s terminal ⋯ opens the seat sheet, with the terminal\'s Reconnect and no Terminal button',
      (tester) async {
    final store = await installFakes();
    await tester.binding.setSurfaceSize(const Size(390, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: phone(store, TerminalScreen(target: SeatTarget('conveyor', seatFromFixture('r-conveyor', 'impl'))))));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Seat options'));
    await tester.pumpAndSettle();
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.text('Remove from rig…'), findsOneWidget, reason: 'the same sheet the chat opens');
    expect(find.widgetWithText(OutlinedButton, 'Terminal'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('desktop: the mouse wheel and the trackpad scroll tmux history; a mouse drag does not', (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    final ran = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          ran.add(cmd);
          return '1';
        });
    addTearDown(() => SshExec.debugConnect = null);
    await tester.pumpWidget(MaterialApp(
        home: phone(store, TerminalScreen(target: SeatTarget('conveyor', seatFromFixture('r-conveyor', 'impl'))))));
    await tester.pump(const Duration(milliseconds: 300));
    final at = tester.getCenter(find.byType(TerminalScreen));
    Future<void> flush() => tester.pump(const Duration(milliseconds: 200));

    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(at));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -120)));
    await flush();
    expect(ran.where((c) => c.contains('scroll-up')), isNotEmpty, reason: 'wheel up: older lines');

    ran.clear();
    final pad = TestPointer(2, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(pad.panZoomStart(at));
    await tester.sendEventToBinding(pad.panZoomUpdate(at, pan: const Offset(0, 120)));
    await tester.sendEventToBinding(pad.panZoomEnd());
    await flush();
    expect(ran.where((c) => c.contains('scroll-up')), isNotEmpty, reason: 'two fingers down: older lines');

    // tmux with `mouse on` turns mouse reporting on; the wheel must still scroll (it did nothing on this Mac).
    ran.clear();
    final mouseOn = tester.widget<TerminalView>(find.byType(TerminalView)).terminal..write('\x1b[?1000h\x1b[?1006h');
    expect(mouseOn.mouseMode.reportScroll, isTrue);
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -120)));
    await flush();
    expect(ran.where((c) => c.contains('scroll-up')), isNotEmpty, reason: 'wheel up with mouse reporting on');

    // The pane is in copy mode now. The wheel's own mouse report is not typing: leaving copy mode on it sent every
    // scroll back to the bottom. Typing still leaves it.
    ran.clear();
    mouseOn.onOutput!('\x1b[<64;10;5M');
    await flush();
    expect(ran.where((c) => c.contains('cancel')), isEmpty, reason: 'a mouse report keeps the scroll position');
    mouseOn.onOutput!('a');
    await flush();
    expect(ran.where((c) => c.contains('cancel')), isNotEmpty, reason: 'typing leaves copy mode');

    ran.clear();
    await tester.dragFrom(at, const Offset(0, 200), kind: PointerDeviceKind.mouse);
    await flush();
    expect(ran.where((c) => c.contains('scroll')), isEmpty, reason: 'a mouse drag selects text');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('phone: the terminal opens with the keyboard and key bar folded; a tap opens them; Hide folds them again',
      (tester) async {
    // A phone-sized screen, as phone() lays out for (the default test surface is 800×600).
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = await installFakes();
    await tester.pumpWidget(MaterialApp(
        home: phone(store, TerminalScreen(target: SeatTarget('conveyor', seatFromFixture('r-conveyor', 'lead'))))));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(TerminalKeyBar), findsNothing, reason: 'the key bar starts folded');
    expect(tester.testTextInput.isVisible, isFalse, reason: 'no system keyboard on open');
    // Still enough to answer a menu or drive a TUI: esc, tab, ctrl, up, down and Enter (← → are in the opened row).
    for (final key in ['esc', 'tab', 'ctrl', '↑', '↓']) {
      expect(find.text(key), findsOneWidget, reason: key);
    }
    expect(find.byIcon(Icons.keyboard_return), findsOneWidget);
    expect(find.text('←'), findsNothing);
    expect(find.byType(TextField), findsNothing, reason: 'no line field: type into the terminal itself');
    final view = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(view.deleteDetection, isTrue, reason: 'Backspace on the phone keyboard reaches the terminal');
    expect(view.keyboardType, TextInputType.visiblePassword, reason: 'no autocorrect or suggestions');

    await tester.tap(find.byType(TerminalView));
    await tester.pump();
    expect(find.byType(TerminalKeyBar), findsOneWidget, reason: 'a tap on the terminal opens the key bar');
    expect(tester.testTextInput.isVisible, isTrue, reason: 'and the keyboard');
    expect(find.text('Hide'), findsOneWidget, reason: 'Hide in the place of Keyboard');
    expect(find.text('Keyboard'), findsNothing);
    for (final key in ['esc', 'tab', 'ctrl', '↑', '↓', '←', '→']) {
      expect(find.text(key), findsOneWidget, reason: '$key stays with the keyboard up');
    }
    expect(find.byIcon(Icons.keyboard_return), findsOneWidget, reason: 'the ↵ key');
    expect(tester.getTopLeft(find.text('←')).dy, lessThan(tester.getTopLeft(find.text('esc')).dy),
        reason: 'the extra keys (← → …) are a row above esc tab ctrl ↑ ↓ enter');
    expect(find.text('paste'), findsOneWidget);

    await tester.tap(find.text('Hide'));
    await tester.pump();
    expect(find.byType(TerminalKeyBar), findsNothing);
    await tester.tap(find.text('Keyboard'));
    await tester.pump();
    expect(find.byType(TerminalKeyBar), findsOneWidget, reason: 'the folded key row opens it too');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a waiting seat\'s phone terminal: a quiet route line and no answer card, bar or prompt strip',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = await installFakes();
    final lead = seatFromFixture('r-conveyor', 'lead'); // waits on a permission in the fixture
    await tester.pumpWidget(MaterialApp(home: phone(store, TerminalScreen(target: SeatTarget('conveyor', lead)))));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('lead'), findsWidgets);
    expect(find.text('app › conveyor'), findsOneWidget, reason: 'the path only: the switch already says terminal');
    expect(find.text('Chat'), findsOneWidget, reason: 'the Terminal | Chat switch');
    expect(find.byTooltip('Seat options'), findsOneWidget);
    expect(find.byType(PermissionCard), findsNothing, reason: 'answers are in chat, the Inbox and the banner');
    expect(find.byType(AnswerBar), findsNothing);
    expect(find.text('Prompt detected'), findsNothing);
    expect(find.text('Replay prompt'), findsNothing);

    await tester.tap(find.byTooltip('Seat options'));
    await tester.pumpAndSettle();
    expect(find.text('Open as chat'), findsOneWidget, reason: 'the agent list, as in the chat and on a tile');
    expect(find.text('Open as terminal'), findsNothing, reason: 'it is the terminal already');
    expect(find.text('Agent details'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the key bar: one row of esc, tab, the modifiers, paste, then ⇧tab ^C ^D ^R pgup pgdn; none the phone keyboard has',
      (tester) async {
    final sent = <String>[];
    final mods = <TermMod>{};
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => TerminalKeyBar(
            mods: mods,
            locked: const {},
            onMod: (m) => setState(() => mods.contains(m) ? mods.remove(m) : mods.add(m)),
            onKey: sent.add,
            onPaste: () => sent.add('paste'),
          ),
        ),
      ),
    ));
    double x(String label) => tester.getTopLeft(find.text(label)).dx;
    double y(String label) => tester.getTopLeft(find.text(label)).dy;
    const keys = ['←', '→', 'alt', '⇧', 'paste', '⇧tab', '^C', '^D'];
    for (var i = 1; i < keys.length; i++) {
      expect(x(keys[i]), greaterThan(x(keys[i - 1])), reason: keys[i]);
      expect(y(keys[i]), y(keys.first), reason: keys[i]);
    }
    for (final inRowBelow in ['esc', 'tab', 'ctrl', '↑', '↓']) {
      expect(find.text(inRowBelow), findsNothing, reason: 'the row below has $inRowBelow');
    }
    for (final onKeyboard in ['⏎', '/', '|', '~', '-', '_', '\\', '`']) {
      expect(find.text(onKeyboard, skipOffstage: false), findsNothing, reason: onKeyboard);
    }
    await tester.tap(find.text('alt'));
    await tester.pump();
    expect(mods, {TermMod.alt}, reason: 'sticky: on for the next key');
    await tester.tap(find.text('^C'));
    expect(sent, ['\x03']);
    await tester.tap(find.text('paste'));
    expect(sent.last, 'paste');
  });

  testWidgets('phone: a long press selects, Copy puts the selection on the clipboard; Paste sends the clipboard as typed',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var clipboard = 'pasted text';
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      if (call.method == 'Clipboard.getData') return {'text': clipboard};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final store = await installFakes();
    await tester.pumpWidget(MaterialApp(
        home: phone(store, TerminalScreen(target: SeatTarget('conveyor', seatFromFixture('r-conveyor', 'lead'))))));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final terminal = tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    final sent = <String>[];
    terminal
      ..write('\x1b[2J\x1b[Hhello world')
      ..onOutput = sent.add;
    await tester.pump();
    expect(find.text('Copy'), findsNothing, reason: 'no selection, no menu');

    await tester.longPressAt(tester.getTopLeft(find.byType(TerminalView)) + const Offset(14, 14));
    await tester.pump();
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Select all'), findsOneWidget);
    expect(find.text('Paste'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(copied, 'hello', reason: 'the selected word is on the clipboard');
    expect(find.text('Copy'), findsNothing, reason: 'the menu goes with the selection');

    // Paste: typed in, or bracketed when the program asked for it.
    await tester.longPressAt(tester.getTopLeft(find.byType(TerminalView)) + const Offset(14, 14));
    await tester.pump();
    await tester.tap(find.text('Paste'));
    await tester.pump();
    expect(sent, ['pasted text']);
    terminal.write('\x1b[?2004h');
    await tester.tap(find.byType(TerminalView));
    await tester.pump();
    await tester.tap(find.text('paste'));
    await tester.pump();
    expect(sent.last, '\x1b[200~pasted text\x1b[201~');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('desktop (Mac): ⌘A ⌘C copy what is on the terminal and ⌘V pastes the clipboard as typed', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    var clipboard = 'from the clipboard';
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      if (call.method == 'Clipboard.getData') return {'text': clipboard};
      return null;
    });
    final store = await installFakes();
    isDesktop = true;
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    await tester.pumpWidget(MaterialApp(
        home: phone(store, TerminalScreen(target: SeatTarget('conveyor', seatFromFixture('r-conveyor', 'impl'))))));
    await tester.pump(const Duration(milliseconds: 300));
    final terminal = tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    final sent = <String>[];
    terminal
      ..write('\x1b[2J\x1b[Hhello world')
      ..onOutput = sent.add;
    await tester.pump();
    Future<void> chord(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
    }

    await chord(LogicalKeyboardKey.keyA);
    await chord(LogicalKeyboardKey.keyC);
    expect(copied, contains('hello world'));
    await chord(LogicalKeyboardKey.keyV);
    expect(sent, ['from the clipboard']);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    isDesktop = false;
    debugDefaultTargetPlatformOverride = null;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    await tester.binding.setSurfaceSize(null);
  });

  group('phone: scrolling through tmux history', () {
    late List<String> ran;

    Future<TerminalView> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      ran = [];
      final store = await installFakes();
      SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
            ran.add(cmd);
            return cmd.contains('pane_in_mode') ? '1' : '';
          });
      addTearDown(() => SshExec.debugConnect = null);
      await tester.pumpWidget(MaterialApp(
          home: phone(store, TerminalScreen(target: SeatTarget('conveyor', seatFromFixture('r-conveyor', 'lead'))))));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return tester.widget<TerminalView>(find.byType(TerminalView));
    }

    Future<void> flush(WidgetTester tester) => tester.pump(const Duration(milliseconds: 300));
    Future<void> end(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }

    testWidgets('a finger drag scrolls the history, also when tmux has mouse reporting on; Back to live shows while scrolled back and returns',
        (tester) async {
      final view = await open(tester);
      view.terminal.write('\x1b[?1000h\x1b[?1006h'); // tmux `mouse on`
      expect(view.terminal.mouseMode.reportScroll, isTrue);
      expect(find.text('Back to live'), findsNothing);

      await tester.dragFrom(tester.getCenter(find.byType(TerminalView)), const Offset(0, 200));
      await flush(tester);
      expect(ran.where((c) => c.contains('scroll-up')), isNotEmpty, reason: 'a drag down shows older lines');
      expect(find.text('Back to live'), findsOneWidget);

      ran.clear();
      await tester.tap(find.text('Back to live'));
      await flush(tester);
      expect(ran.where((c) => c.contains('cancel')), isNotEmpty, reason: 'leaves copy mode');
      expect(find.text('Back to live'), findsNothing);
      await end(tester);
    });

    testWidgets('a key press goes back to live', (tester) async {
      await open(tester);
      await tester.dragFrom(tester.getCenter(find.byType(TerminalView)), const Offset(0, 200));
      await flush(tester);
      expect(find.text('Back to live'), findsOneWidget);
      ran.clear();
      await tester.tap(find.byIcon(Icons.keyboard_return));
      await flush(tester);
      expect(ran.where((c) => c.contains('cancel')), isNotEmpty);
      expect(find.text('Back to live'), findsNothing);
      await end(tester);
    });

    testWidgets('after a long press the drag extends the selection instead of scrolling', (tester) async {
      final view = await open(tester);
      view.terminal.write('\x1b[2J\x1b[Hhello world');
      await tester.pump();
      final at = tester.getTopLeft(find.byType(TerminalView)) + const Offset(14, 14);
      final g = await tester.startGesture(at);
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('Copy'), findsOneWidget, reason: 'the long press selected');
      await g.moveBy(const Offset(0, 120));
      await g.up();
      await flush(tester);
      expect(ran.where((c) => c.contains('scroll-up')), isEmpty, reason: 'selecting is not scrolling');
      await end(tester);
    });
  });
}
