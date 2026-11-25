part of 'spec_editor_screen.dart';

/// One editable value row: label, current value (or "—"), chevron.
class _Field extends StatelessWidget {
  const _Field(this.label, this.value, {required this.onTap, this.mono = false});
  final String label;
  final String? value;
  final VoidCallback onTap;
  final bool mono;

  @override
  Widget build(BuildContext context) => RowTile(
        minHeight: 52,
        title: label,
        meta: value ?? '—',
        metaMono: mono,
        trailing: const Chevron(),
        onTap: onTap,
      );
}

/// A sheet's bottom button row: Save, and Delete when editing something.
class _SheetButtons extends StatelessWidget {
  const _SheetButtons({required this.onSave, this.onDelete, this.deleteLabel = 'Delete'});
  final VoidCallback onSave;
  final VoidCallback? onDelete;
  final String deleteLabel;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FilledButton(
        onPressed: onSave,
        style: sheetAction,
        child: const Text('Done'),
      ),
      if (onDelete != null)
        TextButton(
          onPressed: onDelete,
          style: TextButton.styleFrom(foregroundColor: k.removed).merge(sheetAction),
          child: Text(deleteLabel),
        ),
    ]);
  }
}

EdgeInsets _sheetPadding(BuildContext context) => EdgeInsets.fromLTRB(
    20, 0, 20, math.max(MediaQuery.viewInsetsOf(context).bottom, MediaQuery.paddingOf(context).bottom) + 20);

InputDecoration _decor(String label, {String? hint, String? error}) =>
    InputDecoration(labelText: label, hintText: hint, errorText: error, border: const OutlineInputBorder());

/// A labelled dropdown that hugs the form's width.
class _Choice extends StatelessWidget {
  const _Choice({required this.label, required this.value, required this.items, required this.onChanged});
  final String label;
  final String? value;
  final List<(String?, String)> items;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String?>(
        initialValue: value,
        isExpanded: true,
        decoration: _decor(label),
        items: [
          for (final (v, text) in items) DropdownMenuItem(value: v, child: Text(text, overflow: TextOverflow.ellipsis))
        ],
        onChanged: onChanged,
      );
}

/// One text value (rig name, summary, culture file).
class _TextSheet extends StatefulWidget {
  const _TextSheet({required this.title, required this.value, this.hint, this.lines = 1});
  final String title;
  final String value;
  final String? hint;
  final int lines;
  @override
  State<_TextSheet> createState() => _TextSheetState();
}

class _TextSheetState extends State<_TextSheet> {
  late final _ctrl = TextEditingController(text: widget.value);
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: _sheetPadding(context),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            autofocus: true,
            minLines: widget.lines,
            maxLines: widget.lines < 2 ? 1 : widget.lines + 4,
            autocorrect: widget.lines > 1,
            decoration: _decor(widget.title, hint: widget.hint),
            onSubmitted: widget.lines > 1 ? null : (_) => Navigator.pop(context, _ctrl.text),
          ),
          const SizedBox(height: 16),
          _SheetButtons(onSave: () => Navigator.pop(context, _ctrl.text)),
        ]),
      );
}

/// Pick a `permission_policy` ref: built-ins, none, a custom path.
class _PolicySheet extends StatefulWidget {
  const _PolicySheet({required this.value, required this.rigLevel});
  final String? value;
  final bool rigLevel;

  /// Returned when the caller should remove the key.
  static const inherit = '\u0000inherit';
  @override
  State<_PolicySheet> createState() => _PolicySheetState();
}

class _PolicySheetState extends State<_PolicySheet> {
  late String _pick = _initial;
  late final _path = TextEditingController(text: _isCustom(widget.value) ? widget.value : '');
  String? _pathError;

  static bool _isCustom(String? v) => v != null && v != 'none' && !v.startsWith('builtin:');
  String get _initial =>
      widget.value == null ? _PolicySheet.inherit : (_isCustom(widget.value) ? 'custom' : widget.value!);

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final k = Tokens.of(context);
    const notes = {
      'locked': 'nothing without asking',
      'standard': 'the everyday set',
      'open': 'most tools without asking',
      'yolo': 'everything, no prompts',
      'auto': 'the runtime decides per call',
    };
    final options = [
      (_PolicySheet.inherit, widget.rigLevel ? 'Runtime default' : 'Inherit the rig\'s policy', 'no policy set here'),
      for (final p in builtinPolicies) ('builtin:$p', p, notes[p]!),
      ('none', 'None', 'deliberately unset'),
      ('custom', 'Custom policy file', 'a path beside the spec'),
    ];
    return Padding(
      padding: _sheetPadding(context),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Permission policy', style: t.titleLarge),
          const SizedBox(height: 8),
          RadioGroup<String>(
            groupValue: _pick,
            onChanged: (x) => setState(() => _pick = x!),
            child: Column(children: [
              for (final (v, label, note) in options)
                RadioListTile<String>(
                  value: v,
                  contentPadding: EdgeInsets.zero,
                  title: Text(label),
                  subtitle: Text(note, style: TextStyle(color: k.muted, fontSize: 12)),
                  dense: true,
                ),
            ]),
          ),
          if (_pick == 'custom')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: _path,
                autocorrect: false,
                style: const TextStyle(fontFamily: fontMono),
                decoration: _decor('Policy file', hint: 'policies/review.yaml', error: _pathError),
              ),
            ),
          const SizedBox(height: 16),
          _SheetButtons(onSave: () {
            final v = _pick == 'custom' ? _path.text.trim() : _pick;
            if (_pick == 'custom' && v.isEmpty) return setState(() => _pathError = 'Required');
            Navigator.pop(context, v);
          }),
        ]),
      ),
    );
  }
}

class _PodEdit {
  _PodEdit({this.id = '', this.label = '', this.fields = const {}, this.delete = false});
  final String id;
  final String label;

  /// `summary`, `continuity_policy`, `startup`: null removes the key.
  final Map<String, Object?> fields;
  final bool delete;
}

/// Add or rename a department; delete it from here too.
class _PodSheet extends StatefulWidget {
  const _PodSheet({required this.pod, required this.taken, this.summary, this.blocks = const {}});
  final SpecPod? pod;
  final Set<String> taken;
  final Object? summary;

  /// The department's current nested blocks, by key (see [_podBlocks]).
  final Map<String, Object?> blocks;
  @override
  State<_PodSheet> createState() => _PodSheetState();
}

class _PodSheetState extends State<_PodSheet> {
  late final _label = TextEditingController(text: widget.pod?.label ?? '');
  late final _id = TextEditingController(text: widget.pod?.id ?? '');
  late final _summary = TextEditingController(text: widget.summary is String ? widget.summary as String : '');
  late final _blocks = {for (final e in widget.blocks.entries) e.key: TextEditingController(text: yamlBlockText(e.value))};
  String? _idError;
  bool _idTouched = false;

  @override
  void dispose() {
    _label.dispose();
    _id.dispose();
    _summary.dispose();
    for (final c in _blocks.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// A fresh department's id follows its label until the id is edited.
  void _labelChanged(String v) {
    if (widget.pod != null || _idTouched) return;
    _id.text = v.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  }

  void _done() {
    final id = _id.text.trim();
    final label = _label.text.trim();
    setState(() {
      _idError = id.isEmpty
          ? 'Required'
          : !idPattern.hasMatch(id)
              ? 'Letters, digits, - and _ only'
              : widget.taken.contains(id)
                  ? 'Another department uses this id'
                  : null;
    });
    if (_idError != null || _blocks.values.any((c) => _blockError(c.text) != null)) return;
    Navigator.pop(
      context,
      _PodEdit(id: id, label: label.isEmpty ? id : label, fields: {
        'summary': _summary.text,
        for (final e in _blocks.entries) e.key: parseYamlBlock(e.value.text),
      }),
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: _sheetPadding(context),
        child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.pod == null ? 'New department' : 'Department', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _label,
            autofocus: widget.pod == null,
            textCapitalization: TextCapitalization.words,
            decoration: _decor('Label', hint: 'Review Team'),
            onChanged: _labelChanged,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _id,
            autocorrect: false,
            style: const TextStyle(fontFamily: fontMono),
            decoration: _decor('Id', hint: 'review', error: _idError),
            onChanged: (_) => _idTouched = true,
            onSubmitted: (_) => _done(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _summary,
            minLines: 1,
            maxLines: 4,
            decoration: _decor('Summary', hint: 'What this department is for'),
          ),
          for (final e in _blocks.entries) ...[
            const SizedBox(height: 12),
            _YamlBox(controller: e.value, label: _podBlocks[e.key]!.$1, hint: _podBlocks[e.key]!.$2),
          ],
          const SizedBox(height: 16),
          _SheetButtons(
            onSave: _done,
            onDelete: widget.pod == null ? null : () => Navigator.pop(context, _PodEdit(delete: true)),
            deleteLabel: 'Delete department and its roles',
          ),
        ])),
      );
}

class _EdgeEdit {
  _EdgeEdit({this.from = '', this.kind = '', this.to = '', this.delete = false});
  final String from;
  final String kind;
  final String to;
  final bool delete;
}

/// Add or change a relationship: who, how, to whom.
class _EdgeSheet extends StatefulWidget {
  const _EdgeSheet({required this.edge, required this.seats});
  final SpecEdge? edge;
  final List<String> seats;
  @override
  State<_EdgeSheet> createState() => _EdgeSheetState();
}

class _EdgeSheetState extends State<_EdgeSheet> {
  late String _from = widget.seats.contains(widget.edge?.from) ? widget.edge!.from : widget.seats.first;
  late String _to = widget.seats.contains(widget.edge?.to)
      ? widget.edge!.to
      : widget.seats.firstWhere((s) => s != _from, orElse: () => widget.seats.first);
  late String _kind = edgeKinds.contains(widget.edge?.kind) ? widget.edge!.kind : edgeKinds.first;
  String? _error;

  void _done() {
    if (_from == _to) {
      setState(() => _error = 'A role can\'t relate to itself');
      return;
    }
    Navigator.pop(context, _EdgeEdit(from: _from, kind: _kind, to: _to));
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final seats = [for (final s in widget.seats) (s, s)];
    return Padding(
      padding: _sheetPadding(context),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.edge == null ? 'New relationship' : 'Relationship', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        _Choice(label: 'From', value: _from, items: seats, onChanged: (v) => setState(() => _from = v!)),
        const SizedBox(height: 12),
        _Choice(
          label: 'How',
          value: _kind,
          items: [for (final kind in edgeKinds) (kind, edgeKindLabel(kind))],
          onChanged: (v) => setState(() => _kind = v!),
        ),
        const SizedBox(height: 12),
        _Choice(label: 'To', value: _to, items: seats, onChanged: (v) => setState(() => _to = v!)),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: k.accent, fontSize: 13)),
        ],
        const SizedBox(height: 16),
        _SheetButtons(
          onSave: _done,
          onDelete: widget.edge == null ? null : () => Navigator.pop(context, _EdgeEdit(delete: true)),
          deleteLabel: 'Remove relationship',
        ),
      ]),
    );
  }
}
