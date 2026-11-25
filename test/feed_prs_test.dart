import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';

void main() {
  test('refreshPrs looks up new folders at once and known ones only when stale', () async {
    final asked = <String>[];
    SshExec.debugConnect = (_) async => SshExec.fake((cmd) async {
          final dir = RegExp(r'/w/(\w+)').firstMatch(cmd)!.group(1)!;
          asked.add(dir);
          return '@@pocketrig-status\n# branch.head x\n@@pocketrig-numstat\n@@pocketrig-pr\n'
              '{"number": 7, "title": "Fix $dir", "state": "OPEN"}';
        });
    addTearDown(() => SshExec.debugConnect = null);
    final feed = HostFeed(Host(id: 'h', name: 'h', address: 'h', sshUser: 'u', privateKeyPem: 'k'));

    await feed.refreshPrs(['/w/a', '/w/a']);
    expect(asked, ['a']);
    expect(feed.prs['/w/a']?.title, 'Fix a');

    await feed.refreshPrs(['/w/a', '/w/b']);
    expect(asked, ['a', 'b'], reason: 'a is fresh, b is new');

    await feed.refreshPrs(['/w/a', '/w/b'], every: Duration.zero);
    expect(asked, ['a', 'b', 'a', 'b'], reason: 'stale: everything again');
  });
}
