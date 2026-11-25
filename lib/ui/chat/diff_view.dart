import 'package:flutter/material.dart';

import '../../data/projects.dart';
import '../../main.dart';
import '../../ssh/ssh_exec.dart';
import '../artifact_viewer.dart';
import '../common.dart';
import '../kit.dart';
import '../theme.dart';

/// Read at most this much: SSH decrypts on the UI thread here, about a second per MB.
const _maxDiffBytes = 512 * 1024;

/// What [root]'s `git diff` says about [path], against HEAD. Git leaves new
/// files out of that, so [untracked] ones are compared with nothing.
/// Plain patch output whatever the host's git config says (color.ui=always,
/// diff.external=difftastic), or the +/- lines can't be told apart.
String diffCommand(String root, String path, {required bool untracked}) {
  const git = 'git diff --no-color --no-ext-diff';
  final diff = untracked ? '$git --no-index -- /dev/null ${shQuote(path)}' : '$git HEAD -- ${shQuote(path)}';
  return 'cd ${shQuote(root)} && $diff | head -c $_maxDiffBytes';
}

enum DiffLine { meta, hunk, added, removed, context }

DiffLine diffLineKind(String line) {
  if (line.startsWith('+++') || line.startsWith('---')) return DiffLine.meta;
  if (line.startsWith('@@')) return DiffLine.hunk;
  if (line.startsWith('+')) return DiffLine.added;
  if (line.startsWith('-')) return DiffLine.removed;
  if (line.startsWith(' ') || line.isEmpty) return DiffLine.context;
  return DiffLine.meta; // diff --git, index, new file mode, Binary files…
}

/// One file's uncommitted changes, read-only.
class DiffScreen extends StatefulWidget {
  const DiffScreen({super.key, required this.root, required this.path, this.untracked = false, this.embedded = false});
  final String root;

  /// In a pane beside a file list (the rig page's Code tab on a wide pane): the diff with a slim title row, no page chrome.
  final bool embedded;

  /// Relative to [root].
  final String path;
  final bool untracked;
  @override
  State<DiffScreen> createState() => _DiffScreenState();
}

class _DiffScreenState extends State<DiffScreen> {
  List<String>? _lines;
  String? _error;
  bool _cut = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final host = AppScope.read(context).active;
    if (host == null) return;
    SshExec? ssh;
    try {
      ssh = await SshExec.connect(host);
      // Login shell, like the git status that listed the file, so it's the same git.
      final out = await ssh.runLogin(diffCommand(widget.root, widget.path, untracked: widget.untracked));
      if (!mounted) return;
      setState(() {
        _cut = out.length >= _maxDiffBytes;
        _lines = out.isEmpty ? const [] : out.trimRight().split('\n');
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Couldn\'t read the diff over SSH: $e');
    } finally {
      ssh?.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final lines = _lines;
    final content = _error != null
        ? Padding(padding: const EdgeInsets.all(16), child: ErrorBanner(_error!, margin: EdgeInsets.zero))
        : lines == null
            ? const Center(child: CircularProgressIndicator())
            : lines.isEmpty
                ? Center(child: Text('No changes to show.', style: TextStyle(color: k.muted)))
                : ListView.builder(
                    padding: EdgeInsets.fromLTRB(0, 8, 0, 8 + MediaQuery.paddingOf(context).bottom),
                    itemCount: lines.length + (_cut ? 1 : 0),
                    itemBuilder: (_, i) => i == lines.length
                        ? Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text('Diff too long, the rest is cut off.', style: TextStyle(fontSize: 12, color: k.muted)),
                          )
                        : _Line(lines[i]),
                  );
    if (widget.embedded) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(children: [
            Flexible(child: Text(widget.path, style: mono(context, size: 12, color: k.ink), maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (lines != null && lines.isNotEmpty) ...[const SizedBox(width: 8), DeltaText(_counts(lines), size: 11)],
          ]),
        ),
        Divider(height: 1, color: k.border),
        Expanded(child: content),
      ]);
    }
    return Scaffold(
      body: Column(children: [
        PageHeader(
          compact: true,
          title: widget.path.split('/').last,
          subtitle: Row(children: [
            if (lines != null && lines.isNotEmpty) ...[
              DeltaText(_counts(lines), size: 11),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text('${widget.path} · ${widget.untracked ? 'new file' : 'uncommitted'}',
                  style: mono(context), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ]),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ArtifactViewer(path: '${widget.root}/${widget.path}', fromDiff: true),
                )),
                style: compactAction,
                child: const Text('View file'),
              ),
            ),
          ],
        ),
        Expanded(child: content),
      ]),
    );
  }
}

/// "+24 −6" over a diff's lines.
String _counts(List<String> lines) {
  var add = 0, del = 0;
  for (final l in lines) {
    switch (diffLineKind(l)) {
      case DiffLine.added:
        add++;
      case DiffLine.removed:
        del++;
      default:
    }
  }
  return del == 0 ? '+$add' : '+$add −$del';
}

class _Line extends StatelessWidget {
  const _Line(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final kind = diffLineKind(text);
    // Dark: neon tints with a bar down the left edge, the text lifted toward the color.
    final dark = k.isDark;
    final (Color? bg, Color fg, Color? bar) = switch (kind) {
      DiffLine.added => (
          k.added.withValues(alpha: dark ? 0.09 : 0.14),
          dark ? Color.lerp(k.added, Colors.white, 0.7)! : k.ink,
          k.added
        ),
      DiffLine.removed => (
          k.removed.withValues(alpha: dark ? 0.09 : 0.14),
          dark ? Color.lerp(k.removed, Colors.white, 0.7)! : k.ink,
          k.removed
        ),
      DiffLine.hunk => (k.fill, k.muted, null),
      DiffLine.meta => (null, k.muted, null),
      DiffLine.context => (null, dark ? k.muted : k.ink, null),
    };
    return Container(
      decoration: BoxDecoration(
        color: bg,
        border: bar == null ? null : Border(left: BorderSide(color: bar, width: 2)),
      ),
      padding: EdgeInsets.fromLTRB(bar == null ? 12 : 10, 1, 12, 1),
      // No ligatures: a diff should show the characters that are in the file.
      child: Text(text,
          style: mono(context, size: 11.5, color: fg)
              .copyWith(fontFeatures: const [FontFeature.disable('liga'), FontFeature.disable('calt')])),
    );
  }
}
