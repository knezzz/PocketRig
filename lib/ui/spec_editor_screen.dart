import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/rig_spec.dart';
import '../data/rig_spec_edit.dart';
import '../main.dart';
import '../models.dart';
import '../ssh/ssh_exec.dart';
import 'common.dart';
import 'option_sheet.dart';
import 'kit.dart';
import 'switch_row.dart';
import 'theme.dart';

part 'spec_editor_fields.dart';
part 'spec_editor_member.dart';
part 'spec_editor_sheets.dart';

/// Board 1c: edit a RigSpec without touching the YAML. Departments (pods)
/// hold roles (members); each role picks its runtime and provider, model,
/// effort and permissions; relationships are the edges between roles.
/// Save writes the file back over SSH and returns the new text.
class SpecEditorScreen extends StatefulWidget {
  const SpecEditorScreen({super.key, required this.file, required this.text, required this.projectName, this.member});
  final RigSpecFile file;
  final String text;
  final String projectName;

  /// A seat's logical id (`dev.impl`): opens straight on that member's sheet.
  final String? member;

  @override
  State<SpecEditorScreen> createState() => _SpecEditorScreenState();
}

class _SpecEditorScreenState extends State<SpecEditorScreen> {
  late RigSpecEditor _ed = RigSpecEditor(widget.text);
  late final _yaml = TextEditingController(text: widget.text);

  /// Why the typed YAML can't be used; Save waits until it parses.
  final _yamlErrorN = ValueNotifier<String?>(null);
  String? get _yamlError => _yamlErrorN.value;
  bool _dirty = false;

  /// Form edits since opening, and whether YAML was typed: the header's count.
  int _changes = 0;
  bool _typedEdits = false;
  bool _saving = false;
  String? _error;

  RigSpecSummary get _spec => _ed.spec;

  @override
  void initState() {
    super.initState();
    final id = widget.member;
    if (id == null) return;
    for (final (pi, p) in _spec.pods.indexed) {
      for (final (mi, m) in p.members.indexed) {
        if ('${p.id}.${m.id}' == id) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _editMember(pi, mi);
          });
          return;
        }
      }
    }
  }

  /// Applies one change to the YAML and redraws from it.
  void _change(void Function() apply) {
    setState(() {
      try {
        apply();
        _dirty = true;
        _changes++;
        _error = null;
        _yaml.text = _ed.text;
      } catch (e) {
        _error = 'Couldn\'t apply that change: $e';
      }
    });
  }

  @override
  void dispose() {
    _yaml.dispose();
    _yamlErrorN.dispose();
    super.dispose();
  }

  /// YAML typed in the side pane (wide windows): the form redraws from it.
  void _typed(String text) {
    setState(() {
      _dirty = true;
      _typedEdits = true;
      try {
        _ed = RigSpecEditor(text);
        _yamlErrorN.value = _ed.spec.error;
      } catch (e) {
        _yamlErrorN.value = '$e';
      }
    });
  }

  Future<void> _save() async {
    final host = AppScope.read(context).active;
    if (host == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    SshExec? ssh;
    try {
      ssh = await SshExec.connect(host);
      await ssh.writeFile(widget.file.path, _ed.text);
      if (!mounted) return;
      toast(context, 'Saved ${widget.file.relativePath}');
      Navigator.of(context).pop(_ed.text);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Couldn\'t save over SSH: $e';
        });
        toast(context, 'Couldn\'t save over SSH');
      }
    } finally {
      ssh?.close();
    }
  }

  Future<void> _leave() async {
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await confirmSheet(context,
        title: 'Discard changes?',
        body: '${widget.file.relativePath} hasn\'t been saved.',
        action: 'Discard',
        cancel: 'Keep editing');
    if (discard && mounted) Navigator.of(context).pop();
  }

  // ── Sheets ───────────────────────────────────────────────────────────

  Future<T?> _sheet<T>(Widget child) => showModalBottomSheet<T>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (_) => SafeArea(top: false, child: child),
      );

  Future<void> _editText(String title, String key, String? value, {String? hint, int lines = 1}) async {
    final v = await _sheet<String>(_TextSheet(title: title, value: value ?? '', hint: hint, lines: lines));
    if (v == null) return;
    _change(() => _ed.setRigField(key, v));
  }

  /// Reads the culture file beside the spec, edits it, and writes it straight back.
  Future<void> _editCulture() async {
    final host = AppScope.read(context).active;
    if (host == null) return;
    final name = _spec.cultureFile ?? 'CULTURE.md';
    final dir = widget.file.path.substring(0, widget.file.path.lastIndexOf('/'));
    // shortcut: `~/` paths aren't expanded; resolve them if a spec ever uses one.
    final path = name.startsWith('/') ? name : '$dir/$name';
    SshExec? ssh;
    try {
      ssh = await SshExec.connect(host);
      var text = '';
      try {
        text = await ssh.readFile(path);
      } catch (e) {
        if (!'$e'.contains('No such file')) rethrow;
      }
      if (!mounted) return;
      final v = await _sheet<String>(_TextSheet(title: name, value: text, hint: 'How this team works', lines: 14));
      if (v == null || v == text) return;
      await ssh.writeFile(path, v);
      if (!mounted) return;
      toast(context, 'Saved $name');
      if (_spec.cultureFile == null) _change(() => _ed.setRigField('culture_file', name));
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Couldn\'t edit $name: $e');
        toast(context, 'Couldn\'t save $name over SSH');
      }
    } finally {
      ssh?.close();
    }
  }

  Future<void> _editPolicy() async {
    final v = await _sheet<String>(_PolicySheet(value: _spec.permissionPolicy, rigLevel: true));
    if (v == null) return;
    _change(() => _ed.setRigField('permission_policy', v == _PolicySheet.inherit ? null : v));
  }

  /// A rig field that is one of a few values (a switch, an enum); null is "not set".
  Future<void> _pick<T>(String title, T current, List<(T, String)> options, void Function(T) apply, {String? note}) async {
    final r = await _sheet<(T,)>(OptionSheet<T>(title: title, current: current, options: [for (final (v, l) in options) (v, l, null)], note: note, wrap: true));
    if (r != null) _change(() => apply(r.$1));
  }

  static const _onOff = <(bool?, String)>[(null, 'Not set'), (true, 'On'), (false, 'Off')];

  Future<void> _editBlock(String title, String key, {String? hint}) async {
    final r = await _sheet<(Object?,)>(_BlockSheet(title: title, value: _ed.rigValue(key), hint: hint));
    if (r != null) _change(() => _ed.setRigValue(key, r.$1));
  }

  Future<void> _editEnv() async {
    final r = await _sheet<Map<String, String>>(_EnvSheet(
        title: 'Environment',
        value: _ed.rigValue('env'),
        note: 'For every seat; a role\'s own variables win. Not secret: the values are stored in the spec.'));
    if (r != null) _change(() => _ed.setRigValue('env', r));
  }

  Future<void> _editPod(int? index) async {
    final pod = index == null ? null : _spec.pods[index];
    final taken = {
      for (final (i, p) in _spec.pods.indexed)
        if (i != index) p.id
    };
    final r = await _sheet<_PodEdit>(
        _PodSheet(pod: pod, taken: taken, summary: index == null ? null : _ed.podValue(index, 'summary'), blocks: {
      for (final k in _podBlocks.keys) k: index == null ? null : _ed.podValue(index, k)
    }));
    if (r == null) return;
    _change(() {
      if (r.delete) {
        _ed.removePod(index!);
      } else if (index == null) {
        _ed.addPod(id: r.id, label: r.label);
        _ed.updatePodFields(_spec.pods.length - 1, r.fields);
      } else {
        _ed.updatePod(index, id: r.id, label: r.label);
        _ed.updatePodFields(index, r.fields);
      }
    });
  }

  Future<void> _editMember(int pod, int? index) async {
    final p = _spec.pods[pod];
    final member = index == null ? null : p.members[index];
    final taken = {
      for (final (i, m) in p.members.indexed)
        if (i != index) m.id
    };
    final raw = index == null ? const <String, Object?>{} : _ed.memberMap(pod, index);
    final r = await _sheet<_MemberEdit>(_MemberSheet(member: member, podLabel: p.label ?? p.id, taken: taken, raw: raw));
    if (r == null) return;
    _change(() {
      if (r.delete) {
        _ed.removeMember(pod, index!);
      } else if (index == null) {
        _ed.addMember(pod, r.fields);
      } else {
        _ed.updateMember(pod, index, r.fields);
      }
    });
  }

  Future<void> _editEdge(SpecEdge? edge) async {
    final r = await _sheet<_EdgeEdit>(_EdgeSheet(edge: edge, seats: _spec.qualifiedIds));
    if (r == null) return;
    _change(() {
      if (r.delete) {
        _ed.removeEdge(edge!);
      } else if (edge == null) {
        _ed.addEdge(r.from, r.kind, r.to);
      } else {
        _ed.updateEdge(edge, from: r.from, kind: r.kind, to: r.to);
      }
    });
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final t = Theme.of(context).textTheme;
    final spec = _spec;
    final seats = spec.qualifiedIds;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () {
            if (_dirty && !_saving && _yamlError == null) _save();
          },
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            // One width decides both the side pane and the YAML button.
            body: LayoutBuilder(builder: (context, page) {
              final narrow = page.maxWidth < 760;
              return Column(children: [
              PageHeader(
                overline: '${widget.projectName} · edit spec',
                title: 'Edit ${spec.name ?? widget.file.relativePath}',
                back: _leave,
                // Under the title, so the title row is the title and Save.
                bottom: narrow ? Align(alignment: Alignment.centerLeft, child: PillButton('YAML', onPressed: _openYaml)) : null,
                actions: [
                  PillButton(_saving ? 'Saving…' : 'Save',
                      filled: true, onPressed: _dirty && !_saving && _yamlError == null ? _save : null),
                ],
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final form = ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                      children: [
                        if (_error != null) ErrorBanner(_error!, margin: const EdgeInsets.only(bottom: 16)),
                        if (narrow) // the wide layout shows it beside the YAML
                        ValueListenableBuilder<String?>(
                          valueListenable: _yamlErrorN,
                          builder: (_, e, __) =>
                              e == null ? const SizedBox.shrink() : ErrorBanner('YAML doesn\'t parse: $e', margin: const EdgeInsets.only(bottom: 16)),
                        ),
                        // The path once, cut in the middle so the file name stays, and how the spec stands.
                        Text(middleEllipsis(displayPath(widget.file.path), max: 44), maxLines: 1, style: mono(context)),
                        const SizedBox(height: 4),
                        ValueListenableBuilder<String?>(
                          valueListenable: _yamlErrorN,
                          builder: (context, bad, _) {
                            final valid = bad == null && spec.error == null;
                            final n = _changes + (_typedEdits ? 1 : 0);
                            final color = valid ? k.added : k.removed;
                            return Row(children: [
                              Icon(valid ? Icons.check : Icons.error_outline, size: 14, color: color),
                              const SizedBox(width: 4),
                              Text(valid ? 'valid' : 'invalid',
                                  style: mono(context).copyWith(color: color, fontWeight: FontWeight.w600)),
                              Text(' · ${n == 0 ? 'no changes' : '$n change${n == 1 ? '' : 's'}'}', style: mono(context)),
                            ]);
                          },
                        ),
                        const SizedBox(height: 12),
                        BorderedList(
                          header: Text('Rig', style: t.titleSmall),
                          children: [
                            _Field('Name', spec.name,
                                onTap: () => _editText('Rig name', 'name', spec.name, hint: 'my-rig')),
                            _Field('Summary', spec.summary,
                                onTap: () => _editText('Summary', 'summary', spec.summary,
                                    hint: 'What this rig is for', lines: 4)),
                            _Field('Permission policy', _policyLabel(spec.permissionPolicy, rigLevel: true),
                                onTap: _editPolicy),
                            // One row: the culture file's name, and it opens the file (or creates it).
                            _Field('Culture', spec.cultureFile ?? 'Create CULTURE.md', mono: spec.cultureFile != null, onTap: _editCulture),
                          ],
                        ),
                        const SizedBox(height: 12),
                        BorderedList(
                          header: Text('Rig options', style: t.titleSmall),
                          children: [
                            _Field('Non-interruptive', _onOffLabel(_ed.rigValue('non_interruptive')),
                                onTap: () => _pick<bool?>('Non-interruptive', _ed.rigValue('non_interruptive') as bool?,
                                    _onOff, (v) => _ed.setRigValue('non_interruptive', v),
                                    note: 'Accepts the harness\'s supported launch warnings on full-bypass seats. It grants no permissions.')),
                            _Field('Environment', _envLabel(_ed.rigValue('env')), onTap: _editEnv),
                            _Field('Claude instruction file', _managedFile(_ed.rigValue('managed_blocks')) ?? 'CLAUDE.md (default)',
                                mono: true,
                                onTap: () => _pick<String?>(
                                    'Claude instruction file',
                                    _managedFile(_ed.rigValue('managed_blocks')),
                                    [(null, 'Not set (CLAUDE.md)'), for (final f in managedBlockFiles) (f, f)],
                                    (v) => _ed.setRigValue('managed_blocks', v == null ? null : {'claude-code': v}),
                                    note: 'Where OpenRig writes its managed blocks for Claude Code seats.')),
                            for (final (title, key, hint) in _rigBlocks)
                              _Field(title, _blockLabel(_ed.rigValue(key)), onTap: () => _editBlock(title, key, hint: hint)),
                          ],
                        ),
                        const SizedBox(height: 20),
                        SectionLabel('Departments · ${spec.pods.length}'),
                        for (final (pi, pod) in spec.pods.indexed)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: BorderedList(
                              header: InkWell(
                                onTap: () => _editPod(pi),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(minHeight: 48),
                                  child: Row(children: [
                                    Expanded(
                                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                        Text(pod.label ?? pod.id, style: t.titleSmall),
                                        Text(pod.id, style: mono(context)),
                                      ]),
                                    ),
                                    Icon(Icons.edit_outlined, size: 16, color: k.muted),
                                  ]),
                                ),
                              ),
                              children: [
                                for (final (mi, m) in pod.members.indexed)
                                  RowTile(
                                    minHeight: 56,
                                    leading: RuntimeSquare(m.runtimeBadge, size: 28),
                                    title: m.role == null ? m.id : '${m.id} · ${m.role}',
                                    meta: m.oneLine,
                                    extra: m.agentRef,
                                    trailing: const Chevron(),
                                    onTap: () => _editMember(pi, mi),
                                  ),
                                RowTile(
                                  minHeight: 44,
                                  leading: SizedBox(width: 24, child: Icon(Icons.add, size: 18, color: k.muted)),
                                  title: 'Add role',
                                  onTap: () => _editMember(pi, null),
                                ),
                              ],
                            ),
                          ),
                        OutlinedButton.icon(
                          onPressed: () => _editPod(null),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add department'),
                          style: OutlinedButton.styleFrom(
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius))).merge(sheetAction),
                        ),
                        const SizedBox(height: 20),
                        SectionLabel('Relationships · ${spec.edges.length}'),
                        BorderedList(children: [
                          for (final e in spec.edges)
                            RowTile(
                              minHeight: 52,
                              title: '${e.from}  →  ${e.to}',
                              meta: edgeKindLabel(e.kind),
                              trailing: const Chevron(),
                              onTap: () => _editEdge(e),
                            ),
                          RowTile(
                            minHeight: 44,
                            leading: SizedBox(width: 24, child: Icon(Icons.add, size: 18, color: k.muted)),
                            title: 'Add relationship',
                            meta: seats.length < 2 ? 'needs two roles' : null,
                            onTap: seats.length < 2 ? null : () => _editEdge(null),
                          ),
                        ]),
                        const SizedBox(height: 16),
                        Text(
                            'Comments and any field the editor doesn\'t know are kept as they are. The YAML shows everything.',
                            style: t.bodySmall),
                      ],
                    );
                    if (narrow) return form;
                    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(child: form),
                      Expanded(child: _yamlPane(context)),
                    ]);
                  },
                ),
              ),
            ]);
            }),
          ),
        ),
      ),
    );
  }

  /// The whole spec as text, full screen: the side pane's phone-sized twin.
  void _openYaml() => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (ctx) => Scaffold(
          body: Column(children: [
            PageHeader(overline: widget.projectName, title: 'YAML', back: () => Navigator.of(ctx).pop()),
            Expanded(child: _yamlPane(ctx)),
          ]),
        ),
      ));

  /// The spec as text beside the form: follows the form, and typing here redraws it.
  Widget _yamlPane(BuildContext context) {
    final k = Tokens.of(context);
    return ValueListenableBuilder<String?>(
      valueListenable: _yamlErrorN,
      builder: (context, bad, _) => _yamlBox(context, k, bad),
    );
  }

  Widget _yamlBox(BuildContext context, Tokens k, String? bad) {
    return ColoredBox(
      color: k.termBg,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: k.termDim.withValues(alpha: 0.25)))),
          child: Row(children: [
            Expanded(child: Text(widget.file.relativePath, style: mono(context, color: k.termDim))),
            Text(bad == null ? '✓ valid' : '! doesn\'t parse',
                style: mono(context, color: bad == null ? Tokens.dark.added : Tokens.dark.accent)),
          ]),
        ),
        if (bad != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: Text(bad,
                style: mono(context, color: Tokens.dark.accent), maxLines: 3, overflow: TextOverflow.ellipsis),
          ),
        Expanded(
          child: Semantics(
            label: 'Spec YAML',
            child: TextField(
              controller: _yaml,
              onChanged: _typed,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: mono(context, size: 12, color: k.termFg).copyWith(height: 1.55),
              cursorColor: k.termFg,
              decoration: const InputDecoration(
                border: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.all(14),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Rig-level nested blocks edited as YAML: title, key, an example.
const _rigBlocks = [
  ('Startup', 'startup', 'files:\n  - path: guidance/team-norms.md\n    required: true'),
  ('Services', 'services', 'kind: compose\ncompose_file: docker-compose.yaml'),
  ('Workspace', 'workspace', 'workspace_root: .\nrepos:\n  - {name: app, path: app, kind: project}'),
  ('Docs', 'docs', '- path: SETUP.md'),
];

/// Department blocks edited as YAML: key to title and an example.
const _podBlocks = {
  'continuity_policy': ('Continuity policy', 'enabled: true\nsync_triggers: [pre_compaction, pre_shutdown]'),
  'startup': ('Startup', 'files:\n  - path: guidance/dev-sop.md\n    required: true'),
};

/// Role blocks edited as YAML: key to title and an example.
const _memberBlocks = {
  'startup': ('Startup', 'files:\n  - path: guidance/impl.md\n    required: false'),
  'session_source': ('Session source', 'mode: fork\nref:\n  kind: native_id\n  value: 0f3c9a1e-…'),
  'claude_token': ('Claude token', 'label: dev-sub\nfile: /abs/tokens/dev.token'),
  'codex_permissions': ('Codex permissions', 'sandbox: workspace-write\napproval: never'),
};
const _memberBlockKeys = ['startup', 'session_source', 'claude_token', 'codex_permissions'];

String _onOffLabel(Object? v) => switch (v) {
      true => 'On',
      false => 'Off',
      _ => '—',
    };

String? _managedFile(Object? v) => v is Map ? v['claude-code'] as String? : null;

String _policyLabel(String? ref, {required bool rigLevel}) => switch (ref) {
      null => rigLevel ? 'runtime default' : 'inherit from rig',
      'none' => 'none (deliberately unset)',
      final r when r.startsWith('builtin:') => r.substring('builtin:'.length),
      final r => r,
    };
