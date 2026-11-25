import 'package:flutter/material.dart';

import '../data/git_status.dart';
import '../data/projects.dart';
import '../main.dart';
import '../ssh/ssh_exec.dart';
import 'artifact_viewer.dart';
import 'chat/diff_view.dart';
import 'chat_screen.dart' show ChangesCard;
import 'common.dart';
import 'desktop_shell.dart';
import 'kit.dart';
import 'theme.dart';

const _unreadableMark = '@@pocketrig-unreadable@@';

/// `ls -1Ap` output: folders (trailing `/`) first, then files.
List<String> parseListing(String out) {
  final names = out.split('\n').where((l) => l.isNotEmpty).toList();
  return [...names.where((n) => n.endsWith('/')), ...names.where((n) => !n.endsWith('/'))];
}

/// A project folder's uncommitted changes and its file tree, read over SSH.
/// Folders open in place; files open their diff when git has one, else read-only.
class ProjectFiles extends StatefulWidget {
  const ProjectFiles({super.key, required this.path});
  final String path;
  @override
  State<ProjectFiles> createState() => ProjectFilesState();
}

class ProjectFilesState extends State<ProjectFiles> {
  String? _root;

  /// The open folder, relative to [_root] ('' is the project folder).
  String _rel = '';
  List<String>? _entries;

  /// The open folder exists but SSH could not read it.
  bool _unreadable = false;
  GitStatus? _git;
  String? _error;

  String get _dir => _rel.isEmpty ? _root! : '$_root/$_rel';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => reload());
  }

  /// Lists the open folder, then refreshes git status (slower: it asks gh too).
  Future<void> reload({bool git = true}) async {
    final host = AppScope.read(context).active;
    if (host == null) return;
    setState(() => _error = null);
    SshExec? ssh;
    try {
      ssh = await SshExec.connect(host);
      _root ??= await ssh.resolve(widget.path);
      // shortcut: first 1000 entries only, page it if huge folders matter.
      final out = await ssh.run(
          'ls -1Ap -- ${shQuote(_dir)} 2>/dev/null | head -n 1000; [ -d ${shQuote(_dir)} ] && [ -r ${shQuote(_dir)} ] || echo $_unreadableMark');
      if (!mounted) return;
      setState(() {
        _unreadable = out.contains(_unreadableMark);
        _entries = parseListing(out.replaceAll(_unreadableMark, ''));
      });
      if (git) {
        final status = await ssh.gitStatus(_root!);
        if (mounted) setState(() => _git = status);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      ssh?.close();
    }
  }

  void _cd(String rel) {
    setState(() {
      _rel = rel;
      _entries = null;
      _error = null;
    });
    reload(git: false);
  }

  void _open(String abs) {
    final git = _git, root = git?.root;
    final rel = root != null && abs.startsWith('$root/') ? abs.substring(root.length + 1) : null;
    final changed = rel != null && git!.changeRows.any((r) => r.$2 == rel);
    detailNavigator(context).push(MaterialPageRoute<void>(
        builder: (_) => changed
            ? DiffScreen(root: root!, path: rel, untracked: git.untracked.contains(rel))
            : ArtifactViewer(path: abs)));
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final git = _git;
    // Changed paths as absolute, for the status letter beside each file.
    final status = {
      if (git?.root case final root?)
        for (final (s, p, _) in git!.changeRows) '$root/$p': s,
    };
    final entries = _entries;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (_error != null) ErrorBanner(_error!, margin: const EdgeInsets.only(bottom: 12)),
      const SectionLabel('Uncommitted changes'),
      if (git == null && _error != null)
        Text('Not read: SSH couldn\'t connect.', style: TextStyle(color: k.muted))
      else if (git == null)
        const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
      else if (!git.isRepo)
        Text('Not a git checkout.', style: TextStyle(color: k.muted))
      else if (git.changeRows.isEmpty)
        Text('Nothing uncommitted.', style: TextStyle(color: k.muted))
      else
        ChangesCard(git: git, onOpen: _open),
      const SizedBox(height: 22),
      SectionLabel(_rel.isEmpty ? 'Files' : 'Files · $_rel'),
      if (entries == null && _error != null)
        // The SSH connection failed (the banner above says why): the listing never ran.
        BorderedList(children: [
          RowTile(
            minHeight: 44,
            title: 'SSH couldn\'t connect, so the files can\'t be listed.',
            trailing: Text('Retry', style: TextStyle(color: k.accent, fontWeight: FontWeight.w600)),
            onTap: reload,
          ),
        ])
      else if (entries == null)
        const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
      else
        BorderedList(children: [
          if (_rel.isNotEmpty)
            RowTile(
              minHeight: 44,
              leading: Icon(Icons.arrow_upward, size: 18, color: k.muted),
              title: '..',
              onTap: () => _cd(_rel.contains('/') ? _rel.substring(0, _rel.lastIndexOf('/')) : ''),
            ),
          if (entries.isEmpty)
            RowTile(minHeight: 44, title: _unreadable ? 'This folder is missing or SSH has no permission to read it.' : 'Empty folder.')
          else
            for (final e in entries)
              if (e.endsWith('/'))
                RowTile(
                  minHeight: 44,
                  leading: Icon(Icons.folder_outlined, size: 18, color: k.muted),
                  title: e.substring(0, e.length - 1),
                  onTap: () => _cd([if (_rel.isNotEmpty) _rel, e.substring(0, e.length - 1)].join('/')),
                  arrow: true,
                )
              else
                RowTile(
                  minHeight: 44,
                  leading: Icon(Icons.description_outlined, size: 18, color: k.muted),
                  title: e,
                  trailing: status['$_dir/$e'] == null ? null : Text(status['$_dir/$e']!, style: mono(context)),
                  onTap: () => _open('$_dir/$e'),
                ),
        ]),
    ]);
  }
}

/// The project's changes and file tree on their own screen, pushed from the project's Overview.
class ProjectFilesScreen extends StatefulWidget {
  const ProjectFilesScreen({super.key, required this.path, required this.name});
  final String path;
  final String name;
  @override
  State<ProjectFilesScreen> createState() => _ProjectFilesScreenState();
}

class _ProjectFilesScreenState extends State<ProjectFilesScreen> {
  final _files = GlobalKey<ProjectFilesState>();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          PageHeader(title: 'Files', subtitle: Text(widget.name, style: mono(context))),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => _files.currentState?.reload(),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [ProjectFiles(key: _files, path: widget.path)],
              ),
            ),
          ),
        ]),
      );
}
