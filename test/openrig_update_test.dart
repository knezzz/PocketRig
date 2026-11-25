import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/host_setup.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';

void main() {
  final host = Host(id: 'h', name: 'mini', address: 'mini', sshUser: 'me', privateKeyPem: 'k');
  tearDown(() => SshExec.debugConnect = null);

  test('reads the installed and latest versions', () {
    // Real output from a Mac with 0.7.6 installed.
    expect(parseOpenRigVersions('0.7.6 (c00c6321)\n@@pocketrig-latest\n0.7.8\n'), ('0.7.6', '0.7.8'));
    expect(parseOpenRigVersions('@@pocketrig-latest\n0.7.8\n'), (null, '0.7.8'), reason: 'rig not installed');
    expect(parseOpenRigVersions('0.7.6 (c00c6321)\n@@pocketrig-latest\n'), ('0.7.6', null), reason: 'npm offline');
  });

  test('only restarts the daemon after npm installed', () {
    expect(openRigUpdateScript, startsWith('npm install -g @openrig/cli@latest 2>&1 && echo pocketrig-install-ok || exit 0; '));
    expect(openRigUpdateScript, contains('rig daemon stop 2>&1; rig daemon start 2>&1 && echo pocketrig-restart-ok'));
  });

  Future<Object> update(String out) async {
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async => out);
    try {
      return await updateOpenRig(host);
    } catch (e) {
      return e;
    }
  }

  test('reports the new version, or which step failed', () async {
    expect(await update('added 1 package\npocketrig-install-ok\nDaemon started\npocketrig-restart-ok\npocketrig-version 0.7.8\n'),
        '0.7.8');
    final denied = await update('npm error code EACCES\nnpm error path /usr/local/lib/node_modules\n');
    expect(denied, isA<OpenRigException>());
    expect('$denied', contains('Nothing was restarted'));
    expect('$denied', contains('EACCES'));
    final noStart = await update('pocketrig-install-ok\nError: port 7433 in use\npocketrig-version 0.7.8\n');
    expect('$noStart', contains('Installed OpenRig 0.7.8, but the daemon didn\'t start again'));
  });
}
