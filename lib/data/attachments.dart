import 'dart:typed_data';

import '../api/openrig_client.dart';
import '../models.dart';
import '../ssh/ssh_exec.dart';

/// Larger files are refused: they're read into the phone's memory whole.
const maxAttachmentBytes = 50 * 1024 * 1024;

/// A shell- and prompt-safe file name for an upload, prefixed with [now] and
/// the file's place [n] in the batch, so two photos both called image.jpg
/// don't overwrite each other.
String uploadName(String name, DateTime now, [int n = 0]) {
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp = '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
  final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return '$stamp${n > 0 ? '-$n' : ''}-${safe.isEmpty ? 'file' : safe}';
}

/// Uploads [files] (name, bytes) to [host] and returns their paths there.
Future<List<String>> uploadAttachments(Host host, List<(String, Uint8List)> files) async {
  for (final (name, bytes) in files) {
    if (bytes.length > maxAttachmentBytes) throw OpenRigException('$name is over 50 MB, too big to send.');
  }
  return SshExec.use(host, (ssh) async {
    final now = DateTime.now();
    return [for (final (i, (name, bytes)) in files.indexed) await ssh.upload(uploadName(name, now, i), bytes)];
  });
}
