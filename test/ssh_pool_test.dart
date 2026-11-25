import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/api/openrig_client.dart' show OpenRigException;
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';

class FakeClient implements SSHClient {
  bool closed = false;
  Duration? slowPing;
  bool hung = false; // a silently dead link: ping never answers
  @override
  bool get isClosed => closed;
  @override
  Future<void> ping() =>
      hung ? Completer<void>().future : (slowPing == null ? Future.value() : Future.delayed(slowPing!));
  final hungRun = Completer<Uint8List>();
  @override
  Future<SftpClient> sftp() => Completer<SftpClient>().future; // never answers
  @override
  Future<Uint8List> run(String command,
          {bool runInPty = false, bool stdout = true, bool stderr = true, SSHPtyConfig? pty, Map<String, String>? environment}) =>
      hungRun.future;
  @override
  Future<void> close() async {
    closed = true;
    if (!hungRun.isCompleted) hungRun.complete(Uint8List(0)); // as dartssh2 does
  }
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Host host([String id = 'h']) => Host(id: id, name: id, address: 'a', sshUser: 'u');

void main() {
  late List<FakeClient> made;
  SshPool pool({int max = 8}) => SshPool(busyPing: const Duration(milliseconds: 300), (h) async {
        final c = FakeClient();
        made.add(c);
        return c;
      }, maxLeases: max);
  setUp(() => made = []);

  test('a second lease reuses the connection', () async {
    final p = pool();
    final a = await p.lease(host());
    p.release(a);
    final b = await p.lease(host());
    expect(b, same(a));
    expect(made, hasLength(1));
  });

  test('parallel first leases share one connect; hosts do not share', () async {
    final p = pool();
    final both = await Future.wait([p.lease(host()), p.lease(host())]);
    expect(both[0], same(both[1]));
    await p.lease(host('other'));
    expect(made, hasLength(2));
  });

  test('past the lease limit it opens another connection', () async {
    final p = pool(max: 2);
    final cs = [for (var i = 0; i < 3; i++) await p.lease(host())];
    expect(made, hasLength(2));
    expect(cs[2], isNot(same(cs[0])));
  });

  test('a dead link is dropped by failed(), even while a lease is held', () async {
    final p = pool();
    final a = await p.lease(host());
    (a as FakeClient).hung = true;
    await p.failed(a); // the 3 s ping times out
    expect(a.closed, isTrue);
    expect(p.open, 0);
    final live = await p.lease(host());
    await p.failed(live);
    expect((live as FakeClient).closed, isFalse, reason: 'a live client stays');
  });

  test('SshExec.run on a dead link throws within the watchdog window instead of hanging', () async {
    final p = pool();
    final old = (SshExec.pool, SshExec.watchdog);
    SshExec.pool = p;
    SshExec.watchdog = const Duration(milliseconds: 100);
    addTearDown(() {
      SshExec.pool = old.$1;
      SshExec.watchdog = old.$2;
    });
    final c = await p.lease(host()) as FakeClient..hung = true;
    await expectLater(SshExec.over(c, host()).run('echo hi').timeout(const Duration(seconds: 10)), throwsA(isA<OpenRigException>()));
    expect(c.closed, isTrue);
    expect(p.open, 0);
  });

  test('SFTP on a dead link under a held lease throws too, and a held lease is still pinged by the next lease', () async {
    final p = pool();
    final old = (SshExec.pool, SshExec.watchdog);
    SshExec.pool = p;
    SshExec.watchdog = const Duration(milliseconds: 100);
    addTearDown(() {
      SshExec.pool = old.$1;
      SshExec.watchdog = old.$2;
    });
    final c = await p.lease(host()) as FakeClient..hung = true; // still held: never released
    await expectLater(SshExec.over(c, host()).download('/x.png').timeout(const Duration(seconds: 10)), throwsA(isA<OpenRigException>()));
    expect(c.closed, isTrue);

    final p2 = SshPool((h) async {
      final n = FakeClient();
      made.add(n);
      return n;
    }, staleAfter: Duration.zero);
    final held = await p2.lease(host()); // the tunnel's lease, kept
    (held as FakeClient).hung = true;
    final next = await p2.lease(host());
    expect(next, isNot(same(held)), reason: 'the dead client is replaced although a lease is held');
  });

  test('a slow ping (a transfer in progress) does not drop a healthy client', () async {
    final p = SshPool(busyPing: const Duration(seconds: 2), (h) async => FakeClient());
    final c = await p.lease(host()) as FakeClient;
    c.slowPing = const Duration(milliseconds: 500);
    expect(await p.failed(c), isFalse);
    expect(c.closed, isFalse);
  });

  test('an idle client is pinged before reuse and replaced when it is dead', () async {
    final p = SshPool((h) async {
      final c = FakeClient();
      made.add(c);
      return c;
    }, staleAfter: Duration.zero);
    final a = await p.lease(host());
    p.release(a);
    (a as FakeClient).hung = true;
    final b = await p.lease(host());
    expect(b, isNot(same(a)));
  });

  test('a connection the server closed is replaced', () async {
    final p = pool();
    final a = await p.lease(host());
    p.release(a);
    (a as FakeClient).closed = true;
    final b = await p.lease(host());
    expect(b, isNot(same(a)));
    expect(p.open, 1);
  });

  test('released while closed is dropped; a failed connect leaves nothing behind', () async {
    final p = pool();
    final a = await p.lease(host());
    (a as FakeClient).closed = true;
    p.release(a);
    expect(p.open, 0);

    final bad = SshPool((h) async => throw StateError('no route'));
    await expectLater(bad.lease(host()), throwsStateError);
    expect(bad.open, 0);
  });

  test('it closes after sitting idle, not while leased', () async {
    final p = SshPool((h) async => FakeClient(), idleAfter: const Duration(milliseconds: 60));
    final c = await p.lease(host()) as FakeClient;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(c.closed, isFalse, reason: 'still leased');
    p.release(c);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.closed, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(c.closed, isTrue);
    expect(p.open, 0);
  });
}
