import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:home_widget/home_widget.dart';
import 'package:loggy/loggy.dart';

import '../api/openrig_client.dart';
import '../models.dart';
import 'host_store.dart';

/// One rate-limit window from the daemon's `hostUsage[].windows[]`.
class UsageWindow {
  UsageWindow({
    required this.window,
    required this.usedPercent,
    required this.resetsAt,
    required this.asOf,
    this.seatSession,
  });

  final String window;
  final num usedPercent;
  final DateTime resetsAt;
  final DateTime asOf;
  final String? seatSession;

  static UsageWindow? fromJson(Map<String, Object?> j) {
    final resetsAt = DateTime.tryParse(j['resetsAt'] as String? ?? '');
    final asOf = DateTime.tryParse(j['asOf'] as String? ?? '');
    if (j['window'] is! String || j['usedPercent'] is! num || resetsAt == null || asOf == null) return null;
    return UsageWindow(
      window: j['window'] as String,
      usedPercent: j['usedPercent'] as num,
      resetsAt: resetsAt,
      asOf: asOf,
      seatSession: j['seatSession'] as String?,
    );
  }
}

/// One `hostUsage[]` row: a daemon host's readings for one provider.
class HostUsage {
  HostUsage({required this.host, required this.provider, required this.windows});

  /// The daemon's own host label (`local` for the daemon's machine).
  final String host;
  final String provider;
  final List<UsageWindow> windows;

  factory HostUsage.fromJson(Map<String, Object?> j) => HostUsage(
        host: j['host'] as String? ?? 'local',
        provider: j['provider'] as String? ?? '',
        windows: (j['windows'] is List ? j['windows'] as List : const [])
            .whereType<Map>()
            .map((m) => UsageWindow.fromJson(m.cast<String, Object?>()))
            .whereType<UsageWindow>()
            .toList(),
      );
}

/// Contract `windowSeconds` per window; windows not listed here are skipped.
const usageWindowSeconds = {'five_hour': 18000, 'weekly': 604800};

/// Reduces every host's readings to the `usage_rings_v1` contract: the
/// freshest reading (max `asOf`) per app host / daemon host / provider /
/// window. See the slice SPEC for the shape the widgets read. The native
/// background fetchers reimplement this; `test/fixtures/usage_rings_*.json`
/// is the shared equivalence check.
Map<String, Object?> usageRingsJson(List<(Host, List<HostUsage>)> readings, {DateTime? writtenAt}) {
  final rings = <String, Map<String, Object?>>{};
  final freshest = <String, Map<String, UsageWindow>>{};
  for (final (host, usages) in readings) {
    for (final u in usages) {
      final id = '${host.id}/${u.host}/${u.provider}';
      rings.putIfAbsent(
          id,
          () => {
                'id': id,
                'hostLabel': u.host == 'local' ? host.name : '${host.name} · ${u.host}',
                'provider': u.provider,
              });
      final byWindow = freshest.putIfAbsent(id, () => {});
      for (final w in u.windows) {
        if (!usageWindowSeconds.containsKey(w.window)) continue;
        final cur = byWindow[w.window];
        if (cur == null || w.asOf.isAfter(cur.asOf)) byWindow[w.window] = w;
      }
    }
  }
  return {
    'writtenAt': (writtenAt ?? DateTime.now()).toUtc().toIso8601String(),
    'rings': [
      // A ring with no known window is dropped so both widgets see the same rings.
      for (final e in rings.entries)
        if (freshest[e.key]!.isNotEmpty)
          {
            ...e.value,
            'windows': [
              for (final w in freshest[e.key]!.values)
                {
                  'window': w.window,
                  'windowSeconds': usageWindowSeconds[w.window],
                  // One rounding here so iOS and Android show the same integer.
                  'usedPercent': w.usedPercent.round(),
                  'resetsAt': w.resetsAt.toUtc().toIso8601String(),
                  'asOf': w.asOf.toUtc().toIso8601String(),
                },
            ],
          },
    ],
  };
}

/// The `usage_hosts_v1` contract: where the native background fetchers GET
/// `/api/provider/status` from. No secrets; the daemon takes no app token.
Map<String, Object?> usageHostsJson(List<Host> hosts) => {
      'hosts': [
        for (final h in hosts) {'id': h.id, 'label': h.name, 'daemonBase': h.daemonBase.toString()},
      ],
    };

/// The latest readings from every host, for the in-app usage strip.
/// [UsageRingsRefresher] fills it; the strip asks for a fetch when it's
/// empty or older than [UsageRingsRefresher.interval].
class UsageNow extends ValueNotifier<List<(Host, List<HostUsage>)>> {
  UsageNow() : super(const []);

  DateTime? at;
  Future<void>? _inFlight;

  bool get stale => at == null || DateTime.now().difference(at!) > UsageRingsRefresher.interval;

  void set(List<(Host, List<HostUsage>)> readings) {
    at = DateTime.now();
    value = readings;
  }

  /// Fetches every host's usage (each host best effort).
  Future<void> fetch(List<Host> hosts) => _inFlight ??= () async {
        try {
          set(await fetchUsage(hosts));
        } finally {
          _inFlight = null;
        }
      }();

  @visibleForTesting
  void reset() {
    at = null;
    value = const [];
  }
}

final usageNow = UsageNow();

/// Every host's provider usage; a host that does not answer reads as empty.
Future<List<(Host, List<HostUsage>)>> fetchUsage(List<Host> hosts) => Future.wait(hosts.map((h) async {
      final client = OpenRigClient.create(h);
      try {
        return (h, await client.providerUsage());
      } catch (e) {
        logWarning('usage rings: ${h.name}: $e');
        return (h, const <HostUsage>[]);
      } finally {
        client.close();
      }
    }));

/// One window of one ring, with where its pace is.
class UsageReading {
  UsageReading({required this.window, required this.windowSeconds, required this.usedPercent, required this.resetsAt, required this.asOf});
  final String window;
  final int windowSeconds;
  final int usedPercent;
  final DateTime resetsAt;
  final DateTime asOf;

  String get label => window == 'weekly' ? 'week' : '5h';

  /// How far through the window we are, 0..1: where even use would be now.
  double pace(DateTime now) =>
      (1 - resetsAt.difference(now).inMilliseconds / (windowSeconds * 1000)).clamp(0.0, 1.0).toDouble();

  /// Used minus pace, in percent points: positive means burning faster than the window allows.
  int ahead(DateTime now) => usedPercent - (pace(now) * 100).round();

  bool stale(DateTime now) => now.difference(asOf) > const Duration(hours: 1);

  /// "2h 10m", "3d 4h", "now".
  String resetsIn(DateTime now) {
    final left = resetsAt.difference(now);
    if (left.inMinutes < 1) return 'now';
    if (left.inHours < 1) return '${left.inMinutes}m';
    if (left.inDays < 1) return '${left.inHours}h ${(left.inMinutes % 60).toString().padLeft(2, '0')}m';
    return '${left.inDays}d ${left.inHours % 24}h';
  }
}

/// One host + provider, with its 5-hour and weekly readings.
class UsageRing {
  UsageRing({required this.hostLabel, required this.provider, required this.windows});
  final String hostLabel;
  final String provider;
  final List<UsageReading> windows;

  String get providerLabel => provider.isEmpty ? provider : '${provider[0].toUpperCase()}${provider.substring(1)}';

  /// The same rings the home-screen widgets draw, from [usageRingsJson].
  static List<UsageRing> from(List<(Host, List<HostUsage>)> readings) {
    final json = usageRingsJson(readings);
    return [
      for (final r in (json['rings'] as List).cast<Map<String, Object?>>())
        UsageRing(
          hostLabel: r['hostLabel'] as String,
          provider: r['provider'] as String,
          windows: [
            for (final w in (r['windows'] as List).cast<Map<String, Object?>>())
              UsageReading(
                window: w['window'] as String,
                windowSeconds: w['windowSeconds'] as int,
                usedPercent: w['usedPercent'] as int,
                resetsAt: DateTime.parse(w['resetsAt'] as String),
                asOf: DateTime.parse(w['asOf'] as String),
              ),
          ]..sort((a, b) => a.windowSeconds.compareTo(b.windowSeconds)),
        ),
    ];
  }
}

/// Fetches usage from every stored host and writes the contract JSON to the
/// widgets' shared storage: on start, on resume and every 5 minutes while
/// the app is in the foreground. A host that does not answer is skipped.
/// The host list goes to storage too, on every refresh and whenever it changes.
class UsageRingsRefresher with WidgetsBindingObserver {
  UsageRingsRefresher(this.store);

  static const key = 'usage_rings_v1';
  static const hostsKey = 'usage_hosts_v1';
  static const appGroupId = 'group.dev.pocketrig.pocketRig';
  static const interval = Duration(minutes: 5);

  final HostStore store;
  Timer? _timer;

  Future<void> start() async {
    try {
      await HomeWidget.setAppGroupId(appGroupId);
    } catch (e) {
      logWarning('usage rings: app group: $e');
    }
    WidgetsBinding.instance.addObserver(this);
    _ids = {for (final h in store.hosts) h.id};
    store.addListener(_onStore);
    _resume();
  }

  void dispose() {
    _timer?.cancel();
    store.removeListener(_onStore);
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resume();
    } else {
      _timer?.cancel();
    }
  }

  void _resume() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => refresh());
    refresh();
  }

  Set<String> _ids = {};

  /// The host list changed: write it, and when hosts came or went (one turned on or off) read usage again now, not
  /// at the next tick.
  void _onStore() {
    final ids = {for (final h in store.hosts) h.id};
    final changed = !(ids.length == _ids.length && ids.containsAll(_ids));
    _ids = ids;
    if (changed) {
      refresh();
    } else {
      writeHosts();
    }
  }

  /// Writes `usage_hosts_v1` for the native background fetchers.
  Future<void> writeHosts() async {
    try {
      await HomeWidget.saveWidgetData(hostsKey, jsonEncode(usageHostsJson(store.hosts)));
    } catch (e) {
      logWarning('usage rings: hosts: $e');
    }
  }

  /// One fetch-reduce-write pass; returns the JSON it wrote.
  Future<String> refresh() async {
    await writeHosts();
    final readings = await fetchUsage(store.hosts);
    usageNow.set(readings);
    final json = jsonEncode(usageRingsJson(readings));
    try {
      await HomeWidget.saveWidgetData(key, json);
      await HomeWidget.updateWidget(iOSName: 'PocketRigWidget', androidName: 'UsageRingsWidget');
      logDebug('usage rings written: $json');
    } catch (e) {
      logWarning('usage rings: shared storage: $e');
    }
    return json;
  }
}
