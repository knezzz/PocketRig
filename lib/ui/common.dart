import 'dart:async';

import 'package:flutter/material.dart';

import '../api/openrig_client.dart';
import '../data/ux_log.dart';
import '../main.dart';
import '../models.dart';
import 'status_shape.dart';
import 'theme.dart';

// Moved to data/ in 05cc9cf; still reachable here for screens that import it from common.dart.
export '../data/needs_you.dart' show needsYouCount;

/// Makes [host] the active one, for screens that talk to the active host
/// (rig, seat, chat, terminal). Opening something from another host's
/// section of a list goes through here first.
void useHost(BuildContext context, Host host) {
  final store = AppScope.read(context);
  if (store.active?.id != host.id) store.select(host.id);
}

/// Brand-neutral accents kept in one place.

/// Keeps a screen fresh: reloads when the daemon's event stream reports
/// something ([wants] filters), and polls as the fallback — every [every]
/// while the stream is down, every [slowEvery] while it is up. Screens pull
/// to refresh too.
mixin Polling<T extends StatefulWidget> on State<T> {
  Timer? _timer;
  Timer? _soon;
  StreamSubscription<RigEvent>? _events;
  ValueNotifier<bool>? _connected;
  OpenRigClient? _api;

  Duration get every => const Duration(seconds: 5);
  Duration get slowEvery => const Duration(seconds: 30);
  Future<void> load();

  /// Which events should trigger a reload. All of them by default.
  bool wants(RigEvent e) => true;

  /// Whether [api] is still the active host's client. A load that started
  /// before the host was switched must drop what it fetched, or the old
  /// host's data lands on the new host's screen.
  bool current(OpenRigClient api) => mounted && identical(AppScope.clientOf(context), api);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) load();
    });
    _schedule(every);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    AppScope.of(context); // re-run when the active host changes
    final api = AppScope.clientOf(context);
    if (identical(api, _api)) return;
    _unlisten();
    _api = api;
    if (api == null) return;
    _connected = api.live.connected..addListener(_onConnection);
    _events = api.live.stream.listen((e) {
      if (!mounted || !wants(e)) return;
      // Coalesce bursts into one reload.
      _soon ??= Timer(const Duration(milliseconds: 400), () {
        _soon = null;
        if (mounted) load();
      });
    });
  }

  void _onConnection() => _schedule(_connected?.value == true ? slowEvery : every);

  void _schedule(Duration d) {
    _timer?.cancel();
    _timer = Timer.periodic(d, (_) {
      if (mounted) load();
    });
  }

  void _unlisten() {
    _events?.cancel();
    _events = null;
    _connected?.removeListener(_onConnection);
    _connected = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _soon?.cancel();
    _unlisten();
    super.dispose();
  }
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.message,
      {super.key, this.margin = const EdgeInsets.fromLTRB(16, 8, 16, 0), this.action, this.onAction, this.color});
  final String message;

  /// The outline: the accent by default; a plain failure to read something (a detail pane's history) uses the failed red.
  final Color? color;
  final EdgeInsets margin;

  /// A next step beside the message (Reconnect); both or neither.
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      margin: margin,
      decoration: BoxDecoration(border: Border.all(color: color ?? k.accent), borderRadius: BorderRadius.circular(kRadius)),
      child: action == null
          ? Text(message, style: Theme.of(context).textTheme.bodyMedium)
          : Row(children: [
              Expanded(child: Text(message, style: Theme.of(context).textTheme.bodyMedium)),
              TextButton(onPressed: onAction, child: Text(action!)),
            ]),
    );
  }
}

/// What a toast reports: something that happened ([done]), a setting that
/// changed ([info]), or a problem.
enum ToastKind { done, info, problem }

/// Guesses the kind from the wording, for call sites that don't say.
ToastKind toastKindOf(String msg) {
  final m = msg.toLowerCase();
  if (m.contains("couldn't") || m.startsWith('not sent') || m.contains('failed') || m.contains('error')) {
    return ToastKind.problem;
  }
  if (m.startsWith('model') ||
      m.startsWith('effort') ||
      m.contains('next time') ||
      m.contains('relaunching') ||
      m.contains('using ssh') ||
      m.contains(' → ')) {
    return ToastKind.info;
  }
  return ToastKind.done;
}

/// One toast at a time, at the top under the status bar, and every kind goes on its own: done and info after
/// 3 s, a problem or one with an [action] after 6 s (with a screen reader on, those two stay until closed). A swipe up dismisses it early. Done: dark-on-light with ✓.
/// Info: same, with a dot. Problem: outlined in the failed color with its mark and a close button. [action]
/// adds a next step (Restore, Retry, Relaunch now, Open).
void toast(BuildContext context, String msg, {ToastKind? kind, String? action, VoidCallback? onAction}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  toastOn(messenger, Tokens.of(context), msg, kind: kind, action: action, onAction: onAction);
}

OverlayEntry? _toast;

/// A problem a toast reported, kept for the Inbox after the toast has gone.
class ToastProblem {
  ToastProblem(this.message, this.at, this.action, this.onAction);
  final String message;
  final DateTime at;
  final String? action;
  final VoidCallback? onAction;
}

/// The last 20 problems toasted, newest first. In memory only: an action's callback can't outlive the app.
final toastProblems = ValueNotifier<List<ToastProblem>>(const []);

void _hideToast() {
  _toast
    ?..remove()
    ..dispose();
  _toast = null;
}

/// [toast] through a messenger captured before an await, when the widget
/// that asked may be gone by the time the result is in.
void toastOn(ScaffoldMessengerState messenger, Tokens k, String msg,
    {ToastKind? kind, String? action, VoidCallback? onAction}) {
  uxLog.add('toast', msg);
  // The app's Navigator sits under the messenger: its overlay draws above every route, sheet and dialog.
  OverlayState? overlay;
  void find(Element e) {
    if (overlay != null) return;
    if (e is StatefulElement && e.state is OverlayState) {
      overlay = e.state as OverlayState;
    } else {
      e.visitChildren(find);
    }
  }

  if (messenger.mounted) messenger.context.visitChildElements(find);
  final kind0 = kind ?? toastKindOf(msg);
  final problem = kind0 == ToastKind.problem;
  if (problem) {
    toastProblems.value = [ToastProblem(msg, DateTime.now(), action, onAction), ...toastProblems.value].take(20).toList();
  }
  final fg = problem ? k.ink : k.onInk;
  _hideToast();
  late final OverlayEntry entry;
  void close() {
    if (identical(_toast, entry)) _hideToast();
  }

  entry = OverlayEntry(
    builder: (context) => _Toast(
      duration: Duration(seconds: problem || action != null ? 6 : 3),
      hold: problem || action != null,
      onGone: close,
      child: Material(
        color: problem ? k.surface : k.ink,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadius),
          side: problem ? BorderSide(color: k.removed, width: 1.5) : BorderSide.none,
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 4, problem || action != null ? 4 : 16, 4),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(children: [
              SizedBox(
                width: 16,
                child: problem
                    ? const Center(child: StatusShape(Status.failed, size: 10, semantics: false))
                    : Text(kind0 == ToastKind.done ? '✓' : '·',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontFamily: fontMono, fontWeight: FontWeight.w700, color: fg)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(msg, style: TextStyle(color: fg, fontSize: 14)),
                ),
              ),
              if (action != null)
                TextButton(
                  onPressed: () {
                    close();
                    (onAction ?? () {})();
                  },
                  style: TextButton.styleFrom(foregroundColor: fg),
                  child: Text(action),
                ),
              // Any toast that can stay (see _Toast.hold) can be closed without its action, also by a screen reader.
              if (problem || action != null)
                IconButton(
                  tooltip: 'Dismiss',
                  icon: Icon(Icons.close, size: 18, color: k.muted),
                  onPressed: close,
                ),
            ]),
          ),
        ),
      ),
    ),
  );
  _toast = entry;
  overlay?.insert(entry);
  if (overlay == null) _toast = null;
}

/// A toast's place and life: under the status bar, sliding in, gone after [duration] or a swipe up.
class _Toast extends StatefulWidget {
  const _Toast({required this.duration, required this.hold, required this.onGone, required this.child});
  final Duration duration;

  /// With a screen reader on, stays until closed: its action or close button may take longer than [duration] to reach.
  final bool hold;
  final VoidCallback onGone;
  final Widget child;
  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> {
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_timer == null && !(widget.hold && MediaQuery.accessibleNavigationOf(context))) {
      _timer = Timer(widget.duration, widget.onGone);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Semantics(
              liveRegion: true,
              child: Dismissible(
                key: const ValueKey('toast'),
                direction: DismissDirection.up,
                onDismissed: (_) => widget.onGone(),
                child: TweenAnimationBuilder<Offset>(
                  tween: Tween(begin: const Offset(0, -1), end: Offset.zero),
                  duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 200),
                  curve: kEaseOut,
                  builder: (context, o, child) => FractionalTranslation(translation: o, child: child),
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      );
}

/// A faint wash of the accent behind a row that's waiting on you.
class NeedsYouTint extends StatelessWidget {
  const NeedsYouTint({super.key, required this.on, required this.child});
  final bool on;
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      on ? Material(color: Tokens.of(context).accent.withValues(alpha: 0.1), child: child) : child;
}

/// Line counts like "+12 −3" in the git colors; other words ("new") stay muted.
class DeltaText extends StatelessWidget {
  const DeltaText(this.delta, {super.key, this.size = 11});
  final String delta;
  final double size;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final parts = delta.split(' ');
    return Text.rich(TextSpan(children: [
      for (var i = 0; i < parts.length; i++)
        TextSpan(
          text: i == 0 ? parts[i] : ' ${parts[i]}',
          style: mono(context,
              size: size,
              weight: FontWeight.w500,
              color: switch (parts[i][0]) { '+' => k.added, '−' => k.removed, _ => k.muted }),
        ),
    ]));
  }
}

/// Ticks once a minute while anything listens, so "just now" and "3m ago" age on a quiet screen. One timer for
/// the whole app, stopped when nothing listens.
final minuteTick = _MinuteTick();

class _MinuteTick extends ChangeNotifier {
  Timer? _timer;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _timer ??= Timer.periodic(const Duration(minutes: 1), (_) => notifyListeners());
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
    }
  }
}

/// [ago], or a dash when nothing is known, so every agent row shows a last activity.
String agoOrDash(DateTime? at, [DateTime? now]) => at == null ? '—' : ago(at, now);

/// "4m ago", or "just now" under a minute (not "now ago").
String agoPhrase(DateTime at, [DateTime? now]) {
  final a = ago(at, now);
  return a == 'now' ? 'just now' : '$a ago';
}

/// Tests pin what "now" is for [ago], so a rendered "just now" can't turn into "1m ago" while a board runs.
DateTime? debugAgoClock;

/// "3m ago" style relative time.
String ago(DateTime? at, [DateTime? now]) {
  if (at == null) return '';
  final d = (now ?? debugAgoClock ?? DateTime.now()).difference(at);
  if (d.inSeconds < 60) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  return '${d.inDays}d';
}

/// 950 → "950", 12 400 → "12.4k", 3 200 000 → "3.2M".
String compactCount(int n) => n < 1000
    ? '$n'
    : n < 1000000
        ? '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}k'
        : '${(n / 1000000).toStringAsFixed(1)}M';

/// [s] cut in the middle to at most [max] characters ("~/code/app/…/flaky-ci"), so the end of a path, which names
/// the folder, stays in view.
String middleEllipsis(String s, {int max = 34}) =>
    s.length <= max ? s : '${s.substring(0, (max - 1) ~/ 2)}…${s.substring(s.length - (max - 1 + 1) ~/ 2)}';
