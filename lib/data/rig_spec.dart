import 'package:yaml/yaml.dart';

import '../models.dart';

final _inWorktree = RegExp('^$worktreeDirs/([^/]+)/');

/// A RigSpec YAML file found in a project folder over SSH.
class RigSpecFile {
  RigSpecFile({required this.path, required this.projectPath});

  /// Absolute path on the host.
  final String path;
  final String projectPath;

  /// Path shown in the UI, relative to the project folder.
  String get relativePath =>
      path.startsWith('$projectPath/') ? path.substring(projectPath.length + 1) : path;

  /// The project's worktree this copy is in; null in the main checkout.
  String? get worktree => _inWorktree.firstMatch(relativePath)?.group(1);

  /// Path inside its checkout, the same for every worktree's copy of a spec.
  String get checkoutPath => relativePath.replaceFirst(_inWorktree, '');
}

class SpecMember {
  SpecMember({
    required this.id,
    this.runtime,
    this.agentRef,
    this.cwd,
    this.label,
    this.role,
    this.model,
    this.effort,
    this.profile,
    this.permissionPolicy,
    this.claudePermissions = const {},
  });
  final String id;
  final String? runtime;
  final String? agentRef;
  final String? cwd;
  final String? label;

  /// The seat's declared role, for workflow binding (`role:`).
  final String? role;
  final String? model;
  final String? effort;
  final String? profile;

  /// `permission_policy`: `builtin:<name>`, a spec-relative path, or `none`.
  final String? permissionPolicy;

  /// `claude_permissions`: tool rules by list (`allow`, `deny`, `ask`).
  final Map<String, List<String>> claudePermissions;

  /// "Claude Code · claude-opus-5-5 · high effort · standard": what a row
  /// says about how a seat runs.
  String get oneLine => [
        runtimeLabel(runtime),
        if (model != null) model!,
        if (effort != null) '$effort effort',
        if (permissionPolicy != null) permissionPolicy!.replaceFirst('builtin:', ''),
      ].join(' · ');

  static String runtimeLabel(String? runtime) => switch (runtime) {
        'claude-code' => 'Claude Code',
        'codex' => 'Codex',
        'pi' => 'Pi',
        'terminal' => 'Terminal',
        null => 'default runtime',
        final r => r,
      };

  String get runtimeBadge => switch (runtime) {
        'claude-code' => 'CC',
        'codex' => 'CX',
        'terminal' => 'SH',
        null => '··',
        final String r => r.substring(0, r.length < 2 ? r.length : 2).toUpperCase(),
      };
}

class SpecPod {
  SpecPod({required this.id, this.label, required this.members});
  final String id;
  final String? label;
  final List<SpecMember> members;
}

class SpecEdge {
  SpecEdge(this.from, this.kind, this.to, {this.pod, this.index = 0});
  final String from;
  final String kind;
  final String to;

  /// Which `edges:` list holds it: the pod at this index, or the rig's (null).
  final int? pod;
  final int index;
}

/// The parts of a RigSpec (version 0.2 layout) the app shows. Parsing never
/// throws on unknown shapes; [error] is set when the YAML itself is invalid.
class RigSpecSummary {
  RigSpecSummary({
    this.name,
    this.version,
    this.summary,
    this.pods = const [],
    this.edges = const [],
    this.permissionPolicy,
    this.cultureFile,
    this.error,
  });

  final String? name;
  final String? version;
  final String? summary;
  final List<SpecPod> pods;
  final List<SpecEdge> edges;

  /// The rig-wide `permission_policy` ref; a member's own overrides it.
  final String? permissionPolicy;
  final String? cultureFile;
  final String? error;

  /// Every seat as `pod.member`, in spec order.
  List<String> get qualifiedIds => [for (final p in pods) for (final m in p.members) '${p.id}.${m.id}'];

  int get seatCount => pods.fold(0, (n, p) => n + p.members.length);

  Set<String> get runtimes =>
      {for (final p in pods) for (final m in p.members) if (m.runtime != null) m.runtime!};

  /// "2 pods · 4 seats · claude-code + codex"
  String get oneLine {
    if (error != null) return 'invalid YAML';
    // "claude + codex", as the boards and the Projects list write it.
    final short = runtimes.map((r) => r == 'claude-code' ? 'claude' : r);
    final rt = runtimes.isEmpty ? '' : ' · ${short.join(' + ')}';
    return '${pods.length} pod${pods.length == 1 ? '' : 's'} · $seatCount seat${seatCount == 1 ? '' : 's'}$rt';
  }

  static String? _str(Object? v) => v == null ? null : '$v'.trim().isEmpty ? null : '$v'.trim();

  static List<SpecEdge> _edges(Object? list, [String? podPrefix, int? podIndex]) {
    if (list is! List) return const [];
    return [
      for (final (i, e) in list.indexed)
        if (e is Map && e['from'] != null && e['to'] != null)
          SpecEdge(
            podPrefix != null && !'${e['from']}'.contains('.') ? '$podPrefix.${e['from']}' : '${e['from']}',
            _str(e['kind']) ?? 'edge',
            podPrefix != null && !'${e['to']}'.contains('.') ? '$podPrefix.${e['to']}' : '${e['to']}',
            pod: podIndex,
            index: i,
          ),
    ];
  }

  static Map<String, List<String>> _rules(Object? v) {
    if (v is! Map) return const {};
    return {
      for (final e in v.entries)
        if (e.value is List) '${e.key}': [for (final r in e.value as List) '$r'],
    };
  }

  factory RigSpecSummary.parse(String text) {
    final Object? doc;
    try {
      doc = loadYaml(text);
    } on YamlException catch (e) {
      return RigSpecSummary(error: e.message);
    } catch (e) {
      return RigSpecSummary(error: '$e');
    }
    if (doc is! Map) return RigSpecSummary(error: 'Not a RigSpec (top level is not a map)');

    final pods = <SpecPod>[];
    final edges = <SpecEdge>[];
    final rawPods = doc['pods'];
    if (rawPods is List) {
      for (final (pi, p) in rawPods.indexed) {
        if (p is! Map) continue;
        final id = _str(p['id']) ?? 'pod';
        final members = <SpecMember>[];
        final rawMembers = p['members'];
        if (rawMembers is List) {
          for (final m in rawMembers) {
            if (m is! Map) continue;
            members.add(SpecMember(
              id: _str(m['id']) ?? '?',
              runtime: _str(m['runtime']),
              agentRef: _str(m['agent_ref']),
              cwd: _str(m['cwd']),
              label: _str(m['label']),
              role: _str(m['role']),
              model: _str(m['model']),
              effort: _str(m['effort']),
              profile: _str(m['profile']),
              permissionPolicy: _str(m['permission_policy']),
              claudePermissions: _rules(m['claude_permissions']),
            ));
          }
        }
        pods.add(SpecPod(id: id, label: _str(p['label']), members: members));
        edges.addAll(_edges(p['edges'], id, pi));
      }
    }
    edges.addAll(_edges(doc['edges']));
    return RigSpecSummary(
      name: _str(doc['name']),
      version: _str(doc['version']),
      summary: _str(doc['summary']),
      pods: pods,
      edges: edges,
      permissionPolicy: _str(doc['permission_policy']),
      cultureFile: _str(doc['culture_file']),
    );
  }
}

/// `error` as a sentence: a string, or the `{fact, consequence, action}`
/// object OpenRig uses for launches that need attention.
String? describeErrorField(Object? e) {
  if (e is String) return e;
  if (e is Map) {
    final parts = [e['fact'], e['consequence'], e['action']].whereType<String>().where((p) => p.isNotEmpty);
    if (parts.isNotEmpty) return parts.join(' ');
    if (e['message'] is String) return e['message'] as String;
  }
  return null;
}

/// What `POST /api/up` answered, in plan or apply mode.
class LaunchResult {
  LaunchResult({required this.status, this.rigId, this.stages = const [], this.errors = const [], this.failedSeats = const {}});

  /// planned | completed | partial | failed | ...
  final String status;
  final String? rigId;
  final List<(String stage, String status, String? detail)> stages;
  final List<String> errors;

  /// The seats that failed to launch, by logical id, with why: `stages[].detail.nodes[]` entries with `status: failed` and an `error`
  /// (what OpenRig 0.7.22's `rig up` names). Empty for a launch that started every seat.
  final Map<String, String> failedSeats;

  /// `restored` is what restoring a stopped rig by name answers.
  bool get ok => const {'planned', 'completed', 'partial', 'restored'}.contains(status);

  factory LaunchResult.fromJson(Object? json) {
    if (json is! Map) return LaunchResult(status: 'unknown');
    final stages = <(String, String, String?)>[];
    final rawStages = json['stages'];
    if (rawStages is List) {
      for (final s in rawStages) {
        if (s is! Map) continue;
        final d = s['detail'];
        final detail = d == null
            ? null
            : d is String
                ? d
                : d is Map
                    ? (d['message'] ?? d['summary'] ?? d['reason'])?.toString()
                    : null;
        stages.add(('${s['stage'] ?? '?'}', '${s['status'] ?? '?'}', detail));
      }
    }
    final failed = <String, String>{};
    if (rawStages is List) {
      for (final s in rawStages) {
        final d = s is Map ? s['detail'] : null;
        final nodes = d is Map ? d['nodes'] : null;
        if (nodes is! List) continue;
        for (final n in nodes) {
          if (n is Map && n['status'] == 'failed' && n['logicalId'] is String && n['error'] is String) {
            failed[n['logicalId'] as String] = n['error'] as String;
          }
        }
      }
    }
    final errs = json['errors'];
    return LaunchResult(
      status: '${json['status'] ?? (json['error'] != null ? 'failed' : 'unknown')}',
      rigId: json['rigId'] as String?,
      stages: stages,
      failedSeats: failed,
      errors: [
        if (errs is List) ...errs.map((e) => '$e'),
        if (describeErrorField(json['error']) != null) describeErrorField(json['error'])!,
        // A partial launch names the seats that need you.
        if (json['attentionNodes'] is List && (json['attentionNodes'] as List).isNotEmpty)
          'Needs you: ${(json['attentionNodes'] as List).map((n) => n is Map ? (n['logicalId'] ?? n['sessionName'] ?? '?') : '$n').join(', ')}',
      ],
    );
  }
}
