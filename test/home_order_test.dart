import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/home_order.dart';

void main() {
  late DateTime now;
  late StableTiers order;
  setUp(() {
    now = DateTime(2026, 11, 23, 12);
    order = StableTiers(clock: () => now);
  });

  List<String> sort(Map<String, int> tiers, {Map<String, DateTime> asked = const {}}) => order.sorted(tiers.keys,
      key: (k) => k, raw: (k) => tiers[k]!, name: (k) => k, asked: (k) => asked[k]);

  test('tier, then name A to Z; needs you by the oldest ask first', () {
    final t0 = now;
    final got = sort({'zeta': 1, 'beta': 3, 'alpha': 1, 'late': 0, 'early': 0, 'shell': 2},
        asked: {'late': t0.add(const Duration(minutes: 3)), 'early': t0});
    expect(got, ['early', 'late', 'alpha', 'zeta', 'shell', 'beta']);
  });

  test('a flicker shorter than 5 minutes changes nothing; the change shows after it has held 5 minutes', () {
    expect(sort({'a': 1, 'b': 1}), ['a', 'b']);
    // b goes idle, then back to working inside 5 minutes: nothing moved.
    now = now.add(const Duration(minutes: 1));
    expect(sort({'a': 1, 'b': 3}), ['a', 'b']);
    now = now.add(const Duration(minutes: 3));
    expect(sort({'a': 1, 'b': 1}), ['a', 'b']);
    // a goes idle and stays idle: after 4m59s it still holds its place, at 5m it drops under b.
    now = now.add(const Duration(minutes: 1));
    expect(sort({'a': 3, 'b': 1}), ['a', 'b']);
    now = now.add(const Duration(minutes: 4, seconds: 59));
    expect(sort({'a': 3, 'b': 1}), ['a', 'b'], reason: '4m59s: not yet');
    now = now.add(const Duration(seconds: 1));
    expect(sort({'a': 3, 'b': 1}), ['b', 'a'], reason: 'held 5 minutes');
  });

  test('promotion to needs you shows at once, and an answered ask keeps its place until the demotion has held', () {
    sort({'a': 1, 'b': 1, 'c': 1});
    now = now.add(const Duration(seconds: 30));
    expect(sort({'a': 1, 'b': 1, 'c': 0}, asked: {'c': now}), ['c', 'a', 'b'], reason: 'at once');
    // answered: c is working again, but keeps the top until it has held 5 minutes.
    now = now.add(const Duration(minutes: 1));
    expect(sort({'a': 1, 'b': 1, 'c': 1}), ['c', 'a', 'b']);
    now = now.add(const Duration(minutes: 4));
    expect(sort({'a': 1, 'b': 1, 'c': 1}), ['c', 'a', 'b'], reason: '4 minutes after the answer');
    now = now.add(const Duration(minutes: 1));
    expect(sort({'a': 1, 'b': 1, 'c': 1}), ['a', 'b', 'c'], reason: 'settled by name');
  });

  test('a first sight is not held against anything', () {
    expect(sort({'new': 1}), ['new']);
    expect(order.tier('x', 3), 3);
  });
}
