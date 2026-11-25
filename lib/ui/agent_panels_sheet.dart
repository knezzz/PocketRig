import 'package:flutter/material.dart';

import '../data/chat_cache.dart';
import '../data/fleet.dart' show HostFeed;
import '../models.dart';
import 'agent_panels.dart' show PanelArtifacts, PanelFiles, PanelImages, artifactsOf, filesOf, isPanelMedia, seatMedia, takePanelsOpenedAt;
import 'agent_panels_live.dart';
import 'subagent_open.dart';
import 'artifact_viewer.dart';
import 'chat/media_view.dart';
import 'tab_strip.dart';
import 'theme.dart';

/// The phone terminal's panels strip, above its keys: "Files n · Images n". A tap or a drag up opens the sheet with
/// the agent's file edits and images. Nothing when the agent has neither.
class PanelsStrip extends StatefulWidget {
  const PanelsStrip({super.key, required this.seat});
  final Seat seat;

  @override
  State<PanelsStrip> createState() => _PanelsStripState();
}

class _PanelsStripState extends State<PanelsStrip> {
  Stream<List<RigMedia>>? _media;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _media ??= seatMedia(context, widget.seat);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<RigMedia>>(
      stream: _media,
      builder: (context, snap) {
        final all = snap.data ?? const <RigMedia>[];
        final feed = panelFeed(context);
        return ListenableBuilder(listenable: feed ?? ValueNotifier(0), builder: (context, _) => _strip(context, all, feed));
      },
    );
  }

  Widget _strip(BuildContext context, List<RigMedia> all, HostFeed? feed) {
    final k = Tokens.of(context);
        final files = filesOf(all).length, images = all.where(isPanelMedia).length, docs = artifactsOf(all).length;
        final subs = subagentsIn(feed, widget.seat).length, shells = shellCountIn(feed, widget.seat);
        if (files + images + docs + subs + shells == 0) return const SizedBox.shrink();
        void open() => showPanelsSheet(context, widget.seat, all);
        return Semantics(
          button: true,
          label: 'Panels: $files files, $images images, $docs artifacts, $subs subagents, $shells shells',
          onTap: open,
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: open,
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) < -200) open();
            },
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(color: k.fill, border: Border(top: BorderSide(color: k.border))),
              child: Row(children: [
                Icon(Icons.expand_less, size: 18, color: k.muted),
                const SizedBox(width: 6),
                // Five counts are wider than a phone: the row scrolls sideways (a vertical drag still opens the sheet).
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Text('Files $files · Images $images · Artifacts $docs · Subagents $subs · Shells $shells',
                        maxLines: 1, style: mono(context, size: 12, color: k.muted)),
                  ),
                ),
              ]),
            ),
          ),
        );
  }
}

/// The panels as a bottom sheet with a tab each: Files (the file edits) and Images.
Future<void> showPanelsSheet(BuildContext context, Seat seat, List<RigMedia> all) {
  final files = filesOf(all), docs = artifactsOf(all);
  final images = [for (final m in all) if (isPanelMedia(m)) m];
  final newSince = takePanelsOpenedAt(seat); // what the agent wrote since these panels were last shown reads "new"
  final nav = Navigator.of(context);
  final feed = panelFeed(context);
  var tab = 0;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, setTab) => SizedBox(
        height: MediaQuery.sizeOf(sheet).height * 0.6,
        child: Column(children: [
          ListenableBuilder(
            listenable: feed ?? ValueNotifier(0),
            builder: (context, _) => TabStrip<int>(
              values: const [0, 1, 2, 3, 4],
              labels: ['Files ${files.length}', 'Images ${images.length}', 'Artifacts ${docs.length}', 'Subagents ${subagentsIn(feed, seat).length}', 'Shells ${shellCountIn(feed, seat)}'],
              selected: tab,
              onChanged: (i) => setTab(() => tab = i),
              semanticLabel: 'Agent panels',
            ),
          ),
          Expanded(
            child: IndexedStack(index: tab, children: [
              PanelFiles(files: files, cwd: seat.cwd, onOpen: (m) {
                Navigator.pop(sheet);
                nav.push(MaterialPageRoute<void>(builder: (_) => ArtifactViewer(path: m.ref)));
              }),
              PanelImages(images: images, onOpen: (m) {
                Navigator.pop(sheet);
                final paths = [for (final i in images) i.ref];
                nav.push(MaterialPageRoute<void>(
                    builder: (_) => MediaViewer(paths: paths, initial: paths.indexOf(m.ref), seat: seat)));
              }),
              PanelArtifacts(docs: docs, cwd: seat.cwd, newSince: newSince),
              ListenableBuilder(
                listenable: feed ?? ValueNotifier(0),
                builder: (context, _) => SingleChildScrollView(
                  child: SubagentsList(
                    parent: seat,
                    subagents: subagentsIn(feed, seat),
                    onOpen: (sub) {
                      Navigator.pop(sheet);
                      nav.push(MaterialPageRoute<void>(builder: (_) => subagentScreen(seat, sub)));
                    },
                  ),
                ),
              ),
              SingleChildScrollView(child: ShellsList(seat: seat, padding: const EdgeInsets.all(12))),
            ]),
          ),
        ]),
      ),
    ),
  );
}
