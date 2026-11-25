import 'dart:convert';

import '../api/openrig_client.dart' show OpenRigException;
import '../models.dart';
import '../ssh/ssh_exec.dart';
import 'projects.dart' show shQuote;

/// One entry of a daemon's host registry (`~/.openrig/hosts.yaml`), as
/// `rig host list --json` prints it. Bearer fields are pointers (an env var
/// name or a file path), never token values.
class RegistryHost {
  const RegistryHost({
    required this.id,
    required this.transport,
    this.target,
    this.user,
    this.url,
    this.bearerEnv,
    this.bearerFile,
    this.notes,
    this.selected = false,
    this.status,
  });

  final String id;

  /// `ssh` or `http`; fixed once the entry exists.
  final String transport;
  final String? target, user, url, bearerEnv, bearerFile, notes;
  final bool selected;

  /// `reachable`, `unreachable` or `unknown`, when the daemon probed it.
  final String? status;

  bool get isSsh => transport == 'ssh';

  /// Where the entry points, for a row subtitle.
  String get where => isSsh ? '${user == null ? '' : '$user@'}${target ?? ''}' : url ?? '';

  static RegistryHost? fromJson(Object? j) {
    if (j is! Map) return null;
    String? s(String k) => j[k] is String && (j[k] as String).isNotEmpty ? j[k] as String : null;
    final id = s('id');
    if (id == null) return null;
    return RegistryHost(
      id: id,
      transport: s('transport') ?? 'ssh',
      target: s('target'),
      user: s('user'),
      url: s('url'),
      bearerEnv: s('bearer_env'),
      bearerFile: s('bearer_file'),
      notes: s('notes'),
      selected: j['selected'] == true,
      status: s('status'),
    );
  }
}

/// Reads `rig host list --json`: a bare array of entries, or `{hosts: [...]}`
/// as the daemon's GET /api/hosts sends it. Throws when it is neither.
List<RegistryHost> parseRegistryHosts(String out) {
  final Object? json;
  try {
    json = jsonDecode(out.trim());
  } catch (_) {
    throw OpenRigException('rig host list didn\'t print JSON: ${_tail(out)}');
  }
  final rows = json is List ? json : (json is Map && json['hosts'] is List ? json['hosts'] as List : null);
  if (rows == null) throw OpenRigException('rig host list printed something unexpected: ${_tail(out)}');
  return rows.map(RegistryHost.fromJson).whereType<RegistryHost>().toList();
}

String _tail(String s) => s.trim().split('\n').take(4).join('\n');

/// Runs `rig host <args>` on [host] over SSH and returns its output. The
/// command is `sh`-quoted; a nonzero exit puts rig's own message in the error.
class RegistryClient {
  RegistryClient(this.host);
  final Host host;

  static const _ok = 'pocketrig-host-ok';

  /// [anyExit]: return the output whatever the exit code (doctor exits 1 when a step fails).
  Future<String> _rig(List<String> args, {bool anyExit = false}) async {
    return SshExec.use(host, (ssh) async {
      final cmd = 'rig host ${args.map(shQuote).join(' ')} 2>&1 ${anyExit ? ';' : '&&'} echo $_ok';
      final out = await ssh.runLogin(cmd);
      if (!out.contains(_ok)) throw OpenRigException(_tail(out).isEmpty ? 'rig printed nothing.' : _tail(out));
      return out.replaceAll(_ok, '');
    });
  }

  Future<List<RegistryHost>> list() async => parseRegistryHosts(await _rig(['list', '--json']));

  /// An empty value leaves the flag off.
  Future<void> add({
    required String id,
    required String transport,
    String? target,
    String? user,
    String? url,
    String? bearerEnv,
    String? bearerFile,
    String? notes,
  }) async {
    String? v(String? s) => s == null || s.trim().isEmpty ? null : s.trim();
    final flags = {
      '--target': v(target),
      '--user': v(user),
      '--url': v(url),
      '--bearer-env': v(bearerEnv),
      '--bearer-file': v(bearerFile),
      '--notes': v(notes),
    };
    await _rig([
      'add',
      '--id', id.trim(),
      '--transport', transport,
      for (final e in flags.entries)
        if (e.value != null) ...[e.key, e.value!],
    ]);
  }

  /// Only the fields that apply to the entry's transport; an empty string
  /// clears `user` and `notes`.
  Future<void> edit(RegistryHost h, {String? target, String? user, String? url, String? notes}) => _rig([
        'edit',
        h.id,
        if (h.isSsh) ...['--target', target?.trim() ?? '', '--user', user?.trim() ?? ''] else ...['--url', url?.trim() ?? ''],
        '--notes', notes?.trim() ?? '',
      ]);

  Future<void> remove(String id) => _rig(['remove', id]);

  Future<void> select(String id) => _rig(['select', id]);

  /// Blocks until the target's person approves (up to [timeoutSeconds]).
  Future<String> pair(String address, {String? id, int timeoutSeconds = 600}) =>
      _rig(['pair', address.trim(), if (id != null && id.trim().isNotEmpty) ...['--id', id.trim()], '--timeout', '$timeoutSeconds']);

  Future<String> doctor(String id) => _rig(['doctor', id], anyExit: true);
}
