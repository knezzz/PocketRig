import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:borealis/borealis.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// One thing the person did or ran into. [kind] is one of: app, open,
/// close (detail: ms on screen), tap (x,y), rage, error, toast, call.
class UxEvent {
  UxEvent(this.kind, this.screen, [this.detail, DateTime? t]) : t = t ?? DateTime.now();
  final DateTime t;
  final String kind;
  final String screen;
  final String? detail;

  Map<String, Object?> toJson() =>
      {'t': t.millisecondsSinceEpoch, 'k': kind, 's': screen, if (detail != null) 'd': detail};
  factory UxEvent.fromJson(Map<String, dynamic> j) =>
      UxEvent(j['k'] as String, j['s'] as String, j['d'] as String?, DateTime.fromMillisecondsSinceEpoch(j['t'] as int));
}

/// UX analytics that never leave the phone: what was opened, tapped, and
/// went wrong, kept in a file so friction shows up across days of use.
class UxLog extends ChangeNotifier {
  UxLog._();
  static final instance = UxLog._();
  static const _max = 5000;

  final List<UxEvent> events = [];

  /// The screen on top, so taps and errors know where they happened.
  String screen = 'Projects';

  File? _file;
  Timer? _save;
  final _recentTaps = <(DateTime, Offset)>[];

  /// Reads the saved log and starts recording crashes and app state. Taps
  /// come from [UxTaps] around the app, so the Borealis panel's own aren't counted.
  Future<void> start() async {
    _file = File('${(await getApplicationSupportDirectory()).path}/ux_log.json');
    try {
      events.addAll([for (final j in jsonDecode(await _file!.readAsString()) as List) UxEvent.fromJson(j)]);
    } catch (_) {} // first run or a corrupt file: start empty
    final flutterError = FlutterError.onError;
    FlutterError.onError = (d) {
      add('error', d.exceptionAsString());
      flutterError?.call(d);
    };
    final platformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (e, st) {
      add('error', '$e');
      return platformError?.call(e, st) ?? false;
    };
    AppLifecycleListener(onStateChange: (s) {
      if (s == AppLifecycleState.resumed || s == AppLifecycleState.paused) add('app', s.name);
      if (s == AppLifecycleState.paused) _flush();
    });
    add('app', 'start');
  }

  void add(String kind, [String? detail]) {
    final d = detail != null && detail.length > 200 ? '${detail.substring(0, 200)}…' : detail;
    events.add(UxEvent(kind, screen, d));
    if (events.length > _max) events.removeRange(0, events.length - _max);
    notifyListeners();
    if (_file != null) _save ??= Timer(const Duration(seconds: 3), _flush);
  }

  void _flush() {
    _save?.cancel();
    _save = null;
    _file?.writeAsString(jsonEncode(events)).ignore();
  }

  void enter(String name) {
    screen = name;
    add('open');
  }

  void tap(Offset at) {
    add('tap', '${at.dx.round()},${at.dy.round()}');
    final now = DateTime.now();
    _recentTaps
      ..removeWhere((t) => now.difference(t.$1) > const Duration(seconds: 1) || (t.$2 - at).distance > 40)
      ..add((now, at));
    // Three quick taps on one spot: it looked tappable and didn't respond.
    if (_recentTaps.length == 3) add('rage', '${at.dx.round()},${at.dy.round()}');
  }

  /// A network or SSH call, kept only when it was slow or failed.
  void call(String what, Duration took, {Object? error, int? status}) {
    final failed = error != null || (status != null && status >= 400);
    if (!failed && took < const Duration(seconds: 2)) return;
    add('call', '$what ${took.inMilliseconds}ms${status != null ? ' $status' : ''}${error != null ? ' $error' : ''}');
  }

  void clear() {
    events.clear();
    notifyListeners();
    _flush();
  }

  /// The markdown report an agent turns into UX suggestions.
  String report() {
    final s = screenStats(events);
    final b = StringBuffer()
      ..writeln('# PocketRig UX log (recorded on the phone)')
      ..writeln()
      ..writeln('${events.length} events, ${events.where((e) => e.kind == 'app' && e.detail != 'paused').length} '
          'sessions${events.isEmpty ? '' : ', ${events.first.t.toIso8601String()} to ${events.last.t.toIso8601String()}'}.')
      ..writeln('Kinds: open/close (close detail = ms on screen), tap (x,y in dp), rage (3 taps on one spot in 1 s), '
          'error (crash), toast (snackbar text), call (network/SSH call that was slow ≥2 s or failed), app (lifecycle).')
      ..writeln()
      ..writeln('## Friction flags')
      ..writeln();
    for (final f in findings(events)) {
      b.writeln('- $f');
    }
    b
      ..writeln()
      ..writeln('## Screens')
      ..writeln()
      ..writeln('| screen | visits | median s | taps/visit | quick back-outs |')
      ..writeln('|---|---|---|---|---|');
    for (final x in s) {
      b.writeln('| ${x.name} | ${x.visits} | ${x.medianSeconds.toStringAsFixed(1)} | '
          '${x.tapsPerVisit.toStringAsFixed(1)} | ${x.quickBackOuts} |');
    }
    final recent = events.length > 1500 ? events.sublist(events.length - 1500) : events;
    b
      ..writeln()
      ..writeln('## Last ${recent.length} events')
      ..writeln()
      ..writeln('```json')
      ..writeln(jsonEncode(recent))
      ..writeln('```')
      ..writeln()
      ..writeln('Using this log and the PocketRig source, suggest the changes that would remove the most friction. '
          'Rank them, cite the evidence for each, and name the file to change.');
    return b.toString();
  }
}

final uxLog = UxLog.instance;

/// A closed screen counts as a quick back-out under this.
const quickBackOut = Duration(seconds: 2);

class ScreenStats {
  ScreenStats(this.name);
  final String name;
  int visits = 0, taps = 0, quickBackOuts = 0;
  final dwellMs = <int>[];
  double get tapsPerVisit => visits == 0 ? 0 : taps / visits;
  double get medianSeconds {
    if (dwellMs.isEmpty) return 0;
    final d = [...dwellMs]..sort();
    return d[d.length ~/ 2] / 1000;
  }
}

/// Per screen, most visited first.
List<ScreenStats> screenStats(List<UxEvent> events) {
  final m = <String, ScreenStats>{};
  for (final e in events) {
    final s = m.putIfAbsent(e.screen, () => ScreenStats(e.screen));
    switch (e.kind) {
      case 'open':
        s.visits++;
      case 'tap':
        s.taps++;
      case 'close':
        final ms = int.tryParse(e.detail ?? '') ?? 0;
        s.dwellMs.add(ms);
        if (ms < quickBackOut.inMilliseconds) s.quickBackOuts++;
    }
  }
  return m.values.toList()..sort((a, b) => b.visits.compareTo(a.visits));
}

final _errorToast = RegExp(r"couldn't|can't|failed|error|exception|timed out|refused", caseSensitive: false);

/// Rule-based friction flags, worst first.
List<String> findings(List<UxEvent> events) {
  final out = <(int, String)>[];
  Map<String, int> count(bool Function(UxEvent) test, [String Function(UxEvent)? key]) {
    final m = <String, int>{};
    for (final e in events.where(test)) {
      final k = key?.call(e) ?? e.screen;
      m[k] = (m[k] ?? 0) + 1;
    }
    return m;
  }

  count((e) => e.kind == 'rage').forEach((s, n) =>
      out.add((n * 3, '$n rage tap${n == 1 ? '' : 's'} on $s: something there looks tappable but isn\'t, or answers too slowly.')));
  count((e) => e.kind == 'error').forEach((s, n) => out.add((n * 3, '$n crash${n == 1 ? '' : 'es'} on $s.')));
  count((e) => e.kind == 'toast' && _errorToast.hasMatch(e.detail ?? '')).forEach((s, n) =>
      out.add((n * 2, '$n error message${n == 1 ? '' : 's'} shown on $s.')));
  for (final s in screenStats(events)) {
    if (s.quickBackOuts >= 2) {
      out.add((s.quickBackOuts, '${s.name} closed within ${quickBackOut.inSeconds} s ${s.quickBackOuts} times '
          'of ${s.dwellMs.length}: opened by mistake, or not what was expected.'));
    }
  }
  // Group calls by what was called, without the timing and status.
  count((e) => e.kind == 'call', (e) => (e.detail ?? '').split(' ').take(2).join(' ')).forEach((what, n) {
    if (n >= 2) out.add((n, '$what was slow or failed $n times.'));
  });
  out.sort((a, b) => b.$1.compareTo(a.$1));
  return [for (final f in out) f.$2];
}

/// Records which screen is on top and how long each stayed open.
class UxRouteObserver extends NavigatorObserver {
  final _shown = <Route<dynamic>, (String, DateTime)>{};

  /// The home route's name: the bottom tab that's selected.
  String homeTab = 'Projects';

  void _enter(Route<dynamic> route) => WidgetsBinding.instance.addPostFrameCallback((_) {
        final name = route.isFirst ? homeTab : screenName(route);
        _shown[route] = (name, DateTime.now());
        uxLog.enter(name);
      });

  void _leave(Route<dynamic> route, Route<dynamic>? back) {
    final shown = _shown.remove(route);
    if (shown != null) {
      uxLog.screen = shown.$1;
      uxLog.add('close', '${DateTime.now().difference(shown.$2).inMilliseconds}');
    }
    if (back != null) uxLog.screen = back.isFirst ? homeTab : (_shown[back]?.$1 ?? uxLog.screen);
  }

  /// HomeShell's tabs share one route, so it reports switches itself.
  void tab(String name) {
    homeTab = name;
    uxLog.enter(name);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _enter(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _leave(route, previousRoute);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _leave(route, null);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _leave(oldRoute, null);
    if (newRoute != null) _enter(newRoute);
  }

  /// The app's screen widget inside [route]: routes here are unnamed, so the
  /// first widget called *Screen, *Sheet or *Dialog names it.
  static String screenName(Route<dynamic> route) {
    if (route.settings.name case final n?) return n;
    final ctx = route is ModalRoute ? route.subtreeContext : null;
    String? found;
    void visit(Element e) {
      if (found != null) return;
      final t = e.widget.runtimeType.toString();
      if (!t.startsWith('_') && t != 'BottomSheet' && RegExp(r'(Screen|Sheet|Dialog|Viewer)$').hasMatch(t)) {
        found = t;
        return;
      }
      e.visitChildren(visit);
    }

    if (ctx is Element) visit(ctx);
    return found ?? route.runtimeType.toString();
  }
}

/// Records taps that land on [child]; overlays above it (the debug panel) don't reach it.
class UxTaps extends StatelessWidget {
  const UxTaps({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Listener(
      // Translucent: taps on blank, non-interactive spots count too (rage taps).
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) => uxLog.tap(e.position),
      child: child);
}

/// shortcut: only the app's root navigator; the wide desktop window's detail pane isn't tracked.
final uxRoutes = UxRouteObserver();

/// The **UX** tab of the Borealis panel: friction flags and a report to
/// hand to an agent.
class UxBorealisPage extends BorealisPage {
  const UxBorealisPage() : super(title: 'UX', icon: Icons.insights);

  static final _badge = CountListenable(uxLog, () => findings(uxLog.events).length);

  @override
  ValueListenable<int>? get badgeListenable => _badge;

  @override
  VoidCallback? get onClearTap => uxLog.clear;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: uxLog,
        builder: (context, _) {
          final flags = findings(uxLog.events);
          return ListView(padding: const EdgeInsets.all(12), children: [
            FilledButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Copy report for an agent'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: uxLog.report()));
                if (context.mounted) {
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Copied')));
                }
              },
            ),
            const SizedBox(height: 8),
            Text('${uxLog.events.length} events on this device', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            if (flags.isEmpty) const Text('No friction flagged yet'),
            for (final f in flags) ListTile(dense: true, leading: const Icon(Icons.flag, size: 18), title: Text(f)),
            const Divider(),
            for (final s in screenStats(uxLog.events).take(20))
              ListTile(
                dense: true,
                title: Text(s.name),
                subtitle: Text('${s.visits} visits · ${s.medianSeconds.toStringAsFixed(1)} s median · '
                    '${s.tapsPerVisit.toStringAsFixed(1)} taps/visit · ${s.quickBackOuts} quick back-outs'),
              ),
          ]);
        },
      );
}
