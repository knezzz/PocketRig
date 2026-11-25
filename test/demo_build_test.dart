import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/host_store.dart' show isDesktop;
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;

import '../tool/demo/main_demo.dart';
import 'golden/fixtures.dart';

void main() {
  test('the shipped app has no demo in it: the flag is off, and lib/ never mentions the demo entrypoint', () {
    expect(kDemoBuild, isFalse, reason: 'POCKETRIG_DEMO is off unless a build sets it');
    expect(demoThemeMode, isNull, reason: 'no forced theme unless a build sets one');
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      expect(f.readAsStringSync(), isNot(contains('main_demo')), reason: f.path);
      expect(f.readAsStringSync(), isNot(contains('POCKETRIG_DEMO')), reason: f.path);
    }
  });

  test('the demo setup: the fixture hosts (the second one offline), the Rigs home first, everything on show', () async {
    final store = await demoSetup();
    expect([for (final h in store.hosts) h.name], [homelab.name, macbook.name]);
    expect(AppShell.debugStartOnInbox, isFalse);
    expect([showLoose, showWorktrees, showBarRigs], [true, true, true]);
    // More than the boards have: two idle agents (3 and 25 minutes) in the running conveyor rig, a rig whose seats are all
    // idle in a project of its own, and the scan finds a subagent, a shell under an agent and project shells.
    expect([for (final n in nodes['r-conveyor']!) n['logicalId']], containsAll(['docs', 'archivist']));
    expect([for (final r in rigs) r['name']], contains('docs-sync'));
    // The wrapper that adds those links still answers everything else from the fixtures (the demo was offline without it).
    final ps = await OpenRigClient.factory(homelab).rigs();
    expect([for (final r in ps) r.name], containsAll(['conveyor', 'adversarial-review', 'docs-sync']));
    // conveyor's graph shows every link kind (the five with their own look and the two the fixtures have).
    final topo = await OpenRigClient.factory(homelab).topology('r-conveyor');
    expect({for (final e in topo.edges) e.kind},
        containsAll(['delegates_to', 'collaborates_with', 'can_observe', 'escalates_to', 'spawned_by', 'hands_off_to', 'reviewed_by']));
    final scan = await (await SshExec.debugConnect!(homelab)).run('cat loose.json; echo; echo @@pocketrig-subagents; echo; echo @@pocketrig-jobs');
    expect(scan, contains('@@sub\tsess-attacker'));
    expect(scan, contains('shell-snapshots'));
    expect(scan, contains('@@jobs\trp-app'));
    expect(scan, contains('eval \'dev server\''), reason: 'conveyor impl waits on a shell');
    expect(scan, contains('eval \'npm run dev\''), reason: 'a loose agent waits on a shell');
  });

  test('the empty variant is This Mac only and nothing on it; the stopped one has just the stopped rig', () async {
    isDesktop = true; // the Mac app: This Mac is always a host
    addTearDown(() => isDesktop = false);
    for (final variant in ['empty', 'stopped']) {
      final store = await demoSetup(variant: variant);
      expect([for (final h in store.hosts) h.isLocal], [true], reason: variant);
      expect([showLoose, showWorktrees, showBarRigs], [false, false, false], reason: 'no loose agents or extra rigs: $variant');
      final api = OpenRigClient.factory(store.hosts.single);
      final ps = await api.rigs();
      expect([for (final r in ps) r.name], variant == 'empty' ? isEmpty : ['research-team'], reason: variant);
      expect([for (final r in ps) r.status], variant == 'empty' ? isEmpty : ['stopped'], reason: variant);
    }
  });

  test('the demo app starts without deep links (so no push registration or notification dialog) and without the debug-panel button', () {
    final source = File('tool/demo/main_demo.dart').readAsStringSync();
    expect(source, contains('deepLinks: false'));
    expect(source, contains('debugOverlay.value = false'));
  });
}
