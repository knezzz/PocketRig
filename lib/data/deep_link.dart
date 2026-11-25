import 'dart:math';

/// `pocketrig://seat/<session>?host=<name>` — what a notification opens.
class SeatLink {
  SeatLink(this.session, {this.host});
  final String session;
  final String? host;

  static SeatLink? parse(Uri uri) {
    if (uri.scheme != 'pocketrig' || uri.host != 'seat') return null;
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs.isEmpty) return null;
    final session = segs.join('/');
    final host = uri.queryParameters['host'];
    return SeatLink(session, host: host == null || host.isEmpty ? null : host);
  }

  String get logicalId => session.split('@').first;
  String? get rigName => session.contains('@') ? session.split('@').last : null;
}

/// `pocketrig://agent/<claude session id>?host=&tmux=&cwd=` — an agent
/// started by hand, outside a rig.
class AgentLink {
  AgentLink(this.id, {this.host, this.tmux, this.cwd});
  final String id;
  final String? host;
  final String? tmux;
  final String? cwd;

  static AgentLink? parse(Uri uri) {
    if (uri.scheme != 'pocketrig' || uri.host != 'agent') return null;
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs.isEmpty) return null;
    String? q(String k) => (uri.queryParameters[k]?.isEmpty ?? true) ? null : uri.queryParameters[k];
    return AgentLink(segs.first, host: q('host'), tmux: q('tmux'), cwd: q('cwd'));
  }
}

/// A hard-to-guess ntfy topic. Anyone who knows a topic on ntfy.sh can read
/// it, so it acts as the password.
String newNtfyTopic([Random? random]) {
  final r = random ?? Random.secure();
  const chars = 'abcdefghijkmnpqrstuvwxyz23456789';
  return 'pocketrig-${List.generate(16, (_) => chars[r.nextInt(chars.length)]).join()}';
}

bool validNtfyTopic(String t) => RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(t);
