import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:path_provider/path_provider.dart';

import '../data/chat_cache.dart';
import '../main.dart';
import '../models.dart';
import 'agent_panels_live.dart';
import 'artifact_viewer.dart';
import 'chat/media_view.dart';
import 'chat/message_views.dart' show ArtifactTile;
import '../data/fleet.dart' show HostFeed;
import '../data/host_store.dart' show isDesktop;
import 'kit.dart' show OptionRow, SectionLabel, panelRouteName;
import 'progress_bar.dart' show ContextBar;
import 'tab_strip.dart';
import 'theme.dart';

/// The dock's tabs: Info (context, and what runs here), then what the agent's tool calls changed and made.
enum DockTab { info, files, images, artifacts }

/// Whether the dock is open and how wide. One layout for every agent, kept in a small file like the other app settings.
@immutable
class PanelLayout {
  const PanelLayout({this.open = true, this.width = 320});
  final bool open;

  /// The dock's width, dragged at its left edge.
  final double width;
  static const minWidth = 220.0, maxWidth = 900.0;

  PanelLayout copyWith({bool? open, double? width}) =>
      PanelLayout(open: open ?? this.open, width: (width ?? this.width).clamp(minWidth, maxWidth));

  Map<String, Object> toJson() => {'open': open, 'width': width};

  static PanelLayout fromJson(Map<String, dynamic> j) => PanelLayout(
      open: j['open'] as bool? ?? true,
      width: ((j['width'] as num?)?.toDouble() ?? 320).clamp(PanelLayout.minWidth, PanelLayout.maxWidth));
}

final agentPanels = ValueNotifier<PanelLayout>(const PanelLayout());

/// Where the layout is saved. Tests point it nowhere: real file IO never finishes under a widget test's fake clock.
Future<File?> Function() agentPanelsFile = _file;

Future<File?> _file() async {
  try {
    return File('${(await getApplicationSupportDirectory()).path}/agent-panels.json');
  } catch (_) {
    return null; // tests and platforms without a support folder: keep the default
  }
}

Future<void> loadAgentPanels() async {
  try {
    final f = await agentPanelsFile();
    if (f == null || !await f.exists()) return;
    agentPanels.value = PanelLayout.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
  } catch (_) {}
}

Future<void> _saving = Future.value();

/// Shows [layout] now and saves it after any earlier save, so quick clicks can't leave an older layout on disk.
Future<void> setAgentPanels(PanelLayout layout) {
  agentPanels.value = layout;
  return _saving = _saving.then((_) async {
    try {
      await (await agentPanelsFile())?.writeAsString(jsonEncode(layout.toJson()));
    } catch (_) {}
  });
}

/// [seat]'s cached media and file edits, newest first. Null without a chat cache or a host.
Stream<List<RigMedia>>? seatMedia(BuildContext context, Seat seat) {
  final host = AppScope.read(context).active;
  return host == null ? null : chatCache?.watchChatMedia(host.id, chatKey(seat));
}

/// An image or a video: what the Images panel lists.
bool isPanelMedia(RigMedia m) => m.kind == 'image' || m.kind == 'video';

bool _isArtifact(RigMedia m) => m.kind == 'file' && const {'Document', 'Page'}.contains(ArtifactTile.kindOf(m.ref));

/// The documents and pages the agent wrote (the same files chat shows as an artifact tile), newest first.
List<RigMedia> artifactsOf(List<RigMedia> all) => [for (final m in all) if (_isArtifact(m)) m];

/// The agent's code edits. A Markdown or HTML file is in Artifacts only, not here too.
List<RigMedia> filesOf(List<RigMedia> all) => [for (final m in all) if (m.kind == 'file' && !_isArtifact(m)) m];

/// When each agent's panels were last shown, this run: what the agent wrote after it is "new". Not kept across launches.
final _openedAt = <String, DateTime>{};

/// When [seat]'s panels were last shown (null the first time), and now they are shown: the dock and the phone's sheet both ask.
DateTime? takePanelsOpenedAt(Seat seat) {
  final key = chatKey(seat), before = _openedAt[key];
  _openedAt[key] = DateTime.now();
  return before;
}

/// The Files panel: the file edits, a row each (a tap opens it). The dock's rows are denser than the phone's.
class PanelFiles extends StatelessWidget {
  const PanelFiles({super.key, required this.files, required this.cwd, required this.onOpen, this.dense = false});
  final List<RigMedia> files;
  final String? cwd;
  final void Function(RigMedia) onOpen;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    if (files.isEmpty) return PanelEmpty('No files changed yet', dense: dense);
    return ListView(children: [
      for (final m in files)
        OptionRow(
          leading: Icon(Icons.description_outlined, size: dense ? 18 : 20),
          title: Text(m.ref.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(cwd != null && m.ref.startsWith('$cwd/') ? m.ref.substring(cwd!.length + 1) : displayPath(m.ref),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, color: k.muted)),
          onTap: () => onOpen(m),
        ),
    ]);
  }
}

/// The Images panel: thumbnails (the newest 30: each is an SSH download; the viewer swipes through all of them). With
/// [heroWidth] the newest is shown that wide, the rest as thumbnails.
class PanelImages extends StatelessWidget {
  const PanelImages({super.key, required this.images, required this.onOpen, this.heroWidth, this.dense = false});
  final List<RigMedia> images;
  final void Function(RigMedia) onOpen;
  final double? heroWidth;
  final bool dense;

  // shortcut: the newest 30 only.
  static const maxThumbs = 30;

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) return PanelEmpty('No images yet', dense: dense);
    return SingleChildScrollView(
      padding: EdgeInsets.all(dense ? 8 : 12),
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (i, m) in images.take(maxThumbs).indexed)
          MediaTile(m.ref, key: ValueKey(m.ref), size: i == 0 && heroWidth != null ? heroWidth! : 96, onOpen: () => onOpen(m)),
      ]),
    );
  }
}

/// The Artifacts panel: "N new" when the agent wrote some after [newSince], then the cards.
class PanelArtifacts extends StatelessWidget {
  const PanelArtifacts({super.key, required this.docs, required this.cwd, this.newSince, this.dense = false});
  final List<RigMedia> docs;
  final String? cwd;
  final DateTime? newSince;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    if (docs.isEmpty) return PanelEmpty('No documents or pages yet', dense: dense);
    final k = Tokens.of(context);
    final fresh = _newCount(docs, newSince);
    return ListView(children: [
      if (fresh > 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Text('$fresh new', style: mono(context, size: 11, color: k.accent)),
        ),
      ArtifactCards(items: docs, cwd: cwd, newSince: newSince),
    ]);
  }
}

/// A panel with nothing in it yet.
class PanelEmpty extends StatelessWidget {
  const PanelEmpty(this.text, {super.key, this.dense = false});
  final String text;
  final bool dense;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(12), child: Text(text, style: TextStyle(fontSize: dense ? 12 : 13, color: Tokens.of(context).muted)));
}

/// The agent's main area (its terminal) with the dock beside it. A dock item (artifact, file, image) opens as a preview in the
/// place of [child], not as a screen over the whole window: the dock stays open, and closing the preview brings back the same
/// [child], still mounted (so a terminal keeps its connection and scroll). The preview is a small navigator of its own, so a
/// diff opened from a file stays in the main area too; Back from the first page closes it. [seat] null: no dock.
class PanelPreviewHost extends StatefulWidget {
  const PanelPreviewHost({super.key, required this.child, required this.seat, this.focus});
  final Widget child;
  final Seat? seat;

  /// The child's focus (the terminal's): taken back when the preview closes, so typing goes on without a click.
  final FocusNode? focus;

  /// Opens [page] in the main area of the nearest host, or on the navigator when there is none (a phone's sheet).
  static void open(BuildContext context, WidgetBuilder page) {
    final host = context.getInheritedWidgetOfExactType<_PreviewScope>();
    if (host != null) {
      host.open(page);
    } else {
      Navigator.of(context).push(MaterialPageRoute<void>(builder: page));
    }
  }

  @override
  State<PanelPreviewHost> createState() => _PanelPreviewHostState();
}

class _PanelPreviewHostState extends State<PanelPreviewHost> {
  WidgetBuilder? _page;
  GlobalKey<NavigatorState>? _nav;

  @override
  void didUpdateWidget(PanelPreviewHost old) {
    super.didUpdateWidget(old);
    // The dock went (a tile shrank): so does what it opened.
    if (widget.seat == null) _page = null;
  }

  void _open(WidgetBuilder page) => setState(() {
        _page = page;
        _nav = GlobalKey<NavigatorState>();
      });

  /// Closes the preview and gives the keyboard back to the child (once it is back in the focus tree).
  void _close() {
    if (!mounted) return;
    setState(() => _page = null);
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.focus?.requestFocus());
  }

  /// Back and Escape: the page on top of the preview goes first; the last one closes it.
  void _back() {
    final n = _nav?.currentState;
    if (n != null && n.canPop()) {
      n.maybePop();
    } else {
      _close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    // The screen's header has a Back of its own (it closes the preview, below): then the preview shows none, one arrow in all.
    // Without one the preview keeps its own, or it could not be closed.
    final headerBack = Navigator.of(context).canPop() && !(isDesktop && ModalRoute.of(context)?.settings.name == panelRouteName);
    // Back (the header's, the shell's) closes the preview first: only a bare host lets the screen go.
    return PopScope(
      canPop: page == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: _PreviewScope(
      open: _open,
      child: CallbackShortcuts(
      bindings: {if (page != null) const SingleActivator(LogicalKeyboardKey.escape): _back},
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: Stack(children: [
            // Laid out at the same size while hidden: the terminal does not resize, and takes no keys.
            Positioned.fill(
              child: Offstage(
                  offstage: page != null,
                  child: ExcludeFocus(excluding: page != null, child: TickerMode(enabled: page == null, child: widget.child))),
            ),
            if (page != null)
              Positioned.fill(
                // The preview holds the keyboard, so Escape reaches it.
                child: Focus(
                  autofocus: true,
                  child: Navigator(
                    key: _nav,
                    observers: [if (!headerBack) _BaseObserver(_close)],
                    onGenerateInitialRoutes: (_, __) => [
                      if (!headerBack) PageRouteBuilder<void>(pageBuilder: (_, __, ___) => const SizedBox.shrink()),
                      MaterialPageRoute<void>(builder: page),
                    ],
                  ),
                ),
              ),
          ]),
        ),
        if (widget.seat != null) AgentPanelDock(seat: widget.seat!),
      ]),
    )));
  }
}

class _PreviewScope extends InheritedWidget {
  const _PreviewScope({required this.open, required super.child});
  final void Function(WidgetBuilder page) open;
  @override
  bool updateShouldNotify(_PreviewScope old) => false;
}

/// Tells when the preview's navigator is back at its empty first page.
class _BaseObserver extends NavigatorObserver {
  _BaseObserver(this.onBase);
  final VoidCallback onBase;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute?.isFirst ?? false) WidgetsBinding.instance.addPostFrameCallback((_) => onBase());
  }
}

/// The dock at the right of an agent's desktop terminal: tabs for Info (context, and what runs here), Files, Images and
/// Artifacts. Fed by the background chat sync, so it trails the agent by a sync cycle.
class AgentPanelDock extends StatefulWidget {
  const AgentPanelDock({super.key, required this.seat});
  final Seat seat;

  @override
  State<AgentPanelDock> createState() => _AgentPanelDockState();
}

class _AgentPanelDockState extends State<AgentPanelDock> {
  Stream<List<RigMedia>>? _media;
  String? _key;
  DateTime? _newSince;
  DockTab _tab = DockTab.info;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final key = chatKey(widget.seat);
    if (key != _key) {
      _key = key;
      _media = seatMedia(context, widget.seat);
      _newSince = takePanelsOpenedAt(widget.seat);
    }
  }

  @override
  void didUpdateWidget(AgentPanelDock old) {
    super.didUpdateWidget(old);
    if (chatKey(widget.seat) != _key) didChangeDependencies();
  }

  void _open(BuildContext context, RigMedia m, List<RigMedia> items) {
    if (_tab == DockTab.files) return PanelPreviewHost.open(context, (_) => ArtifactViewer(path: m.ref));
    final paths = [for (final i in items) i.ref];
    PanelPreviewHost.open(context, (_) => MediaViewer(paths: paths, initial: paths.indexOf(m.ref), seat: widget.seat));
  }

  Widget _info(BuildContext context, Tokens k, HostFeed? feed) {
    final s = widget.seat;
    final pct = s.contextUsedPercent;
    final subs = subagentsIn(feed, s), shells = shellCountIn(feed, s);
    final line = [
      if (s.model != null) modelLabel(s.model!),
      if (pct != null) '${pct.round()}% of context',
      if (s.inputTokens != null) '${s.inputTokens} tokens in',
    ].join(' · ');
    return ListView(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ContextBar(pct, height: 6),
          if (line.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(line, style: mono(context, size: 11, color: k.muted)),
          ],
        ]),
      ),
      const Padding(padding: EdgeInsets.fromLTRB(12, 12, 12, 0), child: SectionLabel('Running here')),
      Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Text('Subagents · ${subs.length}', style: TextStyle(fontSize: 13, color: k.ink))),
      SubagentsList(parent: s, subagents: subs),
      Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Text('Shells · $shells', style: TextStyle(fontSize: 13, color: k.ink))),
      ShellsList(seat: s),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final feed = panelFeed(context);
    // The feed's own scan feeds the Subagents and Shells lists: no loop here.
    return ListenableBuilder(
      listenable: feed ?? agentPanels,
      builder: (context, _) => ValueListenableBuilder<PanelLayout>(
        valueListenable: agentPanels,
        builder: (context, layout, _) {
          if (!layout.open) return const SizedBox.shrink();
          // A Material, not a colored box: the file rows paint their ink on it.
          final dock = Material(
            color: k.ground,
            shape: Border(left: BorderSide(color: k.border)),
            child: SizedBox(
              width: layout.width,
              child: StreamBuilder<List<RigMedia>>(
                stream: _media,
                builder: (context, snap) {
                  final all = snap.data ?? const <RigMedia>[];
                  final files = filesOf(all), images = all.where(isPanelMedia).toList(), docs = artifactsOf(all);
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    TabStrip<DockTab>(
                      values: DockTab.values,
                      labels: ['Info', 'Files ${files.length}', 'Images ${images.length}', 'Artifacts ${docs.length}'],
                      selected: _tab,
                      onChanged: (t) => setState(() => _tab = t),
                      semanticLabel: 'Agent panels',
                    ),
                    Expanded(
                      child: switch (_tab) {
                        DockTab.info => _info(context, k, feed),
                        DockTab.files => PanelFiles(files: files, cwd: widget.seat.cwd, dense: true, onOpen: (m) => _open(context, m, files)),
                        DockTab.images => PanelImages(
                            images: images, dense: true, heroWidth: layout.width - 16, onOpen: (m) => _open(context, m, images)),
                        DockTab.artifacts => PanelArtifacts(docs: docs, cwd: widget.seat.cwd, newSince: _newSince, dense: true),
                      },
                    ),
                  ]);
                },
              ),
            ),
          );
          // The left edge drags the dock wider or narrower; the width is saved when the drag ends.
          return Stack(clipBehavior: Clip.none, children: [
            dock,
            Positioned(
              left: -3,
              top: 0,
              bottom: 0,
              width: 8,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: (d) =>
                      agentPanels.value = agentPanels.value.copyWith(width: agentPanels.value.width - d.delta.dx),
                  onHorizontalDragEnd: (_) => setAgentPanels(agentPanels.value),
                ),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

int _newCount(List<RigMedia> items, DateTime? since) =>
    since == null ? 0 : items.where((m) => m.touchedAt.isAfter(since)).length;

/// The artifacts as small cards in a grid: a sketch of the page, the name, its kind and "new" when the agent wrote it
/// after [newSince]. A tap opens it read-only. The dock and the phone's panels sheet both show this.
class ArtifactCards extends StatelessWidget {
  const ArtifactCards({super.key, required this.items, this.cwd, this.newSince, this.columns = 2});
  final List<RigMedia> items;
  final String? cwd;
  final DateTime? newSince;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    Widget card(RigMedia m) {
      final name = m.ref.split('/').last;
      final kind = ArtifactTile.kindOf(m.ref);
      final fresh = newSince != null && m.touchedAt.isAfter(newSince!);
      final page = kind == 'Page';
      final line = k.border;
      Widget bar(double w, double h, Color c) =>
          FractionallySizedBox(widthFactor: w, child: Container(height: h, color: c));
      return Semantics(
        button: true,
        label: 'Open $name, $kind${fresh ? ', new' : ''}',
        onTap: () => _open(context, m),
        excludeSemantics: true,
        child: Material(
          color: k.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6), side: BorderSide(color: fresh ? k.accent : k.border)),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => _open(context, m),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  height: 60,
                  width: double.infinity,
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(color: k.ground, borderRadius: BorderRadius.circular(3)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (page) bar(1, 10, k.shell) else bar(.6, 6, k.muted),
                    const SizedBox(height: 4),
                    bar(page ? .7 : .9, 3, line),
                    const SizedBox(height: 4),
                    bar(.8, 3, line),
                  ]),
                ),
                const SizedBox(height: 6),
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                Text(fresh ? '$kind · new' : kind,
                    maxLines: 1, style: TextStyle(fontSize: 11, color: fresh ? k.accent : k.muted)),
              ]),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: LayoutBuilder(builder: (context, box) {
        const gap = 8.0;
        final w = (box.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(spacing: gap, runSpacing: gap, children: [for (final m in items) SizedBox(width: w, child: card(m))]);
      }),
    );
  }

  void _open(BuildContext context, RigMedia m) => PanelPreviewHost.open(context, (_) => ArtifactViewer(path: m.ref));
}

/// The header button that shows or hides the dock.
class AgentPanelsToggle extends StatelessWidget {
  const AgentPanelsToggle({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<PanelLayout>(
        valueListenable: agentPanels,
        builder: (_, layout, __) => IconButton(
          tooltip: layout.open ? 'Hide panels' : 'Show panels',
          isSelected: layout.open,
          onPressed: () => setAgentPanels(layout.copyWith(open: !layout.open)),
          icon: const Icon(Icons.view_sidebar_outlined, size: 20),
        ),
      );
}

/// A tile's one-line summary: how many images the agent's tools touched and files it changed. Empty when none.
class AgentMediaCounts extends StatefulWidget {
  const AgentMediaCounts({super.key, required this.seat});
  final Seat seat;

  @override
  State<AgentMediaCounts> createState() => _AgentMediaCountsState();
}

class _AgentMediaCountsState extends State<AgentMediaCounts> {
  Stream<List<RigMedia>>? _media;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _media ??= seatMedia(context, widget.seat);
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return StreamBuilder<List<RigMedia>>(
      stream: _media,
      builder: (context, snap) {
        final all = snap.data ?? const <RigMedia>[];
        final images = all.where(isPanelMedia).length, files = filesOf(all).length, docs = artifactsOf(all).length;
        Widget count(IconData icon, int n, String spoken) => Semantics(
              label: '$n $spoken',
              excludeSemantics: true,
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 12, color: k.muted),
                  const SizedBox(width: 3),
                  Text('$n', style: mono(context, size: 11, color: k.muted)),
                ]),
              ),
            );
        return Row(mainAxisSize: MainAxisSize.min, children: [
          if (docs > 0) count(Icons.article_outlined, docs, docs == 1 ? 'artifact' : 'artifacts'),
          if (images > 0) count(Icons.photo_library_outlined, images, images == 1 ? 'image' : 'images'),
          if (files > 0) count(Icons.edit_note, files, files == 1 ? 'file changed' : 'files changed'),
        ]);
      },
    );
  }
}
