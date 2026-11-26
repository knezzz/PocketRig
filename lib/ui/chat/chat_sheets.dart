part of '../chat_screen.dart';

// C
extension _ChatSheets on _ChatPageState {
  Widget _fileTile(BuildContext ctx, String path, (int, int)? n, VoidCallback onTap) {
    final k = Tokens.of(ctx);
    return OptionRow(
      leading: const Icon(Icons.description_outlined, size: 20),
      title: Text(path.split('/').last, overflow: TextOverflow.ellipsis),
      subtitle: Text(_relative(path), maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(ctx, color: k.muted)),
      trailing: n == null
          ? null
          : Text.rich(
              TextSpan(children: [
                TextSpan(text: '+${n.$1} ', style: TextStyle(color: k.added)),
                TextSpan(text: '−${n.$2}', style: TextStyle(color: k.removed)),
              ]),
              style: mono(ctx, size: 12)),
      onTap: onTap,
    );
  }

  /// The subagents this session started: its Agent (Task) calls, oldest first.
  List<ToolCall> get _startedSubagents =>
      _transcript.items.whereType<ToolCall>().where((c) => c.name == 'Agent' || c.name == 'Task').toList();

  void _openSubagent(Subagent s) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => subagentScreen(_seat, s)));

  /// Every subagent this session started, the running ones marked (and opening their chat).
  void _showSubagents() {
    final calls = _startedSubagents.reversed.toList();
    final running = [..._subagents];
    // Running ones the log doesn't show yet still get a row.
    final unmatched = running.where((r) => !calls.any((c) => c.target == r.description)).toList();
    _showList('Subagents · ${calls.length + unmatched.length}${running.isEmpty ? '' : ' · ${running.length} running'}',
        (ctx, then) {
      final k = Tokens.of(ctx);
      Widget tile(String title, String? type, Subagent? live) => OptionRow(
            leading: Icon(Icons.account_tree_outlined, color: live != null ? k.added : k.muted),
            title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(
                [
                  if (type != null) type,
                  if (live != null) 'running${live.started == null ? '' : ' · ${ago(live.started)}'}' else 'finished',
                ].join(' · '),
                style: TextStyle(color: live != null ? k.added : k.muted)),
            trailing: live?.path == null ? null : const Chevron(),
            onTap: live?.path == null ? null : then(() => _openSubagent(live!)),
          );
      return [
        for (final r in unmatched) tile(r.title, r.type, r),
        for (final c in calls)
          tile(c.target.isEmpty ? 'Subagent' : c.target, c.input['subagent_type'] as String?,
              running.where((r) => r.description == c.target).firstOrNull),
      ];
    });
  }

  void _showList(String title, List<Widget> Function(BuildContext ctx, VoidCallback Function(VoidCallback) then) rows) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        VoidCallback then(VoidCallback f) => () {
              Navigator.of(ctx).pop();
              f();
            };
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          builder: (_, scroll) => SafeArea(
            child: ListView(controller: scroll, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(title, style: Theme.of(ctx).textTheme.titleLarge),
              ),
              ...rows(ctx, then),
              const SizedBox(height: 8),
            ]),
          ),
        );
      },
    );
  }

  void _showFiles() {
    final files = _files;
    _showList('Files changed · ${files.length}', (ctx, then) => [
          for (final MapEntry(key: path, value: n) in files) _fileTile(ctx, path, n, then(() => _openFile(path))),
        ]);
  }

  void _showMedia() {
    final media = _media;
    _showList('Images & videos · ${media.length}', (ctx, then) => [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in media) MediaTile(p, onOpen: then(() => _openMedia(p))),
            ]),
          ),
        ]);
  }

  void _showArtifacts() {
    final artifacts = _transcript.publishedArtifacts.reversed.toList();
    _showList('Artifacts · ${artifacts.length}', (ctx, then) => [
          for (final (name, url) in artifacts)
            OptionRow(
              leading: const Icon(Icons.web_asset, size: 20),
              title: Text(name, overflow: TextOverflow.ellipsis),
              subtitle: Text(url.toString(), maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: then(() => _openUrl(url)),
            ),
        ]);
  }

  void _showPrs() {
    final prs = _prs;
    _showList('Pull requests · ${prs.length}', (ctx, then) => [
          for (final (name, url) in prs)
            OptionRow(
              leading: const Icon(Icons.call_merge, size: 20),
              title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: switch (_prDetail(url)) { final d? => Text(d), null => null },
              onTap: then(() => _openUrl(url)),
            ),
        ]);
  }

  void _showJobs() => showJobsSheet(context, _jobs, _seat.sessionName!, (j) => _set(() => _jobs = j));

  /// The agent's details: model and context, usage, code, live activity; for
  /// an agent outside a rig also answer, rename, adopt, restart and kill.
  void _openDetails() {
    final a = widget.loose;
    final onJobs = _seat.sessionName == null ? null : _showJobs;
    // From the details: the terminal takes the chat's place, under the closed details.
    void toTerminal() {
      Navigator.of(context).pop();
      _toTerminal();
    }

    final inClaude = _seat.resumeToken == null ? null : _openInClaude;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => a != null
            ? LooseAgentScreen(
                agent: a, rigs: widget.rigs, fromChat: true, details: _details, onJobs: onJobs, onOpenInClaude: inClaude)
            : SeatDetailsScreen(
                details: _details,
                rigName: widget.rigName,
                onJobs: onJobs,
                onTerminal: toTerminal,
                onOpenInClaude: inClaude,
                onKilled: () {
                  if (mounted) Navigator.of(context).pop();
                })));
  }

  /// The header menu: terminal, Open in Claude, the agent's details, and
  /// what this session made: the files it changed (folded), the artifacts it
  /// published, the PRs it opened.
  Future<void> _removeSeat() async {
    final nav = Navigator.of(context);
    if (await removeSeatFromRig(context, _seat, widget.rigName)) nav.pop();
  }

  /// Ends a rig seat's tmux session and leaves the chat; the seat stays in the rig.
  Future<void> _killSession() async {
    final nav = Navigator.of(context);
    if (await killSeatSession(context, _seat, widget.rigName)) nav.pop();
  }

  /// The header's ⋯: for a rig seat the seat sheet; otherwise the agent's
  /// details, its terminal, and the red actions pinned under them. What the
  /// session made (files, artifacts, PRs) lives in the pills over the composer.
  Future<void> _showMenu() async {
    final rigSeat = widget.loose == null && !_subagent && _seat.nodeId != null && widget.rigName != 'no rig';
    // A rig seat: the agent's one ⋯ list; Agent details is the seat sheet, as the rig's list and map open it.
    if (rigSeat) {
      final session = _seat.sessionName;
      void gone() {
        if (mounted) Navigator.of(context).pop();
      }
      await showActionRows(
          context,
          _seat.logicalId,
          seatMenuRows(context, widget.rigName, _seat,
              fromChat: true,
              onTerminal: session == null ? null : _toTerminal,
              onGone: gone,
              onRefresh: _pollSeat,
              onDetails: () async {
                await showSeatSheet(
                  context,
                  widget.rigName,
                  _seat,
                  details: _details,
                  mode: _mode == null || _mode!.isEmpty ? null : _mode,
                  fromChat: true,
                  onTerminal: session == null ? null : _toTerminal,
                  onJobs: session == null ? null : _showJobs,
                  onSubagents: _showSubagents,
                  onEditSpec: _editSpec,
                  onGone: gone,
                  onRefresh: _pollSeat,
                );
                if (mounted) await _loadMode();
              }));
      return;
    }
    // An agent outside a rig: its own list, the one its screen has.
    if (widget.loose case final a?) {
      await showLooseActions(context, a,
          onTerminal: _seat.sessionName == null ? null : _toTerminal,
          onDetails: _openDetails,
          onRenamed: () => _set(() {}),
          onKilled: () {
            if (mounted) Navigator.of(context).pop();
          });
      return;
    }
    // A subagent has nothing to open or kill.
    await showActionSheet(context, null, [
      if (_seat.sessionName != null && !_subagent)
        (Icons.terminal_outlined, 'Open terminal', 'The seat\'s live pane, for anything the chat can\'t do', _toTerminal),
      if (!_subagent)
        (Icons.info_outline, 'Agent details', 'Model, context, usage, code and what it\'s doing', _openDetails),
    ], danger: [
      if (!_subagent && _seat.nodeId != null && widget.rigName != 'no rig') ...[
        if (_seat.sessionName != null) ('Kill session…', Icons.dangerous_outlined, _killSession),
        ('Remove from rig…', Icons.delete_outline, _removeSeat),
      ],
    ]);
  }

  /// The seat's member in the spec its rig was launched from.
  Future<void> _editSpec() async {
    final api = AppScope.clientOf(context);
    if (api == null) return;
    try {
      final rig = await api.rig(_seat.rigId);
      final seats = await api.seats(_seat.rigId);
      if (!mounted) return;
      if (rig == null) return toast(context, 'That rig no longer exists on the daemon.');
      await editRigSpec(context, rig, seats,
          projectName: switch (RigWithSeats(rig, seats).primaryCwd) { final c? => folderName(c), _ => widget.rigName }, member: _seat.logicalId);
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
  }
}
