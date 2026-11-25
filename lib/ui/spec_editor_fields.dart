part of 'spec_editor_screen.dart';

// The pieces behind the editor's extra options: a YAML box for nested
// blocks, name/value rows for `env`, and the sheets that hold them.

/// Why [text] can't be a nested block, or null.
String? _blockError(String text) {
  try {
    parseYamlBlock(text);
    return null;
  } on FormatException catch (e) {
    return e.message;
  }
}

/// A nested block typed as YAML; the box says why it doesn't parse.
class _YamlBox extends StatefulWidget {
  const _YamlBox({required this.controller, required this.label, this.hint});
  final TextEditingController controller;
  final String label;
  final String? hint;
  @override
  State<_YamlBox> createState() => _YamlBoxState();
}

class _YamlBoxState extends State<_YamlBox> {
  @override
  Widget build(BuildContext context) => TextField(
        controller: widget.controller,
        minLines: 3,
        maxLines: 12,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(fontFamily: fontMono, fontSize: 13),
        decoration: _decor(widget.label, hint: widget.hint, error: _blockError(widget.controller.text)),
        onChanged: (_) => setState(() {}),
      );
}

/// The name/value rows of an `env`.
class _EnvRowsController {
  _EnvRowsController(Object? initial) {
    if (initial is Map) {
      for (final e in initial.entries) {
        rows.add((TextEditingController(text: '${e.key}'), TextEditingController(text: '${e.value}')));
      }
    }
  }

  final rows = <(TextEditingController, TextEditingController)>[];

  List<(String, String)> get values => [for (final (n, v) in rows) (n.text, v.text)];

  void dispose() {
    for (final (n, v) in rows) {
      n.dispose();
      v.dispose();
    }
  }
}

class _EnvRows extends StatefulWidget {
  const _EnvRows(this.controller);
  final _EnvRowsController controller;
  @override
  State<_EnvRows> createState() => _EnvRowsState();
}

class _EnvRowsState extends State<_EnvRows> {
  List<(TextEditingController, TextEditingController)> get _rows => widget.controller.rows;

  @override
  Widget build(BuildContext context) {
    final error = envError(widget.controller.values);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (i, (name, value)) in _rows.indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              flex: 5,
              child: Semantics(
                label: 'Variable name ${i + 1}',
                child: TextField(
                  controller: name,
                  autocorrect: false,
                  textCapitalization: TextCapitalization.characters,
                  style: const TextStyle(fontFamily: fontMono, fontSize: 13),
                  decoration: _decor('Name', hint: 'LOG_LEVEL'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 6,
              child: Semantics(
                label: 'Variable value ${i + 1}',
                child: TextField(
                  controller: value,
                  autocorrect: false,
                  style: const TextStyle(fontFamily: fontMono, fontSize: 13),
                  decoration: _decor('Value', hint: 'info'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Remove variable',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => setState(() {
                final (n, v) = _rows.removeAt(i);
                n.dispose();
                v.dispose();
              }),
            ),
          ]),
        ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => setState(() => _rows.add((TextEditingController(), TextEditingController()))),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add variable'),
        ),
      ),
    ]);
  }
}

/// A rig's `env`: name/value rows. Returns the new map (empty clears).
class _EnvSheet extends StatefulWidget {
  const _EnvSheet({required this.title, required this.value, this.note});
  final String title;
  final Object? value;
  final String? note;
  @override
  State<_EnvSheet> createState() => _EnvSheetState();
}

class _EnvSheetState extends State<_EnvSheet> {
  late final _env = _EnvRowsController(widget.value);

  @override
  void dispose() {
    _env.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: _sheetPadding(context),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.title, style: t.titleLarge),
          const SizedBox(height: 4),
          Text(widget.note ?? 'Not secret: the values are stored in the spec and in snapshots.', style: t.bodySmall),
          const SizedBox(height: 16),
          _EnvRows(_env),
          const SizedBox(height: 12),
          _SheetButtons(onSave: () {
            if (envError(_env.values) != null) return;
            Navigator.pop(context, envMap(_env.values));
          }),
        ]),
      ),
    );
  }
}

/// One nested block (startup, services, workspace…) as YAML. Returns the parsed value (null clears).
class _BlockSheet extends StatefulWidget {
  const _BlockSheet({required this.title, required this.value, this.hint});
  final String title;
  final Object? value;
  final String? hint;
  @override
  State<_BlockSheet> createState() => _BlockSheetState();
}

class _BlockSheetState extends State<_BlockSheet> {
  late final _text = TextEditingController(text: yamlBlockText(widget.value));

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: _sheetPadding(context),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('YAML, as in the spec. Clear it to remove the block.', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            _YamlBox(controller: _text, label: widget.title, hint: widget.hint),
            const SizedBox(height: 16),
            _SheetButtons(onSave: () {
              if (_blockError(_text.text) != null) return;
              Navigator.pop(context, (parseYamlBlock(_text.text),));
            }),
          ]),
        ),
      );
}

/// Short text for a field row: how a value reads in the list.
String _blockLabel(Object? v) => v == null ? '—' : 'set';
String _envLabel(Object? v) => v is Map && v.isNotEmpty ? '${v.length} variable${v.length == 1 ? '' : 's'}' : '—';
