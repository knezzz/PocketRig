import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/terminal/terminal_link.dart';
import 'package:pocket_rig/terminal/transport.dart';
import 'package:xterm/xterm.dart';

class _T implements TerminalTransport {
  final out = StreamController<String>();
  final resizes = <String>[];
  final sent = <String>[];
  var closed = false;
  @override
  String get label => 't';
  @override
  Stream<String> get output => out.stream;
  @override
  void sendRaw(String data) => sent.add(data);
  @override
  void resize(int cols, int rows) => resizes.add('${cols}x$rows');
  @override
  Future<void> close() async => closed = true;
}

/// The one connect the single terminal and a tile share.
void main() {
  final host = Host(id: 'h', name: 'h', address: 'a', sshUser: 'u');
  final target = SeatTarget('rig', Seat(rigId: 'r', logicalId: 'a', sessionName: 'a@r', runtime: 'claude-code'));

  test('connectTerminal sizes the window to the terminal, routes typing and output, and reports a closed session or a stream error', () async {
    final t = _T();
    debugOpenTerminal = (h, tg) async => t;
    addTearDown(() => debugOpenTerminal = null);
    final term = Terminal(maxLines: 100);
    final typed = <String>[];
    final errors = <String>[];
    final link = await connectTerminal(host, target, term, onInput: typed.add, alive: () => true, onError: errors.add);
    expect(link, isNotNull);
    expect(t.resizes, ['${term.viewWidth}x${term.viewHeight}'], reason: 'the agent\'s window follows the terminal');
    term.onOutput!('x');
    expect(typed, ['x']);
    term.onResize!(100, 30, 0, 0);
    expect(t.resizes.last, '100x30');
    t.out.add('hello');
    await Future<void>.delayed(Duration.zero);
    expect(term.buffer.lines[0].getText(), contains('hello'));
    t.out.addError('boom');
    await Future<void>.delayed(Duration.zero);
    await t.out.close();
    await Future<void>.delayed(Duration.zero);
    expect(errors, ['boom', 'Session closed']);
    await link!.close();
    expect(t.closed, isTrue);
  });

  test('a screen that is gone by the time the terminal opened gets nothing, and the transport is closed', () async {
    final t = _T();
    debugOpenTerminal = (h, tg) async => t;
    addTearDown(() => debugOpenTerminal = null);
    final link = await connectTerminal(host, target, Terminal(), onInput: (_) {}, alive: () => false, onError: (_) {});
    expect(link, isNull);
    expect(t.closed, isTrue);
  });
}
