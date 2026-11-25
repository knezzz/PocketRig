import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';

import 'golden/fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a ~ pin is stored as the host path, so it and the rigs running there are one project', () async {
    final store = await installFakes();
    final host = store.hosts.firstWhere((h) => h.id == homelab.id);
    addTearDown(() => host.pinnedFolders = ['~/dotfiles']); // the fixture host is shared
    await store.pinFolder(host, '~/code/atlas');
    expect(host.pinnedFolders, contains('/Users/me/code/atlas'));
    expect(host.pinnedFolders, isNot(contains('~/code/atlas')));
  });

  test('pins saved with ~ are resolved once the host answers; an unreachable host keeps them as typed', () async {
    final store = await installFakes();
    final host = store.hosts.firstWhere((h) => h.id == homelab.id);
    addTearDown(() => host.pinnedFolders = ['~/dotfiles']); // the fixture host is shared
    expect(host.pinnedFolders, ['~/dotfiles'], reason: 'the fixture pins it with ~');

    final reach = SshExec.debugConnect;
    SshExec.debugConnect = (_) async => throw Exception('offline');
    await store.resolvePins(host);
    expect(host.pinnedFolders, ['~/dotfiles']);

    SshExec.debugConnect = reach;
    await store.resolvePins(host);
    expect(host.pinnedFolders, ['/Users/me/dotfiles']);
  });

  test('a pin made while ~ pins resolve is kept', () async {
    final store = await installFakes();
    final host = store.hosts.firstWhere((h) => h.id == homelab.id);
    addTearDown(() => host.pinnedFolders = ['~/dotfiles']); // the fixture host is shared
    final resolving = store.resolvePins(host);
    host.pinnedFolders.add('/w/new'); // pinned while the host is still answering
    await resolving;
    expect(host.pinnedFolders, ['/Users/me/dotfiles', '/w/new']);
  });
}
