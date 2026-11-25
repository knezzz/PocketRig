import 'dart:io';

import 'package:drift/drift.dart';
import 'package:loggy/loggy.dart';

import '../models.dart';
import 'chat_cache.dart';

/// Set in main next to [chatCache]. Null in tests that don't use it.
MediaCache? mediaCache;

/// Downloaded images, videos and files kept on the phone, so opening one again
/// makes no SSH call. A copy of the host's file, in the OS cache folder.
///
/// A file goes stale only when a newer chat line mentions it (see
/// [ChatCache.mentionedAt]) or on [force]. shortcut: a file changed on the host
/// with no chat line about it stays old until Reload; phone and host clocks are
/// compared as they are.
class MediaCache {
  MediaCache(this.db, {this.maxBytes = 256 << 20, this.maxFileBytes = 50 << 20});

  final ChatCache db;

  /// Total kept; least recently opened go first.
  final int maxBytes;

  /// Bigger files are shown but not stored.
  final int maxFileBytes;

  final _inFlight = <String, Future<Uint8List>>{};

  /// [path]'s bytes on [host]: from disk when cached and fresh, otherwise from
  /// [fetch] (the SSH download), which is then stored. A failed fetch stores
  /// nothing and throws; a failed write only logs.
  Future<Uint8List> get(Host host, String path, {required Future<Uint8List> Function() fetch, bool force = false}) {
    final key = '${host.id}|$path';
    final running = _inFlight[key];
    if (!force && running != null) return running;
    final f = _load(host.id, path, fetch, force);
    _inFlight[key] = f;
    f.then((_) {
      _inFlight.remove(key);
    }, onError: (Object _) {
      _inFlight.remove(key);
    });
    return f;
  }

  Future<MediaFile?> _row(String hostId, String path) =>
      (db.select(db.mediaFiles)..where((f) => f.hostId.equals(hostId) & f.path.equals(path))).getSingleOrNull();

  Future<Uint8List> _load(String hostId, String path, Future<Uint8List> Function() fetch, bool force) async {
    // Both sides of the staleness check are chat-line times (the host's clock): the phone's clock never enters.
    int? mention;
    try {
      mention = await db.mentionedAt(hostId, path);
      final dir = await db.mediaDir();
      final row = await _row(hostId, path);
      if (row != null && !force) {
        final file = File('${dir.path}/${row.id}');
        if (await file.exists()) {
          if (mention == null || mention <= row.fetchedAt) {
            await (db.update(db.mediaFiles)..where((f) => f.id.equals(row.id)))
                .write(MediaFilesCompanion(openedAt: Value(DateTime.now().millisecondsSinceEpoch)));
            return await file.readAsBytes();
          }
        } else {
          // The OS purged the folder: the row points at nothing.
          await (db.delete(db.mediaFiles)..where((f) => f.id.equals(row.id))).go();
        }
      }
    } catch (e) {
      logWarning('media cache: $e');
    }
    final bytes = await fetch();
    try {
      await _store(hostId, path, bytes, mention ?? 0);
    } catch (e) {
      logWarning('media cache: $e');
    }
    return bytes;
  }

  /// [mentioned] is the newest chat-line time that named the file when it was fetched (0: none).
  Future<void> _store(String hostId, String path, Uint8List bytes, int mentioned) async {
    if (bytes.length > maxFileBytes) return;
    final dir = await db.mediaDir();
    await dir.create(recursive: true);
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await db.transaction(() async {
      final row = await _row(hostId, path);
      if (row == null) {
        return db.into(db.mediaFiles).insert(
            MediaFilesCompanion.insert(hostId: hostId, path: path, size: bytes.length, fetchedAt: mentioned, openedAt: now));
      }
      await (db.update(db.mediaFiles)..where((f) => f.id.equals(row.id)))
          .write(MediaFilesCompanion(size: Value(bytes.length), fetchedAt: Value(mentioned), openedAt: Value(now)));
      return row.id;
    });
    final part = File('${dir.path}/$id.part');
    try {
      await part.writeAsBytes(bytes, flush: true);
      await part.rename('${dir.path}/$id');
    } catch (_) {
      // Full disk or similar: keep nothing, never a half file under the row.
      await (db.delete(db.mediaFiles)..where((f) => f.id.equals(id))).go();
      await db.deleteMediaFiles([MediaFile(id: id, hostId: hostId, path: path, size: 0, fetchedAt: 0, openedAt: 0)]);
      rethrow;
    }
    await _trim(keep: id);
  }

  Future<void> _trim({required int keep}) async {
    final rows = await (db.select(db.mediaFiles)..orderBy([(f) => OrderingTerm.asc(f.openedAt)])).get();
    var used = rows.fold<int>(0, (a, r) => a + r.size);
    final drop = <MediaFile>[];
    for (final r in rows) {
      if (used <= maxBytes) break;
      if (r.id == keep) continue;
      used -= r.size;
      drop.add(r);
    }
    if (drop.isEmpty) return;
    await (db.delete(db.mediaFiles)..where((f) => f.id.isIn(drop.map((r) => r.id)))).go();
    await db.deleteMediaFiles(drop);
  }
}
