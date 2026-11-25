import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';
import 'dart:ui' show AppExitResponse;

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_pty/flutter_pty.dart';

import '../api/openrig_client.dart';
import '../data/prompt_screen.dart' show realDialogGrep;
import '../data/projects.dart';
import '../models.dart';
import '../ssh/ssh_exec.dart';
import '../ssh/ssh_log.dart';

/// A live terminal, whichever way it is connected.
abstract class TerminalTransport {
  /// Shown under the title, e.g. "ssh · homelab · impl@conveyor".
  String get label;

  Stream<String> get output;

  /// Raw bytes as the terminal emulator produced them (keys, paste, …).
  void sendRaw(String data);

  void resize(int cols, int rows) {}

  Future<void> close();
}

/// SSH over Tailscale: a login shell with a command typed into it, so the
/// user's PATH (Homebrew tmux on macOS) is loaded exactly as in Terminal.app.
class SshTerminal implements TerminalTransport {
  SshTerminal._(this._client, this._session, this.label);

  final SSHClient _client;
  final SSHSession _session;
  @override
  final String label;
  static Future<TerminalTransport> connect(
    Host host, {
    String? command,
    required String label,
    int cols = 80,
    int rows = 24,
  }) async {
    if (host.isLocal) return LocalTerminal.start(command: command, label: label.replaceFirst('ssh · ', ''), cols: cols, rows: rows);
    final client = await sshConnect(host);
    final SSHSession session;
    try {
      session = await SshLog.instance.track(
        host,
        'shell ${cols}x$rows${command == null ? '' : ' → $command'}',
        () => client.shell(pty: SSHPtyConfig(width: cols, height: rows)),
        show: (_) => '<interactive>',
      );
    } catch (_) {
      client.close();
      rethrow;
    }
    if (command != null) {
      session.write(Uint8List.fromList(utf8.encode('$command\n')));
    }
    return SshTerminal._(client, session, label);
  }

  @override
  Stream<String> get output => _session.stdout
      .cast<List<int>>()
      .transform(const Utf8Decoder(allowMalformed: true));

  @override
  void sendRaw(String data) =>
      _session.write(Uint8List.fromList(utf8.encode(data)));

  @override
  void resize(int cols, int rows) => _session.resizeTerminal(cols, rows);

  @override
  Future<void> close() async {
    _session.close();
    _client.close();
  }
}

/// A login shell on this machine in a pty (desktop): the same command the
/// SSH terminal types, run without SSH.
class LocalTerminal implements TerminalTransport {
  LocalTerminal._(this._pty, this.label) : output = _pty.output.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).asBroadcastStream();

  final Pty _pty;
  @override
  final String label;
  @override
  final Stream<String> output;
  static LocalTerminal start({String? command, required String label, int cols = 80, int rows = 24}) {
    final env = Platform.environment;
    final pty = Pty.start(env['SHELL'] ?? '/bin/zsh',
        arguments: ['-l', if (command != null) ...['-c', command]],
        workingDirectory: env['HOME'],
        // A Finder-launched app has a bare PATH; the login shell adds the rest.
        environment: {'PATH': '${env['PATH'] ?? '/usr/bin:/bin'}:/opt/homebrew/bin:/usr/local/bin'},
        columns: cols,
        rows: rows);
    // Quitting with a terminal open would leave its `tmux attach` running, holding the agent's window at this size.
    _onExit ??= AppLifecycleListener(onExitRequested: () async {
      for (final t in [..._open]) {
        await t.close();
      }
      return AppExitResponse.exit;
    });
    return LocalTerminal._(pty, label).._addOpen();
  }

  static final Set<LocalTerminal> _open = {};
  static AppLifecycleListener? _onExit;
  void _addOpen() => _open.add(this);

  @override
  void sendRaw(String data) => _pty.write(Uint8List.fromList(utf8.encode(data)));

  @override
  void resize(int cols, int rows) => _pty.resize(rows, cols);

  @override
  Future<void> close() async {
    _open.remove(this);
    _pty.kill();
  }
}

/// What a terminal screen opens.
sealed class TerminalTarget {
  const TerminalTarget();
  String get title;
}

class SeatTarget extends TerminalTarget {
  const SeatTarget(this.rigName, this.seat);
  final String rigName;
  final Seat seat;
  @override
  String get title => seatTitle(rigName, seat);
}

class ProjectShellTarget extends TerminalTarget {
  const ProjectShellTarget(this.path);
  final String path;
  @override
  String get title => '${path.split('/').where((p) => p.isNotEmpty).lastOrNull ?? path} · shell';
}

/// The daemon's attach command, if it is a plain `tmux …` line. It arrives over
/// unauthenticated HTTP and runs in a shell, so anything with shell syntax
/// (`;`, `|`, `$`, backticks, redirects, newlines) is refused.
String? safeAttachCommand(String? cmd) =>
    cmd != null && RegExp(r"^tmux [A-Za-z0-9 _@./:=%,+'-]+$").hasMatch(cmd) ? cmd : null;

/// [cmd] with tmux told the terminal speaks UTF-8 (`tmux -u …`). Our SSH shell sends no LANG, so on a host whose login shell
/// sets none, a bare `tmux attach` assumes ASCII and draws every ⎿ ✻ ✔ as `_`. The pane's own bytes are fine; the client is not.
String tmuxUtf8(String cmd) => cmd.startsWith('tmux ') && !cmd.startsWith('tmux -u ') ? 'tmux -u ${cmd.substring(5)}' : cmd;

/// The shell line that attaches to [seat]'s tmux session (the daemon's attach command when it is a plain one), or null when
/// it has no session.
String? seatAttachCommand(Seat seat) {
  final session = seat.sessionName;
  final attach = safeAttachCommand(seat.tmuxAttachCommand) ?? (session != null ? 'tmux attach -t ${shQuote('=$session')}' : null);
  return attach == null ? null : 'exec ${tmuxUtf8(attach)}';
}

/// A seat opens as SSH + `tmux attach`, a project shell as an SSH login shell.
/// Tests replace this to show a canned terminal.
@visibleForTesting
Future<TerminalTransport> Function(Host host, TerminalTarget target)? debugOpenTerminal;

Future<TerminalTransport> openTerminal(Host host, TerminalTarget target) async {
  if (debugOpenTerminal != null) return debugOpenTerminal!(host, target);
  switch (target) {
    case SeatTarget(:final seat):
      final session = seat.sessionName;
      final attach = seatAttachCommand(seat);
      if (attach == null) {
        throw OpenRigException('This seat has no tmux session to attach to.');
      }
      return SshTerminal.connect(host,
          command: attach, label: 'ssh · ${host.name} · ${session ?? seat.logicalId}');
    case ProjectShellTarget(:final path):
      return SshTerminal.connect(host,
          command: projectShellCommand(path), label: 'ssh · ${host.name} · $path');
  }
}

/// One answer to a seat's prompt: the tmux key that gives it.
enum SeatAnswer {
  allowOnce('1'),
  allowAlways('2'),
  deny('Escape');

  const SeatAnswer(this.tmuxKey);
  final String tmuxKey;
}

/// Answers a seat's prompt without opening a terminal screen: `tmux send-keys` over SSH.
Future<void> answerSeat(Host host, Seat seat, SeatAnswer answer) => pressSeatKeys(host, seat, [answer.tmuxKey]);

/// Text typed into a menu's "Type something" field, then Enter. It goes in as
/// input like the menu's digits: `api.send` is message delivery, which wraps
/// the words in an envelope and refuses them (409 `target_needs_input`) while the daemon sees the seat at a menu.
class TypedAnswer {
  const TypedAnswer(this.text);
  final String text;
  @override
  bool operator ==(Object other) => other is TypedAnswer && other.text == text;
  @override
  int get hashCode => text.hashCode;
  @override
  String toString() => 'TypedAnswer($text)';
}

/// The `-t` target for keys sent to [session]: the exact [pane] when one is known (a loose agent's own pane, which may not be
/// its session's active one), else `=session:`, whose `=` matches the name exactly (a bare name prefix-matches, so a gone `dev`
/// would answer `dev2`) and whose `:` is the session's active pane. Every keystroke into a host goes through this one rule.
String tmuxTarget(String session, {String? pane}) => shQuote(pane ?? '=$session:');

/// Shell that succeeds when tmux pane [pane] (`%4`) is still in [session]. A `%N` is only unique within one tmux server run: after a
/// restart it can be another session's pane, and keys sent to it would land in the wrong agent or a shell.
String tmuxPaneInSession(String session, String pane) =>
    '[ "\$(tmux display-message -p -t ${shQuote(pane)} \'#{session_name}\' 2>/dev/null)" = ${shQuote(session)} ] || '
    '{ echo "(pane $pane is no longer in session $session)"; false; }';

/// [text] as one bracketed paste into [target], in a tmux buffer of its own: one tmux server holds every send's buffer, so a shared
/// name would let two sends at once paste each other's text. `-d` frees it after a good paste; a failed one deletes it here.
String _pasteCommand(String text, String target) {
  final b = 'pocketrig-send-${base64Url.encode(List.generate(9, (_) => Random.secure().nextInt(256)))}';
  return 'printf %s ${shQuote(text)} | tmux load-buffer -b $b - && '
      '{ tmux paste-buffer -p -d -b $b -t $target || { tmux delete-buffer -b $b 2>/dev/null; false; }; }';
}

/// The `tmux send-keys` commands for [steps] (key names, or a [TypedAnswer]
/// typed literally and submitted), a beat apart.
String tmuxPressCommand(String session, List<Object> steps, {String? pane}) {
  final target = tmuxTarget(session, pane: pane);
  return steps
      .expand((s) => s is TypedAnswer
          ? [
              // Several lines go in as one bracketed paste: typed with raw newlines, Claude's input would submit at the first.
              if (s.text.contains('\n')) _pasteCommand(s.text, target) else
                'tmux send-keys -t $target -l -- ${shQuote(s.text)}',
              'tmux send-keys -t $target Enter',
            ]
          : ['tmux send-keys -t $target ${shQuote(s as String)}'])
      .join(' && sleep 0.3 && ');
}

/// Presses tmux [keys] in a seat's pane one at a time, a beat apart, so a
/// menu sees each press (a question menu moves on after a digit). A
/// [TypedAnswer] among them is typed, then submitted.
Future<void> pressSeatKeys(Host host, Seat seat, List<Object> keys) async {
  final session = seat.sessionName;
  if (session == null) throw OpenRigException('This seat has no session to answer.');
  await SshExec.use(host, (ssh) async {
    // `=name` matches the session exactly: a bare name prefix-matches, so a
    // gone `dev@app` would answer `dev@app-2`. has-session fails loudly first,
    // because send-keys to a missing `=name:` doesn't.
    final pane = seat.tmuxPane;
    // POCKETRIG_READY is printed once the session (and pane) check has passed, just before the first key: a result with it but
    // without POCKETRIG_SENT means keys may have been typed, so the caller must not send again on its own.
    final script = '${tmuxHasSession(session)} && ${pane == null ? '' : '${tmuxPaneInSession(session, pane)} && '}'
        'echo POCKETRIG_READY && ${tmuxPressCommand(session, keys, pane: pane)} && echo POCKETRIG_SENT';
    final String out;
    var started = false;
    try {
      out = await ssh.runLogin(script, onStarted: () => started = true);
    } catch (e) {
      // A channel that never opened ran nothing: the error stands and a retry is safe.
      if (!started) rethrow;
      // The command was handed to the host and the connection then failed: it may have run to the end.
      throw OpenRigException('The connection to ${host.name} dropped while sending; it may have arrived: $e', maybeSent: true);
    }
    if (out.contains('POCKETRIG_SENT')) return;
    if (out.contains('POCKETRIG_READY')) {
      throw OpenRigException('No confirmation from ${host.name}; it may have arrived. Check before you send again.', maybeSent: true);
    }
    throw OpenRigException('No tmux session $session on ${host.name}: ${out.trim()}');
  });
}

/// Scrolls tmux [session]'s pane through its history: [lines] up (positive,
/// entering copy mode) or down (`-e` leaves copy mode at the bottom). Prints
/// 1 while the pane is still in copy mode, 0 once it's back to live.
String tmuxScrollCommand(String session, int lines) {
  final t = shQuote('=$session:');
  final move = lines > 0
      ? 'tmux copy-mode -e -t $t && tmux send-keys -t $t -X -N $lines scroll-up'
      : 'tmux send-keys -t $t -X -N ${-lines} scroll-down';
  return '$move 2>/dev/null; tmux display -p -t $t \'#{pane_in_mode}\'';
}

/// Leaves copy mode in tmux [session]'s pane, so typing reaches the program again.
String tmuxCancelCopyMode(String session) => 'tmux send-keys -t ${shQuote('=$session:')} -X cancel 2>/dev/null; true';

/// Shell that succeeds when tmux has [session] exactly. Otherwise it prints
/// tmux's error and the sessions the host does have, for the error message.
String tmuxHasSession(String session) =>
    'tmux has-session -t ${shQuote('=$session')} 2>&1 || '
    '{ echo "(sessions here: \$(tmux ls -F \'#S\' 2>&1 | tr \'\\n\' \' \'))"; false; }';

/// Cycles a Claude seat's live mode with Shift+Tab until its footer says
/// `auto mode on`. Stops, without pressing, if a permission menu is up
/// (Shift+Tab there picks an option).
// shortcut: matches Claude Code's footer text (2.1.x); if a release renames it, this fails loudly rather than guessing.
Future<void> switchSeatToAuto(Host host, Seat seat) async {
  final session = seat.sessionName;
  if (session == null) throw OpenRigException('This seat has no session to switch.');
  await SshExec.use(host, (ssh) async {
    final out = await ssh.runLogin(autoSwitchScript(session));
    if (out.contains('POCKETRIG_AUTO')) return;
    throw OpenRigException(out.contains('POCKETRIG_PROMPT')
        ? '${seat.logicalId} asked another permission first; answer it, then switch.'
        : out.contains('POCKETRIG_NOAUTO')
            ? 'Shift+Tab never reached Auto on ${seat.logicalId}; its mode may have changed. Check the terminal.'
            : 'No tmux session $session on ${host.name}: ${out.trim()}');
  });
}

/// The shell [switchSeatToAuto] runs on the host; prints POCKETRIG_AUTO,
/// _PROMPT or _NOAUTO.
@visibleForTesting
String autoSwitchScript(String session) {
  final t = shQuote('=$session:');
  return 'tmux has-session -t ${shQuote('=$session')} 2>&1 || exit; '
      'for i in 0 1 2 3 4 5 6; do '
      'pane=\$(tmux capture-pane -p -t $t); '
      // The footer is what follows the input box's bottom rule; conversation text sits above it.
      'foot=\$(printf "%s\\n" "\$pane" | awk \'/^─/{f="";next}{f=f \$0 "\\n"}END{printf "%s",f}\'); '
      // A dialog (a permission prompt, a question menu, the trust dialog) is open: the same rule as the send guard's. The last 15
      // non-blank lines, so an old dialog scrolled up the conversation, or the blank rows under the box, don't decide it.
      'if printf "%s\\n" "\$pane" | grep -v "^[[:space:]]*\$" | tail -n 15 | grep -Eq ${shQuote(realDialogGrep)}; then echo POCKETRIG_PROMPT; exit; fi; '
      'case "\$foot" in *"auto mode on"*) echo POCKETRIG_AUTO; exit;; esac; '
      '[ \$i = 6 ] || { tmux send-keys -t $t BTab; sleep 0.5; }; '
      'done; echo POCKETRIG_NOAUTO';
}
