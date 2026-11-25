part of 'spec_editor_screen.dart';

class _MemberEdit {
  _MemberEdit({this.fields = const {}, this.delete = false});

  /// Spec keys to their new value; null removes the key.
  final Map<String, Object?> fields;
  final bool delete;
}

/// Add or edit a role: runtime and provider, model, effort, permissions,
/// agent definition and working folder.
class _MemberSheet extends StatefulWidget {
  const _MemberSheet({required this.member, required this.podLabel, required this.taken, required this.raw});
  final SpecMember? member;
  final String podLabel;
  final Set<String> taken;

  /// The role's whole entry in the spec, for the options the form reads straight from it.
  final Map<String, Object?> raw;
  @override
  State<_MemberSheet> createState() => _MemberSheetState();
}

class _MemberSheetState extends State<_MemberSheet> {
  SpecMember? get m => widget.member;
  late final _id = TextEditingController(text: m?.id ?? '');
  late final _role = TextEditingController(text: m?.role ?? '');
  late final _model = TextEditingController(text: m?.model ?? '');
  late final _agentRef = TextEditingController(text: m?.agentRef ?? '');
  late final _cwd = TextEditingController(text: m?.cwd ?? '');
  late final _policyPath = TextEditingController(text: _customPolicy(m?.permissionPolicy) ? m!.permissionPolicy! : '');
  late final _allow = TextEditingController(text: (m?.claudePermissions['allow'] ?? const []).join('\n'));
  late final _deny = TextEditingController(text: (m?.claudePermissions['deny'] ?? const []).join('\n'));
  late final _ask = TextEditingController(text: (m?.claudePermissions['ask'] ?? const []).join('\n'));
  Object? _raw(String key) => widget.raw[key];
  String _rawText(String key) => _raw(key) is String ? _raw(key) as String : '';
  late final _advisor = TextEditingController(text: _rawText('advisor'));
  late final _mechanic = TextEditingController(text: _rawText('mechanic'));
  late final _agentFile = TextEditingController(text: _rawText('agent_file'));
  late final _appendPrompt = TextEditingController(text: _rawText('append_system_prompt_file'));
  late final _pluginDirs = TextEditingController(text: _raw('plugin_dirs') is List ? (_raw('plugin_dirs') as List).join('\n') : '');
  late final _codexProfile = TextEditingController(text: _rawText('codex_config_profile'));
  late final _starter = TextEditingController(
      text: _raw('starter_ref') is Map ? '${(_raw('starter_ref') as Map)['name'] ?? ''}' : '');
  late final _env = _EnvRowsController(_raw('env'));
  late final _blocks = {
    for (final k in _memberBlocks.keys) k: TextEditingController(text: yamlBlockText(_raw(k))),
  };
  late bool _mcpNone = _raw('claude_mcp') == 'none';
  late String? _restore = _raw('restore_policy') as String?;
  late String? _compaction = _raw('compaction_strategy') as String?;
  String? _optionsError;
  String? _pathError;
  final _more = ExpansibleController();
  late String _runtime = m?.runtime ?? 'claude-code';
  late String? _effort = m?.effort;
  late String _policy = m?.permissionPolicy == null
      ? _PolicySheet.inherit
      : _customPolicy(m!.permissionPolicy)
          ? 'custom'
          : m!.permissionPolicy!;
  String? _idError;
  String? _rulesError;

  /// Whether a nested block applies to this runtime.
  bool _blockShown(String key) => switch (key) {
        'claude_token' => _runtime == 'claude-code',
        'codex_permissions' => _runtime == 'codex',
        'session_source' => !_terminal,
        _ => true,
      };

  bool get _hasOptions => const [
        'advisor', 'claude_mcp', 'restore_policy', 'compaction_strategy', 'mechanic', 'agent_file',
        'append_system_prompt_file', 'plugin_dirs', 'codex_config_profile', 'starter_ref', 'env', //
        ..._memberBlockKeys,
      ].any((k) => widget.raw[k] != null);

  static bool _customPolicy(String? v) => v != null && v != 'none' && !v.startsWith('builtin:');
  bool get _terminal => _runtime == 'terminal';
  bool get _wasTerminal => m?.runtime == 'terminal';

  @override
  void dispose() {
    for (final c in [
      _id, _role, _model, _agentRef, _cwd, _policyPath, _allow, _deny, _ask, //
      _advisor, _mechanic, _agentFile, _appendPrompt, _pluginDirs, _codexProfile, _starter,
      ..._blocks.values,
    ]) {
      c.dispose();
    }
    _env.dispose();
    super.dispose();
  }

  void _setRuntime(String? r) {
    if (r == null) return;
    setState(() {
      _runtime = r;
      // Levels differ per runtime; keep one the new runtime knows.
      if (_effort != null && !(effortLevels[r] ?? const []).contains(_effort)) _effort = null;
      if (r == 'terminal') {
        _agentRef.text = 'builtin:terminal';
      } else if (_agentRef.text == 'builtin:terminal') {
        _agentRef.clear();
      }
    });
  }

  List<String> _lines(TextEditingController c) =>
      c.text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

  void _done() {
    final id = _id.text.trim();
    final rules = {
      'allow': _lines(_allow),
      'deny': _lines(_deny),
      'ask': _lines(_ask),
    }..removeWhere((_, v) => v.isEmpty);
    final badRule = rules.values.expand((v) => v).where((r) => !rulePattern.hasMatch(r)).firstOrNull;
    setState(() {
      _idError = id.isEmpty
          ? 'Required'
          : !idPattern.hasMatch(id)
              ? 'Letters, digits, - and _ only'
              : widget.taken.contains(id)
                  ? 'Another role in ${widget.podLabel} uses this id'
                  : null;
      _rulesError = badRule == null ? null : '"$badRule" isn\'t a tool rule (Bash(npm run *), Read, mcp__github)';
    });
    final claude = _runtime == 'claude-code', codex = _runtime == 'codex';
    final dirs = _lines(_pluginDirs);
    final starter = _starter.text.trim();
    final problem = envError(_env.values) ??
        [for (final e in _blocks.entries) if (_blockError(e.value.text) != null) '${_memberBlocks[e.key]!.$1}: ${_blockError(e.value.text)}']
            .firstOrNull ??
        (claude
            ? [for (final (label, v) in [('Agent file', _agentFile.text.trim()), ('System prompt file', _appendPrompt.text.trim()), for (final d in dirs) ('Plugin folder', d)])
                if (v.isNotEmpty && !safeRelativePath(v)) '$label "$v" must be a path beside the spec (no .., not absolute)'].firstOrNull
            : null) ??
        (codex && _codexProfile.text.trim().isNotEmpty && !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(_codexProfile.text.trim())
            ? 'Codex profile: letters, numbers, _ . - only'
            : null) ??
        (_compaction == 'apprentice-handover' && _mechanic.text.trim().isNotEmpty && !_mechanic.text.contains('@')
            ? 'Mechanic is a seat address like mechanic@my-rig'
            : null) ??
        (!_terminal && starter.isNotEmpty && !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]*$').hasMatch(starter)
            ? 'Starter name: letters, digits, - and _'
            : null);
    setState(() => _optionsError = problem);
    if (problem != null) _more.expand();
    if (_idError != null || _rulesError != null || problem != null) return;
    final policy = _policy == 'custom' ? _policyPath.text.trim() : _policy;
    if (_policy == 'custom' && policy.isEmpty) return setState(() => _pathError = 'Required');
    Navigator.pop(
      context,
      _MemberEdit(fields: {
        'id': id,
        'runtime': _runtime,
        'role': _terminal ? null : _role.text,
        'model': _terminal ? null : _model.text,
        'effort': _terminal ? null : _effort,
        'permission_policy': _terminal || policy == _PolicySheet.inherit ? null : policy,
        'claude_permissions': claude && rules.isNotEmpty ? rules : null,
        'agent_ref': _terminal ? 'builtin:terminal' : _agentRef.text,
        'cwd': _cwd.text,
        // Options only some runtimes take go away when the runtime changes.
        'advisor': claude ? _advisor.text : null,
        'claude_mcp': claude && _mcpNone ? 'none' : null,
        'agent_file': claude ? _agentFile.text : null,
        'append_system_prompt_file': claude ? _appendPrompt.text : null,
        'plugin_dirs': claude && dirs.isNotEmpty ? dirs : null,
        'codex_config_profile': codex ? _codexProfile.text : null,
        'restore_policy': _terminal ? null : _restore,
        'compaction_strategy': _terminal ? null : _compaction,
        'mechanic': !_terminal && _compaction == 'apprentice-handover' ? _mechanic.text : null,
        'starter_ref': _terminal || starter.isEmpty ? null : {'name': starter},
        'env': envMap(_env.values),
        for (final e in _blocks.entries)
          e.key: switch (e.key) {
            'claude_token' => claude,
            'codex_permissions' => codex,
            'session_source' => !_terminal,
            _ => true,
          }
              ? parseYamlBlock(e.value.text)
              : null,
        // A terminal seat is `profile: none`; leaving terminal drops that.
        if (_terminal) 'profile': 'none' else if (_wasTerminal) 'profile': null,
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final k = Tokens.of(context);
    final levels = effortLevels[_runtime] ?? const <String>[];
    final suggestions = modelSuggestions[_runtime] ?? const <String>[];
    final claude = _runtime == 'claude-code';
    final policyItems = <(String?, String)>[
      (_PolicySheet.inherit, 'Inherit the rig\'s policy'),
      for (final p in builtinPolicies) ('builtin:$p', p),
      ('none', 'None (deliberately unset)'),
      ('custom', 'Custom policy file…'),
    ];
    Widget gap([double h = 12]) => SizedBox(height: h);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: _sheetPadding(context),
        children: [
          Text(m == null ? 'New role in ${widget.podLabel}' : m!.id, style: t.titleLarge),
          Text(m == null ? 'A seat the rig starts in this department.' : widget.podLabel, style: t.bodySmall),
          gap(16),
          TextField(
            controller: _id,
            autofocus: m == null,
            autocorrect: false,
            style: const TextStyle(fontFamily: fontMono),
            decoration: _decor('Id', hint: 'reviewer', error: _idError),
          ),
          if (!_terminal) ...[
            gap(),
            TextField(
              controller: _role,
              autocorrect: false,
              decoration: _decor('Role', hint: 'reviewer · what workflows bind to'),
            ),
          ],
          gap(16),
          Text('Runtime and provider', style: t.titleSmall),
          gap(8),
          _Choice(
            label: 'Runtime',
            value: _runtime,
            items: [for (final (id, name, provider) in runtimeChoices) (id, '$name · $provider')],
            onChanged: _setRuntime,
          ),
          if (!_terminal) ...[
            gap(),
            TextField(
              controller: _model,
              autocorrect: false,
              style: const TextStyle(fontFamily: fontMono),
              decoration: _decor('Model', hint: 'runtime default'),
            ),
            if (suggestions.isNotEmpty) ...[
              gap(8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final s in suggestions)
                  ActionChip(
                    label: Text(s, style: const TextStyle(fontFamily: fontMono, fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() => _model.text = s),
                  ),
              ]),
            ],
            if (levels.isNotEmpty) ...[
              gap(),
              _Choice(
                label: 'Effort',
                value: _effort,
                items: [(null, 'Runtime default'), for (final l in levels) (l, l)],
                onChanged: (v) => setState(() => _effort = v),
              ),
            ],
            gap(16),
            Text('Permissions', style: t.titleSmall),
            gap(8),
            _Choice(
                label: 'Policy', value: _policy, items: policyItems, onChanged: (v) => setState(() => _policy = v!)),
            if (_policy == 'custom') ...[
              gap(),
              TextField(
                controller: _policyPath,
                autocorrect: false,
                style: const TextStyle(fontFamily: fontMono),
                decoration: _decor('Policy file', hint: 'policies/review.yaml', error: _pathError),
              ),
            ],
            if (_runtime == 'claude-code') ...[
              gap(),
              Text('Tool rules for Claude Code, one per line.', style: TextStyle(fontSize: 12, color: k.muted)),
              gap(8),
              for (final (label, c, hint) in [
                ('Allow', _allow, 'Bash(npm run *)\nRead'),
                ('Ask', _ask, 'Bash(git push *)'),
                ('Deny', _deny, 'WebFetch'),
              ]) ...[
                TextField(
                  controller: c,
                  minLines: 1,
                  maxLines: 5,
                  autocorrect: false,
                  style: const TextStyle(fontFamily: fontMono, fontSize: 13),
                  decoration: _decor(label, hint: hint, error: label == 'Allow' ? _rulesError : null),
                ),
                gap(8),
              ],
            ],
          ],
          gap(8),
          Text('Agent', style: t.titleSmall),
          gap(8),
          TextField(
            controller: _agentRef,
            autocorrect: false,
            enabled: !_terminal,
            style: const TextStyle(fontFamily: fontMono),
            decoration: _decor('Agent definition', hint: 'local:agents/review/reviewer'),
          ),
          gap(),
          TextField(
            controller: _cwd,
            autocorrect: false,
            style: const TextStyle(fontFamily: fontMono),
            decoration: _decor('Working folder', hint: '. (where the rig starts)'),
          ),
          gap(8),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              controller: _more,
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              initiallyExpanded: _optionsError != null || _hasOptions,
              title: Text('More options', style: t.titleSmall),
              subtitle: Text('Restore, compaction, environment, startup and the rest.', style: t.bodySmall),
              children: [
                if (_optionsError != null) ...[
                  Text(_optionsError!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
                  gap(8),
                ],
                if (!_terminal) ...[
                  _Choice(
                    label: 'Restore policy',
                    value: _restore,
                    items: [(null, 'The agent definition\'s'), for (final r in <String>{...restorePolicies, if (_restore != null) _restore!}) (r, r)],
                    onChanged: (v) => setState(() => _restore = v),
                  ),
                  gap(),
                  _Choice(
                    label: 'Compaction',
                    value: _compaction,
                    items: [(null, 'Default'), for (final c in <String>{...compactionStrategies, if (_compaction != null) _compaction!}) (c, c)],
                    onChanged: (v) => setState(() => _compaction = v),
                  ),
                  if (_compaction == 'apprentice-handover') ...[
                    gap(),
                    TextField(
                      controller: _mechanic,
                      autocorrect: false,
                      style: const TextStyle(fontFamily: fontMono),
                      decoration: _decor('Mechanic', hint: 'mechanic@my-rig'),
                    ),
                  ],
                  gap(),
                  TextField(
                    controller: _starter,
                    autocorrect: false,
                    style: const TextStyle(fontFamily: fontMono),
                    decoration: _decor('Starter', hint: 'name of an agent starter'),
                  ),
                ],
                if (claude) ...[
                  gap(),
                  TextField(
                    controller: _advisor,
                    autocorrect: false,
                    style: const TextStyle(fontFamily: fontMono),
                    decoration: _decor('Advisor model', hint: 'runtime default'),
                  ),
                  SwitchRow(
                    'Load no MCP servers',
                    subtitle: 'claude_mcp: none',
                    inset: false,
                    value: _mcpNone,
                    onChanged: (v) => setState(() => _mcpNone = v),
                  ),
                  TextField(
                    controller: _agentFile,
                    autocorrect: false,
                    style: const TextStyle(fontFamily: fontMono),
                    decoration: _decor('Agent file', hint: 'agents/reviewer.md'),
                  ),
                  gap(),
                  TextField(
                    controller: _appendPrompt,
                    autocorrect: false,
                    style: const TextStyle(fontFamily: fontMono),
                    decoration: _decor('System prompt file', hint: 'prompts/extra.md'),
                  ),
                  gap(),
                  TextField(
                    controller: _pluginDirs,
                    minLines: 1,
                    maxLines: 4,
                    autocorrect: false,
                    style: const TextStyle(fontFamily: fontMono, fontSize: 13),
                    decoration: _decor('Plugin folders', hint: 'one per line'),
                  ),
                ],
                if (_runtime == 'codex') ...[
                  gap(),
                  TextField(
                    controller: _codexProfile,
                    autocorrect: false,
                    style: const TextStyle(fontFamily: fontMono),
                    decoration: _decor('Codex profile', hint: 'native profile name'),
                  ),
                ],
                gap(16),
                Text('Environment', style: t.titleSmall),
                gap(8),
                _EnvRows(_env),
                for (final e in _memberBlocks.entries)
                  if (_blockShown(e.key)) ...[
                    gap(),
                    _YamlBox(controller: _blocks[e.key]!, label: e.value.$1, hint: e.value.$2),
                  ],
              ],
            ),
          ),
          gap(20),
          _SheetButtons(
            onSave: _done,
            onDelete: m == null ? null : () => Navigator.pop(context, _MemberEdit(delete: true)),
            deleteLabel: 'Remove role',
          ),
        ],
      ),
    );
  }
}
