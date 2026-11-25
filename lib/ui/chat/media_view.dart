import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../chat/transcript.dart';
import '../../data/media_cache.dart';
import '../../main.dart';
import '../../models.dart';
import '../../ssh/ssh_exec.dart';
import '../common.dart';
import '../theme.dart';
import 'draw_screen.dart';

final _cache = <String, Future<Uint8List>>{};

/// [path]'s bytes from [host], fetched once per host and path. A failed
/// fetch is forgotten, so opening it again retries.
Future<Uint8List> mediaBytes(Host host, String path) {
  final key = '${host.id}|$path';
  final cached = _cache[key];
  if (cached != null) return cached;
  Future<Uint8List> read() async {
    final ssh = await SshExec.connect(host);
    try {
      // `~/x.png`: SFTP starts in the home folder.
      return await ssh.download(path.startsWith('~/') ? path.substring(2) : path);
    } finally {
      ssh.close();
    }
  }

  // The phone's saved copy first: a file already downloaded makes no SSH call.
  final fetch = _cache[key] = mediaCache?.get(host, path, fetch: read) ?? read();
  fetch.then((_) {}, onError: (Object _) {
    _cache.remove(key);
  });
  return fetch;
}

/// Images and videos the agent made, as a row of tiles.
class MediaRow extends StatelessWidget {
  const MediaRow(this.paths, {super.key, required this.onOpen});
  final List<String> paths;
  final void Function(String path) onOpen;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        // Clip.none lets the tiles slide out to the screen edge, past the chat's padding.
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(children: [
            for (final p in paths) ...[
              if (p != paths.first) const SizedBox(width: 8),
              MediaTile(p, onOpen: () => onOpen(p)),
            ],
          ]),
        ),
      );
}

/// A square preview: the image itself, or a play badge for a video.
class MediaTile extends StatelessWidget {
  const MediaTile(this.path, {super.key, required this.onOpen, this.size = 112});
  final String path;
  final VoidCallback onOpen;
  final double size;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final host = AppScope.read(context).active;
    final name = path.split('/').last;
    final video = isVideoPath(path);
    Widget placeholder(IconData icon) => ColoredBox(
          color: k.fill,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 28, color: k.muted),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(name,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: k.muted)),
            ),
          ]),
        );
    final Widget preview = video || host == null
        ? placeholder(video ? Icons.play_circle_outline : Icons.image_outlined)
        : FutureBuilder<Uint8List>(
            future: mediaBytes(host, path),
            builder: (context, snap) => switch (snap) {
              AsyncSnapshot(hasError: true) => placeholder(Icons.broken_image_outlined),
              AsyncSnapshot(:final data?) => Image.memory(data,
                  fit: BoxFit.cover,
                  // Decode small: a phone screenshot is 1–4 MB at full size.
                  cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
                  errorBuilder: (_, __, ___) => placeholder(Icons.broken_image_outlined)),
              _ => placeholder(Icons.image_outlined),
            },
          );
    return Semantics(
      button: true,
      label: 'Open ${video ? 'video' : 'image'} $name',
      onTap: onOpen,
      excludeSemantics: true,
      child: Material(
        shape: RoundedRectangleBorder(side: BorderSide(color: k.border), borderRadius: BorderRadius.circular(kRadius)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onOpen, child: SizedBox.square(dimension: size, child: preview)),
      ),
    );
  }
}

/// Images and videos from the host, full screen, swiping left and right
/// between them: images pinch to zoom, videos play with a scrubber.
class MediaViewer extends StatefulWidget {
  const MediaViewer({super.key, required this.paths, this.initial = 0, this.seat});
  final List<String> paths;
  final int initial;

  /// The agent a drawing on an image goes back to; without one there's no Draw.
  final Seat? seat;

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> {
  late final _pages = PageController(initialPage: widget.initial);
  late int _at = widget.initial;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// Hands the file to the system share sheet (save to Photos or Files, send
  /// it on). Where sharing isn't available, copies the path instead.
  Future<void> _share() async {
    final path = widget.paths[_at];
    final host = AppScope.read(context).active;
    if (host == null) return;
    final name = path.split('/').last;
    try {
      final bytes = await mediaBytes(host, path);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/share-${path.hashCode.toUnsigned(32)}-$name');
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)],
        fileNameOverrides: [name],
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: path));
      if (mounted) toast(context, 'Couldn\'t share $name here. Path copied');
    }
  }

  /// Draws on the image on screen, then sends the drawing to [MediaViewer.seat].
  Future<void> _draw() async {
    final host = AppScope.read(context).active, seat = widget.seat, path = widget.paths[_at];
    if (host == null || seat == null) return;
    try {
      final bytes = await mediaBytes(host, path);
      if (!mounted) return;
      await Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => DrawScreen(image: bytes, name: path.split('/').last, seat: seat)));
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t open the image: $e');
    }
  }

  void _show(int i) => _pages.jumpToPage(i);

  @override
  Widget build(BuildContext context) {
    final path = widget.paths[_at];
    final count = widget.paths.length;
    final k = Tokens.of(context);
    return Scaffold(
      appBar: AppBar(
        actions: [
          if (widget.seat != null && !isVideoPath(path))
            IconButton(
                tooltip: 'Draw and send to ${widget.seat!.logicalId}',
                onPressed: _draw,
                icon: const Icon(Icons.draw_outlined, size: 22)),
          IconButton(tooltip: 'Share or save', onPressed: _share, icon: const Icon(Icons.ios_share, size: 22)),
        ],
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(count > 1 ? '${path.split('/').last} · ${_at + 1} of $count' : path.split('/').last,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(path,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: fontMono),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ]),
      ),
      // Pages off screen are disposed, so a video stops when swiped away.
      body: Column(children: [
        Expanded(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _at > 0 ? _show(_at - 1) : null,
              const SingleActivator(LogicalKeyboardKey.arrowRight): () => _at < count - 1 ? _show(_at + 1) : null,
            },
            child: Focus(
              autofocus: true,
              child: PageView.builder(
                controller: _pages,
                itemCount: count,
                onPageChanged: (i) => setState(() => _at = i),
                itemBuilder: (_, i) => _MediaPage(key: ValueKey(widget.paths[i]), path: widget.paths[i]),
              ),
            ),
          ),
        ),
        // Every image as a thumbnail: one tap shows it.
        if (count > 1)
          SafeArea(
            top: false,
            child: SizedBox(
              height: 76,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.all(6),
                itemCount: count,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (_, i) => Container(
                  decoration: BoxDecoration(
                      border: Border.all(color: i == _at ? k.accent : Colors.transparent, width: 2)),
                  child: MediaTile(widget.paths[i], key: ValueKey(widget.paths[i]), size: 60, onOpen: () => _show(i)),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// One image or video of the [MediaViewer].
class _MediaPage extends StatefulWidget {
  const _MediaPage({super.key, required this.path});
  final String path;

  @override
  State<_MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<_MediaPage> {
  Uint8List? _bytes;
  VideoPlayerController? _video;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final host = AppScope.read(context).active;
    if (host == null) return;
    setState(() => _error = null);
    try {
      final bytes = await mediaBytes(host, widget.path);
      if (!isVideoPath(widget.path)) {
        if (mounted) setState(() => _bytes = bytes);
        return;
      }
      // The player wants a file: keep one copy per path in the temp folder.
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/media-${widget.path.hashCode.toUnsigned(32)}-${widget.path.split('/').last}');
      await file.writeAsBytes(bytes, flush: true);
      final video = VideoPlayerController.file(file);
      try {
        await video.initialize();
        await video.setLooping(true);
      } catch (_) {
        await video.dispose();
        rethrow;
      }
      if (!mounted) {
        await video.dispose();
        return;
      }
      setState(() => _video = video..play());
    } catch (e) {
      if (mounted) setState(() => _error = 'Couldn\'t open ${widget.path.split('/').last}: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.path.split('/').last;
    final video = _video, bytes = _bytes;
    final Widget body;
    if (_error != null) {
      body = ListView(padding: const EdgeInsets.all(16), children: [
        ErrorBanner(_error!, margin: EdgeInsets.zero),
        const SizedBox(height: 16),
        Align(alignment: Alignment.centerLeft, child: OutlinedButton(onPressed: _load, child: const Text('Try again'))),
      ]);
    } else if (bytes != null) {
      body = InteractiveViewer(
        maxScale: 8,
        child: Center(
            child: Image.memory(bytes,
                semanticLabel: name,
                errorBuilder: (_, __, ___) => Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        ErrorBanner('Couldn\'t show $name', margin: EdgeInsets.zero),
                        const SizedBox(height: 16),
                        Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton(onPressed: _load, child: const Text('Try again'))),
                      ]),
                    ))),
      );
    } else if (video != null) {
      body = Column(children: [
        Expanded(
          child: GestureDetector(
            onTap: () => setState(() => video.value.isPlaying ? video.pause() : video.play()),
            child: Center(child: AspectRatio(aspectRatio: video.value.aspectRatio, child: VideoPlayer(video))),
          ),
        ),
        SafeArea(
          top: false,
          child: Row(children: [
            IconButton(
              tooltip: video.value.isPlaying ? 'Pause' : 'Play',
              onPressed: () => setState(() => video.value.isPlaying ? video.pause() : video.play()),
              icon: Icon(video.value.isPlaying ? Icons.pause : Icons.play_arrow),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: VideoProgressIndicator(video,
                    allowScrubbing: true,
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    colors: VideoProgressColors(
                        playedColor: Tokens.of(context).ink,
                        bufferedColor: Tokens.of(context).border,
                        backgroundColor: Tokens.of(context).divider)),
              ),
            ),
          ]),
        ),
      ]);
    } else {
      body = const Center(child: CircularProgressIndicator());
    }
    return body;
  }
}
