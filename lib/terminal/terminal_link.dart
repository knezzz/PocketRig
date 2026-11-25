import 'dart:async';

import 'package:xterm/xterm.dart';

import '../models.dart';
import 'transport.dart';

/// An open terminal: its transport and the subscription feeding its output into the [Terminal].
class TerminalLink {
  TerminalLink(this.transport, this.output);
  final TerminalTransport transport;
  final StreamSubscription<String> output;

  Future<void> close() async {
    await output.cancel();
    await transport.close();
  }
}

/// Opens [target] on [host] and wires it to [terminal]: the window follows the terminal's size, typing goes to [onInput], the
/// output is written in, and [onError] hears 'Session closed' or a stream error. The one connect the single terminal and a tile
/// share. Null when [alive] says the screen is gone by the time it opened (the transport is closed); throws when it can't open.
Future<TerminalLink?> connectTerminal(
  Host host,
  TerminalTarget target,
  Terminal terminal, {
  required void Function(String data) onInput,
  required bool Function() alive,
  required void Function(String message) onError,
}) async {
  final t = await openTerminal(host, target);
  if (!alive()) {
    await t.close();
    return null;
  }
  t.resize(terminal.viewWidth, terminal.viewHeight);
  terminal.onOutput = onInput;
  terminal.onResize = (w, h, pw, ph) => t.resize(w, h);
  final sub = t.output.listen(terminal.write, onDone: () {
    if (alive()) onError('Session closed');
  }, onError: (Object e) {
    if (alive()) onError(e.toString());
  });
  return TerminalLink(t, sub);
}
