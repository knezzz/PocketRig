import 'package:flutter/material.dart';

import '../api/openrig_client.dart' show OpenRigException;
import '../data/new_worktree.dart';
import '../models.dart' show Host;
import 'busy.dart';
import 'new_sheet.dart' show createWorktree;
import 'project_actions.dart' show projectNameOf;
import 'theme.dart';

/// The branch name being typed for a new worktree, and what the project says about it: where it branches from, which
/// folder it makes, and what already collides. Shared by the project's New worktree sheet and the New sheet.
class WorktreeNameModel extends ChangeNotifier {
  WorktreeNameModel() {
    text.addListener(notifyListeners);
  }

  final text = TextEditingController();
  WorktreeSetup? setup;
  Object? readError;
  bool loading = false;
  (String, String)? _for;

  /// Reads [project] on [host]; again when either changes.
  Future<void> load(Host host, String project) async {
    final key = (host.id, project);
    if (_for == key) return;
    _for = key;
    setup = null;
    readError = null;
    loading = true;
    notifyListeners();
    try {
      final s = await readWorktreeSetup(host, project);
      if (_for != key) return;
      setup = s;
    } catch (e) {
      if (_for != key) return;
      readError = e;
    }
    loading = false;
    notifyListeners();
  }

  String get name => text.text.trim();
  String? get nameError => worktreeNameError(name, setup);

  /// A name that can be created: typed, valid, and the project read.
  bool get ok => name.isNotEmpty && nameError == null && setup != null;

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }
}

/// The name field with its live preview ('Branch  fix/flaky-ci  from <current branch>', 'Folder  <project>/.claude/worktrees/…')
/// and the inline error under it.
class WorktreeNameField extends StatelessWidget {
  const WorktreeNameField({super.key, required this.model, this.autofocus = true, this.extraError});
  final WorktreeNameModel model;
  final bool autofocus;

  /// An error from trying to create it (git's own message), shown in the same place.
  final String? extraError;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final name = model.name.isEmpty ? '…' : model.name;
        final s = model.setup;
        final base = s == null ? '…' : (s.base ?? 'a detached HEAD');
        final project = s == null ? '…' : projectNameOf(s.repo);
        final folder = model.name.isEmpty ? '…' : worktreeFolderName(model.name);
        final mono12 = mono(context, size: 12, color: k.muted);
        final read = model.readError;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          // The refused name is the error red (message, outline and label), not the needs-you orange.
          Theme(
            data: Theme.of(context).copyWith(colorScheme: Theme.of(context).colorScheme.copyWith(error: k.removed)),
            child: TextField(
              controller: model.text,
              autofocus: autofocus,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: fontMono, fontSize: 13),
              decoration: InputDecoration(labelText: 'Branch name', hintText: 'fix/flaky-ci', errorText: model.nameError ?? extraError),
            ),
          ),
          const SizedBox(height: 8),
          if (read != null)
            Text('Couldn\'t read the project: ${read is OpenRigException ? read.message : read}',
                style: TextStyle(fontSize: 12, color: k.removed))
          else ...[
            Text('Branch  $name  from $base', style: mono12, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text('Folder  $project/.claude/worktrees/$folder', style: mono12, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ]);
      },
    );
  }
}

/// The project's New worktree sheet: the name field, then Create. Pops the new worktree's path. It runs on [host], the
/// project's own, whatever host is active by then.
class NewWorktreeSheet extends StatefulWidget {
  const NewWorktreeSheet({super.key, required this.host, required this.project, this.initialName});
  final Host host;
  final String project;

  /// A name typed already (the demo screens).
  final String? initialName;

  @override
  State<NewWorktreeSheet> createState() => _NewWorktreeSheetState();
}

class _NewWorktreeSheetState extends State<NewWorktreeSheet> {
  final _model = WorktreeNameModel();
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _model.load(widget.host, widget.project);
    if (widget.initialName != null) _model.text.text = widget.initialName!;
    _model.text.addListener(() {
      if (_error != null && mounted) setState(() => _error = null);
    });
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _model.name;
    setState(() {
      _creating = true;
      _error = null;
    });
    String? path;
    try {
      await exclusive('new-worktree:${widget.project}', () async => path = await createWorktree(widget.host, widget.project, name));
      if (!mounted) return;
      if (path == null) {
        setState(() => _creating = false); // already being made by another tap
      } else {
        Navigator.pop(context, path);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _creating = false;
          _error = e is OpenRigException ? e.message : e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('New worktree', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            WorktreeNameField(model: _model, extraError: _error),
            const SizedBox(height: 16),
            ListenableBuilder(
              listenable: _model,
              builder: (context, _) => FilledButton(
                onPressed: _model.ok && !_creating ? _create : null,
                style: sheetAction,
                child: Text(_creating ? 'Creating…' : 'Create'),
              ),
            ),
          ]),
        ),
      );
}
