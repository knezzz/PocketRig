import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:loggy/loggy.dart';

import '../chat/session_log.dart';
import '../models.dart';
import '../ssh/host_keys.dart';
import '../ssh/ssh_exec.dart';
import 'chat_cache.dart';
import 'projects.dart';

const _seedBytes = 1 << 20; // the last 1 MB of a log nobody has pulled yet
const _deltaBytes = 256 << 10; // new bytes per chat per cycle
const _cycleBytes = 1 << 20; // all chats together, per cycle
const _endMark = '@@end'; // closes every chunk, so a short read can't run into the next
const _maxGrow = 16 << 20; // a single log line this long is the limit

/// One chat in a sync cycle: where its log was last read to, if at all.
class SyncTarget {
  SyncTarget(this.seat, this.key, this.cursor, {this.cap = _deltaBytes});
  final Seat seat;
  final String key;
  final ({String path, int offset, bool truncated})? cursor;

  /// Bytes to read this cycle. Grows when one log line is longer than that.
  final int cap;
}

/// One script for every chat: `@@pr-log <i> <size> <from> <len> <S|D> <path>`,
/// a line, then exactly `len` raw bytes of the log from byte `from`, then a
/// newline. `D` continues from the saved cursor; `S` is a seed (the last
/// 1 MB, or the whole log if smaller) for a chat with no row, a different log,
/// or a log that got shorter. A log that isn't found prints nothing. All
/// chats together carry at most [_cycleBytes].
String syncScript(List<SyncTarget> targets) {
  final b = StringBuffer('left=$_cycleBytes; ');
  for (var i = 0; i < targets.length; i++) {
    final t = targets[i], c = t.cursor;
    final grown = t.cap > _deltaBytes;
    b.write('f=\$( ( ${locateLogScript(t.seat, exactOnly: true)} ) ); if [ -n "\$f" ]; then ');
    b.write('s=\$(wc -c < "\$f" | tr -d " "); ');
    b.write('from=${c?.offset ?? -1}; [ ${shQuote(c?.path ?? '')} = "\$f" ] || from=-1; ');
    b.write('[ "\$from" -gt "\$s" ] && from=-1; ');
    b.write('if [ "\$from" -lt 0 ]; then m=S; from=\$((s-${max(_seedBytes, t.cap)})); [ "\$from" -lt 0 ] && from=0; cap=${max(_seedBytes, t.cap)}; '
        'else m=D; cap=${t.cap}; fi; ');
    b.write('len=\$((s-from)); [ "\$len" -gt "\$cap" ] && len=\$cap; ');
    // A grown read is for one huge line: the shared budget doesn't apply.
    if (!grown) b.write('[ "\$len" -gt "\$left" ] && len=\$left; ');
    b.write('left=\$((left-len)); [ "\$left" -lt 0 ] && left=0; ');
    b.write('printf "@@pr-log $i %s %s %s %s %s\\n" "\$s" "\$from" "\$len" "\$m" "\$f"; ');
    b.write('[ "\$len" -gt 0 ] && tail -c +\$((from+1)) "\$f" | head -c "\$len"; printf "\\n$_endMark\\n"; fi; ');
  }
  b.write('true');
  return b.toString();
}

/// What the script found for one chat.
class SyncChunk {
  SyncChunk(this.index, this.size, this.from, this.seed, this.path, this.bytes);
  final int index;
  final int size;
  final int from;
  final bool seed;
  final String path;
  final Uint8List bytes;
}

/// Splits [syncScript]'s output by the lengths in its headers, so log bytes
/// are never mistaken for a header. Anything else (a login banner) is skipped.
List<SyncChunk> parseSyncOutput(Uint8List out) {
  final chunks = <SyncChunk>[];
  var pos = 0;
  while (pos < out.length) {
    var end = out.indexOf(10, pos);
    if (end < 0) break;
    final line = utf8.decode(out.sublist(pos, end), allowMalformed: true);
    pos = end + 1;
    if (!line.startsWith('@@pr-log ')) continue;
    final f = line.split(' ');
    if (f.length < 7) continue;
    final index = int.tryParse(f[1]), size = int.tryParse(f[2]), from = int.tryParse(f[3]), len = int.tryParse(f[4]);
    if (index == null || size == null || from == null || len == null || pos + len + _endMark.length + 2 > out.length) break;
    if (utf8.decode(out.sublist(pos + len, pos + len + _endMark.length + 2), allowMalformed: true) != '\n$_endMark\n') break;
    chunks.add(SyncChunk(index, size, from, f[5] == 'S', f.sublist(6).join(' '), out.sublist(pos, pos + len)));
    pos += len + _endMark.length + 2;
  }
  return chunks;
}

/// Runs [script] on [host]'s shell and returns stdout, over SSH on a
/// long-lived isolate: decrypting a 1 MB seed on the UI isolate drops frames.
class SyncWorker {
  SyncWorker(this.host) : hostKey = workerKey(host);
  final Host host;
  final String hostKey;

  Isolate? _isolate;
  SendPort? _to;
  ReceivePort? _from;
  Future<void>? _starting;
  final _pending = <int, Completer<Uint8List>>{};
  int _id = 0;
  Timer? _idle;

  /// Changes with the host's connection settings and its pinned key: the worker connects with a copy.
  static String workerKey(Host h) => '${SshPool.keyOf(h)}|${h.hostKeyFingerprint}';

  static const idleAfter = Duration(minutes: 2);

  Future<Uint8List> run(String script) async {
    _idle?.cancel();
    try {
      await (_starting ??= _start());
    } catch (_) {
      close(); // drop the failed start so the next run spawns again
      rethrow;
    }
    final id = _id++, done = _pending[id] = Completer<Uint8List>();
    _to!.send((id, script));
    _idle = Timer(idleAfter, close);
    return done.future.timeout(const Duration(seconds: 90), onTimeout: () {
      close();
      throw TimeoutException('sync on ${host.name}');
    });
  }

  Future<void> _start() async {
    final from = _from = ReceivePort();
    final ready = Completer<SendPort>();
    from.listen((m) {
      if (m is SendPort) return ready.complete(m);
      final (id, result) = m as (int, Object);
      final c = _pending.remove(id);
      if (c == null) return;
      if (result is TransferableTypedData) {
        c.complete(result.materialize().asUint8List());
      } else {
        c.completeError(result is String ? StateError(result) : result);
      }
    });
    _isolate = await Isolate.spawn(_syncWorker, (from.sendPort, host));
    _to = await ready.future;
  }

  void close() {
    _idle?.cancel();
    _to?.send(null);
    _isolate?.kill();
    _from?.close();
    _isolate = _to = _from = _starting = null;
    for (final c in _pending.values) {
      c.completeError(StateError('sync worker closed'));
    }
    _pending.clear();
  }
}

Future<void> _syncWorker((SendPort, Host) args) async {
  final (out, host) = args;
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  dynamic client;
  await for (final m in inbox) {
    if (m == null) {
      client?.close();
      inbox.close();
      break;
    }
    final (id, script) = m as (int, String);
    try {
      final Uint8List bytes;
      if (host.isLocal) {
        final r = await Process.run('/bin/sh', ['-c', script], stdoutEncoding: null);
        bytes = Uint8List.fromList(r.stdout as List<int>);
      } else {
        client ??= await sshConnect(host, pin: false);
        bytes = await client.run(script, stderr: false) as Uint8List;
      }
      out.send((id, TransferableTypedData.fromList([bytes])));
    } catch (e) {
      client?.close();
      client = null;
      out.send((id, e is HostKeyChangedException ? e : '$e'));
    }
  }
}

/// Keeps every live Claude chat on one host in [ChatCache] while the app is
/// open, so a chat opens from the cache. One batched command per cycle (every
/// [every], and soon after the host reports a change); a chat a screen has
/// open is left to that screen (see [openChatKeys]).
class ChatSync {
  ChatSync({
    required this.host,
    required this.seats,
    this.onLines,
    this.every = const Duration(seconds: 10),
    ChatCache? cache,
    Future<Uint8List> Function(String script)? exec,
  })  : _cache = cache,
        _exec = exec;

  final Host Function() host;

  /// The agents with a chat log.
  final List<Seat> Function() seats;

  /// Lines just saved for a chat, for its preview in the list.
  final void Function(String key, List<String> lines)? onLines;
  final Duration every;
  final ChatCache? _cache;
  final Future<Uint8List> Function(String script)? _exec;

  SyncWorker? _worker;
  Timer? _timer, _soon;
  AppLifecycleListener? _lifecycle;
  bool _busy = false, _stopped = false, _background = false;
  int _fails = 0;
  DateTime _retryAt = DateTime(0);
  DateTime _nextAt = DateTime(0); // a cycle ends, then [every] passes before the timer starts the next
  final _grow = <String, int>{};
  final _previewed = <String, int>{}; // chat key -> cursor offset its preview came from
  final _skipUntil = <String, DateTime>{}; // a line longer than _maxGrow: not read again for a while
  final _fresh = <String>{}; // chats saved to in the current cycle

  ChatCache? get _db => _cache ?? chatCache;

  void start() {
    _stopped = false;
    _timer ??= Timer.periodic(every, (_) => tick(timer: true));
    try {
      _lifecycle ??= AppLifecycleListener(onStateChange: (s) {
        _background = s == AppLifecycleState.paused || s == AppLifecycleState.hidden;
        if (!_background) {
          _fails = 0;
          _retryAt = DateTime(0);
          unawaited(tick());
        }
      });
    } catch (_) {
      // No binding (a plain unit test): nothing to follow.
    }
    unawaited(tick());
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _soon?.cancel();
    _timer = _soon = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    _worker?.close();
    _worker = null;
  }

  /// The host reported a change: sync soon, once for a burst.
  void poke() => _soon ??= Timer(const Duration(seconds: 2), () {
        _soon = null;
        unawaited(tick());
      });

  /// Backoff after a failure: 10, 20, 40 … up to 5 minutes. A success resets it.
  Duration get backoff => Duration(seconds: min(300, 10 * (1 << min(_fails - 1, 5))));

  Future<void> tick({bool timer = false}) async {
    if (_busy || _stopped || _background || DateTime.now().isBefore(_retryAt)) return;
    if (timer && DateTime.now().isBefore(_nextAt)) return;
    _busy = true;
    try {
      await cycle();
      _fails = 0;
    } on HostKeyChangedException {
      _stopped = true; // until the host is edited
    } catch (e) {
      _fails++;
      _retryAt = DateTime.now().add(backoff);
      logWarning('chat sync on ${host().name}: $e');
    } finally {
      _busy = false;
      _nextAt = DateTime.now().add(every);
    }
  }

  /// One pull: read where each chat's saved lines end, ask the host for what
  /// is new, save it.
  Future<void> cycle() async {
    final db = _db, h = host();
    if (db == null || (h.privateKeyPem == null && !h.isLocal)) return;
    final targets = <SyncTarget>[];
    for (final s in seats()) {
      final key = chatKey(s);
      if (!s.isClaude || openChatKeys.contains(openKey(h.id, key))) continue;
      if (_skipUntil[key]?.isAfter(DateTime.now()) ?? false) continue;
      targets.add(SyncTarget(s, key, await db.cursor(h.id, key), cap: _grow[key] ?? _deltaBytes));
    }
    // stop() may have run during the cursor reads: don't spawn a worker after it.
    if (targets.isEmpty || _stopped) return;
    final script = syncScript(targets);
    if (_worker != null && _worker!.hostKey != SyncWorker.workerKey(h)) {
      _worker!.close(); // the host was edited: connect with its new settings
      _worker = null;
    }
    final out = await (_exec ?? (_worker ??= SyncWorker(h)).run)(script);
    for (final c in parseSyncOutput(out)) {
      if (c.index < 0 || c.index >= targets.length) continue;
      final t = targets[c.index];
      // A screen may have opened this chat while the command ran.
      if (openChatKeys.contains(openKey(h.id, t.key))) continue;
      await _apply(db, h.id, t, c);
    }
    // A preview also comes from lines saved earlier (an app restart, a chat the person just closed).
    for (final t in targets) {
      final cur = await db.cursor(h.id, t.key);
      if (cur == null || _previewed[t.key] == cur.offset) continue;
      _previewed[t.key] = cur.offset;
      if (_fresh.remove(t.key)) continue;
      final lines = await db.lastLines(h.id, t.key, 60);
      if (lines.isNotEmpty) onLines?.call(t.key, lines);
    }
    _fresh.clear();
  }

  Future<void> _apply(ChatCache db, String hostId, SyncTarget t, SyncChunk c) async {
    if (c.bytes.isEmpty) return;
    var bytes = c.bytes, from = c.from;
    final cap = c.seed ? max(_seedBytes, t.cap) : t.cap;
    // One log line longer than this read: read more of it next time.
    void grow() {
      if (c.bytes.length < cap) return;
      if (cap < _maxGrow) {
        _grow[t.key] = cap * 2;
      } else {
        _grow.remove(t.key);
        _skipUntil[t.key] = DateTime.now().add(const Duration(minutes: 10));
      }
    }

    if (c.seed && from > 0) {
      // The seed starts mid-line: begin at the next whole one.
      final nl = bytes.indexOf(10);
      if (nl < 0) return grow();
      bytes = bytes.sublist(nl + 1);
      from += nl + 1;
    }
    final last = bytes.lastIndexOf(10);
    if (last < 0) return grow();
    _grow.remove(t.key);
    final lines = const LineSplitter().convert(utf8.decode(bytes.sublist(0, last), allowMalformed: true));
    if (lines.isEmpty) return;
    final to = from + last + 1;
    final bool saved;
    if (c.seed) {
      if (t.cursor != null) await db.drop(hostId, t.key);
      saved = await db.append(hostId, t.key, c.path, from, to, from > 0, lines, seed: true);
    } else {
      saved = await db.append(hostId, t.key, c.path, from, to, t.cursor!.truncated, lines);
    }
    if (saved) {
      _fresh.add(t.key);
      onLines?.call(t.key, lines);
    }
  }
}
