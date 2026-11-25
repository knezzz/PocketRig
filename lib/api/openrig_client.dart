import 'dart:convert';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../data/rig_spec.dart';
import 'daemon_route.dart';
import '../data/usage_rings.dart';
import 'live_events.dart';
import 'sse.dart';
import 'wiretap_client.dart';
import '../models.dart';

/// Thrown for any daemon call that fails; the message is safe to show.
/// True when [e] says the connection was never made, so a request can't
/// have reached the daemon. Anything else (a timeout, a reset) is ambiguous.
bool neverConnected(Object e) {
  final m = e.toString();
  return const [
    'Connection refused',
    'Failed host lookup',
    'HTTP connection timed out', // HttpClient.connectionTimeout: before the request was written
    'No route to host',
    'Network is unreachable',
  ].any(m.contains);
}

class OpenRigException implements Exception {
  OpenRigException(this.message, {this.status, this.code, this.maybeSent = false});
  final String message;
  final int? status;

  /// A POST failed after it may have reached the daemon (a timeout, a reset
  /// mid-request): sending it again could deliver it twice.
  final bool maybeSent;

  /// The daemon's machine-readable `code`, e.g. `rig_not_found`.
  final String? code;
  @override
  String toString() => message;
}

/// Turns a daemon error body into one clear sentence. OpenRig has no single
/// envelope: `{error}`, `{error, code}`, `{ok:false, code, message,
/// guidance}`, and for a partial launch `error` is `{fact, consequence,
/// action}`.
String daemonErrorMessage(int status, Object? json, {String? host}) {
  final m = json is Map ? json : const {};
  final code = m['code'] is String
      ? m['code'] as String
      : (m['error'] is String && !(m['error'] as String).contains(' ') ? m['error'] as String : null);
  // An error that is only a code ('missing_closure_reason') is explained by the daemon's message beside it, when there is one.
  final raw = (code != null && m['error'] == code && m['message'] is String && (m['message'] as String).isNotEmpty
          ? m['message'] as String
          : null) ??
      describeErrorField(m['error']) ??
      (m['message'] is String ? m['message'] as String : null) ??
      (m['reason'] is String ? m['reason'] as String : null);
  final guidance = m['guidance'] is String ? ' ${m['guidance']}' : '';
  final friendly = switch (code) {
    'rig_not_found' => 'That rig no longer exists on the daemon. Pull to refresh.',
    'ambiguous_name' => 'More than one rig has that name. Stop or rename one of them, then try again.',
    'untrusted_host' => 'The daemon refused the name "${host ?? 'this host'}". Use its full MagicDNS name '
        '(name.tailXXXX.ts.net) or 100.x IP, or add the name to OPENRIG_ALLOWED_HOSTS on the host.',
    'unauthorized' => 'This host requires its owner token, which PocketRig doesn\'t have.',
    'conflict' => 'That launch is already in progress.',
    'rig_not_stopped' => 'The rig is still running. Stop it before restoring.',
    'rig_name_running' => 'A rig with that name is already running.',
    'pre_restore_validation_failed' => 'The snapshot can\'t be restored as it is: ${raw ?? 'validation failed'}.',
    'seat_not_found' || 'session_missing' => 'That seat isn\'t running any more. Pull to refresh.',
    'target_needs_input' => 'The seat is waiting on a prompt. Answer it first, then send.',
    'mid_work' => 'The seat is busy. Try again when it is idle.',
    'tmux_unavailable' => 'tmux isn\'t available to the daemon on the host.',
    'qitem_not_found' => 'That work item no longer exists.',
    'context_refresh_failed' => 'The daemon couldn\'t refresh context usage.',
    'not_found' => 'This daemon doesn\'t have that endpoint. Is it OpenRig 0.7.6 or newer?',
    'invalid_json' => 'The daemon couldn\'t read the request.',
    _ => null,
  };
  if (friendly != null) return friendly;
  if (raw != null && raw.isNotEmpty) return '$raw$guidance';
  return switch (status) {
    401 || 403 => 'The daemon refused the request ($status).',
    404 => 'Not found on the daemon.',
    409 => 'The daemon reported a conflict.',
    >= 500 => 'The daemon hit an error ($status). Check its log on the host.',
    _ => 'Daemon returned $status',
  };
}

/// Thin client for the OpenRig daemon's local HTTP API (default port 7433).
///
/// Every endpoint lives here so a daemon upgrade breaks one file. This API is
/// internal to OpenRig, not a published contract: pin the OpenRig version you
/// test against (see README).
class OpenRigClient {
  OpenRigClient(this.host, {http.Client? httpClient, this.eventSource})
      : _http = httpClient ?? newHttpClient(RoutedClient(host));

  /// Replaces GET /api/events (tests): events for [rigId], or all of them.
  final Stream<RigEvent> Function({String? rigId, int? replay, String? lastEventId})? eventSource;

  /// How the app makes a client for a host. Tests swap in a fake daemon.
  @visibleForTesting
  static OpenRigClient Function(Host host) factory = OpenRigClient.new;

  /// A client for [host] made by [factory].
  static OpenRigClient create(Host host) => factory(host);

  final Host host;
  final http.Client _http;
  /// Long enough for a dead direct route to fall back to SSH: a 5s connect,
  /// two 5s health checks and the SSH handshake (see [RoutedClient]).
  static const _timeout = Duration(seconds: 30);

  Uri _u(String path, [Map<String, String>? q]) => host.daemonBase.replace(path: path, queryParameters: q);

  Future<Object?> _get(String path, [Map<String, String>? q, Map<String, String>? headers]) async {
    final http.Response res;
    try {
      res = await _http.get(_u(path, q), headers: headers).timeout(_timeout);
    } catch (e) {
      throw OpenRigException(
          'Can\'t reach the daemon on ${host.address}:${host.daemonPort}, directly or over SSH. '
          'Is Tailscale on and the daemon running?');
    }
    return _decode(res);
  }

  Future<Object?> _post(String path, Map<String, Object?> body,
          {Duration timeout = const Duration(seconds: 30)}) async =>
      _decode(await _send(path, body, timeout));

  Future<http.Response> _send(String path, Map<String, Object?> body, Duration timeout) async {
    try {
      return await _http
          .post(_u(path), headers: {'content-type': 'application/json'}, body: jsonEncode(body))
          .timeout(timeout);
    } catch (e) {
      throw OpenRigException('Request to ${host.address} failed: $e', maybeSent: !neverConnected(e));
    }
  }

  Object? _decode(http.Response res) {
    Object? json;
    try {
      json = res.body.isEmpty ? null : jsonDecode(res.body);
    } catch (_) {
      json = null;
    }
    if (res.statusCode >= 400) {
      throw OpenRigException(daemonErrorMessage(res.statusCode, json, host: host.address),
          status: res.statusCode, code: json is Map && json['code'] is String ? json['code'] as String : null);
    }
    return json;
  }

  static List<Map<String, Object?>> _rows(Object? json, [String? key]) {
    final list = json is List ? json : (json is Map && key != null && json[key] is List ? json[key] : []);
    return (list as List).whereType<Map>().map((m) => m.cast<String, Object?>()).toList();
  }

  /// Daemon liveness: GET /healthz.
  Future<bool> healthy() async {
    try {
      final res = await _http.get(_u('/healthz')).timeout(_timeout);
      return res.statusCode < 400;
    } catch (_) {
      return false;
    }
  }

  /// The daemon's version from GET /healthz (`semver`), or null when the
  /// daemon is unreachable or an unstamped dev build.
  Future<String?> version() async {
    try {
      final res = await _http.get(_u('/healthz')).timeout(_timeout);
      final json = jsonDecode(res.body);
      return json is Map && json['semver'] is String ? json['semver'] as String : null;
    } catch (_) {
      return null;
    }
  }

  // ---- Core app job: /api/apps/v1 (OpenRig 0.7.22+, "answer a structured question") ----

  /// GET /api/apps/v1/capabilities. True only for the v1 contract that takes option and typed answers. A 401 means the
  /// route exists (it wants a credential): the job is there, so this asks without one and reads 401 as available.
  Future<bool> coreAppAvailable() async {
    try {
      final res = await _http.get(_u('/api/apps/v1/capabilities')).timeout(_timeout);
      if (res.statusCode == 401) return true;
      if (res.statusCode >= 400) return false;
      final j = jsonDecode(res.body);
      return j is Map && j['contract'] == 'openrig.core-app' && j['version'] == 1;
    } catch (_) {
      return false;
    }
  }

  /// The host's default registered person (`<id>@external`) from GET /api/gateway/participants, or null when no
  /// person is registered (`rig gateway human add` makes one).
  Future<String?> defaultPerson() async {
    final j = await _get('/api/gateway/participants');
    final d = j is Map ? j['default'] : null;
    final id = d is Map ? d['id'] : null;
    if (id is! String) return null;
    for (final p in _rows(j, 'participants')) {
      if (p['id'] == id && p['address'] is String) return p['address'] as String;
    }
    return '$id@external';
  }

  /// POST /api/apps/v1/credentials: a credential for [actor] to answer as. The token comes back once.
  Future<({String credentialId, String token})> issueAppCredential(String actor) async {
    final j = await _post('/api/apps/v1/credentials',
        {'appId': 'pocketrig', 'actors': [actor], 'job': 'human-answer', 'attribution': 'app-attributed'});
    final id = j is Map ? j['credentialId'] : null;
    final token = j is Map ? j['token'] : null;
    if (id is! String || token is! String) throw OpenRigException('The daemon didn\'t return a credential.');
    return (credentialId: id, token: token);
  }

  /// GET /api/apps/v1/needs-me: the structured asks waiting for [actor], as the daemon's request objects. A 401/403
  /// throws with that status (the stored credential is bad).
  Future<List<Map<String, Object?>>> appNeedsMe(String token, String actor) async {
    final j = await _get('/api/apps/v1/needs-me', {'actor': actor}, {'authorization': 'Bearer $token'});
    return _rows(j, 'requests');
  }

  /// One Core app call with the app's [token]: the status and decoded body, whatever the status (the caller reads 409s
  /// and 503s). Throws [OpenRigException] (with `maybeSent`) only when no response came.
  Future<({int status, Object? json})> appCall(String method, String path, String token,
      {Map<String, String>? query, Map<String, Object?>? body}) async {
    final headers = {'authorization': 'Bearer $token', if (body != null) 'content-type': 'application/json'};
    try {
      final res = await (method == 'POST'
              ? _http.post(_u(path, query), headers: headers, body: jsonEncode(body))
              : _http.get(_u(path, query), headers: headers))
          .timeout(_timeout);
      Object? json;
      try {
        json = res.body.isEmpty ? null : jsonDecode(res.body);
      } catch (_) {}
      return (status: res.statusCode, json: json);
    } catch (e) {
      throw OpenRigException('Request to ${host.address} failed: $e', maybeSent: method == 'POST' && !neverConnected(e));
    }
  }

  /// DELETE /api/apps/v1/credentials/:id, best effort.
  Future<void> revokeAppCredential(String credentialId) async {
    try {
      await _http.delete(_u('/api/apps/v1/credentials/${Uri.encodeComponent(credentialId)}')).timeout(_timeout);
    } catch (_) {}
  }

  /// GET /api/seat/status/:seatRef → `permissions.effective.effectiveMode`.
  /// Node rows don't carry the permission mode, so the sheet asks for it.
  Future<String?> permissionMode(Seat seat) async {
    final ref = seat.sessionName ?? seat.logicalId;
    final json = await _get('/api/seat/status/${Uri.encodeComponent(ref)}');
    if (json is! Map) return null;
    final perms = json['permissions'];
    if (perms is! Map) return null;
    final effective = perms['effective'];
    if (effective is Map && effective['effectiveMode'] is String) return effective['effectiveMode'] as String;
    final desired = perms['desired'];
    return desired is Map && desired['mode'] is String ? desired['mode'] as String : null;
  }

  /// GET /api/slices — every slice OpenRig tracks, across missions.
  Future<List<SliceSummary>> slices() async =>
      _rows(await _get('/api/slices', {'filter': 'all'}), 'slices').map(SliceSummary.fromJson).toList();

  /// GET /api/slices/:name — acceptance items, story and the rigs it touches.
  Future<SliceDetail> slice(String name) async {
    final json = await _get('/api/slices/${Uri.encodeComponent(name)}');
    if (json is! Map) throw OpenRigException('The daemon sent no slice $name.');
    return SliceDetail.fromJson(json.cast<String, Object?>());
  }

  /// GET /api/progress/tree — the PROGRESS.md files OpenRig indexes.
  Future<List<ProgressFile>> progressFiles() async =>
      _rows(await _get('/api/progress/tree'), 'files').map(ProgressFile.fromJson).toList();

  /// The spec file [rigId] was last launched from: the newest rig_spec run
  /// in GET /api/bootstrap (what `rig up <path>` records). Null without one.
  Future<String?> rigSpecSource(String rigId) async {
    final runs = _rows(await _get('/api/bootstrap'))
        .where((r) => r['rigId'] == rigId && r['sourceKind'] == 'rig_spec' && r['sourceRef'] is String)
        .toList()
      ..sort((a, b) => '${b['createdAt']}'.compareTo('${a['createdAt']}'));
    return runs.firstOrNull?['sourceRef'] as String?;
  }

  /// GET /api/ps — one row per rig.
  Future<List<Rig>> rigs() async => _rows(await _get('/api/ps')).map(Rig.fromJson).toList();

  /// GET /api/rigs/:rigId/nodes — the rig's seats.
  Future<List<Seat>> seats(String rigId) async =>
      _rows(await _get('/api/rigs/${Uri.encodeComponent(rigId)}/nodes'), 'nodes').map(Seat.fromJson).toList();

  /// Every rig with its seats. A rig [reuse] returns true for keeps the seats
  /// in [known]; the others are fetched [parallel] at a time, not all at once.
  Future<List<RigWithSeats>> rigsWithSeats(
      {Map<String, List<Seat>> known = const {}, bool Function(Rig)? reuse, int parallel = 3}) async {
    final rs = await rigs();
    final todo = [
      for (final r in rs)
        if (!(reuse?.call(r) == true && known.containsKey(r.id))) r
    ];
    final fetched = <String, List<Seat>>{};
    var next = 0;
    Future<void> worker() async {
      while (next < todo.length) {
        final r = todo[next++];
        try {
          fetched[r.id] = await seats(r.id);
        } catch (_) {
          fetched[r.id] = known[r.id] ?? <Seat>[];
        }
      }
    }

    await Future.wait([for (var i = 0; i < parallel; i++) worker()]);
    return [for (final r in rs) RigWithSeats(r, fetched[r.id] ?? known[r.id] ?? <Seat>[])];
  }

  /// GET /api/attention — open requests addressed to a person.
  /// Agents in tmux that OpenRig didn't launch. [scan] asks the daemon to
  /// look first (it only scans when asked).
  Future<List<LooseAgent>> discovered({bool scan = false}) async {
    if (scan) {
      try {
        await _post('/api/discovery/scan', const {}, timeout: const Duration(seconds: 15));
      } catch (_) {/* list what it has */}
    }
    return _rows(await _get('/api/discovery', {'status': 'active'}))
        .map(LooseAgent.fromDiscovery)
        .whereType<LooseAgent>()
        .toList();
  }

  /// Adopts a discovered session into [rigId] as a new member of a pod. The
  /// process keeps running; it becomes `<podNamespace>.<memberName>`.
  Future<String> adopt(String discoveryId,
      {required String rigId, required String podId, required String podNamespace, required String memberName}) async {
    final res = await _post('/api/discovery/${Uri.encodeComponent(discoveryId)}/adopt', {
      'rigId': rigId,
      'target': {'kind': 'pod', 'podId': podId, 'podNamespace': podNamespace, 'memberName': memberName},
    });
    return res is Map && res['logicalId'] is String ? res['logicalId'] as String : '$podNamespace.$memberName';
  }

  /// A person's address, not a seat's (the daemon's isHumanSeatSessionRef).
  static final _person = RegExp(r'^human(-[A-Za-z0-9._-]+)?@(kernel|host)$');

  /// GET /api/attention. An item's recipient is the person, so when it names
  /// no asker, the seat to open comes from the queue row it links to: the
  /// owner of work blocked on you, or the sender of an update to you.
  Future<List<AttentionItem>> attention() async {
    final rows = _rows(await _get('/api/attention'), 'items');
    return Future.wait(rows.map((j) async {
      final source = j['source'];
      if (j['asker'] == null && source is String && source.startsWith('/api/queue/')) {
        try {
          final q = await _get(source);
          if (q is Map) {
            final seat = [if (q['waiting'] is Map) q['waiting']['owner'], q['destinationSession'], q['sourceSession']]
                .whereType<String>()
                .where((s) => !_person.hasMatch(s))
                .firstOrNull;
            if (seat != null) j = {...j, 'asker': seat};
          }
        } catch (_) {/* shown without an asker */}
      }
      return AttentionItem.fromJson(j);
    }));
  }

  /// GET /api/provider/status → `hostUsage[]`: model-account usage per
  /// daemon host and provider (one row per seat session inside).
  Future<List<HostUsage>> providerUsage() async =>
      _rows(await _get('/api/provider/status'), 'hostUsage').map(HostUsage.fromJson).toList();

  /// POST /api/transport/send — the same delivery `rig send` uses.
  Future<void> send(String session, String text) async {
    final res = await _post('/api/transport/send', {
      'session': session,
      'text': text,
      'reason': 'sent from PocketRig',
    });
    if (res is Map && res['ok'] == false) {
      throw OpenRigException((res['error'] ?? res['reason'] ?? 'Send failed').toString());
    }
  }

  /// POST /api/transport/broadcast with `rig` — `rig broadcast --rig`: types
  /// [text] into every seat of the rig. One outcome per seat.
  Future<List<BroadcastOutcome>> broadcast(String rigName, String text) async => _rows(
          await _post('/api/transport/broadcast', {'rig': rigName, 'text': text, 'reason': 'sent from PocketRig'},
              timeout: const Duration(minutes: 1)),
          'results')
      .map(BroadcastOutcome.fromJson)
      .toList();

  /// GET /api/rigs/:rigId/chat/history — the rig's chat room, oldest first.
  Future<List<RoomMessage>> roomHistory(String rigId, {int limit = 100}) async =>
      _rows(await _get('/api/rigs/${Uri.encodeComponent(rigId)}/chat/history', {'limit': '$limit'}))
          .map(RoomMessage.fromJson)
          .toList();

  /// POST /api/rigs/:rigId/chat/send — posts to the room. Nobody is woken:
  /// seats read the room when they look.
  Future<void> roomSend(String rigId, String body) async =>
      _post('/api/rigs/${Uri.encodeComponent(rigId)}/chat/send', {'sender': 'pocketrig', 'body': body});

  /// POST /api/compaction/trigger — `rig compact`: the guided compaction
  /// (prepare, /compact, restore) for a Claude seat. Refused while it works.
  Future<void> compact(String session) async {
    final res = await _post('/api/compaction/trigger', {'session': session}, timeout: const Duration(minutes: 2));
    if (res is Map && res['ok'] == false) {
      throw OpenRigException((res['error'] ?? res['reason'] ?? 'Compaction was refused').toString());
    }
  }

  /// GET /api/watchdog/list — every watchdog job, stopped ones included.
  Future<List<WatchdogJob>> watchdogJobs() async =>
      _rows(await _get('/api/watchdog/list')).map(WatchdogJob.fromJson).toList();

  /// POST /api/watchdog/register — a `periodic-reminder` that sends [message]
  /// to [session] every [every].
  Future<void> addReminder(String session, String message, Duration every) => _post('/api/watchdog/register', {
        'policy': 'periodic-reminder',
        // JSON strings are valid YAML scalars, so the message needs no escaping.
        'specYaml': 'policy: periodic-reminder\ntarget:\n  session: ${jsonEncode(session)}\n'
            'context:\n  message: ${jsonEncode(message)}\n',
        'targetSession': session,
        'intervalSeconds': every.inSeconds,
        'registeredBySession': 'pocketrig',
      });

  /// POST /api/watchdog/:id/stop — `rig watchdog stop`.
  Future<void> stopWatchdog(String jobId) =>
      _post('/api/watchdog/${Uri.encodeComponent(jobId)}/stop', {'reason': 'stopped from PocketRig'});

  /// POST /api/seat/set-permissions — `rig seat set-permissions --mode`.
  /// Saved for the seat's next managed launch; the running session keeps its mode.
  Future<void> setPermissionMode(Seat seat, PermissionMode mode) async {
    final ref = seat.sessionName ?? seat.logicalId;
    await _post('/api/seat/set-permissions/${Uri.encodeComponent(ref)}', {
      'mode': mode.modeFor(seat),
      'reason': 'permission mode changed from PocketRig',
      'operator': 'pocketrig',
    });
  }

  /// POST /api/seat/launch — `rig seat launch --fresh --stop`: stops the
  /// seat and starts it again with its saved settings, in a new conversation.
  Future<void> relaunchSeat(Seat seat, {required String reason}) async {
    final ref = seat.sessionName ?? seat.logicalId;
    await _post('/api/seat/launch/${Uri.encodeComponent(ref)}', {
      'fresh': true,
      'stop': true,
      'reason': reason,
      'operator': 'pocketrig',
    }, timeout: const Duration(minutes: 2));
  }

  /// Starts a seat that failed to launch again (`rig seat launch <seat> --fresh`, with no `--stop`: nothing is running in it).
  Future<void> retrySeatLaunch(Seat seat) async {
    final ref = seat.sessionName ?? seat.logicalId;
    await _post('/api/seat/launch/${Uri.encodeComponent(ref)}', {
      'fresh': true,
      'reason': 'retry after a failed launch',
      'operator': 'pocketrig',
    }, timeout: const Duration(minutes: 2));
  }

  /// POST /api/up — what `rig up` does. [sourceRef] is an absolute RigSpec
  /// path on the host, or a rig name to restore a stopped rig from its last
  /// snapshot. With [plan] nothing is launched; the result lists the stages.
  /// Apply waits for the launch to finish, so it gets a long timeout.
  Future<LaunchResult> up(
    String sourceRef, {
    String? cwd,
    String? rigName,
    bool plan = false,
  }) async {
    final res = await _send(
      '/api/up',
      {
        'sourceRef': sourceRef,
        'plan': plan,
        // A phone has nobody at the daemon's console to approve stages.
        if (!plan) 'autoApprove': true,
        if (cwd != null) 'cwdOverride': cwd,
        if (rigName != null && rigName.isNotEmpty) 'rigName': rigName,
      },
      plan ? const Duration(seconds: 30) : const Duration(minutes: 4),
    );
    Object? json;
    try {
      json = res.body.isEmpty ? null : jsonDecode(res.body);
    } catch (_) {}
    // Failed and partial launches still describe what happened in the body.
    final result = LaunchResult.fromJson(json);
    if (res.statusCode >= 400 && result.stages.isEmpty) {
      throw OpenRigException(daemonErrorMessage(res.statusCode, json, host: host.address), status: res.statusCode);
    }
    return result;
  }

  /// POST /api/down — what `rig down` does. With [snapshot] the rig can be
  /// restored later with `up(rigName)`.
  Future<void> down(String rigId, {bool snapshot = true}) async {
    await _post('/api/down', {'rigId': rigId, 'snapshot': snapshot}, timeout: const Duration(minutes: 2));
  }

  /// POST /api/down with delete: `rig down --delete`. Stops the rig if it's
  /// running and removes its record, so it can't be restored.
  Future<void> deleteRig(String rigId) async {
    final r = await _post('/api/down', {'rigId': rigId, 'delete': true}, timeout: const Duration(minutes: 2));
    if (r is! Map || r['deleted'] != true) {
      final errors = r is Map && r['errors'] is List ? (r['errors'] as List).join('\n') : '';
      throw OpenRigException(errors.isEmpty ? 'The rig was not deleted.' : errors);
    }
  }

  /// DELETE /api/rigs/:rigId/nodes/:nodeRef — what `rig remove` does: takes the
  /// seat out of the running rig.
  Future<void> removeSeat(String rigId, String logicalId) async {
    try {
      _decode(await _http
          .delete(host.daemonBase.replace(
              path: '/api/rigs/${Uri.encodeComponent(rigId)}/nodes/${Uri.encodeComponent(logicalId)}'))
          .timeout(const Duration(seconds: 60)));
    } on OpenRigException {
      rethrow;
    } catch (e) {
      throw OpenRigException('Request to ${host.address} failed: $e');
    }
  }

  /// GET /api/rigs/:rigId — the rig's nodes and edges for the graph.
  Future<RigTopology> topology(String rigId) async =>
      RigTopology.fromJson(await _get('/api/rigs/${Uri.encodeComponent(rigId)}'));

  /// One row from /api/ps, refreshed (the rig screen's status line).
  Future<Rig?> rig(String rigId) async => (await rigs()).where((r) => r.id == rigId).firstOrNull;

  /// GET /api/queue/list — active work. `rig` matches sessions ending in
  /// `@<rigName>`, so it takes the rig's name, not its id.
  Future<List<QueueItem>> queue({String? rigName, String? session, int limit = 50}) async =>
      _rows(await _get('/api/queue/list', {
        if (rigName != null) 'rig': rigName,
        if (session != null) 'destinationSession': session,
        'activeOnly': '1',
        'compact': '1',
        'limit': '$limit',
      }))
          .map(QueueItem.fromJson)
          .toList();

  /// GET /api/queue/list for a rig (every rig when null), closed items
  /// included and with bodies: the handoffs between seats, newest first.
  Future<List<QueueItem>> queueHistory(String? rigName, {int limit = 200}) async =>
      _rows(await _get('/api/queue/list', {if (rigName != null) 'rig': rigName, 'limit': '$limit'}))
          .map(QueueItem.fromJson)
          .toList();

  /// POST /api/queue/create — `rig queue create`: durable work on [destination]'s queue (member@rig). The daemon
  /// records [sender] as a claimed actor, since the app has no seat identity. [id] is minted by the caller
  /// ([newQitemId]) and reused on retry: the daemon absorbs a repeat of the same id instead of adding a second row.
  Future<void> queueCreate({
    required String id,
    required String destination,
    required String body,
    String priority = 'routine',
    String sender = 'pocketrig',
  }) async {
    final first = body.trim().split('\n').first.trim();
    await _post('/api/queue/create', {
      'qitemId': id,
      'sourceSession': sender,
      'destinationSession': destination,
      'body': body.trim(),
      'summary': first.length > 80 ? '${first.substring(0, 79)}…' : first,
      'priority': priority,
    });
  }

  /// GET /api/queue/<id> — one item as it is now.
  Future<QueueItem?> queueItem(String id) async {
    final j = await _get('/api/queue/${Uri.encodeComponent(id)}');
    return j is Map<String, Object?> ? QueueItem.fromJson(j) : null;
  }

  /// POST /api/queue/<id>/handoff — `rig queue handoff`: the item closes as handed off and a successor appears on [toSession]
  /// (member@rig), so the history shows the move. The actor is a claimed one, as in [queueCreate].
  Future<void> queueReassign(String id, String toSession, {String sender = 'pocketrig'}) async {
    await _post('/api/queue/${Uri.encodeComponent(id)}/handoff', {
      'fromSession': sender,
      'toSession': toSession,
      'transitionNote': 'Reassigned from Pocket Rig',
    });
  }

  /// POST /api/queue/<id>/update to `done` — `rig queue update --state done --closure-reason`. [expectState] makes the daemon
  /// refuse when the item moved since it was read.
  Future<void> queueMarkDone(String id, String closureReason, {String? expectState, String sender = 'pocketrig'}) async {
    await _post('/api/queue/${Uri.encodeComponent(id)}/update', {
      'actorSession': sender,
      'state': 'done',
      'closureReason': closureReason,
      if (expectState != null) 'expectState': expectState,
      'transitionNote': 'Closed from Pocket Rig',
    });
  }

  /// The id the CLI mints: `qitem-<yyyyMMddHHmmss UTC>-<16 hex>`.
  static String newQitemId([DateTime? now, Random? random]) {
    final t = (now ?? DateTime.now()).toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final r = random ?? Random.secure();
    final hex = List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return 'qitem-${t.year}${two(t.month)}${two(t.day)}${two(t.hour)}${two(t.minute)}${two(t.second)}-$hex';
  }

  /// GET /api/queue/:id/transitions — an item's state changes, oldest first.
  Future<List<QueueTransition>> queueTransitions(String id) async =>
      _rows(await _get('/api/queue/${Uri.encodeComponent(id)}/transitions')).map(QueueTransition.fromJson).toList();

  /// POST /api/rigs/:rigId/snapshots — a manual snapshot. The response
  /// carries the whole snapshot; only its id is kept.
  Future<String?> snapshot(String rigId) async {
    final res = await _post('/api/rigs/${Uri.encodeComponent(rigId)}/snapshots', {'kind': 'manual'},
        timeout: const Duration(minutes: 1));
    return res is Map ? res['id'] as String? : null;
  }

  /// GET /api/events (SSE). With [rigId] only events that carry that rigId
  /// arrive (so not `seat.activity_changed`); [replay] sends the newest n
  /// past events first. Frames without JSON are skipped.
  Stream<RigEvent> events({String? rigId, int? replay, String? lastEventId}) =>
      eventSource?.call(rigId: rigId, replay: replay, lastEventId: lastEventId) ??
      openSse(
        _u('/api/events', {
          if (rigId != null) 'rigId': rigId,
          if (replay != null) 'replay': '$replay',
        }),
        lastEventId: lastEventId,
        client: () => newHttpClient(RoutedClient(host)),
      ).expand((f) {
        try {
          final j = jsonDecode(f.data);
          return j is Map ? [RigEvent.fromJson(j.cast<String, Object?>())] : const <RigEvent>[];
        } catch (_) {
          return const <RigEvent>[];
        }
      });

  /// The global event stream, shared by every screen (replay=0: only new
  /// events; a reconnect resumes with Last-Event-ID).
  late final LiveEvents live = LiveEvents((lastId) => events(replay: lastId == null ? 0 : null, lastEventId: lastId));

  void close() {
    live.close();
    _http.close();
  }
}
