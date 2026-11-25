import 'dart:async';

import 'package:flutter/material.dart';
import 'folder_browser.dart' show chooseFolder;
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;

import '../data/fleet.dart';
import '../data/git_status.dart';
import '../data/host_store.dart' show HostStore;
import '../data/new_session.dart';
import '../main.dart';
import '../models.dart';
import '../ssh/ssh_exec.dart';
import '../terminal/transport.dart';
import 'app_icon.dart';
import 'common.dart';
import 'desktop_shell.dart';
import 'kit.dart';
import 'new_session_sheet.dart' show startAgentWith;
import 'project/specs.dart' show startRigInProject;
import 'project_actions.dart' show projectNameOf;
import 'rigs_home.dart' show tildePath;
import 'terminal_screen.dart';
import 'theme.dart';
import 'worktree_name_field.dart';
import 'worktree_chip.dart';

/// What the New sheet starts.
enum NewKind { agent, shell, rig }

/// What the sheet asks for: [worktree] is the checkout to start in (the project's own path for the main checkout), or
/// [newBranch] to create one first (a worktree on a new branch from main).
class NewChoice {
  const NewChoice(this.kind, this.host, this.project, {this.worktree, this.newBranch, this.runtime = AgentRuntime.claude});
  final NewKind kind;
  final Host host;
  final String project;
  final String? worktree;
  final String? newBranch;
  final AgentRuntime runtime;
}

/// A pasted or typed path as the host wants it: spaces and quotes off the ends, a trailing / dropped (not a bare /).
String cleanTypedPath(String raw) {
  var t = raw.trim().replaceAll(RegExp(r'''^["']+|["']+$'''), '').trim();
  while (t.length > 1 && t.endsWith('/')) {
    t = t.substring(0, t.length - 1);
  }
  return t;
}

/// A worktree on a new branch from the project's main checkout; returns its path.
Future<String> createWorktree(Host host, String project, String branch) async {
  final ssh = await SshExec.connect(host);
  try {
    final main = (await ssh.worktrees(project)).firstOrNull;
    if (main == null) throw StateError('No git repository in ${projectNameOf(project)}.');
    return await ssh.addWorktree(main.path, branch);
  } finally {
    ssh.close();
  }
}

/// The New sheet (a dialog on the Mac): an agent, a shell or a rig, in a location (a project, on its host) and one of its
/// worktrees (the main checkout, an existing one, or a new one on a new branch). [path] pre-fills the location.
Future<void> showNew(BuildContext context, {NewKind kind = NewKind.agent, Host? host, String? path, String? typed}) async {
  // A dialog sits in the root navigator, above the screen's own AppScope: hand the sheet the store it needs.
  final sheet = AppScope(store: AppScope.read(context), child: NewSheet(kind: kind, host: host, path: path, typed: typed));
  final choice = await showDialogOrSheet<NewChoice>(context, child: sheet, maxWidth: 520);
  if (choice == null || !context.mounted) return;
  await _start(context, choice);
}

Future<void> _start(BuildContext context, NewChoice c) async {
  useHost(context, c.host);
  var target = c.worktree ?? c.project;
  if (c.newBranch != null) {
    try {
      target = await createWorktree(c.host, c.project, c.newBranch!);
    } catch (e) {
      if (context.mounted) toast(context, 'Couldn\'t create the worktree: $e', kind: ToastKind.problem);
      return;
    }
    if (!context.mounted) return;
    toast(context, 'Created ${c.newBranch}', kind: ToastKind.done);
  }
  switch (c.kind) {
    case NewKind.agent:
      final id = newSessionId();
      await startAgentWith(context, c.host,
          NewSessionSpec(runtime: c.runtime, cwd: target, name: newSessionName(c.runtime, target, id), sessionId: id));
    case NewKind.shell:
      await detailNavigator(context)
          .push(MaterialPageRoute<void>(builder: (_) => TerminalScreen(target: ProjectShellTarget(target))));
    case NewKind.rig:
      await startRigInProject(context, c.host, c.project, projectNameOf(c.project),
          worktreePath: target, push: (screen) => detailNavigator(context).push(MaterialPageRoute<void>(builder: (_) => screen)));
  }
}

/// Where a typed folder path stands: not asked yet, being asked, a folder, a file, nothing there, or the host unreachable.
enum _PathCheck { idle, checking, ok, file, missing, transport }

class NewSheet extends StatefulWidget {
  const NewSheet({super.key, this.kind = NewKind.agent, this.host, this.path, this.typed});
  final NewKind kind;
  final Host? host;
  final String? path;

  /// Opens with the Location already in 'Type a path…' with this text, checked (the demo opens it in each state).
  final String? typed;

  @override
  State<NewSheet> createState() => _NewSheetState();
}

class _NewSheetState extends State<NewSheet> {
  late NewKind _kind = widget.kind;
  var _runtime = AgentRuntime.claude;
  Host? _host;
  String? _path;

  /// The location's worktrees, main checkout first; null while they load.
  List<Worktree>? _worktrees;
  Object? _error;

  /// The chosen worktree's path; null with [_creating]: a new one.
  String? _worktree;
  bool _creating = false;
  final _name = WorktreeNameModel();

  /// Typing a folder path by hand (checked on the host) instead of choosing an opened location.
  bool _typing = false;
  final _typed = TextEditingController();
  final _typedFocus = FocusNode();
  Timer? _debounce;
  _PathCheck _check = _PathCheck.idle;

  /// The (trimmed) text the last check answered for, and what it was about.
  String _checkedText = '';

  @override
  void initState() {
    super.initState();
    final store = AppScope.read(context);
    _host = widget.host ?? store.active;
    _path = widget.path ?? _locations(store).where((l) => l.$1.id == _host?.id).map((l) => l.$2.path).firstOrNull;
    _load();
    if (widget.typed case final t?) {
      _typing = true;
      _typed.text = t;
      WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _runCheck() : null);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _typed.dispose();
    _typedFocus.dispose();
    _name.dispose();
    super.dispose();
  }

  /// Every opened location: a project of a host (pinned, or with a rig or an agent in it).
  static List<(Host, Project)> _locations(HostStore store) => [
        for (final h in store.hosts)
          for (final p in fleet.feedFor(h).projects)
            if (p.pinned || p.rigs.isNotEmpty || p.loose.isNotEmpty) (h, p)
      ];

  Future<void> _load() async {
    final host = _host, path = _path;
    setState(() {
      _worktrees = null;
      _error = null;
      _worktree = path;
      _creating = false;
    });
    if (host == null || path == null) return;
    _name.load(host, path);
    try {
      final ssh = await SshExec.connect(host);
      try {
        final found = await ssh.worktrees(path).catchError((_) => <Worktree>[]);
        if (!mounted || path != _path || host != _host) return;
        setState(() => _worktrees = found);
      } finally {
        ssh.close();
      }
    } catch (e) {
      if (mounted && path == _path) setState(() => _error = e);
    }
  }

  void _pickLocation(Host host, String path) {
    _debounce?.cancel();
    _typing = false;
    _check = _PathCheck.idle;
    _host = host;
    _path = path;
    _addAsProject = true;
    _load();
  }

  Future<void> _chooseFolder() async {
    final host = _host;
    if (host == null) return;
    final path = await chooseFolder(context, host, title: 'Choose a folder');
    if (path == null || !mounted) return;
    // Choosing a folder to start in does not add it to the project list by itself: the toggle under the field does.
    _pickLocation(host, path);
  }

  void _typedChanged(String _) {
    _debounce?.cancel();
    final text = cleanTypedPath(_typed.text);
    setState(() => _check = text.isEmpty ? _PathCheck.idle : _PathCheck.checking);
    if (text.isNotEmpty) _debounce = Timer(const Duration(milliseconds: 400), _runCheck);
  }

  /// Asks the host whether the typed path is a folder (never on every key: Enter, or 400 ms after the last one).
  Future<void> _runCheck() async {
    _debounce?.cancel();
    final host = _host, text = cleanTypedPath(_typed.text);
    if (host == null || text.isEmpty) return;
    setState(() {
      _check = _PathCheck.checking;
      _checkedText = text;
    });
    try {
      final ssh = await SshExec.connect(host);
      try {
        final (state, abs) = await ssh.folderCheck(text);
        if (!mounted || cleanTypedPath(_typed.text) != text) return;
        switch (state) {
          case FolderState.folder:
            _path = abs;
            setState(() => _check = _PathCheck.ok);
            _load();
          case FolderState.file:
            setState(() => _check = _PathCheck.file);
          case FolderState.missing:
            setState(() => _check = _PathCheck.missing);
        }
      } finally {
        ssh.close();
      }
    } catch (_) {
      if (mounted && cleanTypedPath(_typed.text) == text) setState(() => _check = _PathCheck.transport);
    }
  }

  void _startTyping() {
    setState(() {
      _typing = true;
      _check = _PathCheck.idle;
      _typed.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _typedFocus.requestFocus());
  }

  void _stopTyping() {
    _debounce?.cancel();
    setState(() {
      _typing = false;
      _check = _PathCheck.idle;
    });
  }

  /// How many agents run in worktree [name] (null: the main checkout) of the project.
  int _agentsIn(String? name) {
    final host = _host;
    if (host == null) return 0;
    final p = fleet.feedFor(host).projects.where((p) => p.path == _path).firstOrNull;
    if (p == null) return 0;
    return [
      for (final r in p.rigs) ...r.seats.where((s) => s.isAgent && s.state != SeatState.stopped && worktreeName(s.cwd) == name),
      for (final a in p.loose) if (worktreeName(a.cwd) == name) a,
    ].length;
  }

  /// Add the location to the host's project list when the sheet starts something there (the toggle's state).
  bool _addAsProject = true;

  /// The toggle shows for a folder that is not a project yet (nothing pinned or running there).
  bool get _showAddAsProject {
    final host = _host, path = _path;
    if (host == null || path == null || (_typing && _check != _PathCheck.ok)) return false;
    return !_locations(AppScope.read(context)).any((l) => l.$1.id == host.id && l.$2.path == path);
  }

  bool get _canStart =>
      _host != null &&
      _path != null &&
      (!_typing || _check == _PathCheck.ok) &&
      (!_creating || _name.ok);

  Future<void> _start() async {
    final branch = _name.name;
    if (_showAddAsProject && _addAsProject) await AppScope.read(context).pinFolder(_host!, _path!);
    if (!mounted) return;
    Navigator.pop(
        context,
        NewChoice(_kind, _host!, _path!,
            worktree: _creating ? null : _worktree, newBranch: _creating ? branch : null, runtime: _runtime));
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context);
    final k = Tokens.of(context);
    final many = store.hosts.length > 1;
    final locations = _locations(store);
    // A typed path counts once the host has said it is a folder.
    final hasLocation = _host != null && _path != null && (!_typing || _check == _PathCheck.ok);
    // A folder that is not a git repository has no worktrees to choose: it starts in the folder itself.
    final gitless = hasLocation && _worktrees != null && _worktrees!.isEmpty && _error == null;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Expanded(child: Text('New', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700))),
            IconButton(tooltip: 'Close', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
          ]),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Segmented<NewKind>(
              compact: true,
              values: NewKind.values,
              labels: const ['Agent', 'Shell', 'Rig'],
              selected: _kind,
              onChanged: (v) => setState(() => _kind = v),
              semanticLabel: 'What to start',
            ),
          ),
          const SizedBox(height: 16),
          const SectionLabel('Location'),
          PopupMenuButton<Object>(
            tooltip: 'Location',
            position: PopupMenuPosition.under,
            // As wide as the field it opens from, so a path is not cut to its first letters.
            constraints: const BoxConstraints(minWidth: 320, maxWidth: 480),
            onSelected: (v) {
              if (v == 'type') {
                _startTyping();
              } else if (v == 'choose') {
                _chooseFolder();
              } else if (v is (Host, String)) {
                _pickLocation(v.$1, v.$2);
              }
            },
            itemBuilder: (_) => [
              for (final (h, p) in locations)
                PopupMenuItem<Object>(
                  value: (h, p.path),
                  child: _locationRow(k, h, p, many, selected: h == _host && p.path == _path),
                ),
              const PopupMenuItem<Object>(
                  value: 'type',
                  child: Row(children: [Icon(Icons.keyboard_outlined, size: 16), SizedBox(width: 10), Text('Type a path…')])),
              if (_host != null) ...[
                const PopupMenuDivider(),
                const PopupMenuItem<Object>(value: 'choose', child: Row(children: [Icon(Icons.add, size: 18), SizedBox(width: 10), Text('Choose another folder…')])),
              ],
            ],
            child: _typing
                ? _typedField(k, many)
                : _field(k, [
                    AppIcon(AppIconKind.folder, size: 18, color: k.muted),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text(_path == null ? 'No project yet' : tildePath(_path!),
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 14, color: k.ink))),
                    if (many && _host != null) _hostChip(k, _host!),
                  ]),
          ),
          if (_typing) _typedMessage(k),
          if (_showAddAsProject)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(children: [
                Switch(value: _addAsProject, onChanged: (v) => setState(() => _addAsProject = v)),
                const SizedBox(width: 8),
                Expanded(
                    child: Text('Add ${tildePath(_path!)} as a project',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: k.ink))),
              ]),
            ),
          const SizedBox(height: 16),
          if (gitless)
            Text('Not a git repository: starts in this folder', style: TextStyle(fontSize: 12, color: k.muted))
          else if (_typing && !hasLocation)
            const SizedBox.shrink()
          else ...[
          const SectionLabel('Worktree'),
          if (!hasLocation)
            Text('Choose a location first.', style: TextStyle(color: k.muted))
          else if (_worktrees == null && _error == null)
            _field(k, [Expanded(child: Text('Loading worktrees…', style: TextStyle(fontSize: 14, color: k.muted)))])
          else
            PopupMenuButton<Object>(
              tooltip: 'Worktree',
              position: PopupMenuPosition.under,
              constraints: const BoxConstraints(minWidth: 320, maxWidth: 480),
              onSelected: (v) => setState(() {
                if (v == 'new') {
                  _creating = true;
                } else {
                  _creating = false;
                  _worktree = v as String;
                }
              }),
              itemBuilder: (_) => [
                for (final w in _worktrees ?? <Worktree>[Worktree(_path!, null)])
                  PopupMenuItem<Object>(value: w.path, child: _worktreeRow(k, w, main: w.path == (_worktrees ?? [Worktree(_path!, null)]).first.path)),
                PopupMenuItem<Object>(
                    value: 'new',
                    child: Row(children: [
                      const Icon(Icons.add, size: 18),
                      const SizedBox(width: 10),
                      const Text('New worktree…'),
                      const SizedBox(width: 8),
                      Flexible(
                          child: Text('from the main checkout',
                              maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.end, style: TextStyle(fontSize: 12, color: k.muted))),
                    ])),
              ],
              child: _field(k, _creating ? _newRow(k) : _selectedRow(k)),
            ),
          ],
          if (_creating && !gitless && hasLocation) ...[
            const SizedBox(height: 8),
            // The same field, preview and errors as the project's New worktree sheet.
            WorktreeNameField(model: _name),
          ],
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Couldn\'t read the worktrees: $_error', style: TextStyle(fontSize: 12, color: k.removed))),
          if (_kind == NewKind.agent) ...[
            const SizedBox(height: 16),
            const SectionLabel('Runtime'),
            Align(
              alignment: Alignment.centerLeft,
              child: Segmented<AgentRuntime>(
                compact: true,
                values: AgentRuntime.values,
                labels: const ['Claude', 'Codex'],
                selected: _runtime,
                onChanged: (v) => setState(() => _runtime = v),
                semanticLabel: 'Runtime',
              ),
            ),
          ],
          const SizedBox(height: 20),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            const SizedBox(width: 12),
            FilledButton(
                onPressed: _canStart ? _start : null,
                // A new worktree is made when this is pressed, then the thing starts in it.
                child: Text(_creating
                    ? 'Create worktree and start'
                    : switch (_kind) { NewKind.agent => 'Start agent', NewKind.shell => 'Start shell', NewKind.rig => 'Start rig…' })),
          ]),
        ]),
      ),
    );
  }

  Widget _field(Tokens k, List<Widget> children) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(border: Border.all(color: k.ink, width: 1), borderRadius: BorderRadius.circular(kRadius)),
        child: Row(children: [...children, const SizedBox(width: 8), Icon(Icons.expand_more, color: k.muted)]),
      );

  /// The Location field while typing a path: autofocused, mono, the check's mark and the host chip at its right, the ⌄ to
  /// reopen the menu; Escape goes back to the normal field.
  Widget _typedField(Tokens k, bool many) {
    final mark = switch (_check) {
      _PathCheck.checking => SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: k.muted)),
      _PathCheck.ok => Icon(Icons.check, size: 16, color: k.added),
      _PathCheck.file || _PathCheck.missing => Icon(Icons.priority_high, size: 16, color: k.removed),
      // A warning triangle, not the ! of 'no such folder': the host could not be asked at all.
      _PathCheck.transport => Icon(Icons.warning_amber_rounded, size: 16, color: _transportRed(k)),
      _PathCheck.idle => null,
    };
    return _field(k, [
      AppIcon(AppIconKind.folder, size: 18, color: k.muted),
      const SizedBox(width: 10),
      Expanded(
        child: Focus(
          onKeyEvent: (_, e) {
            if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
              _stopTyping();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: TextField(
            controller: _typed,
            focusNode: _typedFocus,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            style: mono(context, size: 12.5, color: k.ink),
            // No box of its own: the field's outline is the Location field's.
            decoration: InputDecoration(
                isCollapsed: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: '~/code/foo or /srv/x',
                hintStyle: mono(context, size: 12.5, color: k.faint)),
            onChanged: _typedChanged,
            onSubmitted: (_) => _runCheck(),
          ),
        ),
      ),
      if (mark != null) ...[const SizedBox(width: 8), mark],
      if (many && _host != null) ...[const SizedBox(width: 8), _hostChip(k, _host!)],
    ]);
  }

  /// A red apart from the 'no folder' one: the host could not be asked at all.
  Color _transportRed(Tokens k) => Color.lerp(k.removed, k.ink, 0.3)!;

  /// The check's message under the typed field, in place.
  Widget _typedMessage(Tokens k) {
    final text = _checkedText;
    final host = _host?.name ?? 'the host';
    Widget line(String t, Color c, {Widget? action}) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(children: [
            Flexible(child: Text(t, style: TextStyle(fontSize: 12, color: c))),
            if (action != null) ...[const SizedBox(width: 8), action],
          ]),
        );
    return switch (_check) {
      _PathCheck.checking => line('Checking…', k.muted),
      _PathCheck.missing => line('No folder at $text on $host', k.removed),
      _PathCheck.file => line('That is a file, not a folder', k.removed),
      _PathCheck.transport => line('Can\'t reach $host: try again', _transportRed(k),
          action: InkWell(onTap: _runCheck, child: Text('Retry', style: TextStyle(fontSize: 12, color: k.ink, decoration: TextDecoration.underline)))),
      _ => const SizedBox.shrink(),
    };
  }

  Widget _hostChip(Tokens k, Host h) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(border: Border.all(color: k.border), borderRadius: BorderRadius.circular(kRadius)),
        child: Text(h.name, style: mono(context, size: 12, color: k.muted)),
      );

  Widget _locationRow(Tokens k, Host h, Project p, bool many, {required bool selected}) {
    final up = SeatTallyCount.agents(h, p);
    return Row(children: [
      AppIcon(AppIconKind.folder, size: 18, color: k.muted),
      const SizedBox(width: 10),
      // The path and its agent count take the room; the host chip sits at the row's right edge (a Flexible and a Spacer
      // would split the free space and leave it short of the edge).
      Expanded(
        child: Row(children: [
          Flexible(child: Text(tildePath(p.path), overflow: TextOverflow.ellipsis, style: mono(context, size: 13, color: k.ink))),
          if (up > 0) Text(' · $up ${up == 1 ? 'agent' : 'agents'}', style: TextStyle(fontSize: 12, color: k.muted)),
        ]),
      ),
      if (many) _hostChip(k, h),
      // The check's column is reserved on every row, so the chips line up whether or not a row is the chosen one.
      const SizedBox(width: 8),
      SizedBox(width: 18, child: selected ? const Icon(Icons.check, size: 18) : null),
    ]);
  }

  /// The worktree field when one is chosen: its chip, its name and path.
  List<Widget> _selectedRow(Tokens k) {
    final list = _worktrees ?? <Worktree>[Worktree(_path!, null)];
    final w = list.where((w) => w.path == _worktree).firstOrNull ?? list.first;
    final main = w.path == list.first.path;
    return [
      WorktreeChip(main ? 'main' : (worktreeName(w.path) ?? w.branch ?? 'worktree')),
      const SizedBox(width: 10),
      Expanded(
          child: Text('${main ? 'main checkout' : (worktreeName(w.path) ?? w.branch ?? 'worktree')} · ${middleEllipsis(tildePath(w.path), max: 30)}',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 13, color: k.ink))),
    ];
  }

  List<Widget> _newRow(Tokens k) => [
        AppIcon(AppIconKind.worktree, size: 16, color: k.muted),
        const SizedBox(width: 10),
        Expanded(child: Text('New worktree', style: TextStyle(fontSize: 14, color: k.ink))),
      ];

  Widget _worktreeRow(Tokens k, Worktree w, {required bool main}) {
    final name = main ? null : worktreeName(w.path);
    final n = _agentsIn(name);
    return Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(main ? 'main checkout' : (name ?? w.branch ?? 'worktree'), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            WorktreeChip(main ? 'main' : (w.branch ?? name ?? 'worktree')),
          ]),
          // Cut in the middle: the end of the path is what tells worktrees apart.
          Text('${middleEllipsis(tildePath(w.path), max: 34)}${n > 0 ? ' · $n ${n == 1 ? 'agent' : 'agents'}' : ''}',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 12, color: k.muted)),
        ]),
      ),
      if (w.path == _worktree && !_creating) const Icon(Icons.check, size: 18),
    ]);
  }
}

/// Agents running in a project, for the location list.
class SeatTallyCount {
  static int agents(Host h, Project p) => [
        for (final r in p.rigs) ...r.seats.where((s) => s.isAgent && s.state != SeatState.stopped),
        ...p.loose,
      ].length;
}
