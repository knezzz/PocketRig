import '../models.dart';
import 'openrig_client.dart';

/// One client per host, kept while the host's connection settings stay the same.
final Map<String, (String, OpenRigClient)> _clients = {};

/// The host's client; a host whose address or port changed gets a new one, and the old one closes.
OpenRigClient cachedClient(Host host) {
  final key = '${host.address}|${host.daemonPort}';
  final existing = _clients[host.id];
  if (existing != null && existing.$1 == key) return existing.$2;
  if (existing != null) {
    // Let in-flight callers finish before the socket goes away.
    Future<void>.delayed(const Duration(seconds: 10), existing.$2.close);
  }
  final client = OpenRigClient.create(host);
  _clients[host.id] = (key, client);
  return client;
}

void resetCachedClients() => _clients.clear();
