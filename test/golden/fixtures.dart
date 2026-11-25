// A fake host shaped like the sample data on the "RigPocket wireframes"
// boards: daemon (HTTP), SSH commands, a Claude Code session log and a
// seat terminal. Goldens render the real screens against it.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart' show WidgetTester, find;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/chat/session_log.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/host_store.dart';
import 'package:pocket_rig/data/loose_agents.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/data/home_order.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/data/usage_rings.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/terminal/transport.dart';
import 'package:pocket_rig/ui/chat/mermaid_view.dart';
import 'package:pocket_rig/ui/common.dart' show debugAgoClock, toastProblems;
import 'package:pocket_rig/ui/theme.dart';
import 'package:pocket_rig/ui/usage_strip.dart';

const app = '/Users/me/code/app';
const site = '/Users/me/code/site';
const loyalty = '/Users/me/code/loyalty';

final homelab = Host(
  id: 'h1',
  name: 'homelab',
  address: 'homelab.tail1234.ts.net',
  sshUser: 'me',
  privateKeyPem: null,
  pinnedFolders: ['~/dotfiles'],
  ntfyTopic: 'pocketrig-k3v9q2m7x1ab4cde',
);
final macbook = Host(id: 'h2', name: 'macbook', address: 'macbook.tail1234.ts.net', sshUser: 'me');

/// Times are relative to when the fixtures load, so "2m" stays "2m".
final _now = DateTime.now().toUtc();
String _iso(Duration ago) => _now.subtract(ago).toIso8601String();
String _sqlite(Duration ago) => _now.subtract(ago).toIso8601String().replaceFirst('T', ' ').substring(0, 19);

Map<String, Object?> _node(
  String rigId,
  String rigName,
  String id,
  String pod,
  String runtime,
  String cwd, {
  String activity = 'idle-at-prompt',
  int needs = 0,
  String? reason,
  double? ctx,
  bool stopped = false,
  int work = 0,
  Duration? waitingFor,
  Duration? active,
}) =>
    {
      'nodeId': 'n-$rigName-$id',
      'rigId': rigId,
      'rigName': rigName,
      'logicalId': id,
      'podId': pod,
      'podNamespace': pod,
      'canonicalSessionName': '$id@$rigName',
      'runtime': runtime,
      'cwd': cwd,
      'sessionStatus': stopped ? 'stopped' : 'running',
      'intentionallyStopped': stopped,
      'lifecycleState': needs > 0 ? 'attention_required' : (stopped ? 'detached' : 'running'),
      'resumeToken': 'sess-$id',
      'activityState': stopped
          ? null
          : {
              'activity': activity,
              'display': needs > 0 ? 'needs-input' : (activity == 'idle-at-prompt' ? 'idle' : activity),
              'needsInput': {'count': needs, 'reason': reason},
            },
      'contextUsage': ctx == null ? {'availability': 'unknown'} : {'availability': 'known', 'usedPercentage': ctx},
      if (waitingFor != null) 'needsInputEvidence': {'rung': 'needs-input-chrome', 'observedAt': _iso(waitingFor)},
      if (active != null) 'lastActivityAt': _iso(active),
      'pendingWorkCount': work,
      'inProgressWorkCount': 0,
    };

final rigs = [
  {'rigId': 'r-conveyor', 'name': 'conveyor', 'nodeCount': 4, 'runningCount': 4, 'attentionCount': 2, 'status': 'running', 'uptime': '3h 12m', 'latestSnapshot': '14m ago', 'periodicSnapshotActive': true, 'periodicSnapshotIntervalSeconds': 900},
  {'rigId': 'r-adv', 'name': 'adversarial-review', 'nodeCount': 2, 'runningCount': 1, 'attentionCount': 0, 'status': 'partial', 'uptime': '52m'},
  {'rigId': 'r-pair', 'name': 'implementation-pair', 'nodeCount': 2, 'runningCount': 2, 'attentionCount': 1, 'status': 'running', 'uptime': '1h 4m'},
  {'rigId': 'r-research', 'name': 'research-team', 'nodeCount': 3, 'runningCount': 0, 'attentionCount': 0, 'status': 'stopped', 'latestSnapshot': '2d ago'},
];

final nodes = <String, List<Map<String, Object?>>>{
  'r-conveyor': [
    _node('r-conveyor', 'conveyor', 'lead', 'orchestration', 'claude-code', app,
        needs: 1, reason: 'Bash: npm run test:integration', ctx: 62, waitingFor: const Duration(minutes: 2)),
    _node('r-conveyor', 'conveyor', 'impl', 'build', 'codex', app,
        activity: 'working', ctx: 84, work: 1, active: const Duration(seconds: 20)),
    _node('r-conveyor', 'conveyor', 'review', 'build', 'claude-code', app, needs: 1, reason: 'asked a question', ctx: 31, waitingFor: const Duration(minutes: 9)),
    _node('r-conveyor', 'conveyor', 'tests', 'build', 'codex', app, ctx: 9),
  ],
  'r-adv': [
    _node('r-adv', 'adversarial-review', 'attacker', 'review', 'claude-code', app,
        activity: 'working', ctx: 40, active: const Duration(minutes: 1)),
    _node('r-adv', 'adversarial-review', 'defender', 'review', 'claude-code', app, stopped: true),
  ],
  'r-pair': [
    _node('r-pair', 'implementation-pair', 'lead', 'pair', 'claude-code', site,
        ctx: 22, active: const Duration(minutes: 12)),
    _node('r-pair', 'implementation-pair', 'impl', 'pair', 'codex', site, activity: 'working', ctx: 57),
  ],
  // Not in /api/ps (so other boards don't change); the Graph golden opens it directly.
  'r-release': [
    _node('r-release', 'release-train', 'lead', 'release', 'claude-code', app, activity: 'working', ctx: 48),
    _node('r-release', 'release-train', 'impl', 'build', 'codex', app, activity: 'working', ctx: 71),
    _node('r-release', 'release-train', 'docs', 'build', 'claude-code', app, ctx: 12),
    _node('r-release', 'release-train', 'tests', 'qa', 'codex', app, activity: 'working', ctx: 35),
    _node('r-release', 'release-train', 'review', 'qa', 'claude-code', app,
        needs: 1, reason: 'asked whether to block the release', ctx: 55, waitingFor: const Duration(minutes: 4)),
    _node('r-release', 'release-train', 'smoke', 'qa', 'claude-code', app, stopped: true),
  ],
  'r-wa': [
    _node('r-wa', 'retry-pair', 'lead', 'pair', 'claude-code', _wtA,
        needs: 1, reason: 'Bash: npm test', ctx: 30, waitingFor: const Duration(minutes: 3)),
    _node('r-wa', 'retry-pair', 'impl', 'pair', 'codex', _wtA, activity: 'working', ctx: 44),
  ],
  'r-wb': [
    _node('r-wb', 'docs-duo', 'lead', 'pair', 'claude-code', _wtB, ctx: 18, active: const Duration(minutes: 6)),
    _node('r-wb', 'docs-duo', 'writer', 'pair', 'codex', _wtB, activity: 'working', ctx: 52),
  ],
  'r-research': [
    _node('r-research', 'research-team', 'lead', 'research', 'claude-code', loyalty, stopped: true),
    _node('r-research', 'research-team', 'analyst', 'research', 'codex', loyalty, stopped: true),
    _node('r-research', 'research-team', 'writer', 'research', 'claude-code', loyalty, stopped: true),
  ],
};

Map<String, Object?> get conveyorTopology => {
      'rig': {'id': 'r-conveyor', 'name': 'conveyor'},
      'nodes': [
        for (final n in nodes['r-conveyor']!) {'id': n['nodeId'], 'logicalId': n['logicalId'], 'podId': n['podId']},
      ],
      'edges': [
        {'sourceId': 'n-conveyor-lead', 'targetId': 'n-conveyor-impl', 'kind': 'delegates_to'},
        {'sourceId': 'n-conveyor-lead', 'targetId': 'n-conveyor-review', 'kind': 'delegates_to'},
        {'sourceId': 'n-conveyor-impl', 'targetId': 'n-conveyor-review', 'kind': 'reviewed_by'},
        {'sourceId': 'n-conveyor-impl', 'targetId': 'n-conveyor-tests', 'kind': 'hands_off_to'},
      ],
    };

List<Map<String, Object?>> get queue => [
      {'qitemId': 'q1', 'state': 'in-progress', 'priority': 'routine', 'summary': 'Slice 3 — retry 409s', 'destinationSession': 'impl@conveyor', 'tsUpdated': _iso(const Duration(minutes: 41))},
      {'qitemId': 'q2', 'state': 'blocked', 'priority': 'urgent', 'summary': 'Integration suite on staging', 'destinationSession': 'lead@conveyor', 'tsUpdated': _iso(const Duration(minutes: 2))},
      {'qitemId': 'q3', 'state': 'pending', 'priority': 'routine', 'summary': 'Router retry diff', 'destinationSession': 'review@conveyor', 'tsUpdated': _iso(const Duration(minutes: 9))},
      {'qitemId': 'q4', 'state': 'pending', 'priority': 'routine', 'summary': 'Flaky test in queue sweep', 'destinationSession': 'tests@conveyor'},
    ];

/// More attention items a test wants the daemon to report; [installFakes] clears them.
List<Map<String, Object?>> extraAttention = [];

Map<String, Object?> get attention => {
      'scope': 'instance',
      'items': [
        {
          'id': 'queue:q9',
          'kind': 'action',
          'summary': 'Blocked on you: needs the staging API key added to the rig env.',
          'asker': 'impl@implementation-pair',
          'answer': {'verb': 'resolve'},
          'at': _iso(const Duration(minutes: 41)),
          'project': {'id': 'p2', 'root': site},
        },
        ...extraAttention,
      ],
    };

List<RigEvent> get conveyorEvents => [
      RigEvent.fromJson({'type': 'snapshot.created', 'rigId': 'r-conveyor', 'kind': 'auto', 'seq': 1, 'createdAt': _sqlite(const Duration(minutes: 14))}),
      RigEvent.fromJson({'type': 'queue.claimed', 'rigId': 'r-conveyor', 'sessionName': 'impl@conveyor', 'seq': 2, 'createdAt': _sqlite(const Duration(minutes: 12))}),
      RigEvent.fromJson({'type': 'agent.activity', 'rigId': 'r-conveyor', 'nodeId': 'n-conveyor-review', 'activity': {'state': 'needs_input'}, 'seq': 3, 'createdAt': _sqlite(const Duration(minutes: 9))}),
      RigEvent.fromJson({'type': 'agent.activity', 'rigId': 'r-conveyor', 'nodeId': 'n-conveyor-lead', 'activity': {'state': 'needs_input'}, 'seq': 4, 'createdAt': _sqlite(const Duration(minutes: 2))}),
    ];

/// Board 1b's release-train spec, running: three pods, an escalation back up.
Map<String, Object?> get releaseTopology => {
      'rig': {'id': 'r-release', 'name': 'release-train'},
      'nodes': [
        for (final n in nodes['r-release']!) {'id': n['nodeId'], 'logicalId': n['logicalId'], 'podId': n['podId']},
      ],
      'edges': [
        {'sourceId': 'n-release-train-lead', 'targetId': 'n-release-train-impl', 'kind': 'delegates_to'},
        {'sourceId': 'n-release-train-lead', 'targetId': 'n-release-train-docs', 'kind': 'delegates_to'},
        {'sourceId': 'n-release-train-lead', 'targetId': 'n-release-train-tests', 'kind': 'delegates_to'},
        {'sourceId': 'n-release-train-impl', 'targetId': 'n-release-train-review', 'kind': 'delegates_to'},
        {'sourceId': 'n-release-train-tests', 'targetId': 'n-release-train-smoke', 'kind': 'hands_off_to'},
        {'sourceId': 'n-release-train-review', 'targetId': 'n-release-train-lead', 'kind': 'escalates_to'},
      ],
    };

final releaseRig = Rig(
    id: 'r-release', name: 'release-train', nodeCount: 6, runningCount: 5, attentionCount: 1, status: 'running', uptime: '18m');

/// A project with two worktrees, a rig and a loose agent in each (board 7c). Off unless a board turns it on.
bool showWorktrees = false;
const _wtProject = '/Users/me/code/atlas';
const _wtA = '$_wtProject/.claude/worktrees/api-retry';
const _wtB = '$_wtProject/.claude/worktrees/docs-pass';

final wtRigs = [
  {'rigId': 'r-wa', 'name': 'retry-pair', 'nodeCount': 2, 'runningCount': 2, 'attentionCount': 1, 'status': 'running', 'uptime': '40m'},
  {'rigId': 'r-wb', 'name': 'docs-duo', 'nodeCount': 2, 'runningCount': 2, 'attentionCount': 0, 'status': 'running', 'uptime': '1h 2m'},
];

/// A project of rigs of every size for the sidebar's bars (board 1b): one seat, two, six, a 20-character name, and one
/// with every seat idle (folded). Off unless a board turns it on.
bool showBarRigs = false;
const _barProject = '/Users/me/code/bars';

Map<String, Object?> _bar(String rig, String id, {String activity = 'idle-at-prompt', int needs = 0}) =>
    _node('r-$rig', rig, id, 'p', 'claude-code', _barProject,
        activity: activity, needs: needs, reason: needs > 0 ? 'asked a question' : null);

final barRigs = [
  for (final (id, n, attention) in [('solo', 1, 0), ('duo', 2, 1), ('six-seat-pipeline', 6, 1), ('twenty-char-rig-name', 3, 0), ('all-idle', 2, 0)])
    {'rigId': 'r-$id', 'name': id, 'nodeCount': n, 'runningCount': n, 'attentionCount': attention, 'status': 'running', 'uptime': '10m'},
];

final barNodes = <String, List<Map<String, Object?>>>{
  'r-solo': [_bar('solo', 'only', activity: 'working')],
  'r-duo': [_bar('duo', 'a', needs: 1), _bar('duo', 'b')],
  'r-six-seat-pipeline': [
    _bar('six-seat-pipeline', 'planner', needs: 1),
    _bar('six-seat-pipeline', 'coder-1', activity: 'working'),
    _bar('six-seat-pipeline', 'coder-2', activity: 'working'),
    _bar('six-seat-pipeline', 'reviewer'),
    _bar('six-seat-pipeline', 'tester'),
    _bar('six-seat-pipeline', 'docs'),
  ],
  'r-twenty-char-rig-name': [
    _bar('twenty-char-rig-name', 'x', activity: 'working'),
    _bar('twenty-char-rig-name', 'y'),
    _bar('twenty-char-rig-name', 'z'),
  ],
  'r-all-idle': [_bar('all-idle', 'one'), _bar('all-idle', 'two')],
};

final wtDiscovered = [
  {'id': 'd-wa', 'tmuxSession': 'retry-scratch', 'tmuxPane': '%11', 'cwd': _wtA, 'activeCommand': 'claude',
    'runtimeHint': 'claude-code', 'confidence': 'high', 'status': 'active', 'firstSeenAt': _sqlite(const Duration(minutes: 50))},
  {'id': 'd-wb', 'tmuxSession': 'docs-codex', 'tmuxPane': '%12', 'cwd': _wtB, 'activeCommand': 'codex',
    'runtimeHint': 'codex', 'confidence': 'high', 'status': 'active', 'firstSeenAt': _sqlite(const Duration(minutes: 20))},
];

List<Map<String, Object?>> get _found => [if (showLoose) ...discovered, if (showWorktrees) ...wtDiscovered];

/// Agents started by hand (boards 7, 7a). Off unless a board turns it on, so
/// the other boards keep their sample data.
bool showLoose = false;

/// conveyor's `tests` seat at its usage limit, as OpenRig 0.7.22 reports it (activity unknown, `usageLimit` with a reset in 2h).
/// Off unless a test or the demo turns it on.
bool showUsageLimit = false;

Map<String, Object?> _atLimit(Map<String, Object?> n) => {
      ...n,
      'activityState': {
        ...(n['activityState'] as Map<String, Object?>),
        'activity': 'unknown',
        'display': 'unknown',
        'usageLimit': {'rung': 'stop-failure', 'observedAt': _iso(const Duration(minutes: 3)), 'resetsAt': _iso(const Duration(hours: -2))},
      },
    };

List<Map<String, Object?>> _nodesOf(String rigId) => [
      for (final n in nodes[rigId] ?? barNodes[rigId] ?? const <Map<String, Object?>>[])
        showUsageLimit && rigId == 'r-conveyor' && n['logicalId'] == 'tests' ? _atLimit(n) : n,
    ];

final discovered = [
  {'id': 'd-scratch', 'tmuxSession': 'scratch', 'tmuxPane': '%7', 'cwd': app, 'activeCommand': 'claude --continue',
    'runtimeHint': 'claude-code', 'confidence': 'high', 'status': 'active', 'firstSeenAt': _sqlite(const Duration(hours: 2))},
  {'id': 'd-codex', 'tmuxSession': 'codex-fix', 'tmuxPane': '%9', 'cwd': app, 'activeCommand': 'codex',
    'runtimeHint': 'codex', 'confidence': 'high', 'status': 'active', 'firstSeenAt': _sqlite(const Duration(minutes: 40))},
  {'id': 'd-shell', 'tmuxSession': 'rp-app', 'tmuxPane': '%2', 'cwd': app, 'activeCommand': 'zsh',
    'runtimeHint': 'terminal', 'confidence': 'high', 'status': 'active', 'firstSeenAt': _sqlite(const Duration(hours: 5))},
];

final looseHookFile = jsonEncode([
  {'id': 'sess-scratch', 'cwd': app, 'tmux': 'scratch', 'pane': '%7', 'transcriptPath': '/Users/me/.claude/projects/-Users-me-code-app/sess-scratch.jsonl',
    'waiting': true, 'kind': 'permission', 'message': 'Claude needs your permission to use Bash', 'tool': 'Bash',
    'detail': 'rm -rf dist && npm run build', 'firstSeen': _now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch, 'at': 0},
  {'id': 'sess-tab', 'cwd': site, 'transcriptPath': '/Users/me/.claude/projects/-Users-me-code-site/sess-tab.jsonl',
    'waiting': false, 'firstSeen': _now.subtract(const Duration(minutes: 25)).millisecondsSinceEpoch, 'at': 0},
  // A rig seat's own hook: dropped, the daemon reports it.
  {'id': 'sess-lead', 'cwd': app, 'tmux': 'lead@conveyor', 'pane': '%1', 'waiting': true, 'kind': 'permission'},
]);

/// The agent board 7a opens.
LooseAgent scratchAgent() => mergeLooseAgents(
      discovered.map(LooseAgent.fromDiscovery).whereType<LooseAgent>().toList(),
      parseHookFile(looseHookFile),
      const {},
    ).firstWhere((a) => a.name == 'scratch');

List<RigWithSeats> rigsWithSeatsFromFixture() => [
      for (final r in rigs)
        RigWithSeats(Rig.fromJson(r), (nodes[r['rigId']] ?? const []).map(Seat.fromJson).toList()),
    ];

/// The fake daemon (OpenRig 0.7.6 shapes).
/// The conveyor rig's slices (one mission, three slices) and the mission's PROGRESS.md, as the daemon sends them
/// (GET /api/slices, /api/slices/:name, /api/progress/tree): the Progress tab reads these.
final progressSlices = <Map<String, Object?>>[
  for (final (name, title, status, mins, items, story) in [
    (
      'retry-409s-impl',
      'Retry 409s with backoff',
      'active',
      41,
      [('Retries use exponential backoff', true), ('A 409 never retries more than 5 times', true), ('Integration suite green on staging', false)],
      [('queue.created', 'lead', 'Slice opened: retry 409s'), ('transition.claimed', 'impl', 'impl picked it up')],
    ),
    (
      'queue-sweep-flake',
      'Fix the flaky queue-sweep test',
      'blocked',
      130,
      [('Root cause found', true), ('Test passes 50 runs in a row', false)],
      [('transition.blocked', 'tests', 'Blocked on the staging API key')],
    ),
    (
      'router-docs',
      'Document the router retry',
      'done',
      600,
      [('README section written', true), ('Review approved', true)],
      [('transition.done', 'review', 'Approved')],
    ),
  ])
    {
      'summary': {
        'name': name,
        'displayName': title,
        'status': status,
        'missionId': 'retry-409',
        'qitemCount': items.length,
        'lastActivityAt': _iso(Duration(minutes: mins)),
      },
      'detail': {
        'name': name,
        'displayName': title,
        'status': status,
        'missionId': 'retry-409',
        'qitemCount': items.length,
        'lastActivityAt': _iso(Duration(minutes: mins)),
        'acceptance': {
          'items': [for (final (text, done) in items) {'text': text, 'done': done}],
        },
        'story': {
          'events': [
            for (final (i, (kind, actor, summary)) in story.indexed)
              {'ts': _iso(Duration(minutes: mins + 5 * (story.length - i))), 'kind': kind, 'actorSession': '$actor@conveyor', 'summary': summary},
          ],
        },
        'topology': {
          'affectedRigs': [
            {'rigId': 'r-conveyor', 'rigName': 'conveyor'},
          ],
        },
      },
    },
];

final progressFiles = <Map<String, Object?>>[
  {
    'relPath': 'missions/retry-409/PROGRESS.md',
    'title': 'Retry 409s: mission progress',
    'rows': [
      {'kind': 'checkbox', 'text': 'Design the backoff', 'status': 'done', 'depth': 0},
      {'kind': 'checkbox', 'text': 'Implement it in the router', 'status': 'active', 'depth': 0},
      {'kind': 'checkbox', 'text': 'Unit tests', 'status': 'done', 'depth': 1},
      {'kind': 'checkbox', 'text': 'Staging run', 'status': 'blocked', 'depth': 1},
      {'kind': 'checkbox', 'text': 'Write the runbook note', 'status': 'unknown', 'depth': 0},
    ],
  },
];

/// What the demo's queue writes changed (POST /api/queue/<id>/handoff and /update): per-item overrides and the successors a handoff
/// made, applied to the next /api/queue/list. Cleared by installFakes.
final queueOverrides = <String, Map<String, Object?>>{};
final queueAdded = <Map<String, Object?>>[];

http.Client fakeDaemon(Host host) => MockClient((req) async {
      Object? body;
      var status = 200;
      final p = req.url.path;
      if (host.id != homelab.id) return http.Response('offline', 503);
      if (p == '/healthz') {
        body = {'status': 'ok', 'semver': '0.7.6'};
      } else if (p == '/api/ps') {
        body = [...rigs, if (showWorktrees) ...wtRigs, if (showBarRigs) ...barRigs];
      } else if (p.startsWith('/api/rigs/') && p.endsWith('/nodes')) {
        body = _nodesOf(Uri.decodeComponent(p.split('/')[3]));
      } else if (p == '/api/rigs/r-conveyor') {
        body = conveyorTopology;
      } else if (p == '/api/rigs/r-release') {
        body = releaseTopology;
      } else if (p.startsWith('/api/queue/') && p.endsWith('/transitions')) {
        // What the Work page's detail reads: how a queue item moved (newest last).
        body = [
          {'ts': _iso(const Duration(minutes: 41)), 'state': 'pending', 'actorSession': 'lead@conveyor', 'transitionNote': 'Slice opened: retry 409s'},
          {'ts': _iso(const Duration(minutes: 38)), 'state': 'in-progress', 'actorSession': 'impl@conveyor', 'transitionNote': 'impl picked it up'},
          {'ts': _iso(const Duration(minutes: 2)), 'state': 'blocked', 'actorSession': 'impl@conveyor', 'transitionNote': 'staging is down'},
        ];
      } else if (req.method == 'POST' && RegExp(r'^/api/queue/[^/]+/(handoff|update)$').hasMatch(p)) {
        final id = Uri.decodeComponent(p.split('/')[3]);
        final b = jsonDecode(req.body) as Map;
        final all = [...queue, ...queueAdded];
        final item = all.where((q) => q['qitemId'] == id).firstOrNull;
        if (item == null) {
          status = 404;
          body = {'error': 'qitem_not_found', 'message': 'No queue item $id'};
        } else if (p.endsWith('/handoff')) {
          queueOverrides[id] = {'state': 'handed-off', 'closureReason': 'handed_off_to'};
          queueAdded.add({...item, 'qitemId': '$id-h${queueAdded.length}', 'state': 'pending', 'sourceSession': item['destinationSession'], 'destinationSession': b['toSession']});
          status = 201;
          body = {'ok': true};
        } else {
          queueOverrides[id] = {'state': b['state'], if (b['closureReason'] != null) 'closureReason': b['closureReason']};
          body = {...item, ...queueOverrides[id]!};
        }
      } else if (p == '/api/queue/list') {
        body = const {'conveyor', null}.contains(req.url.queryParameters['rig'])
            ? [for (final q in [...queue, ...queueAdded]) {...q, ...?queueOverrides[q['qitemId']]}]
            : [];
      } else if (req.method == 'GET' && RegExp(r'^/api/queue/[^/]+$').hasMatch(p)) {
        final id = Uri.decodeComponent(p.split('/')[3]);
        final item = [...queue, ...queueAdded].where((q) => q['qitemId'] == id).firstOrNull;
        if (item == null) {
          status = 404;
          body = {'error': 'qitem_not_found'};
        } else {
          body = {...item, ...?queueOverrides[id]};
        }
      } else if (p == '/api/discovery/scan') {
        body = {'sessions': _found};
      } else if (p == '/api/discovery') {
        body = _found;
      } else if (p == '/api/slices') {
        body = {'slices': [for (final x in progressSlices) x['summary']]};
      } else if (p.startsWith('/api/slices/')) {
        body = progressSlices.firstWhere((x) => (x['summary']! as Map)['name'] == Uri.decodeComponent(p.split('/').last),
            orElse: () => const {})['detail'];
        if (body == null) status = 404;
      } else if (p == '/api/progress/tree') {
        body = {'files': progressFiles};
      } else if (p == '/api/attention') {
        body = attention;
      } else if (p == '/api/provider/status') {
        // Resets a little past the hour so "resets in" reads the same all test long.
        final now = debugUsageClock!;
        body = {
          'hostUsage': [
            {
              'host': 'local',
              'provider': 'claude',
              'windows': [
                {'window': 'five_hour', 'usedPercent': 71, 'resetsAt': now.add(const Duration(hours: 2, seconds: 30)).toIso8601String(), 'asOf': now.toIso8601String()},
                {'window': 'weekly', 'usedPercent': 34, 'resetsAt': now.add(const Duration(days: 4, hours: 3, seconds: 30)).toIso8601String(), 'asOf': now.toIso8601String()},
              ],
            },
          ],
        };
      } else if (p.startsWith('/api/seat/status/')) {
        final ref = Uri.decodeComponent(p.split('/').last);
        final mode = ref.startsWith('impl') || ref.startsWith('tests') ? 'floor' : 'auto';
        body = {'permissions': {'effective': {'effectiveMode': mode}}};
      } else {
        status = 404;
        body = {'error': 'not_found'};
      }
      return http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
    });

const releaseSpec = '''version: "0.2"
name: release-train
summary: >
  Release lead cuts the branch and drives a build pod and a QA pod; QA
  escalates blockers back to the lead.

pods:
  - id: release
    label: Release
    members:
      - id: lead
        agent_ref: "local:agents/release/lead"
        runtime: claude-code
        cwd: "."
  - id: build
    label: Build
    members:
      - id: impl
        agent_ref: "local:agents/development/implementer"
        runtime: codex
      - id: docs
        agent_ref: "local:agents/writing/docs"
        runtime: claude-code
  - id: qa
    label: QA
    members:
      - id: tests
        agent_ref: "local:agents/qa/tester"
        runtime: codex
      - id: review
        agent_ref: "local:agents/qa/reviewer"
        runtime: claude-code
      - id: smoke
        agent_ref: "local:agents/qa/smoke"
        runtime: claude-code

edges:
  - kind: delegates_to
    from: release.lead
    to: build.impl
  - kind: delegates_to
    from: release.lead
    to: qa.tests
  - kind: delegates_to
    from: build.impl
    to: qa.review
  - kind: escalates_to
    from: qa.review
    to: release.lead
''';

String _spec(String name, int pods, String runtimes) => '''version: "0.2"
name: $name
pods:
${List.generate(pods, (i) => '  - id: pod$i\n    members:\n      - id: m$i\n        runtime: $runtimes').join('\n')}
''';

const gitOutput = '''@@pocketrig-status
# pocketrig.root /Users/me/code/app
# branch.oid 1234abcd
# branch.head feat/409-retry
# branch.upstream origin/feat/409-retry
# branch.ab +2 -0
1 .M N... 100644 100644 100644 aaa bbb src/rig/router.ts
1 A. N... 000000 100644 100644 000 ccc src/rig/retry.ts
1 .M N... 100644 100644 100644 ddd eee test/router.test.ts
@@pocketrig-numstat
18\t4\tsrc/rig/router.ts
21\t0\tsrc/rig/retry.ts
3\t2\ttest/router.test.ts
@@pocketrig-pr
{"number":42,"title":"Retry 409s with backoff","state":"OPEN","url":"https://github.com/example/app/pull/42","reviewDecision":"REVIEW_REQUIRED","headRefName":"feat/409-retry","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":""}]}
''';

/// The fake host's shell: answers the handful of commands the app runs.
/// What conveyor's seats received from each other with rig send (the rig's Messages, on Progress), as the
/// recipients' transcripts hold them. Each line is one received copy; the review one went to two seats.
List<String> get sentLog {
  String line(String from, String to, Duration ago, String body) => jsonEncode({
        'type': 'user',
        'timestamp': _iso(ago),
        'message': {'role': 'user', 'content': 'From: $from\nTo: $to\nSent: x\n---\n$body\n---\n↩ Reply: rig send $from "..."\n'},
      });
  return [
    line('lead@conveyor', 'impl@conveyor', const Duration(minutes: 40), 'Take slice 3: retry 409s with backoff.\nKeep the change in router.ts.'),
    line('impl@conveyor', 'lead@conveyor', const Duration(minutes: 12), 'Slice 3 is in: router retries 409s, 3 tries with jitter. Tests pass.'),
    line('lead@conveyor', 'review@conveyor, tests@conveyor', const Duration(minutes: 9), 'Please review the router retry diff, and run the integration suite on staging.'),
    line('lead@conveyor', 'review@conveyor, tests@conveyor', const Duration(minutes: 9), 'Please review the router retry diff, and run the integration suite on staging.'),
  ];
}

/// A small unified diff for the file a `git diff` command names (the Code tab's diff pane, the Changes section).
String _sampleDiff(String cmd) {
  final path = RegExp(r"-- (?:/dev/null )?'([^']+)'").firstMatch(cmd)?.group(1) ?? 'file';
  return 'diff --git a/$path b/$path\n--- a/$path\n+++ b/$path\n@@ -10,7 +10,11 @@ export async function send(req) {\n'
      '   const res = await fetch(req.url, req.init);\n'
      '-  if (res.status === 409) throw new Conflict();\n'
      '+  for (let n = 0; n < 3 && res.status === 409; n++) {\n'
      '+    await sleep(2 ** n * 100);\n'
      '+    res = await fetch(req.url, req.init);\n'
      '+  }\n'
      '   return res;\n'
      ' }\n';
}

Future<String> fakeShell(String cmd) async {
  if (cmd.contains('git diff --no-color')) return _sampleDiff(cmd);
  if (cmd.contains('POCKETRIG_SENT')) return 'POCKETRIG_SENT\n'; // tmux send-keys answered a seat
  if (cmd.contains('window_width')) return '120 40\n';
  if (cmd.contains("grep -F 'From: '")) return sentLog.join('\n');
  if (cmd.contains('@@pr-seat')) {
    // Every agent's newest lines: lead gets the board's conversation.
    final seats = RegExp(r'@@pr-seat (\d+)').allMatches(cmd).map((m) => m.group(1)!).toList();
    return [
      for (final i in seats) ...['@@pr-seat $i', if (cmd.contains('sess-lead') || i == '0') ...chatLog.skip(chatLog.length - 3)],
    ].join('\n');
  }
  if (cmd.contains('loose.json')) return showLoose ? looseHookFile : '';
  if (cmd.contains('pocketrig-status')) return gitOutput;
  // A worktree with uncommitted work (the demo's Delete worktree dialog): an edited file and a new one.
  if (cmd.contains('.claude/worktrees/flaky-ci') && cmd.contains('git status --porcelain 2>/dev/null')) return ' M src/rig/router.ts\n?? notes.md\n';
  if (cmd.contains('git rev-parse --abbrev-ref HEAD')) return 'feat/409-retry\n';
  if (cmd.contains('git worktree list')) {
    // The folders the browser marks 'git' (fakeFolders) are repositories here too.
    for (final repo in ['site', 'pocketrig']) {
      if (cmd.contains('/$repo')) return 'worktree $fakeHome/code/$repo\nchanged 0\nbranch refs/heads/main\n';
    }
    // atlas: the main checkout and its two worktrees (what the rigs r-wa and r-wb run in).
    if (cmd.contains('atlas')) {
      return 'worktree $_wtProject\nchanged 0\nbranch refs/heads/main\n\n'
          'worktree $_wtA\nchanged 0\nbranch refs/heads/api-retry\n\n'
          'worktree $_wtB\nchanged 1\nbranch refs/heads/docs-pass\n';
    }
    return cmd.contains('app')
        ? 'worktree $app\n# branch.upstream origin/feat/409-retry\n# branch.ab +2 -0\nchanged 3\nbranch refs/heads/feat/409-retry\n\n'
            'worktree $app/.claude/worktrees/flaky-ci\nchanged 0\nbranch refs/heads/fix/flaky-ci\n'
        : '';
  }
  if (cmd.contains('find "\$PWD"')) {
    return cmd.contains('app') ? '$app/rigs/conveyor/rig.yaml\n$app/rig.review.yaml\n$app/rigs/release/rig.yaml\n' : '';
  }
  if (cmd.contains('head -c 262144')) {
    if (cmd.contains('release')) return releaseSpec;
    if (cmd.contains('review')) return _spec('adversarial-review', 1, 'claude-code');
    return _spec('conveyor', 2, 'claude-code').replaceFirst('pod1\n    members:\n      - id: m1\n        runtime: claude-code', 'pod1\n    members:\n      - id: m1\n        runtime: codex');
  }
  if (cmd.contains('@@pocketrig-folders')) return fakeFolders(cmd);
  if (cmd.contains('&& pwd')) {
    final m = RegExp(r"'([^']+)'").firstMatch(cmd);
    // A typed folder check (the New sheet): a name with 'missing' in it is not a folder on the host.
    if (cmd.contains('@@pocketrig-nodir')) {
      final name = m?.group(1) ?? '';
      if (name.contains('missing')) return '@@pocketrig-nodir\n';
      if (name.contains('afile')) return '@@pocketrig-file\n';
    }
    if (cmd.contains(r'"$HOME"')) return '/Users/me/${m?.group(1) ?? ''}\n';
    return '${m?.group(1) ?? app}\n';
  }
  if (cmd.contains('.claude')) return '/Users/me/.claude/projects/-Users-me-code-app/sess-lead.jsonl\n';
  return '';
}

/// Lines a test appends to [chatLog]; [installFakes] clears them.
List<Map<String, Object?>> extraChatLog = [];

/// Board 3a's conversation, as Claude Code session-log lines.
List<String> get chatLog => [
      {'type': 'user', 'uuid': 'u1', 'cwd': app, 'gitBranch': 'feat/409-retry', 'message': {'role': 'user', 'content': 'Add a retry on 409 and run the integration suite.'}},
      {'type': 'assistant', 'uuid': 'a1', 'message': {'id': 'm1', 'content': [{'type': 'text', 'text': "I'll add a bounded retry in the router, then run the suite against staging."}]}},
      {'type': 'assistant', 'uuid': 'a2', 'message': {'id': 'm1', 'content': [{'type': 'tool_use', 'id': 't1', 'name': 'Read', 'input': {'file_path': 'src/rig/router.ts'}}]}},
      {'type': 'user', 'uuid': 'r1', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 't1', 'content': List.generate(212, (i) => 'line $i').join('\n')}]}},
      {'type': 'assistant', 'uuid': 'a3', 'message': {'id': 'm2', 'content': [{'type': 'tool_use', 'id': 't2', 'name': 'Edit', 'input': {'file_path': 'src/rig/router.ts', 'old_string': 'const res = await send(req);', 'new_string': 'let res = await send(req);\nfor (let n = 0; n < 4 && res.status === 409; n++) {\n  await sleep(2 ** n * 100);\n  res = await send(req);\n}'}}]}},
      {'type': 'user', 'uuid': 'r2', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 't2', 'content': 'ok'}]}},
      {'type': 'assistant', 'uuid': 'a4', 'message': {'id': 'm2', 'content': [{'type': 'tool_use', 'id': 't3', 'name': 'Bash', 'input': {'command': 'npm run lint'}}]}},
      {'type': 'user', 'uuid': 'r3', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 't3', 'content': '✔ 0 problems'}]}},
      {'type': 'assistant', 'uuid': 'a5', 'message': {'id': 'm2', 'content': [{'type': 'tool_use', 'id': 't4', 'name': 'Write', 'input': {'file_path': '$app/docs/retry-design.md', 'content': '# Retry'}}]}},
      {'type': 'user', 'uuid': 'r4', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 't4', 'content': 'written'}]}},
      {'type': 'assistant', 'uuid': 'a6', 'message': {'id': 'm2', 'content': [{'type': 'tool_use', 'id': 't5', 'name': 'Write', 'input': {'file_path': '$app/reports/test-report.html', 'content': '<html></html>'}}]}},
      {'type': 'user', 'uuid': 'r5', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 't5', 'content': 'written'}]}},
      {'type': 'assistant', 'uuid': 'a7', 'message': {'id': 'm3', 'content': [{'type': 'text', 'text': "Here's the retry flow I implemented:\n\n```mermaid\ngraph TD\n  A[send request] --> B{status 409?}\n  B -- yes --> C[back off 2^n·100ms] --> D[retry]\n  B -- no --> E[done]\n```"}]}},
      ...extraChatLog,
    ].map(jsonEncode).toList();

/// A tail that replays [chatLog] instead of following a file over SSH.
class FakeTail extends SessionLogTail {
  FakeTail(super.host, super.path);
  @override
  Future<void> start() async {
    reportStatus('live');
    feed(Uint8List.fromList(utf8.encode('${chatLog.join('\n')}\n')));
  }
}

/// Board 3b's terminal text, with dim tool lines.
class FakeTerminal implements TerminalTransport {
  FakeTerminal(this.label, {this.lines});

  /// Never closed: a closed stream reads as "Session closed".
  final _out = StreamController<String>();
  @override
  final String label;

  /// What the pane shows instead of board 3b's text (the demo's glyphs screen).
  final List<String>? lines;
  @override
  Stream<String> get output => (_out
        ..add((lines ?? [
          '\x1b[90m● Read src/rig/router.ts (212 lines)\x1b[0m',
          '\x1b[90m● Update src/rig/router.ts\x1b[0m',
          '\x1b[90m    + 18 lines, - 4 lines\x1b[0m',
          'impl finished slice 3; review flagged the',
          'missing retry on 409. Next I want to run',
          'the integration suite against staging.',
          '',
          '\x1b[90m|| Waiting for your permission...\x1b[0m',
        ]).join('\r\n')))
      .stream;
  @override
  void sendRaw(String data) {}
  @override
  void resize(int cols, int rows) {}
  @override
  Future<void> close() async {}
}

/// For boards: "ago" reads the moment the fixtures' times are offsets from, so a render can't flip from "just now"
/// to "1m ago" with the wall clock. Tests that build times from DateTime.now() leave it alone.
void pinAgoClock() => debugAgoClock = _now;

/// Points every seam at the fake host. Call in setUp.
Future<HostStore> installFakes() async {
  queueOverrides.clear();
  queueAdded.clear();
  homeOrder.reset();
  homeIdleOpen.clear();
  AppShell.debugStartOnInbox = true; // the sidebar and Inbox tests; the Rigs home tests turn it off
  showLoose = false;
  showUsageLimit = false;
  showWorktrees = false;
  showBarRigs = false;
  extraAttention = [];
  toastProblems.value = const [];
  extraChatLog = [];
  fleet.reset();
  usageNow.reset();
  debugUsageClock = DateTime.utc(2026, 11, 2, 12);
  debugAgoClock = null;
  AppScope.resetClients();
  FlutterSecureStorage.setMockInitialValues({});
  final store = HostStore();
  await store.load();
  await store.upsert(homelab);
  await store.upsert(macbook);
  await store.select(homelab.id);
  OpenRigClient.factory = (h) => OpenRigClient(
        h,
        httpClient: fakeDaemon(h),
        eventSource: ({rigId, replay, lastEventId}) =>
            rigId == 'r-conveyor' && lastEventId == null ? Stream.fromIterable(conveyorEvents).asBroadcastStream() : const Stream.empty(),
      );
  SshExec.debugConnect = (h) async => SshExec.fake(fakeShell);
  SessionLogTail.factory = FakeTail.new;
  debugOpenTerminal = (h, t) async => FakeTerminal('ssh homelab · tmux attach -t conveyor-lead');
  MermaidView.useWebView = false;
  return store;
}

Seat seatFromFixture(String rigId, String logicalId) =>
    Seat.fromJson(nodes[rigId]!.firstWhere((n) => n['logicalId'] == logicalId));

Rig rigFromFixture(String rigId) => Rig.fromJson(rigs.firstWhere((r) => r['rigId'] == rigId));

/// A phone: 390×844 with notch and home-indicator insets, the app's theme,
/// and a page underneath so screens show their back button.
Widget phone(HostStore store, Widget screen, {bool dark = false, bool root = false, double height = 844, double width = 390}) {
  final tokens = dark ? Tokens.dark : Tokens.light;
  return AppScope(
    store: store,
    child: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: const EdgeInsets.only(top: 47, bottom: 34),
          viewPadding: const EdgeInsets.only(top: 47, bottom: 34),
        ),
        child: Theme(
          data: buildTheme(tokens, dark ? Brightness.dark : Brightness.light),
          child: SizedBox(
            width: width,
            height: height,
            child: Navigator(
              pages: [
                if (!root) const MaterialPage(child: SizedBox.shrink()),
                MaterialPage(child: screen),
              ],
              onDidRemovePage: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
}

/// Opens the shell's sidebar drawer (the menu button at the root of the panel).
Future<void> openDrawer(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.menu).first);
  await tester.pumpAndSettle();
}

/// The fake remote host's home, for the folder browser: folders with a git mark, an empty one and one nobody can read.
const fakeHome = '/Users/me';
const _fakeTree = <String, List<(String, bool)>>{
  fakeHome: [('code', false), ('Documents', false), ('notes', false)],
  '$fakeHome/code': [
    ('app', true),
    ('site', true),
    ('notes', false),
    ('scratch', false),
    ('pocketrig', true),
    ('archive', false),
    ('experiments', false),
  ],
  '$fakeHome/code/app': [('rigs', false), ('docs', false)],
  '$fakeHome/code/notes': [('ideas', false)],
  '$fakeHome/Documents': [],
  '$fakeHome/code/scratch': [], // an empty folder
};

/// `SshExec.listFolders` on the fake host: [fakeHome] and its tree; `archive` is unreadable, `afile` a file, the rest missing.
String fakeFolders(String cmd) {
  final m = RegExp(r'd=(?:"\$HOME"(?:/\x27([^\x27]*)\x27)?|\x27([^\x27]*)\x27);').firstMatch(cmd);
  final path = m == null ? fakeHome : (m.group(2) ?? (m.group(1) == null ? fakeHome : '$fakeHome/${m.group(1)}'));
  if (path.endsWith('archive')) return '@@pocketrig-unreadable\n';
  if (path.contains('afile')) return '@@pocketrig-file\n';
  final folders = _fakeTree[path];
  if (folders == null) return '@@pocketrig-nodir\n';
  return '${['@@pocketrig-folders', path, for (final (n, git) in folders) '${git ? 'g' : '-'} $n'].join('\n')}\n';
}
