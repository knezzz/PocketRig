import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models.dart';

/// One shared connection to the daemon's global event stream per client.
/// Screens listen to [stream]; the connection opens with the first listener,
/// closes with the last, and reconnects with backoff (resuming via
/// Last-Event-ID). [connected] tells screens whether they can poll slowly.
class LiveEvents {
  LiveEvents(this._open);

  /// Opens the raw stream; [lastEventId] resumes after a drop.
  final Stream<RigEvent> Function(String? lastEventId) _open;

  final connected = ValueNotifier<bool>(false);
  late final StreamController<RigEvent> _out = StreamController<RigEvent>.broadcast(
    onListen: _connect,
    onCancel: _disconnect,
  );
  StreamSubscription<RigEvent>? _sub;
  Timer? _retry;
  Timer? _settle;
  Timer? _quiet;
  String? _lastId;
  int _failures = 0;
  bool _closed = false;

  Stream<RigEvent> get stream => _out.stream;

  void _connect() {
    if (_closed || _sub != null) return;
    _retry?.cancel();
    _sub = _open(_lastId).listen(
      (e) {
        _failures = 0;
        _armQuiet();
        if (!connected.value) connected.value = true;
        _lastId = '${e.seq}';
        _out.add(e);
      },
      onError: (_) => _dropped(),
      onDone: _dropped,
    );
    // The daemon sends no hello frame, so count an open socket as connected
    // once it has stayed up briefly.
    _settle?.cancel();
    _settle = Timer(const Duration(seconds: 2), () {
      if (_sub != null && !_closed) connected.value = true;
    });
    _armQuiet();
  }

  /// How long a stream may stay silent before it is reopened. The daemon
  /// sends no heartbeat, so a socket that died with the network (no FIN)
  /// looks exactly like a quiet rig; reopening resumes via Last-Event-ID.
  static const quietFor = Duration(minutes: 2);

  void _armQuiet() {
    _quiet?.cancel();
    _quiet = Timer(quietFor, () {
      if (_closed || _sub == null) return;
      _sub?.cancel();
      _sub = null;
      _connect(); // keeps [connected]: a failed reopen goes through _dropped
    });
  }

  void _dropped() {
    _quiet?.cancel();
    _sub?.cancel();
    _sub = null;
    connected.value = false;
    if (_closed || !_out.hasListener) return;
    _failures++;
    final wait = Duration(seconds: _failures >= 4 ? 30 : 2 << _failures);
    _retry = Timer(wait, _connect);
  }

  void _disconnect() {
    _failures = 0; // coming back from the background starts fresh
    _retry?.cancel();
    _settle?.cancel();
    _quiet?.cancel();
    _sub?.cancel();
    _sub = null;
    connected.value = false;
  }

  Future<void> close() async {
    _closed = true;
    _disconnect();
    await _out.close();
    connected.dispose();
  }
}
