import 'package:flutter/material.dart';

import '../data/usage_rings.dart';
import '../main.dart';
import '../models.dart' show Host;
import 'kit.dart' show Panel;
import 'progress_bar.dart' show ProgressBar;
import 'theme.dart';

/// A fixed clock for the strip (goldens): pace is drawn from the time.
@visibleForTesting
DateTime? debugUsageClock;

/// Usage limits and pace, Settings › Usage: per account (host · provider) a
/// row for the 5-hour window and one for the week. The bar is what's used:
/// grey while on pace, orange when ahead. The tick is the pace (where even
/// use would be now). The heading names the window furthest ahead and when
/// it resets ("5h 11% ahead · resets 1h48"), in orange; else "on pace".
class UsageStrip extends StatefulWidget {
  const UsageStrip({super.key, this.now});

  /// Fixed clock (goldens).
  final DateTime? now;

  @override
  State<UsageStrip> createState() => _UsageStripState();
}

class _UsageStripState extends State<UsageStrip> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && usageNow.stale) usageNow.fetch(AppScope.read(context).hosts).catchError((_) {});
    });
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: usageNow,
        builder: (context, readings, _) {
          final rings = UsageRing.from(readings);
          if (rings.isEmpty) return const SizedBox.shrink();
          final now = widget.now ?? debugUsageClock ?? DateTime.now();
          return Panel(
            // 1 dp more than the Container's 14/12: its border took room, a Panel's does not.
            padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final (i, ring) in rings.indexed) ...[
                if (i > 0) const SizedBox(height: 12),
                _Account(ring: ring, now: now),
              ],
            ]),
          );
        },
      );
}

/// Ahead of pace by more than this many points reads as ahead; within it, on pace.
const _slack = 2;

/// Where [ahead] (percent points over pace) sits on the green → gray → red gradient, as (from, to, t) with stops
/// 0 green, 1 gray, 2 red: green at -5 or under, gray exactly on pace, red at +5 or over, linear between.
/// The same rule, and the same cases (test/fixtures/pace_colour.json), as the Live Activity and the home widgets.
(int, int, double) paceStops(int ahead) {
  if (ahead <= -5) return (0, 0, 0);
  if (ahead >= 5) return (2, 2, 0);
  return ahead < 0 ? (0, 1, (ahead + 5) / 5) : (1, 2, ahead / 5);
}

/// The percent text colour for [ahead] on the theme's green (`added`), gray (`muted`) and red (`removed`).
Color paceColor(int ahead, Tokens k) {
  final stops = [k.added, k.muted, k.removed];
  final (from, to, t) = paceStops(ahead);
  return Color.lerp(stops[from], stops[to], t)!;
}

/// Context used, in [percent]: neutral grey (`muted`) the whole way, red (`removed`) from 80 (orange is for needs-you only). One rule
/// for every place context shows (the seat bars, the sidebar rows, the seat details); the % text is bolder from 60 ([contextWeight]).
Color contextColor(double percent, Tokens k) => percent >= 80 ? k.removed : k.muted;

/// The % text of context in use: bolder from 60.
FontWeight? contextWeight(double percent) => percent >= 60 ? FontWeight.w700 : null;

/// What red means, in words, where a row has the room.
const compactsSoon = 'compacts soon';

class _Account extends StatelessWidget {
  const _Account({required this.ring, required this.now});
  final UsageRing ring;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final fresh = ring.windows.where((w) => !w.stale(now)).toList();
    final worst = fresh.isEmpty ? null : fresh.reduce((a, b) => b.ahead(now) > a.ahead(now) ? b : a);
    final hot = worst != null && worst.ahead(now) > _slack;
    final head = worst == null
        ? 'stale'
        : hot
            ? '${worst.label} ${worst.ahead(now)}% ahead · resets ${worst.resetsIn(now)}'
            : 'on pace';
    final account = '${ring.hostLabel} · ${ring.providerLabel}';
    return Semantics(
      label: '$account: $head. '
          '${ring.windows.map((w) => '${w.label} ${w.usedPercent}% used, resets in ${w.resetsIn(now)}').join('; ')}',
      excludeSemantics: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Expanded(
            child: Text(account,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: k.ink)),
          ),
          const SizedBox(width: 8),
          Text(head,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: hot ? FontWeight.w600 : FontWeight.w400,
                  color: worst == null ? k.muted : (hot ? k.accent : k.muted))),
        ]),
        const SizedBox(height: 6),
        for (final (i, w) in ring.windows.indexed) ...[
          if (i > 0) const SizedBox(height: 4),
          _Bar(reading: w, now: now),
        ],
      ]),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.reading, required this.now});
  final UsageReading reading;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final stale = reading.stale(now);
    final color = stale ? k.faint : paceColor(reading.ahead(now), k); // the fill and the % text share it
    return Row(children: [
      SizedBox(
          width: 42,
          child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(reading.label, maxLines: 1, style: mono(context, size: 11)))),
      const SizedBox(width: 8),
      Expanded(
        child: ProgressBar(
          value: reading.usedPercent / 100,
          tick: reading.pace(now),
          color: color,
          tickColor: stale ? k.faint : k.ink,
          height: 4,
          boxHeight: 12,
        ),
      ),
      const SizedBox(width: 8),
      SizedBox(
        width: 34,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerRight,
          child: Text('${reading.usedPercent}%',
              maxLines: 1,
              style: mono(context, size: 11, color: color).copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
        ),
      ),
    ]);
  }
}

/// A thin bar for one window of [host]'s usage ([UsageWindow] names: `five_hour`, `weekly`), drawn like the
/// strip's: green on pace, red when ahead, a tick at the pace. With several providers or sub-hosts it shows
/// the highest; with no reading for the window, nothing.
class HostUsageBar extends StatelessWidget {
  const HostUsageBar({super.key, required this.host, this.window = weekly, this.topGap = 0, this.asRow = false, this.now});
  static const fiveHour = 'five_hour';
  static const weekly = 'weekly';
  final Host host;
  final String window;

  /// Space above the bar, only when it draws one (or keeps its place, see [asRow]).
  final double topGap;

  /// A [rowHeight] row with the window's tiny label ("5h", "week") left of the bar, which keeps its space
  /// when there is no reading, so a header holding two rows never changes height.
  final bool asRow;
  static const rowHeight = 14.0;

  /// Fixed clock (tests, goldens).
  final DateTime? now;

  /// [host]'s [window] reading with its ring, or null with none: a fresh reading beats a stale one, then the
  /// highest wins (a stale 90% doesn't beat a fresh 40%).
  static (UsageRing, UsageReading)? _of(Host host, String window, [DateTime? now, String? provider]) {
    final t = now ?? debugUsageClock ?? DateTime.now();
    final all = [
      for (final ring in UsageRing.from([
        for (final r in usageNow.value)
          if (r.$1.id == host.id) r
      ]))
        if (provider == null || ring.provider == provider)
          for (final w in ring.windows)
          if (w.window == window) (ring, w),
    ];
    if (all.isEmpty) return null;
    return all.reduce((a, b) {
      final (sa, sb) = (a.$2.stale(t), b.$2.stale(t));
      return sa != sb ? (sa ? b : a) : (b.$2.usedPercent > a.$2.usedPercent ? b : a);
    });
  }

  /// The clock the bars read: fixed in tests and goldens.
  static DateTime clock() => debugUsageClock ?? DateTime.now();

  /// [host]'s Claude readings, the 5-hour then the weekly one, for the windows it has (a sidebar's rows).
  static List<UsageReading> claudeReadings(Host host, [DateTime? now]) => [
        for (final w in const [fiveHour, weekly])
          if (_of(host, w, now, 'claude') case final r?) r.$2,
      ];

  /// "Claude 5-hour usage 31%" / "Claude 7-day usage 62%": what a bar says to a screen reader, for rows that read it themselves.
  static String? labelFor(Host host, String window, [DateTime? now]) {
    final r = _of(host, window, now);
    return r == null ? null : '${r.$1.providerLabel} ${window == fiveHour ? '5-hour' : '7-day'} usage ${r.$2.usedPercent}%';
  }

  /// The 5-hour then the 7-day words, for the bars that have a reading.
  static List<String> labelsFor(Host host) => [
        for (final w in const [fiveHour, weekly])
          if (labelFor(host, w) case final l?) l,
      ];

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: usageNow,
        builder: (context, readings, _) {
          final found = _of(host, window, now);
          if (found == null) {
            return asRow ? SizedBox(height: topGap + rowHeight) : const SizedBox.shrink();
          }
          final w = found.$2;
          final t = now ?? debugUsageClock ?? DateTime.now();
          final k = Tokens.of(context);
          final bar = ProgressBar(
            value: w.usedPercent / 100,
            tick: w.pace(t),
            color: w.stale(t) ? k.faint : paceColor(w.ahead(t), k),
            tickColor: w.stale(t) ? k.faint : k.ink,
            track: k.border,
            height: 4,
          );
          return Padding(
            padding: EdgeInsets.only(top: topGap),
            child: Semantics(
              label: labelFor(host, window, now),
              excludeSemantics: true,
              child: asRow
                  ? SizedBox(
                      height: rowHeight,
                      child: Row(children: [
                        SizedBox(
                            width: 30,
                            child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(w.label, maxLines: 1, style: TextStyle(fontSize: 11, color: k.muted)))),
                        const SizedBox(width: 6),
                        Expanded(child: bar),
                      ]),
                    )
                  : bar,
            ),
          );
        },
      );
}

/// The 5-hour and week bars of one host, as rows with their labels, one above the other. Both rows are there
/// when the host has any reading (so the height never depends on which), none when it has none.
class HostUsageBars extends StatelessWidget {
  const HostUsageBars({super.key, required this.host, this.now});
  static const minWidth = 120.0;
  final Host host;
  final DateTime? now;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: usageNow,
        builder: (context, readings, _) => HostUsageBar.labelsFor(host).isEmpty
            ? const SizedBox.shrink()
            // 120 wide at least: next to a short count line ('1 project') each bar is still about 84.
            : ConstrainedBox(
                constraints: const BoxConstraints(minWidth: minWidth),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  HostUsageBar(host: host, window: HostUsageBar.fiveHour, topGap: 3, asRow: true, now: now),
                  HostUsageBar(host: host, topGap: 3, asRow: true, now: now),
                ]),
              ),
      );
}

/// A host's Claude usage as one compact line, '5h ▮▮▮ 71%  wk ▮▮ 34%': each bar in the pace colour with a tick at the pace, on a
/// hairline track, the resets in a tooltip. The sidebar's and the Rigs home's. Nothing for a host with no reading.
class HostUsageLine extends StatelessWidget {
  const HostUsageLine({super.key, required this.host});
  final Host host;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: usageNow,
        builder: (context, _, __) {
          final k = Tokens.of(context);
          final now = HostUsageBar.clock();
          final readings = HostUsageBar.claudeReadings(host, now);
          if (readings.isEmpty) return const SizedBox.shrink();
          return Tooltip(
            message: [for (final w in readings) '${w.label}: ${w.usedPercent}% used, resets in ${w.resetsIn(now)}'].join('\n'),
            child: Row(children: [
              for (final (i, w) in readings.indexed) ...[
                if (i > 0) const SizedBox(width: 10),
                Text(w.label == 'week' ? 'wk' : w.label, style: mono(context, size: 11, color: w.stale(now) ? k.faint : k.muted)),
                const SizedBox(width: 5),
                Expanded(
                  child: ProgressBar(
                      value: w.usedPercent / 100,
                      color: w.stale(now) ? k.faint : paceColor(w.ahead(now), k),
                      track: k.border,
                      tick: w.pace(now),
                      tickColor: w.stale(now) ? k.faint : k.ink,
                      height: 3,
                      boxHeight: 9),
                ),
                const SizedBox(width: 5),
                Text('${w.usedPercent}%',
                    style: mono(context, size: 11, color: w.stale(now) ? k.faint : paceColor(w.ahead(now), k))
                        .copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ]),
          );
        },
      );
}
