import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'rig_spec.dart';

/// Runtimes a seat can run on: id, name, and the provider behind it.
const runtimeChoices = [
  ('claude-code', 'Claude Code', 'Anthropic'),
  ('codex', 'Codex', 'OpenAI'),
  ('pi', 'Pi', 'any provider'),
  ('terminal', 'Terminal', 'a plain shell, no agent'),
];

/// Effort levels each runtime is known to accept (OpenRig's list).
const effortLevels = {
  'claude-code': ['low', 'medium', 'high', 'xhigh', 'max'],
  'codex': ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'],
  'pi': ['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'],
};

/// Model ids worth offering per runtime; any id can still be typed.
const modelSuggestions = {
  'claude-code': ['claude-fable-5-1', 'claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5'],
  'codex': ['gpt-6-astra'],
};

/// OpenRig's packaged permission policies (`permission_policy: builtin:<name>`).
const builtinPolicies = ['locked', 'standard', 'open', 'yolo', 'auto'];

/// `restore_policy` values (rig-spec.md, Member).
const restorePolicies = ['resume_if_possible', 'relaunch_fresh', 'checkpoint_only'];

/// `compaction_strategy` values; the deprecated aliases are left out.
const compactionStrategies = ['default-compaction', 'managed-compaction', 'handover', 'apprentice-handover'];

/// `managed_blocks.claude-code` values.
const managedBlockFiles = ['CLAUDE.md', 'CLAUDE.local.md'];

/// An `env` name: upper case, digits and `_`; `OPENRIG_` is reserved.
final envNamePattern = RegExp(r'^[A-Z_][A-Z0-9_]*$');

/// A path beside the spec: not absolute, no `..`.
bool safeRelativePath(String p) => p.isNotEmpty && !p.startsWith('/') && !p.split('/').contains('..');

/// Why these name/value rows can't be an `env`, or null. Rows with neither name nor value are skipped.
String? envError(Iterable<(String, String)> rows) {
  final seen = <String>{};
  for (final (n, v) in rows) {
    final name = n.trim();
    if (name.isEmpty && v.trim().isEmpty) continue;
    if (!envNamePattern.hasMatch(name)) return '"$name" isn\'t a valid name (capitals, digits and _)';
    if (name.startsWith('OPENRIG_')) return '$name is reserved: names starting OPENRIG_ are refused';
    if (v.trim().isEmpty) return '$name needs a value';
    if (!seen.add(name)) return '$name is listed twice';
  }
  return null;
}

/// The rows as the spec's `env` map (empty when there are none).
Map<String, String> envMap(Iterable<(String, String)> rows) =>
    {for (final (n, v) in rows) if (n.trim().isNotEmpty) n.trim(): v.trim()};

/// Parses a nested block typed as YAML: null when blank, a [FormatException] saying why when it doesn't parse.
Object? parseYamlBlock(String text) {
  if (text.trim().isEmpty) return null;
  try {
    return RigSpecEditor._plain(loadYaml(text));
  } on YamlException catch (e) {
    throw FormatException(e.message);
  }
}

/// A value as block-style YAML text; empty for null.
String yamlBlockText(Object? value) {
  if (value == null) return '';
  final y = YamlEditor('')..update([], value);
  return y.toString().trimRight();
}

/// Edge kinds the daemon accepts, most common first.
const edgeKinds = ['delegates_to', 'escalates_to', 'collaborates_with', 'can_observe', 'spawned_by'];

String edgeKindLabel(String kind) => kind.replaceAll('_', ' ');

/// Pod and member ids: they join as `pod.member`, so no dots.
final idPattern = RegExp(r'^[A-Za-z0-9_-]+$');

/// A Claude tool rule: `Bash(npm run *)`, `Read`, `mcp__github`.
final rulePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_*-]*(?:\(.+\))?$');

/// Edits a RigSpec. Changes go into a plain copy of the document; [text]
/// writes back only the top-level keys that changed (through yaml_edit),
/// so comments and layout elsewhere in the file survive. The sections it
/// rewrites come out in plain block style.
class RigSpecEditor {
  RigSpecEditor(this._original) {
    final doc = loadYaml(_original);
    if (doc is! YamlMap) throw const FormatException('Not a RigSpec (top level is not a map)');
    _doc = _plain(doc) as Map<String, Object?>;
    _before = _plain(doc) as Map<String, Object?>;
  }

  final String _original;
  late final Map<String, Object?> _doc;
  late final Map<String, Object?> _before;
  String? _text;
  RigSpecSummary? _spec;

  /// The spec as it would be saved.
  String get text => _text ??= _render();
  RigSpecSummary get spec => _spec ??= RigSpecSummary.parse(text);

  void _changed() {
    _text = null;
    _spec = null;
  }

  String _render() {
    final y = YamlEditor(_original);
    for (final key in {..._before.keys, ..._doc.keys}) {
      final was = _before[key], now = _doc[key];
      if (_same(was, now)) continue;
      if (now == null) {
        y.remove([key]);
      } else {
        y.update([key], now);
      }
    }
    return y.toString();
  }

  // ── Plain copies and comparison ──────────────────────────────────────

  static Object? _plain(Object? v) => switch (v) {
        YamlMap m => {for (final e in m.entries) '${e.key}': _plain(e.value)},
        YamlList l => [for (final x in l) _plain(x)],
        Map m => {for (final e in m.entries) '${e.key}': _plain(e.value)},
        List l => [for (final x in l) _plain(x)],
        _ => v,
      };

  static bool _same(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length && a.entries.every((e) => b.containsKey(e.key) && _same(e.value, b[e.key]));
    }
    if (a is List && b is List) {
      return a.length == b.length && [for (var i = 0; i < a.length; i++) _same(a[i], b[i])].every((x) => x);
    }
    return a == b;
  }

  static bool _blank(Object? v) =>
      v == null || (v is String && v.trim().isEmpty) || (v is Map && v.isEmpty) || (v is List && v.isEmpty);

  static Object _value(Object v) => v is String ? v.trim() : v;

  static Map<String, Object?> _clean(Map<String, Object?> fields) =>
      {for (final e in fields.entries) if (!_blank(e.value)) e.key: _value(e.value!)};

  List<Object?> _list(Map<String, Object?> map, String key) {
    final v = map[key];
    if (v is List<Object?>) return v;
    return map[key] = <Object?>[];
  }

  List<Object?> get _pods => _list(_doc, 'pods');
  Map<String, Object?> _pod(int i) => _pods[i] as Map<String, Object?>;
  List<Object?> _members(int pod) => _list(_pod(pod), 'members');
  Map<String, Object?> _member(int pod, int i) => _members(pod)[i] as Map<String, Object?>;

  // ── Rig ──────────────────────────────────────────────────────────────

  /// `name`, `summary`, `permission_policy`, `culture_file`; empty removes.
  void setRigField(String key, String? value) {
    if (_blank(value)) {
      _doc.remove(key);
    } else {
      _doc[key] = value!.trim();
    }
    _changed();
  }

  /// Any top-level field, of any type (a switch, a map, a block); null or empty removes it.
  void setRigValue(String key, Object? value) {
    if (_blank(value)) {
      _doc.remove(key);
    } else {
      _doc[key] = _value(value!);
    }
    _changed();
  }

  /// A plain copy of a rig, department or role field, or null when it isn't set.
  Object? rigValue(String key) => _plain(_doc[key]);
  Object? podValue(int pod, String key) => _plain(_pod(pod)[key]);
  Object? memberValue(int pod, int member, String key) => _plain(_member(pod, member)[key]);
  Map<String, Object?> memberMap(int pod, int member) => _plain(_member(pod, member)) as Map<String, Object?>;

  // ── Departments (pods) ───────────────────────────────────────────────

  void addPod({required String id, required String label}) {
    _pods.add(<String, Object?>{'id': id, 'label': label, 'members': <Object?>[], 'edges': <Object?>[]});
    _changed();
  }

  void updatePod(int pod, {required String id, required String label}) {
    final p = _pod(pod);
    final old = '${p['id']}';
    p['label'] = label;
    if (id != old) {
      p['id'] = id;
      _rewriteRefs(_doc, (ref) => ref.startsWith('$old.') ? '$id${ref.substring(old.length)}' : ref);
    }
    _changed();
  }

  /// Sets each department field (`summary`, `continuity_policy`, `startup`); null or empty removes it.
  void updatePodFields(int pod, Map<String, Object?> fields) {
    final p = _pod(pod);
    for (final e in fields.entries) {
      if (_blank(e.value)) {
        p.remove(e.key);
      } else {
        p[e.key] = _value(e.value!);
      }
    }
    _changed();
  }

  void removePod(int pod) {
    final id = '${_pod(pod)['id']}';
    _list(_doc, 'edges').removeWhere((e) => e is Map && (_podOf(e['from']) == id || _podOf(e['to']) == id));
    _pods.removeAt(pod);
    _changed();
  }

  static String _podOf(Object? ref) => '$ref'.contains('.') ? '$ref'.substring(0, '$ref'.indexOf('.')) : '';

  // ── Roles (members) ──────────────────────────────────────────────────

  void addMember(int pod, Map<String, Object?> fields) {
    _members(pod).add(_clean(fields));
    _changed();
  }

  /// Sets each field (null or empty removes it). Renaming a role updates
  /// every relationship that names it.
  void updateMember(int pod, int member, Map<String, Object?> fields) {
    final p = _pod(pod);
    final m = _member(pod, member);
    final old = '${m['id']}';
    for (final e in fields.entries) {
      if (_blank(e.value)) {
        m.remove(e.key);
      } else {
        m[e.key] = _value(e.value!);
      }
    }
    final id = fields['id'];
    if (id is String && id.trim() != old) {
      final podId = '${p['id']}';
      _rewriteRefs(p, (ref) => ref == old ? id.trim() : ref);
      _rewriteRefs(_doc, (ref) => ref == '$podId.$old' ? '$podId.${id.trim()}' : ref);
    }
    _changed();
  }

  void removeMember(int pod, int member) {
    final p = _pod(pod);
    final id = '${_member(pod, member)['id']}';
    final q = '${p['id']}.$id';
    _list(p, 'edges').removeWhere((e) => e is Map && (e['from'] == id || e['to'] == id));
    _list(_doc, 'edges').removeWhere((e) => e is Map && (e['from'] == q || e['to'] == q));
    _members(pod).removeAt(member);
    _changed();
  }

  // ── Relationships (edges) ────────────────────────────────────────────

  /// [from] and [to] are `pod.member`. Within one pod the edge is written
  /// pod-local with bare ids; across pods it goes in the rig's list, as
  /// the daemon requires.
  void addEdge(String from, String kind, String to) {
    final fp = _podOf(from), tp = _podOf(to);
    if (fp == tp) {
      final i = _pods.indexWhere((p) => p is Map && p['id'] == fp);
      if (i < 0) throw ArgumentError('No pod "$fp"');
      _list(_pod(i), 'edges')
          .add(<String, Object?>{'kind': kind, 'from': from.substring(fp.length + 1), 'to': to.substring(tp.length + 1)});
    } else {
      _list(_doc, 'edges').add(<String, Object?>{'kind': kind, 'from': from, 'to': to});
    }
    _changed();
  }

  void removeEdge(SpecEdge e) {
    (e.pod == null ? _list(_doc, 'edges') : _list(_pod(e.pod!), 'edges')).removeAt(e.index);
    _changed();
  }

  void updateEdge(SpecEdge e, {required String from, required String kind, required String to}) {
    removeEdge(e);
    addEdge(from, kind, to);
  }

  /// Rewrites `from`/`to` in the `edges` list of [owner] (the rig or a pod).
  static void _rewriteRefs(Map<String, Object?> owner, String Function(String) f) {
    final edges = owner['edges'];
    if (edges is! List) return;
    for (final e in edges) {
      if (e is! Map) continue;
      for (final key in const ['from', 'to']) {
        final v = e[key];
        if (v is String) e[key] = f(v);
      }
    }
  }
}
