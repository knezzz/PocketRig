import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/gestures.dart';

import '../models.dart';
import '../ssh/ssh_exec.dart';
import 'transport.dart';

/// Scrolling a tmux pane: it draws on the alternate screen, where a swipe would send arrow keys to the program. Instead
/// a swipe, the wheel or a trackpad scrolls tmux's own history (copy mode) over SSH (local on this Mac), batched;
/// typing leaves copy mode first ([send]), and [toLive] does it without typing. Even with tmux's `mouse on` a swipe
/// scrolls here: the terminal view reports taps to the program, not drags, so a swipe left to it did nothing.
class TmuxScroller {
  TmuxScroller({required this.session, required this.host, required this.onError});

  /// The tmux session on screen (null: nothing to scroll).
  final String? session;
  final Host? Function() host;

  final void Function(String message) onError;

  /// Whether the pane is scrolled back into history (what a "Back to live" button shows on).
  final inCopyMode = ValueNotifier<bool>(false);

  Future<SshExec>? _ssh;
  Timer? _flushTimer;
  double _dragged = 0;
  int _lines = 0;
  Future<void>? _leaving;
  bool _closed = false;

  void _mode(bool v) {
    if (!_closed) inCopyMode.value = v;
  }

  /// The pointer events that scroll: a finger drags, a mouse drag is left to text selection, and the wheel and a
  /// two-finger trackpad swipe scroll. [line] is one line's height in pixels.
  void onPointerMove(PointerMoveEvent e, double line) {
    if (e.kind != PointerDeviceKind.mouse) swipe(e.delta.dy, line);
  }

  // The wheel and the trackpad always scroll here: xterm's view doesn't pass them on as mouse reports, so with tmux's
  // `mouse on` (which turns reporting on) they did nothing at all.
  void onPointerSignal(PointerSignalEvent e, double line) {
    if (e is PointerScrollEvent) _scroll(-e.scrollDelta.dy, line);
  }

  void onPanZoomUpdate(PointerPanZoomUpdateEvent e, double line) => _scroll(e.panDelta.dy, line);

  /// Swipe distance in pixels: [lineHeight] of it is one line of history.
  void swipe(double dy, double lineHeight) => _scroll(dy, lineHeight);

  void _scroll(double dy, double lineHeight) {
    if (session == null) return;
    _dragged += dy;
    final lines = _dragged ~/ lineHeight;
    if (lines == 0) return;
    _dragged -= lines * lineHeight;
    _lines += lines; // dragging down reveals older lines: scroll up
    _flushTimer ??= Timer(const Duration(milliseconds: 120), _flush);
  }

  Future<void> _flush() async {
    _flushTimer = null;
    final n = _lines, h = host();
    _lines = 0;
    if (n == 0 || session == null || h == null || (n < 0 && !inCopyMode.value)) return;
    try {
      final ssh = await (_ssh ??= SshExec.connect(h));
      final out = await ssh.runLogin(tmuxScrollCommand(session!, n));
      _mode(out.trim().endsWith('1'));
    } catch (e) {
      _ssh = null;
      onError('Couldn\'t scroll: $e');
    }
  }

  /// Back to the live output, without typing.
  Future<void> toLive() async {
    final h = host();
    if (!inCopyMode.value || session == null || h == null) return;
    _mode(false);
    try {
      await (await (_ssh ??= SshExec.connect(h))).runLogin(tmuxCancelCopyMode(session!));
    } catch (e) {
      _ssh = null;
      onError('Couldn\'t go back to live: $e');
    }
  }

  /// Sends [data] through [sink], leaving copy mode first when a scroll put the pane in it.
  void send(void Function(String) sink, String data) {
    final h = host();
    // Mouse reports (each wheel tick sends one under tmux's `mouse on`) and focus reports aren't typing: leaving copy
    // mode on them reset every scroll to the bottom.
    final typed = !data.startsWith('\x1b[<') && !data.startsWith('\x1b[M') && data != '\x1b[I' && data != '\x1b[O';
    if (typed && inCopyMode.value && session != null && h != null) {
      _mode(false);
      _leaving = (_ssh ??= SshExec.connect(h))
          .then((ssh) => ssh.runLogin(tmuxCancelCopyMode(session!)))
          .then((_) {}, onError: (_) {})
          .whenComplete(() => _leaving = null);
    }
    // Keys typed while it leaves wait their turn, in order.
    final leaving = _leaving;
    if (leaving == null) {
      sink(data);
    } else {
      leaving.then((_) => sink(data));
    }
  }

  void dispose() {
    _closed = true;
    _flushTimer?.cancel();
    inCopyMode.dispose();
    _ssh?.then((s) => s.close(), onError: (_) {});
  }
}
