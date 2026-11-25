import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../models.dart';
import '../ssh/ssh_exec.dart';

/// How the app reaches a host's daemon: straight to `address:daemonPort` over
/// Tailscale, or through the host's SSH connection to `127.0.0.1:daemonPort`.
///
/// The daemon always listens on loopback, but it only binds the tailnet
/// address when it sees Tailscale at startup, and a Tailscale forward to it
/// can break while sshd keeps answering. When the direct route fails and SSH
/// works, requests go through SSH until the direct route answers again.
class DaemonRoute {
  DaemonRoute._(this._hostId);

  static final _routes = <String, DaemonRoute>{};

  /// The shared route for [host]: one per host, so every screen agrees.
  static DaemonRoute of(Host host) => _routes.putIfAbsent(host.id, () => DaemonRoute._(host.id));

  /// Forgets every route (tests).
  @visibleForTesting
  static void reset() {
    for (final r in _routes.values) {
      r._tunnel?.close();
    }
    _routes.clear();
  }

  final String _hostId;
  bool _viaSsh = false;
  DateTime _lastDirectTry = DateTime.fromMillisecondsSinceEpoch(0);
  Future<bool>? _deciding;
  _SshTunnel? _tunnel;

  /// While on SSH, the direct route is tried again this often.
  static const directRetry = Duration(seconds: 60);

  /// True while requests go through SSH.
  bool get viaSsh => _viaSsh;

  /// Listeners hear when the route changes (the Hosts screen shows it).
  final _changes = StreamController<bool>.broadcast();
  Stream<bool> get changes => _changes.stream;

  void _set(bool viaSsh) {
    if (_viaSsh == viaSsh) return;
    _viaSsh = viaSsh;
    _changes.add(viaSsh);
    if (!viaSsh) {
      _tunnel?.close();
      _tunnel = null;
    }
  }

  _SshTunnel _tunnelFor(Host host) => _tunnel ??= _SshTunnel(host);

  /// An HttpClient whose every connection goes through SSH to the daemon on
  /// the host's loopback. Use it with [loopbackBase] URLs, so the daemon sees
  /// the same `Host: 127.0.0.1:<port>` as the `rig` CLI on that machine.
  HttpClient tunnelHttpClient(Host host) {
    return HttpClient()
      ..connectionFactory = (url, proxyHost, proxyPort) async {
        // Looked up per connection: a client can outlive a tunnel.
        final port = await _tunnelFor(host).localPort();
        return Socket.startConnect(InternetAddress.loopbackIPv4, port);
      };
  }

  /// Decides the route after a direct request failed to connect. True when
  /// it is now SSH. Concurrent failures share one decision.
  Future<bool> fallBack(Host host) {
    if (_viaSsh) return Future.value(true);
    return _deciding ??= _decide(host).whenComplete(() => _deciding = null);
  }

  Future<bool> _decide(Host host) async {
    if (host.privateKeyPem == null) return false;
    _lastDirectTry = DateTime.now();
    // A slow request isn't a dead route: only switch when a health check fails too.
    if (await _healthy(directHttpClient(), host.daemonBase)) return false;
    // The first request through the tunnel waits for the SSH handshake.
    final ok = await _healthy(tunnelHttpClient(host), loopbackBase(host), timeout: const Duration(seconds: 15));
    if (ok) {
      _set(true);
    } else {
      _tunnel?.close();
      _tunnel = null;
    }
    return ok;
  }

  /// While on SSH, tries the direct route now and then in the background
  /// and switches back as soon as it answers.
  void maybeRetryDirect(Host host) {
    if (!_viaSsh || _deciding != null) return;
    if (DateTime.now().difference(_lastDirectTry) < directRetry) return;
    _lastDirectTry = DateTime.now();
    _deciding = _healthy(directHttpClient(), host.daemonBase).then((ok) {
      if (ok) _set(false);
      return !ok;
    }).whenComplete(() => _deciding = null);
  }

  /// Turns the route back to direct (e.g. after the host's settings change).
  void resetToDirect() => _set(false);

  static Future<bool> _healthy(HttpClient client, Uri base, {Duration timeout = const Duration(seconds: 5)}) async {
    final c = IOClient(client);
    try {
      final res = await c.get(base.replace(path: '/healthz')).timeout(timeout);
      return res.statusCode < 400;
    } catch (_) {
      return false;
    } finally {
      c.close();
    }
  }

  /// The client for the direct route. Connecting gives up quickly so a dead
  /// route falls back to SSH in time.
  static HttpClient directHttpClient() => HttpClient()..connectionTimeout = const Duration(seconds: 5);

  /// The daemon's address as seen from the host itself.
  static Uri loopbackBase(Host host) => Uri(scheme: 'http', host: '127.0.0.1', port: host.daemonPort);

  @override
  String toString() => 'DaemonRoute($_hostId, ${_viaSsh ? 'ssh' : 'direct'})';
}

/// True for failures where the request never reached the daemon (or the
/// daemon never answered): worth trying another route. HTTP errors aren't.
bool isRouteFailure(Object e) =>
    e is SocketException ||
    e is TimeoutException ||
    e is HttpException ||
    e is http.ClientException;

/// An http.Client for one host's daemon that falls back to SSH.
///
/// Requests are addressed to `host.daemonBase` as usual. When the direct
/// route can't connect and SSH works, the request is sent again through SSH
/// (GETs only: a POST may already have run), and later requests go through
/// SSH until the direct route answers again.
class RoutedClient extends http.BaseClient {
  RoutedClient(this.host)
      : _route = DaemonRoute.of(host),
        _direct = IOClient(DaemonRoute.directHttpClient());

  final Host host;
  final DaemonRoute _route;
  final IOClient _direct;
  IOClient? _ssh;
  bool _closed = false;

  /// How long a direct GET may wait for response headers before the route
  /// is checked. The daemon's slowest reads take a few seconds.
  static const headerTimeout = Duration(seconds: 12);

  IOClient _sshClient() => _ssh ??= IOClient(_route.tunnelHttpClient(host));

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _route.maybeRetryDirect(host);
    if (_route.viaSsh) {
      try {
        return await _viaSsh(request);
      } catch (e) {
        // SSH dropped too (the phone changed networks): start over directly.
        if (!_closed && isRouteFailure(e)) _route.resetToDirect();
        rethrow;
      }
    }
    final retry = request.method == 'GET' && request is http.Request ? _copy(request) : null;
    try {
      final f = _direct.send(request);
      return await (request.method == 'GET' ? f.timeout(headerTimeout) : f);
    } catch (e) {
      if (_closed || !isRouteFailure(e)) rethrow;
      final switched = await _route.fallBack(host);
      if (!switched || retry == null) rethrow;
      return _viaSsh(retry);
    }
  }

  Future<http.StreamedResponse> _viaSsh(http.BaseRequest request) {
    final base = DaemonRoute.loopbackBase(host);
    final url = request.url.replace(scheme: base.scheme, host: base.host, port: base.port);
    final r = http.Request(request.method, url)
      ..headers.addAll(request.headers)
      ..followRedirects = request.followRedirects
      ..persistentConnection = request.persistentConnection;
    if (request is http.Request) r.bodyBytes = request.bodyBytes;
    return _sshClient().send(r);
  }

  static http.Request _copy(http.Request r) => http.Request(r.method, r.url)
    ..headers.addAll(r.headers)
    ..bodyBytes = r.bodyBytes
    ..followRedirects = r.followRedirects
    ..persistentConnection = r.persistentConnection;

  @override
  void close() {
    _closed = true;
    _direct.close();
    _ssh?.close();
  }
}

/// A loopback port on the phone that forwards each connection through one
/// SSH connection to `127.0.0.1:daemonPort` on the host. The SSH connection
/// opens on first use, reopens if it drops, and closes after a quiet spell.
class _SshTunnel {
  _SshTunnel(this.host);

  final Host host;
  ServerSocket? _server;
  Future<ServerSocket>? _binding;
  SSHClient? _client;
  Future<SSHClient>? _connecting;
  int _open = 0;
  Timer? _idle;
  bool _closed = false;

  static const idleClose = Duration(minutes: 2);

  Future<int> localPort() async => (await (_binding ??= _bind())).port;

  Future<ServerSocket> _bind() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_relay);
    return server;
  }

  Future<SSHClient> _ssh() async {
    final c = _client;
    if (c != null && !c.isClosed) return c;
    if (c != null) {
      sshPool.release(c); // give the dead lease back before taking a new one
      _client = null;
    }
    return _connecting ??= sshPool.lease(host).then((c) {
      _client = c;
      return c;
    }).whenComplete(() => _connecting = null);
  }

  Future<void> _relay(Socket socket) async {
    _idle?.cancel();
    _open++;
    void done() {
      _open--;
      if (_open > 0) return;
      // Closed while connections were still open: the last one out gives the lease back.
      if (_closed) {
        _closeSsh();
      } else {
        _idle = Timer(idleClose, _closeSsh);
      }
    }

    final SSHForwardChannel channel;
    SSHClient? client;
    try {
      client = await _ssh();
      // A link that died without closing hangs here: give up and let the pool check it.
      channel = await client.forwardLocal('127.0.0.1', host.daemonPort).timeout(const Duration(seconds: 10));
    } catch (_) {
      if (client != null) unawaited(sshPool.failed(client));
      socket.destroy();
      done();
      return;
    }
    var finished = false;
    void finish() {
      if (finished) return;
      finished = true;
      socket.destroy();
      channel.destroy();
      done();
    }

    // Host → phone: flush everything before closing the phone's side.
    unawaited(socket.addStream(channel.stream).then((_) => socket.close()).catchError((_) {}).whenComplete(finish));
    // Phone → host: half-close the channel when the phone is done sending.
    unawaited(channel.sink.addStream(socket).then((_) => channel.sink.close()).catchError((_) {}));
  }

  void _closeSsh() {
    if (_client case final c?) sshPool.release(c);
    _client = null;
  }

  /// Stops taking connections. Ones already open (a terminal, an event
  /// stream) keep their SSH lease until they end.
  void close() {
    _closed = true;
    _idle?.cancel();
    if (_open == 0) _closeSsh();
    _server?.close();
  }
}
