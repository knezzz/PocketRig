part of '../chat_screen.dart';

// C
extension _ChatMedia on _ChatPageState {
  /// The pills over the composer: files changed with the diff, artifacts
  /// and PRs. One of a kind shows its name and opens it; more open a list.
  Widget? _sessionPills() {
    final files = _files;
    final artifacts = _transcript.publishedArtifacts.reversed.toList();
    // The git bar above already shows the branch's PR.
    final shownAbove = _git?.isRepo ?? false ? _git?.pr?.url : null;
    final prs = _prs.where((p) => p.$2.toString() != shownAbove).toList();
    final media = _media;
    final shells = _jobs.where((j) => j.isShell).toList();
    final started = _startedSubagents;
    // Some run before the log shows their call (or from a cached chat): never fewer than are running.
    final count = started.length < _subagents.length ? _subagents.length : started.length;
    if (files.isEmpty && artifacts.isEmpty && prs.isEmpty && media.isEmpty && shells.isEmpty && count == 0) return null;
    final (add, del) = _ChatPageState._sum(files);
    final k = Tokens.of(context);
    final n = '$count ${count == 1 ? 'subagent' : 'subagents'}';
    // Running: mint (working, spending tokens) and first. All done: a whisper of mint with ✓, and last.
    final subagentsPill = _subagents.isEmpty
        ? SessionPill(
            label: '$n done',
            spoken: '$count subagents, all finished',
            leading: Text('✓', style: mono(context, size: 12, color: _ChatPageState._doneMint(k))),
            tint: k.added.withValues(alpha: 0.05),
            textColor: _ChatPageState._doneMint(k),
            onTap: _showSubagents,
          )
        : SessionPill(
            label: '$n · ${_subagents.length} running',
            spoken: '$count subagents started, ${_subagents.length} running',
            leading: const StatusShape(Status.working, size: 8, semantics: false),
            tint: k.added.withValues(alpha: 0.13),
            textColor: k.added,
            bold: true,
            onTap: _showSubagents,
          );
    return SessionPills(pills: [
      if (count > 0 && _subagents.isNotEmpty) subagentsPill,
      if (shells.isNotEmpty)
        SessionPill(
          label: AgentJob.counts(shells).join(' · '),
          spoken: 'Running ${AgentJob.counts(shells).join(', ')}',
          leading: const StatusShape(Status.shell, size: 8, semantics: false),
          tint: k.shell.withValues(alpha: 0.13),
          textColor: k.shell,
          bold: true,
          onTap: _showJobs,
        ),
      if (files.isNotEmpty)
        SessionPill(
          label: files.length == 1 ? files.single.key.split('/').last : '${files.length} files',
          added: add + del == 0 ? null : add,
          removed: add + del == 0 ? null : del,
          spoken: files.length == 1 ? 'Changed file ${files.single.key.split('/').last}' : '${files.length} files changed',
          onTap: files.length == 1 ? () => _openFile(files.single.key) : _showFiles,
        ),
      if (prs.isNotEmpty)
        SessionPill(
          icon: Icons.call_merge,
          label: prs.length == 1 ? prs.single.$1 : '${prs.length} pull requests',
          spoken: prs.length == 1 ? 'Pull request ${prs.single.$1}' : '${prs.length} pull requests',
          onTap: prs.length == 1 ? () => _openUrl(prs.single.$2) : _showPrs,
        ),
      if (media.isNotEmpty)
        SessionPill(
          icon: Icons.photo_library_outlined,
          label: media.length == 1 ? media.single.split('/').last : '${media.length} images & videos',
          spoken: media.length == 1 ? 'Media ${media.single.split('/').last}' : '${media.length} images and videos',
          onTap: media.length == 1 ? () => _openMedia(media.single) : _showMedia,
        ),
      if (artifacts.isNotEmpty)
        SessionPill(
          icon: Icons.web_asset,
          label: artifacts.length == 1 ? artifacts.single.$1 : '${artifacts.length} artifacts',
          spoken: artifacts.length == 1 ? 'Artifact ${artifacts.single.$1}' : '${artifacts.length} artifacts',
          onTap: artifacts.length == 1 ? () => _openUrl(artifacts.single.$2) : _showArtifacts,
        ),
      if (count > 0 && _subagents.isEmpty) subagentsPill,
    ]);
  }

  List<String> _mediaOf(ChatItem i) {
    final size = switch (i) { ToolCall(:final result) => result?.length ?? -1, AssistantMessage(:final text) => text.length, _ => 0 };
    final hit = _mediaSeen[i.key];
    if (hit != null && hit.$1 == size) return hit.$2;
    final found = mediaOf(i, _seat.cwd ?? _transcript.cwd);
    _mediaSeen[i.key] = (size, found);
    return found;
  }

  /// Every image and video the session made or named that the host can
  /// read, newest first. Names in text are often of files that never existed.
  List<String> get _media {
    final all = {for (final i in _transcript.items.reversed) ..._mediaOf(i)};
    if (all.any((p) => !_mediaOk.containsKey(p))) scheduleMicrotask(_checkMedia);
    return _readable(all);
  }

  List<String> _readable(Iterable<String> paths) => [for (final p in paths) if (_mediaOk[p] == true) p];

  Future<void> _checkMedia() async {
    final host = AppScope.read(context).active;
    final failed = _mediaFailedAt;
    if (_checkingMedia || host == null) return;
    if (failed != null && DateTime.now().difference(failed) < const Duration(seconds: 30)) return;
    final todo = {for (final i in _transcript.items) ..._mediaOf(i)}.where((p) => !_mediaOk.containsKey(p)).toList();
    if (todo.isEmpty) return;
    _checkingMedia = true;
    SshExec? ssh;
    try {
      ssh = await SshExec.connect(host);
      final ok = await ssh.readable(todo);
      if (mounted) _set(() => _mediaOk.addAll({for (final p in todo) p: ok.contains(p)}));
    } catch (_) {
      // Unchecked stays hidden; a build after the pause tries again.
      _mediaFailedAt = DateTime.now();
    } finally {
      ssh?.close();
      _checkingMedia = false;
    }
  }

  /// Opens [path] in a viewer that swipes through the session's other media.
  void _openMedia(String path) {
    final all = _media;
    final at = all.indexOf(path);
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => at < 0 ? MediaViewer(paths: [path], seat: _seat) : MediaViewer(paths: all, initial: at, seat: _seat)));
  }
}
