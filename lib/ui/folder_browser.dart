import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/host_store.dart' show isDesktop;
import 'kit.dart' show showDialogOrSheet;
import '../models.dart';
import '../ssh/ssh_exec.dart';
import 'app_icon.dart';
import 'host_color.dart';
import 'new_sheet.dart' show cleanTypedPath;
import 'theme.dart';

/// Asks for a folder on [host]: this Mac's system picker, or, for any other host, the in-app browser over SSH (a dialog
/// on the Mac, a full-height sheet on a phone). Returns the absolute path, or null when cancelled.
Future<String?> chooseFolder(BuildContext context, Host host, {String title = 'Choose a project folder'}) {
  if (host.isLocal && isDesktop) return FilePicker.getDirectoryPath(dialogTitle: title);
  final browser = FolderBrowser(host: host, title: title);
  return showDialogOrSheet<String>(context, child: browser, maxWidth: 640, maxHeight: 640, fullHeight: true);
}

/// Folders only, starting at `~`: tap selects a row, its chevron (or a double-click or long press) opens it; the path
/// field takes a pasted path. "Choose this folder" returns the selected folder, or the one you are in.
class FolderBrowser extends StatefulWidget {
  const FolderBrowser({super.key, required this.host, this.title = 'Choose a project folder'});
  final Host host;
  final String title;

  @override
  State<FolderBrowser> createState() => _FolderBrowserState();
}

class _FolderBrowserState extends State<FolderBrowser> {
  final _field = TextEditingController();
  String? _path, _home, _selected, _fieldError, _transport;
  FolderListing? _listing;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open('~'));
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  /// Lists [path] (one call). From the path field a refused path says why under the field and stays put; from the list it
  /// shows the folder as one that can't be opened.
  Future<void> _open(String path, {bool typed = false}) async {
    setState(() {
      _loading = true;
      _transport = null;
      if (typed) _fieldError = null;
    });
    FolderListing listing;
    try {
      final ssh = await SshExec.connect(widget.host);
      try {
        listing = await ssh.listFolders(path);
      } finally {
        ssh.close();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _transport = 'Can\'t reach ${widget.host.name}.';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (typed && (listing.state == ListingState.missing || listing.state == ListingState.file)) {
        _fieldError = listing.state == ListingState.file ? 'That is a file, not a folder.' : 'No such folder on ${widget.host.name}.';
        return;
      }
      _selected = null;
      _listing = listing;
      _path = listing.path ?? path;
      if (path == '~' && listing.path != null) _home ??= listing.path;
      if (typed) _field.clear();
    });
  }

  String _tilde(String p) {
    final h = _home;
    if (h == null) return p;
    return p == h ? '~' : (p.startsWith('$h/') ? '~${p.substring(h.length)}' : p);
  }

  String _child(String name) => _path == '/' ? '/$name' : '$_path/$name';

  String get _parent => _path == null || !_path!.contains('/') || _path!.lastIndexOf('/') == 0 ? '/' : _path!.substring(0, _path!.lastIndexOf('/'));

  /// The breadcrumb: the host, then `~` (or `/`) and each folder down to the open one, each a jump.
  List<(String, String)> get _crumbs {
    final p = _path;
    if (p == null) return const [];
    final h = _home;
    final under = h != null && (p == h || p.startsWith('$h/'));
    final rel = (under ? p.substring(h.length) : p).split('/').where((s) => s.isNotEmpty);
    var at = under ? h : '';
    return [
      (under ? '~' : '/', under ? h : '/'),
      for (final s in rel) (s, at = '$at/$s'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final rowH = isDesktop ? 40.0 : 48.0;
    final chosen = _selected != null ? _child(_selected!) : _path;
    final listing = _listing;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
        child: Row(children: [
          Expanded(child: Text(widget.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
          Text(widget.host.name.toUpperCase(),
              style: TextStyle(fontFamily: fontMono, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1, color: hostTextColor(widget.host, k))),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
        child: TextField(
          controller: _field,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontFamily: fontMono, fontSize: 13),
          decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: 'Paste a path, e.g. ~/code/app',
              errorText: _fieldError),
          onChanged: (_) => _fieldError == null ? null : setState(() => _fieldError = null),
          onSubmitted: (v) {
            final t = cleanTypedPath(v);
            if (t.isNotEmpty) _open(t, typed: true);
          },
        ),
      ),
      Divider(height: 1, color: k.divider),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            OutlinedButton.icon(
                onPressed: _path == null || _path == '/' || _loading ? null : () => _open(_parent),
                icon: const Icon(Icons.arrow_upward, size: 16),
                label: const Text('Up')),
            const Spacer(),
            Text('folders only', style: TextStyle(fontSize: 13, color: k.muted)),
          ]),
          const SizedBox(height: 8),
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(widget.host.name, style: TextStyle(fontFamily: fontMono, fontSize: 13, color: k.muted)),
            for (final (i, (label, abs)) in _crumbs.indexed) ...[
              Icon(Icons.chevron_right, size: 16, color: k.muted),
              InkWell(
                onTap: i == _crumbs.length - 1 ? null : () => _open(abs),
                child: Text(label,
                    style: TextStyle(
                        fontFamily: fontMono, fontSize: 13, color: i == _crumbs.length - 1 ? k.ink : k.muted, fontWeight: i == _crumbs.length - 1 ? FontWeight.w700 : null)),
              ),
            ],
          ]),
        ]),
      ),
      Divider(height: 1, color: k.divider),
      Expanded(
        child: _transport != null
            ? _note(k, _transport!, action: TextButton(onPressed: () => _open(_path ?? '~'), child: const Text('Retry')))
            : listing == null
                ? const Center(child: CircularProgressIndicator())
                : switch (listing.state) {
                    ListingState.ok when listing.folders.isEmpty => _note(k, 'No folders here'),
                    ListingState.ok => Stack(children: [
                        ListView(children: [
                          for (final (name, git) in listing.folders) _row(k, name, git, rowH),
                        ]),
                        if (_loading) const Align(alignment: Alignment.topCenter, child: LinearProgressIndicator(minHeight: 2)),
                      ]),
                    _ => _note(k, 'Can\'t open this folder',
                        reason: listing.state == ListingState.unreadable ? 'This account has no permission to read it.' : 'It is not a folder, or no longer exists.'),
                  },
      ),
      Divider(height: 1, color: k.divider),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        child: Row(children: [
          Expanded(
              child: Text(chosen == null ? '' : _tilde(chosen),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: fontMono, fontSize: 13, color: k.muted))),
          const SizedBox(width: 12),
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          const SizedBox(width: 12),
          FilledButton(
              onPressed: chosen == null || (_listing?.state != ListingState.ok && _selected == null) ? null : () => Navigator.pop(context, chosen),
              child: const Text('Choose this folder')),
        ]),
      ),
    ]);
  }

  Widget _note(Tokens k, String text, {String? reason, Widget? action}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(text, style: TextStyle(fontSize: 14, color: k.ink)),
            if (reason != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(reason, style: TextStyle(fontSize: 12, color: k.muted))),
            if (action != null) action,
          ]),
        ),
      );

  Widget _row(Tokens k, String name, bool git, double height) {
    final selected = _selected == name;
    void open() => _open(_child(name));
    return Material(
      color: selected ? k.headerFill : Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _selected = name),
        // A double-click opens it (on the Mac; a double-tap listener would delay every single tap).
        onDoubleTap: isDesktop ? open : null,
        onLongPress: open,
        child: Container(
          height: height,
          padding: const EdgeInsets.only(left: 24, right: 8),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: k.divider))),
          child: Row(children: [
            AppIcon(AppIconKind.folder, size: 18, color: git ? k.accent : k.muted),
            const SizedBox(width: 12),
            // The git mark and the chevron sit together at the row's right edge, not after the name.
            Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: k.ink))),
            if (git)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(border: Border.all(color: k.border), borderRadius: BorderRadius.circular(3)),
                child: Text('git', style: TextStyle(fontFamily: fontMono, fontSize: 11, color: k.muted)),
              ),
            IconButton(tooltip: 'Open $name', onPressed: open, icon: Icon(Icons.chevron_right, size: 20, color: k.muted)),
          ]),
        ),
      ),
    );
  }
}
