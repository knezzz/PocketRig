import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../api/openrig_client.dart';
import '../data/attachments.dart';
import '../data/host_store.dart' show isDesktop;
import '../data/projects.dart' show shQuote;
import '../main.dart' show AppScope;
import '../models.dart';
import 'common.dart' show toast;
import 'theme.dart';

final _image = RegExp(r'\.(png|jpe?g|gif|webp)$', caseSensitive: false);

/// The remote paths of the image files in [files] (name, bytes) once they are uploaded to [host]. Anything that isn't an image is refused before anything is sent, so a drop of
/// mixed files uploads nothing. [upload] is [uploadAttachments]; a test passes a fake.
Future<List<String>> dropImagePaths(
  Host host,
  List<(String, Uint8List)> files, {
  Future<List<String>> Function(Host, List<(String, Uint8List)>) upload = uploadAttachments,
}) async {
  if (files.isEmpty) throw OpenRigException('Nothing to attach.');
  final other = files.where((f) => !_image.hasMatch(f.$1)).firstOrNull;
  if (other != null) throw OpenRigException('${other.$1} isn\'t an image (png, jpg, gif or webp).');
  return upload(host, files);
}

/// [paths] as one pasted word list for a terminal: each quoted for the shell, space separated.
String quotedPaths(List<String> paths) => paths.map(shQuote).join(' ');

/// Drop an image file (or a screenshot thumbnail) on [child] on a Mac: it goes to the host's upload folder and
/// [onPaste] gets its remote path, for a terminal to paste quoted ([quotedPaths]) without Enter (Claude Code shows it as [Image #1]). A highlight shows while dragging,
/// 'Uploading…' and then 'Attached' hug the bottom left; a failed upload says why and pastes nothing. Not on a phone.
class ImageDropTarget extends StatefulWidget {
  const ImageDropTarget({super.key, required this.child, required this.onPaste, this.upload});
  final Widget child;
  final void Function(List<String> paths) onPaste;

  /// For a test: the upload step, and with it the files, in place of the real ones.
  final Future<List<String>> Function(Host host, List<(String, Uint8List)> files)? upload;

  @override
  State<ImageDropTarget> createState() => _ImageDropTargetState();
}

enum _Phase { idle, over, uploading, attached }

class _ImageDropTargetState extends State<ImageDropTarget> {
  var _phase = _Phase.idle;

  Future<void> drop(List<(String, Uint8List)> files) async {
    final host = AppScope.read(context).active;
    if (host == null) return;
    setState(() => _phase = _Phase.uploading);
    try {
      final paths = await (widget.upload ?? (h, f) => dropImagePaths(h, f))(host, files);
      if (!mounted) return;
      widget.onPaste(paths);
      setState(() => _phase = _Phase.attached);
      await Future<void>.delayed(const Duration(seconds: 2));
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t attach: ${e is OpenRigException ? e.message : e}');
    }
    if (mounted) setState(() => _phase = _Phase.idle);
  }

  @override
  Widget build(BuildContext context) {
    if (!isDesktop) return widget.child;
    final k = Tokens.of(context);
    return DropTarget(
      // A screen under another one still hears the drag: only the one in front takes it.
      enable: TickerMode.of(context),
      onDragEntered: (_) => setState(() => _phase = _Phase.over),
      onDragExited: (_) => setState(() => _phase = _phase == _Phase.over ? _Phase.idle : _phase),
      onDragDone: (d) async {
        if (_phase == _Phase.uploading) return;
        final files = <(String, Uint8List)>[];
        try {
          for (final f in d.files) {
            files.add((f.name, await f.readAsBytes()));
          }
        } catch (e) {
          if (!mounted) return;
          toast(this.context, 'Couldn\'t read the file: $e');
          setState(() => _phase = _Phase.idle);
          return;
        }
        await drop(files);
      },
      child: Stack(fit: StackFit.passthrough, children: [
        widget.child,
        if (_phase != _Phase.idle)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                    border: Border.all(color: _phase == _Phase.over ? k.ink : Colors.transparent, width: 2),
                    color: _phase == _Phase.over ? k.ink.withValues(alpha: 0.06) : null),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: _phase == _Phase.over
                      ? const SizedBox.shrink()
                      : Container(
                          margin: const EdgeInsets.all(8),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: k.fill, borderRadius: BorderRadius.circular(4)),
                          child: Text(_phase == _Phase.uploading ? 'Uploading…' : 'Attached',
                              style: TextStyle(fontSize: 12, color: k.ink))),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
