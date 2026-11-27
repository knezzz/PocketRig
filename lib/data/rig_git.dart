import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models.dart';
import '../ssh/ssh_exec.dart';
import 'git_status.dart';

/// One rig checkout's git status and PR, read once for every view that shows it (the rig page, its tiles, its chat): one
/// `git` + one `gh pr view` per folder, on open and then every [every], and only while a view is listening. Never per seat
/// or per frame. A host without SSH, gh or auth gives git only (or nothing); the line then simply has less on it.
class RigGit extends ValueNotifier<GitStatus?> {
  RigGit._(this.host, this.cwd) : super(null);
  final Host host;
  final String cwd;

  static const every = Duration(seconds: 60);
  static final _feeds = <String, RigGit>{};
  static var _listeners = <String, int>{};

  /// The feed for [cwd] on [host]; [listen] starts it, [unlisten] stops it when the last view goes.
  static RigGit of(Host host, String cwd) => _feeds.putIfAbsent('${host.id}|$cwd', () => RigGit._(host, cwd));

  Timer? _timer;
  bool _busy = false;

  String get _key => '${host.id}|$cwd';

  void listen() {
    final n = _listeners[_key] = (_listeners[_key] ?? 0) + 1;
    if (n == 1) {
      _timer = Timer.periodic(every, (_) => refresh());
      refresh();
    }
  }

  void unlisten() {
    final n = (_listeners[_key] ?? 1) - 1;
    if (n > 0) {
      _listeners[_key] = n;
      return;
    }
    _listeners.remove(_key);
    _timer?.cancel();
    _timer = null;
  }

  Future<void> refresh() async {
    if (_busy) return;
    _busy = true;
    try {
      final g = await SshExec.use(host, (ssh) => ssh.gitStatus(cwd));
      value = g.isRepo ? g : null;
    } catch (_) {
      // Keeps the last reading: a dropped connection is not a changed branch.
    } finally {
      _busy = false;
    }
  }

  @visibleForTesting
  static void reset() {
    for (final f in _feeds.values) {
      f._timer?.cancel();
    }
    _feeds.clear();
    _listeners = {};
  }
}
