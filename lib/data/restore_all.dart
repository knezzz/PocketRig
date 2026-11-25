import 'dart:math' as math;

/// Runs [job] for every item, at most [limit] at a time (a pool: each finished job starts the next waiting one).
/// [job] must not throw: it reports its own failure.
Future<void> runPool<T>(List<T> items, int limit, Future<void> Function(T) job) async {
  var next = 0;
  Future<void> worker() async {
    while (next < items.length) {
      await job(items[next++]);
    }
  }

  await Future.wait([for (var i = 0; i < math.min(limit, items.length); i++) worker()]);
}
