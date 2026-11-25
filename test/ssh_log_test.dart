import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_log.dart';

void main() {
  final host = Host(id: 'h', name: 'mac', address: '10.0.0.1', sshUser: 'me');
  setUp(SshLog.instance.clear);

  test('records a command, its output and duration', () async {
    final out = await SshLog.instance.track(host, 'uptime', () async => 'up 3 days', show: (s) => s);
    expect(out, 'up 3 days');
    final c = SshLog.instance.calls.single;
    expect(c.host, 'mac');
    expect(c.command, 'uptime');
    expect(c.output, 'up 3 days');
    expect(c.done, isTrue);
    expect(c.error, isNull);
  });

  test('records a failure and rethrows', () async {
    await expectLater(
      SshLog.instance.track<String>(host, 'false', () async => throw StateError('nope')),
      throwsA(isA<StateError>()),
    );
    final c = SshLog.instance.calls.single;
    expect(c.error, isA<StateError>());
    expect(c.done, isTrue);
  });
}
