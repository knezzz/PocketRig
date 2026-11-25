/// The order of the Rigs home: a project (and a rig in it, and an agent in a card) is sorted by its tier, then by name, and
/// its tier does not jump around.
///
/// Tiers: 0 needs you, 1 working, 2 shell running, 3 idle. Within tier 0 the one that has waited longest comes first; within
/// 1-3 by name, A to Z (never by activity time).
///
/// A promotion to needs you shows at once. Any other change of tier is held: it shows only once the new tier has lasted
/// [hold] without interruption, so a flicker between working and idle changes nothing, and an answered ask keeps its place
/// until the demotion has settled.
class StableTiers {
  StableTiers({this.hold = const Duration(minutes: 5), DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final Duration hold;
  final DateTime Function() _clock;

  /// The tier each key shows now.
  final Map<String, int> _shown = {};

  /// A different tier seen since when, waiting out [hold].
  final Map<String, (int, DateTime)> _pending = {};

  /// When each key's current or last ask began: the order inside tier 0 (kept after it is answered).
  final Map<String, DateTime> _askedAt = {};

  /// The tier [key] shows, given its [raw] tier now (and, when it needs you, since when).
  int tier(String key, int raw, {DateTime? askedAt}) {
    final now = _clock();
    if (raw == 0) {
      _shown[key] = 0;
      _pending.remove(key);
      if (askedAt != null) _askedAt[key] = askedAt;
      return 0;
    }
    final shown = _shown[key];
    if (shown == null) {
      _shown[key] = raw; // first sight: nothing to hold against
      return raw;
    }
    if (shown == raw) {
      _pending.remove(key);
      return shown;
    }
    final p = _pending[key];
    if (p == null || p.$1 != raw) {
      _pending[key] = (raw, now);
      return shown;
    }
    if (now.difference(p.$2) >= hold) {
      _shown[key] = raw;
      _pending.remove(key);
      return raw;
    }
    return shown;
  }

  /// When [key]'s ask began, as last seen; null if it never needed you.
  DateTime? askedAt(String key) => _askedAt[key];

  /// [items] in the home's order. [key] names an item for the memory, [raw] is its tier now, [asked] the start of its
  /// waiting ask (tier 0), [name] its sort name.
  List<T> sorted<T>(Iterable<T> items,
      {required String Function(T) key,
      required int Function(T) raw,
      required String Function(T) name,
      DateTime? Function(T)? asked}) {
    final entries = [
      for (final i in items) (i, tier(key(i), raw(i), askedAt: asked?.call(i))),
    ];
    entries.sort((a, b) {
      if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
      if (a.$2 == 0) {
        final x = _askedAt[key(a.$1)], y = _askedAt[key(b.$1)];
        if (x != null && y != null && x != y) return x.compareTo(y);
        if (x != null && y == null) return -1;
        if (x == null && y != null) return 1;
      }
      return name(a.$1).toLowerCase().compareTo(name(b.$1).toLowerCase());
    });
    return [for (final e in entries) e.$1];
  }

  /// Forgets everything (a test, or a host that went away).
  void reset() {
    _shown.clear();
    _pending.clear();
    _askedAt.clear();
  }
}

/// The one memory the Rigs home uses for the whole session.
final homeOrder = StableTiers();

/// Rig cards whose '+N idle' line is open, by rig key: remembered for the session.
final Set<String> homeIdleOpen = {};
