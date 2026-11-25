import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../data/projects.dart';
import '../models.dart';
import '../ssh/ssh_exec.dart';
import '../ssh/ssh_log.dart';
import 'transcript.dart';

/// Claude Code names a project folder after its cwd with every character
/// that isn't a letter or digit turned into `-` (`/Users/me/my.app` →
/// `-Users-me-my-app`). Older versions only replaced `/`, so both are tried.
List<String> claudeProjectSlugs(String cwd) {
  final all = cwd.replaceAll(RegExp(r'[^A-Za-z0-9]'), '-');
  final slashes = cwd.replaceAll('/', '-');
  return {all, slashes}.toList();
}

/// The shell script that prints the seat's log path, best match first:
/// the daemon's transcript path, then `<resumeToken>.jsonl` in any project
/// folder (exact even when seats share a cwd), then the newest log in the
/// cwd's project folder. [exactOnly] skips that last guess: a session that
/// hasn't written its log yet must not borrow its neighbour's.
String locateLogScript(Seat seat, {bool exactOnly = false}) {
  final b = StringBuffer('base="\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/projects"; ');
  final tp = seat.transcriptPath;
  if (tp != null) b.write('[ -f ${shQuote(tp)} ] && { printf "%s\\n" ${shQuote(tp)}; exit 0; }; ');
  final token = seat.resumeToken;
  if (token != null && RegExp(r'^[A-Za-z0-9-]+$').hasMatch(token)) {
    b.write('for f in "\$base"/*/$token.jsonl; do [ -f "\$f" ] && { printf "%s\\n" "\$f"; exit 0; }; done; ');
  }
  final cwd = seat.cwd;
  if (cwd != null && !exactOnly) {
    for (final slug in claudeProjectSlugs(cwd)) {
      b.write('f=\$(ls -t "\$base"/${shQuote(slug)}/*.jsonl 2>/dev/null | head -n 1); '
          '[ -n "\$f" ] && { printf "%s\\n" "\$f"; exit 0; }; ');
    }
  }
  b.write('exit 0');
  return b.toString();
}

/// Follows one JSONL file over SSH: reads the recent tail, then keeps
/// `tail -F` open. If the connection drops it reconnects and resumes from
/// the last byte it saw, so nothing is read twice.
class SessionLogTail {
  SessionLogTail(this.host, this.path, {this.historyBytes = 25 * 1024 * 1024});

  /// How the chat opens a log. Tests swap in a tail that replays lines.
  @visibleForTesting
  static SessionLogTail Function(Host host, String path) factory = SessionLogTail.new;

  /// A tail for [path] made by [factory].
  static SessionLogTail create(Host host, String path) => factory(host, path);

  /// Emits a status line (for fakes that don't connect).
  @protected
  void reportStatus(String s) => _status.add(s);

  final Host host;
  final String path;

  /// How much of an existing log to read on open (a long session can run
  /// to tens of MB; older turns aren't loaded).
  final int historyBytes;

  final _lines = StreamController<String>.broadcast();
  final _status = StreamController<String>.broadcast();
  Stream<String> get lines => _lines.stream;

  /// "live", "reconnecting…", or an error, for the subtitle.
  Stream<String> get status => _status.stream;

  /// True when the first lines of the file were skipped.
  bool truncated = false;

  /// Called when the log turns out shorter than where [resumeFrom] pointed:
  /// it was rewritten, so everything read before is stale.
  VoidCallback? onRewound;

  int _offset = -1;
  bool _resuming = false;
  Isolate? _worker;
  ReceivePort? _port;

  /// Finishes the SSH tab's entry for this read. The tab's log lives on this
  /// isolate, so the worker can't record it.
  Completer<void>? _opening;
  final _partial = BytesBuilder(copy: false);
  bool _dropFirstLine = false;
  bool _closed = false;
  int _failures = 0;

  /// Continue a log already read up to [offset]. Call before [start].
  void resumeFrom(int offset, {required bool truncated}) {
    _offset = offset;
    _resuming = true;
    this.truncated = truncated;
  }

  /// The log byte after the last whole line emitted.
  int get committedOffset => _offset - _partial.length;

  /// Reads the log on a background isolate: dartssh2 decrypts in Dart, at
  /// about a second per MB, which on the UI isolate freezes the app (ANR).
  Future<void> start() async {
    final port = ReceivePort();
    _port = port;
    final opening = _opening = Completer<void>();
    unawaited(SshLog.instance
        .track(host, 'tail -F -- ${shQuote(path)}', () => opening.future, show: (_) => '<stream>')
        .catchError((Object _) {}));
    port.listen((m) => _onWorker(port, m));
    try {
      final worker = await Isolate.spawn(
        _tailWorker,
        (port.sendPort, host, path, _offset, _resuming, historyBytes),
        onExit: port.sendPort,
      );
      if (_port == port) {
        _worker = worker;
      } else {
        worker.kill(priority: Isolate.immediate);
      }
    } catch (e) {
      if (_port != port) return;
      _status.add('$e');
      _retry();
    }
  }

  void _onWorker(ReceivePort port, Object? m) {
    if (_port != port) return;
    switch (m) {
      case Uint8List bytes:
        _onBytes(bytes);
      case (int from, bool restarted):
        if (restarted) {
          if (_resuming) onRewound?.call();
          _offset = from;
          truncated = from > 0;
          _dropFirstLine = truncated;
        }
        _resuming = false;
      case true:
        _finishOpening();
        _failures = 0;
        _status.add('live');
      case String error:
        _finishOpening(error);
        _status.add(error);
      default: // null: the worker exited
        _retry();
    }
  }

  /// Feeds raw bytes as if they came from `tail` (tests only).
  @visibleForTesting
  void feed(Uint8List bytes, {bool dropFirstLine = false}) {
    if (_offset < 0) _offset = 0;
    if (dropFirstLine) _dropFirstLine = true;
    _onBytes(bytes);
  }

  @visibleForTesting
  int get offset => _offset;

  void _onBytes(Uint8List bytes) {
    _offset += bytes.length;
    var start = 0;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != 0x0a) continue;
      _partial.add(Uint8List.sublistView(bytes, start, i));
      final line = utf8.decode(_partial.takeBytes(), allowMalformed: true);
      start = i + 1;
      if (_dropFirstLine) {
        _dropFirstLine = false;
        continue;
      }
      _lines.add(line);
    }
    if (start < bytes.length) _partial.add(Uint8List.sublistView(bytes, start));
  }

  void _retry() {
    _teardown();
    if (_closed) return;
    // A half line in the buffer will be re-read from the offset.
    _offset -= _partial.length;
    _partial.clear();
    _failures++;
    _status.add('reconnecting…');
    final wait = Duration(seconds: _failures > 5 ? 30 : 1 << _failures);
    Future.delayed(wait, () {
      if (!_closed) start();
    });
  }

  void _finishOpening([String? error]) {
    final opening = _opening;
    _opening = null;
    if (opening == null || opening.isCompleted) return;
    error == null ? opening.complete() : opening.completeError(error);
  }

  void _teardown() {
    _finishOpening();
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _port?.close();
    _port = null;
  }

  Future<void> close() async {
    _closed = true;
    _teardown();
    await _lines.close();
    await _status.close();
  }
}

/// The SSH side of [SessionLogTail]. Sends where the read starts as `(offset,
/// restarted)`, `true` once it's streaming, then the bytes; a String on failure.
/// Exiting tells the tail to reconnect. Hosts reach here already pinned, since
/// the chat found the log over SSH first, and a pin here wouldn't be saved.
Future<void> _tailWorker((SendPort, Host, String, int, bool, int) args) async {
  final (out, host, path, from, resuming, historyBytes) = args;
  var offset = from;
  if (host.isLocal) return _tailLocal(out, path, offset, resuming, historyBytes);
  try {
    final client = await sshConnect(host, pin: false);
    if (offset < 0 || resuming) {
      final got = await client.run('wc -c < ${shQuote(path)}', stderr: false);
      final measured = int.tryParse(utf8.decode(got, allowMalformed: true).trim());
      // Unmeasured isn't shorter: stay put and let tail -F wait for the file.
      final restarted = !resuming || (measured != null && measured < offset);
      if (restarted) {
        final size = measured ?? 0;
        offset = size > historyBytes ? size - historyBytes : 0;
      }
      out.send((offset, restarted));
    }
    // tail -F never reads stdin and has no tty to hang up, so a dropped channel left it running
    // forever on a quiet log. sshd closes stdin when the channel goes: kill tail then.
    final session = await client.execute('exec 3<&0; tail -c +${offset + 1} -F -- ${shQuote(path)} & t=\$!; '
        '{ cat <&3 >/dev/null; kill \$t; } >/dev/null 2>&1 & wait \$t');
    out.send(true);
    await session.stdout.forEach(out.send);
  } catch (e) {
    out.send('$e');
  }
}

/// [_tailWorker] on this machine: polls the file in Dart, so killing the
/// isolate stops it (a `tail` child would outlive it).
Future<void> _tailLocal(SendPort out, String path, int offset, bool resuming, int historyBytes) async {
  final f = File(path);
  try {
    if (offset < 0 || resuming) {
      final measured = f.existsSync() ? f.lengthSync() : null;
      final restarted = !resuming || (measured != null && measured < offset);
      if (restarted) {
        final size = measured ?? 0;
        offset = size > historyBytes ? size - historyBytes : 0;
      }
      out.send((offset, restarted));
    }
    out.send(true);
    while (true) {
      final len = f.existsSync() ? f.lengthSync() : 0;
      if (len > offset) {
        final raf = f.openSync()..setPositionSync(offset);
        out.send(raf.readSync(len - offset));
        raf.closeSync();
        offset = len;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  } catch (e) {
    out.send('$e');
  }
}

/// The whole of a tool call the cache cut short, read back from the log.
Future<ToolCall?> fetchToolCall(Host host, String path, String id) async {
  return SshExec.use(host, (ssh) async {
    final lines = await ssh.run('grep -F -- ${shQuote(id)} ${shQuote(path)}');
    final t = ChatTranscript()..addAll(const LineSplitter().convert(lines));
    return t.items.whereType<ToolCall>().where((c) => c.id == id).firstOrNull;
  });
}

/// Finds [seat]'s Claude Code log on the host, or null.
Future<String?> locateSessionLog(Host host, Seat seat, {bool exactOnly = false}) async {
  return SshExec.use(host, (ssh) async {
    final out = (await ssh.run(locateLogScript(seat, exactOnly: exactOnly))).trim();
    return out.isEmpty ? null : out.split('\n').first;
  });
}
