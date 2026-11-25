import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pocket_rig/api/daemon_route.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';

Host host(int port, {String? key}) =>
    Host(id: 'h$port', name: 'mini', address: '127.0.0.1', sshUser: 'me', daemonPort: port, privateKeyPem: key);

/// flutter_test swaps HttpClient for one that answers 400 to everything;
/// these tests talk to a real local server, so they need the real client.
class _RealHttp extends HttpOverrides {}

void main() {
  setUpAll(() => HttpOverrides.global = _RealHttp());
  tearDown(DaemonRoute.reset);
  group('SSH address fallback', sshFallbackTests);

  test('the direct route is used while the daemon answers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) => req.response
      ..write('{"status":"ok"}')
      ..close());
    final h = host(server.port);
    final c = RoutedClient(h);
    final res = await c.get(h.daemonBase.replace(path: '/healthz'));
    expect(res.body, '{"status":"ok"}');
    expect(DaemonRoute.of(h).viaSsh, isFalse);
    c.close();
    await server.close();
  });

  test('without an SSH key a dead daemon fails as before and stays direct', () async {
    // Bind and free a port, so nothing listens on it.
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    final h = host(port);
    final c = RoutedClient(h);
    await expectLater(c.get(h.daemonBase.replace(path: '/healthz')), throwsA(isA<http.ClientException>()));
    expect(DaemonRoute.of(h).viaSsh, isFalse);
    c.close();
  });

  test('HTTP errors are answers, not route failures', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) => req.response
      ..statusCode = 404
      ..close());
    final h = host(server.port, key: 'not-used');
    final c = RoutedClient(h);
    final res = await c.get(h.daemonBase.replace(path: '/api/nope'));
    expect(res.statusCode, 404);
    expect(DaemonRoute.of(h).viaSsh, isFalse);
    c.close();
    await server.close();
  });

  test('route failures are connection problems only', () {
    expect(isRouteFailure(const SocketException('refused')), isTrue);
    expect(isRouteFailure(TimeoutException('slow')), isTrue);
    expect(isRouteFailure(http.ClientException('reset')), isTrue);
    expect(isRouteFailure(const FormatException('bad json')), isFalse);
  });

  test('requests through SSH are addressed to the daemon on loopback', () {
    final h = Host(id: 'x', name: 'mini', address: 'mini.tail1.ts.net', sshUser: 'me');
    expect(DaemonRoute.loopbackBase(h).toString(), 'http://127.0.0.1:7433');
  });
}

class _FakeSocket implements SSHSocket {
  _FakeSocket(this.address);
  final String address;
  @override
  Stream<Uint8List> get stream => const Stream.empty();
  @override
  StreamSink<List<int>> get sink => StreamController<List<int>>();
  @override
  Future<void> get done => Completer<void>().future;
  @override
  Future<void> close() async {}
  @override
  void destroy() {}

  // Anything else SSHSocket gains (e.g. flush) is unused by sshSocket().
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void sshFallbackTests() {
  final tried = <String>[];
  setUp(() {
    tried.clear();
    socketConnect = (address, port, timeout) async {
      tried.add(address);
      if (address.startsWith('100.')) throw const SocketException('tailnet down');
      return _FakeSocket(address);
    };
  });

  test('SSH falls back to the local network address when Tailscale does not answer', () async {
    final h = Host(id: 'lan1', name: 'mini', address: '100.64.0.5', lanAddress: '192.168.1.20', sshUser: 'me');
    final s = await sshSocket(h) as _FakeSocket;
    expect(s.address, '192.168.1.20');
    expect(tried, ['100.64.0.5', '192.168.1.20']);
    expect(sshOverLan(h), isTrue);
    // Within the minute the LAN goes first, so no second wait on the tailnet.
    tried.clear();
    await sshSocket(h);
    expect(tried, ['192.168.1.20']);
  });

  test('without a local address only the tailnet is tried', () async {
    final h = Host(id: 'lan2', name: 'mini', address: '100.64.0.5', sshUser: 'me');
    await expectLater(sshSocket(h), throwsA(isA<SocketException>()));
    expect(tried, ['100.64.0.5']);
    expect(sshOverLan(h), isFalse);
  });
}
