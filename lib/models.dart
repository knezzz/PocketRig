/// Plain data types. Parsing is deliberately forgiving: the OpenRig daemon API
/// is internal and moves fast, so unknown or missing fields never throw.
library;

import 'package:yaml/yaml.dart';

import 'data/agent_jobs.dart';

String? _s(Object? v) => v is String && v.isNotEmpty ? v : null;

/// A host path as people write it: the home folder shown as `~`
/// (`/Users/me/code/app` → `~/code/app`).
String displayPath(String path) => path.replaceFirst(RegExp(r'^(/Users/[^/]+|/home/[^/]+|/root)(?=/|$)'), '~');
int _i(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);

/// One machine running the OpenRig daemon, reached over Tailscale.
class Host {
  Host({
    required this.id,
    required this.name,
    required this.address,
    this.lanAddress,
    this.daemonPort = 7433,
    this.sshPort = 22,
    required this.sshUser,
    this.privateKeyPem,
    this.keyPassphrase,
    List<String>? pinnedFolders,
    this.ntfyTopic,
    this.ntfyServer,
    this.hostKeyType,
    this.hostKeyFingerprint,
    Set<String>? notifyKinds,
    Map<String, String>? agentNames,
    Map<String, String>? specFolders,
    Map<String, String>? rigNames,
    this.color,
    this.enabled = true,
  })  : pinnedFolders = pinnedFolders ?? [],
        agentNames = agentNames ?? {},
        specFolders = specFolders ?? {},
        rigNames = rigNames ?? {},
        notifyKinds = notifyKinds ?? {...NotifyKind.defaults};

  /// Off hides the host app-wide and mutes its notifications; its whole record is kept, so turning it back on needs
  /// no re-pairing. Saved JSON without it is on.
  bool enabled;

  /// The color its name shows in, as ARGB; null picks one from the host's id (see `hostColor`).
  int? color;

  /// Which kinds of "needs you" this host notifies about (see [NotifyKind]).
  /// Sent to the host's watcher, and used for the in-app banner.
  Set<String> notifyKinds;

  /// The SSH host key seen on first connect (trust on first use), as
  /// OpenSSH prints it: `SHA256:…`. A different key later is refused.
  String? hostKeyType;
  String? hostKeyFingerprint;

  /// The ntfy topic the host's watcher posts to (M3); null when off.
  String? ntfyTopic;

  /// ntfy server; null means https://ntfy.sh.
  String? ntfyServer;

  String get ntfyBase => (ntfyServer ?? 'https://ntfy.sh').replaceFirst(RegExp(r'/+$'), '');

  /// Whether a deep link's `host=` names this host: its name, its address,
  /// or the address's first label (what `scutil --get LocalHostName` gives).
  bool matchesHint(String hint) {
    final h = hint.toLowerCase();
    final a = address.toLowerCase();
    return name.toLowerCase() == h || a == h || a.split('.').first == h || a.startsWith('$h.');
  }

  final String id;
  String name;

  /// Tailscale MagicDNS name (homelab.tailXXXX.ts.net) or 100.x IP. The daemon
  /// only answers requests addressed to its own names, so use the full name.
  String address;

  /// The host's address on the local network (e.g. 192.168.1.20), tried for
  /// SSH when [address] doesn't answer: Tailscale on the phone can stall
  /// after a network change while the LAN still works. The daemon isn't on
  /// the LAN, so it is then reached through SSH.
  String? lanAddress;
  int daemonPort;
  int sshPort;
  String sshUser;
  String? privateKeyPem;
  String? keyPassphrase;

  /// Folders to offer a shell in even when no rig runs there.
  List<String> pinnedFolders;

  /// Names given in the app to agents outside a rig, by [LooseAgent.id].
  /// shortcut: entries for ended agents are never pruned; prune when this grows noticeably.
  Map<String, String> agentNames;

  /// Project folder → another folder searched for its rig specs, for specs
  /// kept outside the project.
  Map<String, String> specFolders;

  /// Names given in the app to rigs, by rig name. The daemon can't rename a
  /// rig: its name is part of every seat's address.
  Map<String, String> rigNames;

  /// [rig]'s name in the app, or its own.
  String rigLabel(String rig) => rigNames[rig] ?? rig;

  /// A project shell's name in the app, or its tmux session name. Kept in [rigNames], keyed by the session.
  String shellLabel(String session) => rigNames[session] ?? session;

  Uri get daemonBase => Uri(scheme: 'http', host: address, port: daemonPort);

  /// The desktop app's own machine: commands run here, no SSH.
  static const localId = 'local';
  bool get isLocal => id == localId;

  /// This Mac, for the desktop app. No key, so the daemon never falls back to SSH.
  static Host local(String user) => Host(id: localId, name: 'This Mac', address: '127.0.0.1', sshUser: user);

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'address': address,
        'lanAddress': lanAddress,
        'daemonPort': daemonPort,
        'sshPort': sshPort,
        'sshUser': sshUser,
        'privateKeyPem': privateKeyPem,
        'keyPassphrase': keyPassphrase,
        'pinnedFolders': pinnedFolders,
        'ntfyTopic': ntfyTopic,
        'ntfyServer': ntfyServer,
        'hostKeyType': hostKeyType,
        'hostKeyFingerprint': hostKeyFingerprint,
        'notifyKinds': notifyKinds.toList(),
        'agentNames': agentNames,
        'specFolders': specFolders,
        'rigNames': rigNames,
        'color': color,
        'enabled': enabled,
      };

  factory Host.fromJson(Map<String, Object?> j) => Host(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'host',
        address: j['address'] as String? ?? '',
        lanAddress: _s(j['lanAddress']),
        daemonPort: _i(j['daemonPort']) == 0 ? 7433 : _i(j['daemonPort']),
        sshPort: _i(j['sshPort']) == 0 ? 22 : _i(j['sshPort']),
        sshUser: j['sshUser'] as String? ?? '',
        privateKeyPem: _s(j['privateKeyPem']),
        keyPassphrase: _s(j['keyPassphrase']),
        pinnedFolders: (j['pinnedFolders'] as List?)?.whereType<String>().toList() ?? [],
        ntfyTopic: _s(j['ntfyTopic']),
        ntfyServer: _s(j['ntfyServer']),
        hostKeyType: _s(j['hostKeyType']),
        hostKeyFingerprint: _s(j['hostKeyFingerprint']),
        notifyKinds: j['notifyKinds'] is List ? (j['notifyKinds'] as List).whereType<String>().toSet() : null,
        agentNames: _strMap(j['agentNames']),
        specFolders: _strMap(j['specFolders']),
        rigNames: _strMap(j['rigNames']),
        color: j['color'] is int ? j['color'] as int : null,
        enabled: j['enabled'] != false,
      );

  static Map<String, String>? _strMap(Object? m) =>
      m is Map ? {for (final e in m.entries) if (e.value is String) '${e.key}': e.value as String} : null;
}

/// A row from GET /api/ps.
class Rig {
  Rig({
    required this.id,
    required this.name,
    required this.nodeCount,
    required this.runningCount,
    required this.attentionCount,
    required this.status,
    this.uptime,
    this.latestSnapshot,
    this.autoSnapshotEvery,
  });

  /// Set when periodic snapshots are on (`periodicSnapshotIntervalSeconds`).
  final Duration? autoSnapshotEvery;

  final String id;
  final String name;
  final int nodeCount;
  final int runningCount;
  final int attentionCount;

  /// running | partial | stopped
  final String status;
  final String? uptime;
  final String? latestSnapshot;

  factory Rig.fromJson(Map<String, Object?> j) => Rig(
        id: j['rigId'] as String? ?? '',
        name: _s(j['name']) ?? _s(j['rigName']) ?? '?',
        nodeCount: _i(j['nodeCount']),
        runningCount: _i(j['runningCount']),
        attentionCount: _i(j['attentionCount']),
        status: _s(j['status']) ?? 'stopped',
        uptime: _s(j['uptime']),
        latestSnapshot: _s(j['latestSnapshot']),
        autoSnapshotEvery: j['periodicSnapshotActive'] == true && _i(j['periodicSnapshotIntervalSeconds']) > 0
            ? Duration(seconds: _i(j['periodicSnapshotIntervalSeconds']))
            : null,
      );
}

/// "claude-opus-4-5-20251101" → "Opus 4.5", "opus" → "Opus", "sonnet[1m]" → "Sonnet 1M".
String modelLabel(String model) {
  var m = model.trim().replaceFirst(RegExp(r'^claude-'), '').replaceFirst(RegExp(r'-\d{8}$'), '');
  final big = m.contains('[1m]');
  m = m.replaceAll('[1m]', '');
  if (m == 'opusplan') return 'Opus Plan';
  final parts = m.split('-');
  final name = parts.first.isEmpty ? m : '${parts.first[0].toUpperCase()}${parts.first.substring(1)}';
  final version = parts.skip(1).where((p) => RegExp(r'^\d+$').hasMatch(p)).join('.');
  return [name, if (version.isNotEmpty) version, if (big) '1M'].join(' ');
}

/// A row from GET /api/rigs/:rigId/nodes (the daemon calls seats "nodes").
class Seat {
  Seat({
    required this.rigId,
    required this.logicalId,
    this.podId,
    this.podNamespace,
    this.sessionName,
    this.runtime,
    this.sessionStatus,
    this.cwd,
    this.tmuxAttachCommand,
    this.tmuxPane,
    bool needsInput = false,
    this.needsInputReason,
    this.lastActivityAt,
    this.permissionMode,
    this.nodeId,
    this.activity,
    this.contextUsedPercent,
    this.lifecycleState,
    this.rawSessionStatus,
    this.intentionallyStopped = false,
    this.activeWorkCount = 0,
    this.resumeToken,
    this.transcriptPath,
    this.waitingSince,
    this.inputTokens,
    this.outputTokens,
    this.costUsd,
    this.model,
    this.effort,
    this.startupStatus,
    this.latestError,
    this.atUsageLimit = false,
    this.usageLimitResetsAt,
  }) : daemonAsks = needsInput;

  /// The node row's `startupStatus`: pending | ready | attention_required | failed.
  final String? startupStatus;

  /// The recorded startup error (the node's newest `node.startup_failed` event): why a seat did not launch. Null when it started.
  final String? latestError;

  /// The agent did not launch (`startupStatus: failed`): its reason is [latestError].
  bool get launchFailed => startupStatus == 'failed';

  /// OpenRig 0.7.22+: a typed usage limit ended the seat's last turn (`activityState.usageLimit`; its activity reads unknown, so
  /// it is neither working nor needs-you), with the reset it stated when it stated one. Older daemons never send it.
  final bool atUsageLimit;
  final DateTime? usageLimitResetsAt;

  /// Still starting: the daemon has the seat but its agent is not up yet.
  bool get notReady => startupStatus == 'pending';

  /// The node row's `effort`: what a managed launch sends; null means the runtime's default.
  final String? effort;

  /// The node row's `model`: the configured model id; null means the runtime's default.
  final String? model;

  /// "claude-opus-4-5-20250929" → "opus-4-5"; null when no model is configured.
  String? get shortModel {
    final m = model?.trim();
    if (m == null || m.isEmpty) return null;
    return m.replaceFirst(RegExp(r'^claude-'), '').replaceFirst(RegExp(r'-\d{8}$'), '');
  }

  /// `contextUsage.totalInputTokens` / `totalOutputTokens`: the session's running totals.
  final int? inputTokens;
  final int? outputTokens;

  /// `contextUsage.clientCostEstimateUsd`: Claude's own estimate, when reported.
  final double? costUsd;

  /// When the daemon first saw the seat waiting (`needsInputEvidence`).
  final DateTime? waitingSince;

  /// Claude Code's session id for this seat: `<resumeToken>.jsonl` is its log.
  final String? resumeToken;

  /// `contextUsage.transcriptPath`, when the daemon reports it.
  final String? transcriptPath;

  /// The daemon's node id. Topology edges point at these, not logical ids.
  final String? nodeId;

  /// When the agent last really worked: its latest reply or runtime hook event. Not the pane's output time, which
  /// any redraw (a client attaching or resizing) bumps on idle seats.
  final DateTime? lastActivityAt;

  /// `activityState.activity`: working | idle-at-prompt | unknown.
  final String? activity;

  /// `contextUsage.usedPercentage`, when the daemon knows it.
  final double? contextUsedPercent;

  /// attention_required | running | recoverable | detached
  final String? lifecycleState;

  /// The node row's own `sessionStatus` (sessionStatus above prefers the
  /// friendlier activity display).
  final String? rawSessionStatus;
  final bool intentionallyStopped;

  /// Pending + in-progress queue items addressed to this seat.
  final int activeWorkCount;

  /// What the seat is waiting on, when the daemon says (e.g. a tool prompt).
  final String? needsInputReason;

  final String rigId;
  final String logicalId;
  final String? podId;

  /// The pod's namespace (`core` in `core.lead`): what adopting into a pod needs.
  final String? podNamespace;

  /// Canonical tmux session name, e.g. `impl@conveyor`. Used as the seat
  /// reference for send, terminal and set-runtime.
  final String? sessionName;

  /// claude-code | codex | terminal | pi | ...
  final String? runtime;
  final String? sessionStatus;
  final String? cwd;
  final String? tmuxAttachCommand;

  /// The tmux pane (`%3`) a keystroke goes to, when it is known: a loose agent's own pane, which may not be its session's
  /// active one. Null for rig seats (their session's active pane).
  final String? tmuxPane;
  /// What the daemon reports: it needs a person.
  final bool daemonAsks;

  /// Set by the feed when the daemon holds an ask but the seat's screen shows no dialog (see `asksWithDialog`).
  bool screenClear = false;

  /// Waiting on a person: the daemon's ask, unless the screen shows there is nothing to answer.
  bool get needsInput => daemonAsks && !screenClear;
  final String? permissionMode;

  bool get isAgent => runtime != null && runtime != 'terminal';

  /// The pod's readable name (`core` in `core.lead`); [podId] is a raw ULID.
  String? get podLabel =>
      podNamespace ?? (logicalId.contains('.') ? logicalId.substring(0, logicalId.indexOf('.')) : podId);

  /// One live state for tiles and graph colors.
  SeatState get state {
    if (needsInput) return SeatState.needsYou;
    const down = {'stopped', 'exited', 'dead', 'missing', 'detached', 'vanished'};
    if (intentionallyStopped || lifecycleState == 'detached' || down.contains(rawSessionStatus)) {
      return SeatState.stopped;
    }
    // Working wins: shell means the agent itself is idle, waiting on a shell or monitor it started.
    if (activity == 'working') return SeatState.working;
    if (jobs.isNotEmpty || waitingSubagents > 0) return SeatState.shell;
    return SeatState.idle;
  }

  /// The shells and monitors the agent is waiting on (from the host's
  /// process list, set by the feed after loading): running, but spending no tokens.
  List<AgentJob> jobs = const [];

  /// Depth in the rig's hierarchy, 0 for the top (set by the feed from the topology); null until known.
  int? level;

  /// "2 shells · 1 monitor · no tokens": what a seat row says while it waits.
  String get jobsLine => AgentJob.waitingLine(jobs, waitingSubagents);

  /// Subagents still running while the agent sits idle at its prompt (set by the feed).
  int waitingSubagents = 0;

  bool get isClaude => runtime == 'claude-code';

  /// The later of the agent's last reply and its last hook event. A daemon that reports neither (older ones) gives
  /// only the pane's time.
  static DateTime? _workedAt(Map<String, Object?> j) {
    if (!j.containsKey('modelObservation') && !j.containsKey('agentActivity')) {
      return RigEvent.parseTime(j['lastActivityAt']);
    }
    final reply = j['modelObservation'] is Map ? RigEvent.parseTime((j['modelObservation'] as Map)['observedAt']) : null;
    final hook = j['agentActivity'] is Map ? RigEvent.parseTime((j['agentActivity'] as Map)['eventAt']) : null;
    if (reply == null || hook == null) return reply ?? hook;
    return reply.isAfter(hook) ? reply : hook;
  }

  factory Seat.fromJson(Map<String, Object?> j) {
    final activity = j['activityState'];
    final activityNeeds =
        activity is Map && activity['needsInput'] is Map && _i((activity['needsInput'] as Map)['count']) > 0;
    final needs = j['arbitratedNeedsInput'] == true ||
        j['needsAttention'] == true ||
        activityNeeds ||
        j['lifecycleState'] == 'attention_required';
    return Seat(
      rigId: j['rigId'] as String? ?? '',
      logicalId: _s(j['logicalId']) ?? '?',
      podId: _s(j['podId']),
      podNamespace: _s(j['podNamespace']),
      sessionName: _s(j['canonicalSessionName']),
      runtime: _s(j['runtime']),
      sessionStatus:
          (activity is Map ? _s(activity['display']) : null) ?? _s(j['sessionStatus']) ?? _s(j['startupStatus']),
      cwd: _s(j['cwd']),
      tmuxAttachCommand: _s(j['tmuxAttachCommand']),
      needsInput: needs,
      lastActivityAt: _workedAt(j),
      needsInputReason:
          activity is Map && activity['needsInput'] is Map ? _s((activity['needsInput'] as Map)['reason']) : null,
      permissionMode: _s(j['permissionMode']) ?? _s(j['permissionPolicy']),
      nodeId: _s(j['nodeId']) ?? _s(j['id']),
      activity: activity is Map
          ? _s(activity['activity'])
          : (j['agentActivity'] is Map && (j['agentActivity'] as Map)['state'] == 'running' ? 'working' : null),
      contextUsedPercent: _contextPercent(j['contextUsage']),
      lifecycleState: _s(j['lifecycleState']),
      rawSessionStatus: _s(j['sessionStatus']),
      intentionallyStopped: j['intentionallyStopped'] == true,
      activeWorkCount: _i(j['pendingWorkCount']) + _i(j['inProgressWorkCount']),
      resumeToken: _s(j['resumeToken']),
      waitingSince: j['needsInputEvidence'] is Map ? RigEvent.parseTime((j['needsInputEvidence'] as Map)['observedAt']) : null,
      transcriptPath: j['contextUsage'] is Map ? _s((j['contextUsage'] as Map)['transcriptPath']) : null,
      inputTokens: _usage(j['contextUsage'], 'totalInputTokens')?.toInt(),
      outputTokens: _usage(j['contextUsage'], 'totalOutputTokens')?.toInt(),
      costUsd: _usage(j['contextUsage'], 'clientCostEstimateUsd')?.toDouble(),
      model: _s(j['model']),
      effort: _s(j['effort']),
      startupStatus: _s(j['startupStatus']),
      latestError: _s(j['latestError']),
      atUsageLimit: activity is Map && activity['usageLimit'] is Map,
      usageLimitResetsAt: activity is Map && activity['usageLimit'] is Map
          ? RigEvent.parseTime((activity['usageLimit'] as Map)['resetsAt'])
          : null,
    );
  }

  static num? _usage(Object? usage, String key) => usage is Map && usage[key] is num ? usage[key] as num : null;

  static double? _contextPercent(Object? usage) {
    if (usage is! Map || usage['availability'] == 'unknown') return null;
    final v = usage['usedPercentage'];
    return v is num ? v.toDouble() : null;
  }
}

/// [shell]: waiting on a shell or monitor it started, so running but spending no tokens.
enum SeatState { needsYou, working, shell, idle, stopped }

/// "at usage limit · resets 2h": what a seat at its usage limit says, null for any other seat. The reset is left out when the
/// daemon stated none or it has passed; a seat that needs you says that instead (a permission prompt outranks it).
String? usageLimitLine(Seat s, [DateTime? now]) {
  if (!s.atUsageLimit || s.state == SeatState.needsYou) return null;
  final left = s.usageLimitResetsAt?.difference(now ?? DateTime.now());
  if (left == null || left.inMinutes < 1) return 'at usage limit';
  final short = left.inDays >= 1 ? '${left.inDays}d' : left.inHours >= 1 ? '${left.inHours}h' : '${left.inMinutes}m';
  return 'at usage limit · resets $short';
}

/// GET /api/rigs/:rigId — nodes and the edges between them. Edge ends are
/// node DB ids (cross-rig escalation refs look like `member@rig`).
class RigTopology {
  RigTopology({required this.nodes, required this.edges});
  final List<TopoNode> nodes;
  final List<TopoEdge> edges;

  /// Each seat's depth in the hierarchy (delegation and spawning, as the Seats graph draws it), by logical id:
  /// 0 for the seats nothing delegates to.
  Map<String, int> get levels {
    final ids = {for (final n in nodes) n.id: n.logicalId};
    final children = <String, List<String>>{};
    final below = <String>{};
    for (final e in edges) {
      if (e.kind != 'delegates_to' && e.kind != 'spawned_by') continue;
      final (parent, child) = e.kind == 'spawned_by' ? (e.targetId, e.sourceId) : (e.sourceId, e.targetId);
      if (!ids.containsKey(parent) || !ids.containsKey(child) || parent == child) continue;
      children.putIfAbsent(parent, () => []).add(child);
      below.add(child);
    }
    final depth = {for (final id in ids.keys) if (!below.contains(id)) id: 0};
    final queue = depth.keys.toList();
    for (var i = 0; i < queue.length; i++) {
      for (final c in children[queue[i]] ?? const <String>[]) {
        if (depth.containsKey(c)) continue;
        depth[c] = depth[queue[i]]! + 1;
        queue.add(c);
      }
    }
    return {for (final MapEntry(:key, :value) in depth.entries) ids[key]!: value};
  }

  factory RigTopology.fromJson(Object? json) {
    if (json is! Map) return RigTopology(nodes: const [], edges: const []);
    List<Map> rows(Object? v) => v is List ? v.whereType<Map>().toList() : const [];
    return RigTopology(
      nodes: [
        for (final n in rows(json['nodes']))
          if (_s(n['id']) != null)
            TopoNode(
              id: n['id'] as String,
              logicalId: _s(n['logicalId']) ?? '?',
              podId: _s(n['podId']),
              runtime: _s(n['runtime']),
              label: _s(n['label']),
            ),
      ],
      edges: [
        for (final e in rows(json['edges']))
          if (_s(e['sourceId']) != null && _s(e['targetId']) != null)
            TopoEdge(e['sourceId'] as String, e['targetId'] as String, _s(e['kind']) ?? 'edge'),
      ],
    );
  }
}

class TopoNode {
  TopoNode({required this.id, required this.logicalId, this.podId, this.runtime, this.label});
  final String id;
  final String logicalId;
  final String? podId;
  final String? runtime;
  final String? label;
}

class TopoEdge {
  TopoEdge(this.sourceId, this.targetId, this.kind);
  final String sourceId;
  final String targetId;
  final String kind;
}

/// A row from GET /api/queue/list.
class QueueItem {
  QueueItem({
    required this.id,
    required this.summary,
    required this.state,
    this.priority,
    this.destinationSession,
    this.sourceSession,
    this.updated,
    this.created,
    this.body = '',
    this.closureReason,
  });

  final String id;
  final String summary;

  /// The full message the sender wrote (`body`), for the Chat tab.
  final String body;
  final DateTime? created;

  /// Why it closed (`no-follow-on`, `handed_off_to`, …), once it has.
  final String? closureReason;

  /// pending | in-progress | blocked | done | failed | ...
  final String state;

  /// routine | urgent | critical
  final String? priority;

  /// The seat that owns the item.
  final String? destinationSession;
  final String? sourceSession;
  final DateTime? updated;

  String? get ownerLogicalId => destinationSession?.split('@').first;

  factory QueueItem.fromJson(Map<String, Object?> j) {
    final text = _s(j['summary']) ?? _s(j['body']) ?? '';
    final firstLine = text.split('\n').first;
    return QueueItem(
      id: _s(j['qitemId']) ?? '',
      summary: firstLine.length > 140 ? '${firstLine.substring(0, 140)}…' : firstLine,
      state: _s(j['state']) ?? 'pending',
      priority: _s(j['priority']),
      destinationSession: _s(j['destinationSession']),
      sourceSession: _s(j['sourceSession']),
      updated: DateTime.tryParse(j['tsUpdated'] as String? ?? ''),
      created: DateTime.tryParse(j['tsCreated'] as String? ?? ''),
      body: _s(j['body']) ?? '',
      closureReason: _s(j['closureReason']),
    );
  }
}

/// One row of GET /api/queue/:id/transitions.
class QueueTransition {
  QueueTransition({required this.at, required this.state, this.note, this.actor});
  final DateTime? at;
  final String state;
  final String? note;
  final String? actor;

  factory QueueTransition.fromJson(Map<String, Object?> j) => QueueTransition(
        at: DateTime.tryParse(j['ts'] as String? ?? ''),
        state: _s(j['state']) ?? '?',
        note: _s(j['transitionNote']),
        actor: _s(j['actorSession']),
      );
}

/// One frame from GET /api/events (SSE). The data is a flat event object.
class RigEvent {
  RigEvent({required this.seq, required this.type, required this.data, this.at});
  final int seq;
  final String type;
  final Map<String, Object?> data;
  final DateTime? at;

  String? get rigId => _s(data['rigId']);
  String? get nodeId => _s(data['nodeId']) ?? _s(data['seatNodeId']);
  String? get sessionName => _s(data['sessionName']);

  /// The daemon writes SQLite `YYYY-MM-DD HH:MM:SS` in UTC, without a `Z`.
  static DateTime? parseTime(Object? v) {
    if (v is! String || v.isEmpty) return null;
    final iso = v.contains('T') ? v : v.replaceFirst(' ', 'T');
    return DateTime.tryParse(iso.endsWith('Z') || iso.contains('+') ? iso : '${iso}Z');
  }

  factory RigEvent.fromJson(Map<String, Object?> j) => RigEvent(
        seq: _i(j['seq']),
        type: _s(j['type']) ?? 'event',
        data: j,
        at: parseTime(j['createdAt']),
      );

  /// The seat an event is about, as a logical id, when there is one.
  String? actor([Map<String, String> names = const {}]) =>
      (nodeId != null ? names[nodeId] : null) ?? sessionName?.split('@').first ?? _s(data['logicalId']);

  /// [describe] split into the seat (shown bold) and the rest.
  (String?, String) describeParts([Map<String, String> names = const {}]) {
    final text = describe(names);
    final who = actor(names);
    if (who != null && text.startsWith('$who ')) return (who, text.substring(who.length + 1));
    return (null, text);
  }

  /// One readable line. [names] maps node ids to logical ids.
  String describe([Map<String, String> names = const {}]) {
    final who = (nodeId != null ? names[nodeId] : null) ?? sessionName?.split('@').first ?? _s(data['logicalId']);
    final w = who ?? 'seat';
    return switch (type) {
      'node.launched' => '$w launched',
      'node.startup_ready' => '$w ready',
      'node.startup_pending' => '$w starting',
      'node.startup_failed' => '$w failed to start${_s(data['error']) != null ? ': ${data['error']}' : ''}',
      'node.held' => '$w held${_s(data['reason']) != null ? ': ${data['reason']}' : ''}',
      'session.stopped' => '$w stopped',
      'session.detached' => '$w detached',
      'session.status_changed' => '$w is ${data['status'] ?? 'changed'}',
      'seat.attention_cleared' => '$w no longer needs you',
      'seat.runtime_changed' => '$w restarted with new runtime settings',
      'agent.activity' => '$w ${_activity(data['activity'])}',
      'snapshot.created' => 'Snapshot taken${_s(data['kind']) != null ? ' (${data['kind']})' : ''}',
      'rig.created' => 'Rig created',
      'rig.stopped' => 'Rig stopped',
      'restore.started' => 'Restore started',
      'restore.completed' => 'Restore finished',
      'queue.created' => 'New work item${who != null ? ' for $who' : ''}',
      'queue.claimed' => '${who ?? 'A seat'} picked up work',
      'queue.handed_off' => 'Work handed off',
      'chat.message' => 'Chat message${who != null ? ' from $who' : ''}',
      final t when t.startsWith('bootstrap.') => 'Launch ${t.substring(10)}',
      final t => who != null ? '$t · $who' : t,
    };
  }

  static String _activity(Object? a) {
    final state = a is Map ? a['state'] : null;
    return switch (state) {
      'running' => 'is working',
      'needs_input' => 'needs you',
      'idle' => 'is idle',
      _ => 'activity changed',
    };
  }
}

/// A rig plus its seats, grouped under a project.
class RigWithSeats {
  RigWithSeats(this.rig, this.seats);
  final Rig rig;
  final List<Seat> seats;

  /// The latest any seat did something.
  DateTime? get lastActivityAt => seats
      .map((s) => s.lastActivityAt)
      .nonNulls
      .fold<DateTime?>(null, (latest, at) => latest == null || at.isAfter(latest) ? at : latest);

  /// The folder most of this rig's seats run in.
  String? get primaryCwd {
    final counts = <String, int>{};
    for (final s in seats) {
      if (s.cwd != null) counts[s.cwd!] = (counts[s.cwd!] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    // The most seats; a tie goes to the folder a seat was listed with first, so it never flips between polls.
    String? best;
    for (final e in counts.entries) {
      if (best == null || e.value > counts[best]!) best = e.key;
    }
    return best;
  }
}

// shortcut: goes by the path, so a worktree outside these folders (`git worktree add ../x`) stays its own project; asking the host with `git rev-parse --git-common-dir` would catch those.
const worktreeDirs = r'(?:\.claude/worktrees|\.worktrees)';
final _worktreePath = RegExp('^(.+?)/$worktreeDirs/([^/]+)(?:/|\$)');

/// The name a folder is shown by, everywhere: its main checkout's last segment ('app' for /w/app/.claude/worktrees/feat, so a
/// worktree's agents read as their project's; the worktree itself is told apart by its own chip), '/' for the root.
String folderName(String path) {
  final parts = mainCheckout(path).split('/').where((p) => p.isNotEmpty);
  return parts.isEmpty ? '/' : parts.last;
}

/// The main checkout [cwd] belongs to, or [cwd] when it isn't in a worktree.
String mainCheckout(String cwd) => _worktreePath.firstMatch(cwd)?.group(1) ?? cwd;

/// Whether [path] is [root] or inside it.
bool isUnder(String path, String root) => path == root || path.startsWith(root.endsWith('/') ? root : '$root/');

/// The worktree's folder [cwd] is in (`<project>/.claude/worktrees/<name>`), or null when it isn't in one.
String? worktreeRoot(String? cwd) => cwd == null ? null : RegExp('^(.+?/$worktreeDirs/[^/]+)').firstMatch(cwd)?.group(1);

/// The small chip for a seat that runs somewhere other than its rig ('in main', 'in api-retry'), or null: same place, or no known
/// folder (an unknown one never counts as elsewhere). The rig stays where most of its seats run, with every seat.
String? seatPlaceChip(Seat s, String? rigCwd) =>
    s.cwd == null || rigCwd == null || worktreeName(s.cwd) == worktreeName(rigCwd) ? null : 'in ${worktreeName(s.cwd) ?? 'main'}';

/// The worktree's name, or null when [cwd] isn't in one.
String? worktreeName(String? cwd) => cwd == null ? null : _worktreePath.firstMatch(cwd)?.group(2);

/// A chat or terminal title: "app-build · lead", with the worktree next to
/// the name. "no rig" gives way to it, so the name fits beside the header's switch.
String seatTitle(String rigName, Seat seat) {
  final worktree = worktreeName(seat.cwd);
  return [if (worktree == null || rigName != 'no rig') rigName, seat.logicalId, if (worktree != null) worktree].join(' · ');
}

/// A folder on a host: either where rigs run, or pinned by hand.
class Project {
  Project({required this.path, List<RigWithSeats>? rigs, List<LooseAgent>? loose, this.pinned = false})
      : rigs = rigs ?? [],
        loose = loose ?? [];

  final String path;
  final List<RigWithSeats> rigs;

  /// Agents working in this folder that no rig launched.
  final List<LooseAgent> loose;

  /// Project shells (tmux `rp-*`) running in this folder or a worktree of it.
  final List<ProjectShell> shells = [];
  final bool pinned;

  String get name => folderName(path);


  /// How many needs-you items are in this project: set by `groupIntoProjects`, which orders cards by it.
  int attention = 0;
}

/// A tmux session that "Shell here" started: its name and the folder it runs in.
class ProjectShell {
  const ProjectShell(this.name, this.cwd);
  final String name;
  final String cwd;
}

/// An agent started by hand, outside any rig. Seen two ways, merged by tmux
/// session: the daemon's tmux scan (`/api/discovery`), and the watcher's
/// Claude Code hook (`~/.config/pocketrig/loose.json`), which also covers
/// plain terminal tabs and knows when it is waiting on you.
class LooseAgent {
  LooseAgent({
    required this.id,
    this.discoveryId,
    this.claudeSessionId,
    this.runtime,
    this.cwd,
    this.tmuxSession,
    this.tmuxPane,
    this.activeCommand,
    this.transcriptPath,
    this.waiting = false,
    this.waitingKind,
    this.activity,
    this.activeAt,
    this.heardAt,
    this.message,
    this.tool,
    this.detail,
    this.since,
  });

  /// Stable key: the tmux session, else the Claude session id.
  final String id;

  /// The daemon's discovered-session id, needed to adopt it.
  final String? discoveryId;
  final String? claudeSessionId;

  /// claude-code | codex | …
  final String? runtime;
  final String? cwd;
  final String? tmuxSession;
  final String? tmuxPane;
  final String? activeCommand;
  final String? transcriptPath;
  final bool waiting;

  /// permission | idle
  final String? waitingKind;

  /// working | idle, from the hook; null when only the tmux scan saw it.
  final String? activity;

  /// When it last did something. Idle reminders don't count.
  final DateTime? activeAt;

  /// A session interrupted with Esc sends no Stop, so a long silence reads as idle.
  bool isWorking(DateTime now) {
    if (waiting) return false;
    if (activity == 'working' && activeAt != null) return now.difference(activeAt!) < const Duration(minutes: 15);
    // shortcut: a watcher from before `activity` only says when it last heard
    // from the agent, so a long tool call reads idle; re-running setup fixes it.
    return activity == null && heardAt != null && now.difference(heardAt!) < const Duration(seconds: 60);
  }

  /// When the hook last fired, whatever for.
  final DateTime? heardAt;

  /// The last sign of life: the latest work, else the last hook.
  DateTime? get lastActivityAt => activeAt ?? heardAt;
  final String? message;
  final String? tool;
  final String? detail;
  final DateTime? since;

  /// A name given in the app, from [Host.agentNames].
  String? label;

  String get name => label ?? tmuxSession ?? (runtime == 'codex' ? 'codex' : 'claude');
  bool get inTmux => tmuxSession != null;
  bool get canAdopt => discoveryId != null;
  bool get isPermission => waiting && waitingKind == 'permission';

  String get runtimeLabel => switch (runtime) {
        'claude-code' => 'claude',
        null => 'agent',
        final String r => r,
      };

  /// The folder name, for role › rig › project › device.
  String? get project => cwd == null ? null : folderName(cwd!);

  /// One line under the name: where it runs and what it's doing.
  String get meta {
    final where = inTmux ? 'tmux $tmuxSession' : 'Terminal tab, no tmux';
    if (waiting) return '$where · needs you';
    return inTmux ? '$where · ${activeCommand ?? 'running'}' : '$where · chat only';
  }

  /// A seat-shaped view so the chat and terminal screens can open it.
  Seat toSeat() => Seat(
        rigId: '',
        logicalId: name,
        sessionName: tmuxSession,
        runtime: runtime ?? 'claude-code',
        cwd: cwd,
        tmuxPane: tmuxPane,
        // Without tmux there's nothing to press the key into.
        needsInput: isPermission && inTmux,
        needsInputReason: tool != null ? '$tool: ${detail ?? ''}' : message,
        activity: isWorking(DateTime.now()) ? 'working' : null,
        transcriptPath: transcriptPath,
        resumeToken: claudeSessionId,
      );

  /// A row from GET /api/discovery.
  static LooseAgent? fromDiscovery(Map<String, Object?> j) {
    final tmux = _s(j['tmuxSession']);
    if (tmux == null || j['status'] != 'active') return null;
    final hint = _s(j['runtimeHint']);
    if (hint != 'claude-code' && hint != 'codex') return null; // shells and unknowns aren't agents
    return LooseAgent(
      id: tmux,
      discoveryId: _s(j['id']),
      runtime: hint,
      cwd: _s(j['cwd']),
      tmuxSession: tmux,
      tmuxPane: _s(j['tmuxPane']),
      activeCommand: _s(j['activeCommand']),
      since: RigEvent.parseTime(j['firstSeenAt']),
    );
  }

  /// An entry the watcher's Claude hook wrote.
  static LooseAgent? fromHook(Map<String, Object?> j) {
    final sid = _s(j['id']);
    if (sid == null) return null;
    final tmux = _s(j['tmux']);
    final at = j['firstSeen'];
    final idleReminder = '${j['message'] ?? ''}'.contains('waiting for your input');
    return LooseAgent(
      id: tmux ?? sid,
      claudeSessionId: sid,
      runtime: 'claude-code',
      cwd: _s(j['cwd']),
      tmuxSession: tmux,
      tmuxPane: _s(j['pane']),
      transcriptPath: _s(j['transcriptPath']),
      // An idle reminder means it finished, not that it asked anything.
      waiting: j['waiting'] == true && !idleReminder,
      waitingKind: idleReminder ? null : _s(j['kind']),
      activity: idleReminder ? 'idle' : _s(j['activity']),
      activeAt: _hookTime(j['activeAt']) ?? (idleReminder ? _hookTime(j['at']) : null),
      heardAt: _hookTime(j['at']),
      message: _s(j['message']),
      tool: _s(j['tool']),
      detail: _s(j['detail']),
      since: at is num ? DateTime.fromMillisecondsSinceEpoch(at.toInt()) : null,
    );
  }

  // No time (or 0, as an empty hook entry has) is no time, not 1970.
  static DateTime? _hookTime(Object? ms) => ms is num && ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms.toInt()) : null;

  /// The scan's facts plus the hook's (waiting state, transcript).
  LooseAgent mergeHook(LooseAgent h) => LooseAgent(
        id: id,
        discoveryId: discoveryId,
        claudeSessionId: h.claudeSessionId,
        runtime: runtime ?? h.runtime,
        cwd: cwd ?? h.cwd,
        tmuxSession: tmuxSession,
        tmuxPane: tmuxPane ?? h.tmuxPane,
        activeCommand: activeCommand,
        transcriptPath: h.transcriptPath,
        waiting: h.waiting,
        waitingKind: h.waitingKind,
        activity: h.activity,
        activeAt: h.activeAt,
        heardAt: h.heardAt,
        message: h.message,
        tool: h.tool,
        detail: h.detail,
        since: since ?? h.since,
      );
}

/// An item from GET /api/attention.
class AttentionItem {
  AttentionItem({
    required this.id,
    required this.kind,
    required this.summary,
    this.at,
    this.asker,
    this.projectRoot,
    this.answerVerb,
  });

  final String id;

  /// action | update
  final String kind;
  final String summary;
  final DateTime? at;

  /// The seat that asked; open it to answer in your own words.
  final String? asker;
  final String? projectRoot;

  /// approve | answer | resolve, when the daemon offers a one-tap answer.
  final String? answerVerb;

  factory AttentionItem.fromJson(Map<String, Object?> j) {
    final project = j['project'];
    final answer = j['answer'];
    return AttentionItem(
      id: j['id'] as String? ?? '',
      kind: _s(j['kind']) ?? 'action',
      summary: _s(j['summary']) ?? '',
      at: DateTime.tryParse(j['at'] as String? ?? ''),
      asker: _s(j['asker']),
      projectRoot: project is Map ? _s(project['root']) : null,
      answerVerb: answer is Map ? _s(answer['verb']) : null,
    );
  }
}

/// Claude Code permission modes the app offers. Codex has no "auto";
/// OpenRig launches Codex seats at its floor posture instead.
enum PermissionMode {
  auto('auto', 'Auto', 'Safe actions run on their own, risky ones ask'),
  ask('default', 'Ask', 'Asks before edits and commands'),
  acceptEdits('acceptEdits', 'Accept edits', 'Edits freely, asks before commands'),
  plan('plan', 'Plan only', 'Reads and plans, changes nothing'),
  bypass('bypassPermissions', 'Bypass', 'Never asks — use with care');

  const PermissionMode(this.wire, this.label, this.hint);
  final String wire;
  final String label;
  final String hint;

  static PermissionMode? fromWire(String? w) {
    // Codex only has OpenRig's two postures.
    if (w == 'floor') return ask;
    if (w == 'full_bypass') return bypass;
    for (final m in values) {
      if (m.wire == w) return m;
    }
    return null;
  }

  /// What a seat can be set to: Claude's modes, or Ask/Bypass for Codex.
  static List<PermissionMode> forSeat(Seat seat) => seat.isClaude ? values : const [ask, bypass];

  /// The `rig seat set-permissions --mode` value for [seat].
  String modeFor(Seat seat) => seat.isClaude ? wire : (this == bypass ? 'full_bypass' : 'floor');
}

/// The kinds of "needs you" a host can notify about. The ids match the
/// watcher's (`host/watcher`).
enum NotifyKind {
  permission('permission', 'Permission requests', 'Allow once or deny from the notification'),
  question('question', 'Questions', 'Reply opens the seat\'s chat'),
  blocked('blocked', 'Blocked work', 'Open or snooze for an hour'),
  rig('rig', 'Rig stopped or failed', 'A rig went down without you stopping it');

  const NotifyKind(this.id, this.label, this.hint);
  final String id;
  final String label;
  final String hint;

  static const defaults = {'permission', 'question', 'blocked'};
}

/// One row of GET /api/slices: a slice of a mission, as OpenRig tracks it.
class SliceSummary {
  SliceSummary({
    required this.name,
    required this.displayName,
    required this.status,
    this.missionId,
    this.qitemCount = 0,
    this.lastActivityAt,
  });
  final String name;
  final String displayName;

  /// active | done | blocked (OpenRig's projection of the authored status).
  final String status;
  final String? missionId;
  final int qitemCount;
  final DateTime? lastActivityAt;

  factory SliceSummary.fromJson(Map<String, Object?> j) => SliceSummary(
        name: _s(j['name']) ?? '?',
        displayName: _s(j['displayName']) ?? _s(j['name']) ?? '?',
        status: _s(j['status']) ?? 'active',
        missionId: _s(j['missionId']),
        qitemCount: _i(j['qitemCount']),
        lastActivityAt: RigEvent.parseTime(j['lastActivityAt']),
      );
}

/// GET /api/slices/:name — what the Progress tab shows of a slice.
class SliceDetail {
  SliceDetail({
    required this.summary,
    required this.checks,
    required this.events,
    required this.rigIds,
    required this.rigNames,
  });
  final SliceSummary summary;

  /// Acceptance items: (text, done).
  final List<(String, bool)> checks;

  /// The slice's story, oldest first.
  final List<SliceEvent> events;
  final Set<String> rigIds;
  final Set<String> rigNames;

  int get done => checks.where((c) => c.$2).length;

  bool touches(Rig rig) => rigIds.contains(rig.id) || rigNames.contains(rig.name);

  factory SliceDetail.fromJson(Map<String, Object?> j) {
    final acceptance = j['acceptance'] is Map ? j['acceptance'] as Map : const {};
    final story = j['story'] is Map ? j['story'] as Map : const {};
    final rigs = j['topology'] is Map && (j['topology'] as Map)['affectedRigs'] is List
        ? ((j['topology'] as Map)['affectedRigs'] as List).whereType<Map>().toList()
        : const <Map>[];
    return SliceDetail(
      summary: SliceSummary.fromJson(j),
      checks: [
        for (final i in (acceptance['items'] is List ? acceptance['items'] as List : const []).whereType<Map>())
          if (_s(i['text']) != null) (_s(i['text'])!, i['done'] == true),
      ],
      events: [
        for (final e in (story['events'] is List ? story['events'] as List : const []).whereType<Map>())
          SliceEvent(
            at: RigEvent.parseTime(e['ts']),
            kind: _s(e['kind']) ?? '',
            actor: _s(e['actorSession']),
            summary: _s(e['summary']) ?? '',
          ),
      ],
      rigIds: {for (final r in rigs) if (_s(r['rigId']) != null) _s(r['rigId'])!},
      rigNames: {for (final r in rigs) if (_s(r['rigName']) != null) _s(r['rigName'])!},
    );
  }
}

class SliceEvent {
  SliceEvent({required this.at, required this.kind, required this.actor, required this.summary});
  final DateTime? at;

  /// queue.created, transition.done, transition.blocked, doc.edited, …
  final String kind;

  /// The session that did it (`dev-qa@rig`), when known.
  final String? actor;
  final String summary;
}

/// One PROGRESS.md from GET /api/progress/tree, with its checkbox rows.
class ProgressFile {
  ProgressFile({required this.relPath, required this.title, required this.rows});
  final String relPath;
  final String title;

  /// (text, status, depth): status is done | active | blocked | unknown.
  final List<(String, String, int)> rows;

  /// `missions/<id>/PROGRESS.md` → id; null for a slice's or another root's file.
  String? get missionId => RegExp(r'^missions/([^/]+)/PROGRESS\.md$').firstMatch(relPath)?.group(1);

  factory ProgressFile.fromJson(Map<String, Object?> j) => ProgressFile(
        relPath: _s(j['relPath']) ?? '',
        title: _s(j['title']) ?? _s(j['relPath']) ?? 'Progress',
        rows: [
          for (final r in (j['rows'] is List ? j['rows'] as List : const []).whereType<Map>())
            if (r['kind'] == 'checkbox' && _s(r['text']) != null)
              (_s(r['text'])!, _s(r['status']) ?? 'unknown', _i(r['depth'])),
        ],
      );
}

/// One message in a rig's chat room (GET /api/rigs/:rigId/chat/history).
class RoomMessage {
  RoomMessage({required this.id, required this.sender, required this.body, this.kind, this.topic, this.at});
  final String id, sender, body;
  final String? kind, topic;
  final DateTime? at;

  factory RoomMessage.fromJson(Map<String, Object?> j) => RoomMessage(
        id: '${j['id']}',
        sender: _s(j['sender']) ?? 'unknown',
        body: '${j['body'] ?? ''}',
        kind: _s(j['kind']),
        topic: _s(j['topic']),
        at: RigEvent.parseTime(j['createdAt']),
      );
}

/// One seat's outcome of a broadcast (POST /api/transport/broadcast).
class BroadcastOutcome {
  BroadcastOutcome(this.session, {required this.ok, this.error});
  final String session;
  final bool ok;
  final String? error;

  factory BroadcastOutcome.fromJson(Map<String, Object?> j) => BroadcastOutcome(
        _s(j['sessionName']) ?? 'unknown',
        ok: j['ok'] == true,
        error: _s(j['error']) ?? _s(j['reason']),
      );
}

/// A scheduled watchdog job (GET /api/watchdog/list): a repeating reminder,
/// or one of OpenRig's own checks.
class WatchdogJob {
  WatchdogJob({
    required this.id,
    required this.policy,
    required this.target,
    required this.intervalSeconds,
    required this.state,
    this.message,
    this.lastFired,
  });
  final String id, policy, target, state;
  final int intervalSeconds;
  final String? message;
  final DateTime? lastFired;

  bool get isReminder => policy == 'periodic-reminder';

  factory WatchdogJob.fromJson(Map<String, Object?> j) => WatchdogJob(
        id: '${j['jobId']}',
        policy: _s(j['policy']) ?? 'unknown',
        target: _s(j['targetSession']) ?? '',
        intervalSeconds: _i(j['intervalSeconds']),
        state: _s(j['state']) ?? 'unknown',
        message: _s(j['message']) ?? _specMessage(j['specYaml']),
        lastFired: RigEvent.parseTime(j['lastFireAt']),
      );

  /// The reminder text from its spec: top-level `message:` or `context.message`.
  static String? _specMessage(Object? spec) {
    if (spec is! String) return null;
    try {
      final y = loadYaml(spec);
      if (y is! Map) return null;
      return _s(y['message']) ?? (y['context'] is Map ? _s((y['context'] as Map)['message']) : null);
    } catch (_) {
      return null;
    }
  }
}
