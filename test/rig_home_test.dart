import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/host_store.dart' show isDesktop;
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/rig/rig_host.dart' show RigHost;
import 'package:pocket_rig/ui/rig_screen.dart' show RigScreen;
import 'package:pocket_rig/ui/tiles_screen.dart';

void main() {
  test('rigHome (the one first screen for a rig, the sidebar\'s too): the Mac shows a running rig\'s tiles, a stopped rig\'s page', () {
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    Rig rig(String status) => Rig(id: 'r', name: 'r', nodeCount: 0, runningCount: 0, attentionCount: 0, status: status);
    const key = ValueKey('h:r');
    final running = rigHome(RigWithSeats(rig('running'), const []), 'p', key: key);
    expect(running, isA<RigHost>());
    expect(running.key, key, reason: 'the caller\'s key reaches the tiles');
    expect(rigHome(RigWithSeats(rig('stopped'), const []), 'p', key: key), isA<RigScreen>(), reason: 'a stopped rig has no tiles');
    isDesktop = false;
    expect(rigHome(RigWithSeats(rig('running'), const []), 'p'), isA<RigScreen>(), reason: 'the phone opens the page');
  });
}
