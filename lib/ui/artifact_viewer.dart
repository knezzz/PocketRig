import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../data/media_cache.dart';
import '../data/projects.dart' show shQuote;
import '../main.dart';
import '../models.dart' show displayPath;
import '../ssh/ssh_exec.dart';
import 'chat/code_view.dart';
import 'chat/diff_view.dart';
import 'common.dart';
import 'kit.dart';
import 'theme.dart';

/// A file on the host, read-only: Markdown rendered, code highlighted, HTML
/// in a WebView. Read fresh over SSH (at most 256 KB). Rendered · Source ·
/// Changes, where Changes is the file's uncommitted diff when git has one.
class ArtifactViewer extends StatefulWidget {
  const ArtifactViewer({super.key, required this.path, this.fromDiff = false});
  final String path;

  /// Opened from the file's diff: Changes goes back to it.
  final bool fromDiff;
  @override
  State<ArtifactViewer> createState() => _ArtifactViewerState();
}

enum ArtifactKind { markdown, html, code }

/// [html] told to default to a dark page: a dark canvas and light text where it sets no colours of its own (a page's own
/// background and text colours still win). Goes in as the first thing in the head, after the doctype when there is no head.
String withDarkScheme(String html) {
  const meta = '<meta name="color-scheme" content="dark">';
  final head = RegExp(r'<head[^>]*>', caseSensitive: false).firstMatch(html);
  if (head != null) return html.replaceRange(head.end, head.end, meta);
  final root = RegExp(r'<html[^>]*>', caseSensitive: false).firstMatch(html);
  if (root != null) return html.replaceRange(root.end, root.end, '<head>$meta</head>');
  final doctype = RegExp(r'^\s*<!doctype[^>]*>', caseSensitive: false).firstMatch(html);
  final at = doctype?.end ?? 0;
  return html.replaceRange(at, at, meta);
}

ArtifactKind artifactKind(String path) => switch (path.split('.').last.toLowerCase()) {
      'md' || 'markdown' || 'mdx' => ArtifactKind.markdown,
      'html' || 'htm' => ArtifactKind.html,
      _ => ArtifactKind.code,
    };

enum _View { rendered, source, changes }

class _ArtifactViewerState extends State<ArtifactViewer> {
  String? _text;
  String? _error;
  bool _raw = false;
  WebViewController? _web;
  DateTime? _readAt;

  /// The checkout and the file in it, when git has uncommitted changes to it.
  ({String root, String rel, bool untracked})? _change;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
      _checkChanges();
    });
  }

  /// Asks git whether the file has uncommitted changes, for the Changes tab.
  Future<void> _checkChanges() async {
    final host = AppScope.read(context).active;
    final slash = widget.path.lastIndexOf('/');
    if (host == null || slash <= 0) return;
    final dir = widget.path.substring(0, slash), name = widget.path.substring(slash + 1);
    SshExec? ssh;
    try {
      ssh = await SshExec.connect(host);
      final out = (await ssh.runLogin('cd ${shQuote(dir)} && git rev-parse --show-toplevel && '
              'git status --porcelain -- ${shQuote(name)}'))
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      if (out.length < 2 || !mounted) return;
      final root = out.first.trim();
      if (!widget.path.startsWith('$root/')) return;
      setState(() => _change =
          (root: root, rel: widget.path.substring(root.length + 1), untracked: out[1].startsWith('??')));
    } catch (_) {/* no Changes tab */} finally {
      ssh?.close();
    }
  }

  void _showChanges() {
    if (widget.fromDiff) return Navigator.of(context).pop();
    final c = _change;
    if (c == null) return;
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => DiffScreen(root: c.root, path: c.rel, untracked: c.untracked)));
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: widget.path));
    if (mounted) toast(context, 'Path copied');
  }

  /// Reload ([force]) always reads the host; opening uses the saved copy while no newer chat line mentions the file.
  Future<void> _load({bool force = false}) async {
    final host = AppScope.read(context).active;
    if (host == null) {
      setState(() => _error = 'No host selected.');
      return;
    }
    setState(() => _error = null);
    try {
      Future<Uint8List> read() async {
        final ssh = await SshExec.connect(host);
        try {
          return Uint8List.fromList(utf8.encode(await ssh.readFile(widget.path)));
        } finally {
          ssh.close();
        }
      }

      final cache = mediaCache;
      final bytes = cache == null ? await read() : await cache.get(host, widget.path, fetch: read, force: force);
      final text = utf8.decode(bytes, allowMalformed: true);
      if (!mounted) return;
      setState(() {
        _text = text;
        _readAt = DateTime.now();
        if (artifactKind(widget.path) == ArtifactKind.html) {
          final dark = Tokens.of(context).isDark;
          _web = WebViewController()
            // The sheet behind a page that sets no background of its own is the app's, not white.
            ..setBackgroundColor(Tokens.of(context).ground)
            // Agent-written pages may need JS, but they must not navigate.
            ..setJavaScriptMode(JavaScriptMode.unrestricted)
            ..setNavigationDelegate(NavigationDelegate(
              onNavigationRequest: (r) => r.isMainFrame && !r.url.startsWith('about:')
                  ? NavigationDecision.prevent
                  : NavigationDecision.navigate,
            ))
            ..loadHtmlString(dark ? withDarkScheme(text) : text);
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Couldn\'t read the file over SSH: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.path.split('/').last;
    final kind = artifactKind(widget.path);
    final text = _text;
    Widget body;
    if (_error != null) {
      body = ListView(children: [ErrorBanner(_error!)]);
    } else if (text == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_raw || kind == ArtifactKind.code) {
      body = SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: CodeView(text, language: widget.path, selectable: true),
      );
    } else if (kind == ArtifactKind.markdown) {
      body = Markdown(data: text, selectable: true, padding: const EdgeInsets.all(16));
    } else {
      body = WebViewWidget(controller: _web!);
    }
    final views = [
      if (kind != ArtifactKind.code) _View.rendered,
      _View.source,
      if (_change != null || widget.fromDiff) _View.changes,
    ];
    final showing = _raw || kind == ArtifactKind.code ? _View.source : _View.rendered;
    return Scaffold(
      body: Column(children: [
        PageHeader(
          compact: true,
          title: name,
          subtitle: ListenableBuilder(
            listenable: minuteTick,
            builder: (context, _) => Text(
                [displayPath(widget.path), 'read-only', if (_readAt != null) '${ago(_readAt)} old'].join(' · '),
                style: mono(context),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          actions: [
            IconButton(tooltip: 'Copy path', onPressed: _copyPath, icon: const Icon(Icons.copy_outlined, size: 20)),
            IconButton(
                tooltip: 'Reload from host',
                onPressed: () => _load(force: true),
                icon: const Icon(Icons.refresh, size: 20)),
          ],
          bottom: views.length < 2
              ? null
              : Segmented<_View>(
                  values: views,
                  labels: [
                    for (final v in views)
                      switch (v) { _View.rendered => 'Rendered', _View.source => 'Source', _View.changes => 'Changes' }
                  ],
                  selected: showing,
                  semanticLabel: 'View',
                  onChanged: (v) => switch (v) {
                    _View.changes => _showChanges(),
                    _View.source => setState(() => _raw = true),
                    _View.rendered => setState(() => _raw = false),
                  },
                ),
        ),
        Expanded(child: body),
      ]),
    );
  }
}
