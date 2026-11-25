import 'dart:async';

import 'package:flutter/material.dart';
import 'package:loggy/loggy.dart';

import '../data/host_store.dart' show isDesktop;
import '../data/new_session.dart';
import '../data/projects.dart';
import '../main.dart';
import '../models.dart';
import '../terminal/transport.dart';
import 'chat_screen.dart';
import 'desktop_shell.dart';
import 'kit.dart';
import 'terminal_screen.dart';
import 'theme.dart';

/// Asks for an agent to start in [path] (on the phone) and starts it on the active host, in its own tmux session, opened in the
/// chat for Claude Code and the terminal otherwise. A dialog covers the SSH round trip. (A shell is the project's
/// Shell here; a rig starts from its spec.)
Future<void> startAgentInFolder(BuildContext context, String path) async {
  final host = AppScope.read(context).active;
  if (host == null) return;
  // Desktop skips the sheet: the sheet's defaults (Claude, default model, ask), opened in the terminal, where the
  // person types a model or a message. The phone keeps the sheet.
  final NewSessionSpec? choice;
  if (isDesktop) {
    final id = newSessionId();
    choice = NewSessionSpec(
        runtime: AgentRuntime.claude,
        cwd: path,
        name: newSessionName(AgentRuntime.claude, path, id),
        sessionId: id);
  } else {
    choice = await showModalBottomSheet<NewSessionSpec>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => NewSessionSheet(path: path, hostName: host.name),
    );
  }
  if (choice == null || !context.mounted) return;
  await startAgentWith(context, host, choice);
}

/// Starts [spec] on [host] in its own tmux session and opens it (the chat for Claude Code, else its terminal). A dialog
/// covers the SSH round trip.
Future<void> startAgentWith(BuildContext context, Host host, NewSessionSpec spec) async {
  final nav = Navigator.of(context);
  final api = AppScope.clientOf(context);
  final shown = ValueNotifier('Starting ${spec.runtime.binary} on ${host.name}…');
  unawaited(showStepSheet(nav.context, shown));
  try {
    final agent = await startNewSession(host, spec);
    if (!nav.mounted) return;
    nav.pop();
    // Let the daemon list it under "Not in a rig" without waiting for the next scan.
    unawaited(api?.discovered(scan: true).then((_) {}, onError: (Object e) => logInfo('scan after start: $e')));
    final seat = agent.toSeat();
    unawaited((shownDetailPane() ?? nav).push(MaterialPageRoute<void>(
      builder: (_) => spec.runtime.hasChat && !isDesktop
          ? ChatScreen(rigName: 'no rig', seat: seat, waitForLog: true, pendingMessage: spec.prompt)
          : TerminalScreen(target: SeatTarget('no rig', seat)),
    )));
  } catch (e) {
    if (!nav.mounted) return;
    nav.pop();
    await confirmSheet(nav.context, title: 'Couldn\'t start it', body: '$e', cancel: 'Close');
  }
}

/// The new-agent sheet: runtime, model, permissions, a first message and the tmux session name. Pops with a
/// [NewSessionSpec].
class NewSessionSheet extends StatefulWidget {
  const NewSessionSheet({super.key, required this.path, required this.hostName});
  final String path;
  final String hostName;

  @override
  State<NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends State<NewSessionSheet> {
  final _id = newSessionId();
  var _runtime = AgentRuntime.claude;
  var _mode = ClaudePermissionMode.ask;
  final _model = TextEditingController();
  final _prompt = TextEditingController();
  late final _name = TextEditingController(text: newSessionName(_runtime, widget.path, _id));
  bool _nameEdited = false;

  /// Model aliases offered as segments; anything else goes in the field.
  static const _claudeModels = ['opus', 'sonnet', 'haiku'];

  String get _folder => folderName(widget.path);

  @override
  void dispose() {
    _model.dispose();
    _prompt.dispose();
    _name.dispose();
    super.dispose();
  }

  void _pickRuntime(AgentRuntime r) => setState(() {
        _runtime = r;
        _model.clear();
        if (!_nameEdited) _name.text = newSessionName(r, widget.path, _id);
      });

  void _start() {
    final name = tmuxSafe(_name.text);
    if (name.isEmpty) return;
    Navigator.pop(
      context,
      NewSessionSpec(
        runtime: _runtime,
        cwd: widget.path,
        name: name,
        sessionId: _id,
        model: _model.text.trim().isEmpty ? null : _model.text.trim(),
        permissionMode: _runtime == AgentRuntime.claude ? _mode : ClaudePermissionMode.ask,
        prompt: _prompt.text.trim().isEmpty ? null : _prompt.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final t = Theme.of(context).textTheme;
    return SafeArea(
        child: Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Start in $_folder', style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text('${widget.hostName}:${displayPath(widget.path)}', style: mono(context)),
          const SizedBox(height: 18),
          ..._agent(context, k, t),
        ]),
      ),
    ));
  }

  List<Widget> _agent(BuildContext context, Tokens k, TextTheme t) {
    final model = _model.text.trim();
    return [
      const SectionLabel('Runtime'),
      Segmented<AgentRuntime>(
        values: AgentRuntime.values,
        labels: [for (final r in AgentRuntime.values) r.label],
        selected: _runtime,
        onChanged: _pickRuntime,
        semanticLabel: 'Runtime',
      ),
      const SizedBox(height: 16),
      const SectionLabel('Model'),
      if (_runtime == AgentRuntime.claude) ...[
        Segmented<String>(
          values: const ['', ..._claudeModels],
          labels: const ['default', ..._claudeModels],
          selected: model,
          onChanged: (m) => setState(() => _model.text = m),
          semanticLabel: 'Model',
        ),
        const SizedBox(height: 8),
      ],
      TextField(
        controller: _model,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(fontFamily: fontMono, fontSize: 13),
        decoration: InputDecoration(
          labelText: _runtime == AgentRuntime.claude ? 'Other model' : 'Model',
          hintText: _runtime == AgentRuntime.claude ? 'a full model name' : 'default',
        ),
        onChanged: (_) => setState(() {}),
      ),
      if (_runtime == AgentRuntime.claude) ...[
        const SizedBox(height: 16),
        const SectionLabel('Permissions'),
        Segmented<ClaudePermissionMode>(
          values: ClaudePermissionMode.values,
          labels: [for (final m in ClaudePermissionMode.values) m.label],
          selected: _mode,
          onChanged: (m) => setState(() => _mode = m),
          semanticLabel: 'Permissions',
        ),
        if (_mode == ClaudePermissionMode.bypass) ...[
          const SizedBox(height: 6),
          Text('Runs every tool without asking. Nothing will show up under Needs you.',
              style: t.bodySmall?.copyWith(color: k.accent)),
        ],
      ],
      const SizedBox(height: 16),
      TextField(
        controller: _prompt,
        minLines: 2,
        maxLines: 6,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          labelText: 'First message · optional',
          hintText: 'What should it work on?',
          alignLabelWithHint: true,
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _name,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(fontFamily: fontMono, fontSize: 13),
        decoration: InputDecoration(
          labelText: 'tmux session',
          helperText: tmuxSafe(_name.text).isEmpty
              ? 'Enter a name to start'
              : tmuxSafe(_name.text) == _name.text
                  ? null
                  : 'Will be named ${tmuxSafe(_name.text)}',
          helperMaxLines: 2,
        ),
        onChanged: (_) => setState(() => _nameEdited = true),
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: tmuxSafe(_name.text).isEmpty ? null : _start,
        style: sheetAction,
        child: Text(_runtime.hasChat ? 'Start and open chat' : 'Start and open terminal'),
      ),
      const SizedBox(height: 6),
      Text(
        tmuxSafe(_name.text).isEmpty
            ? 'Name the tmux session to start.'
            : [
                'Runs in its own tmux session — keeps going if your phone drops.',
                if (!_runtime.hasChat) '${_runtime.label} sessions are terminal-only in PocketRig.',
              ].join(' '),
        textAlign: TextAlign.center,
        style: t.bodySmall,
      ),
    ];
  }
}
