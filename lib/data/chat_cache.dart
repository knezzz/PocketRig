import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:path_provider/path_provider.dart';

import '../chat/media_index.dart';
import '../models.dart';

part 'chat_cache.g.dart';

/// Set in main. Null in tests that don't exercise the cache.
ChatCache? chatCache;

/// Chats an open chat screen is writing, as [openKey]. Background sync skips
/// these: a chat has one writer.
final openChatKeys = <String>[]; // a list: two screens on one chat each hold it, and the first to close lets go of one

String openKey(String hostId, String key) => '$hostId/$key';

/// What one seat or agent's chat is filed under on its host.
String chatKey(Seat seat) => seat.rigId.isEmpty
    ? 'loose/${seat.sessionName ?? seat.resumeToken ?? seat.logicalId}'
    : '${seat.rigId}/${seat.logicalId}';

/// Which of [keys] belong to agents that are gone from the host. Anything the
/// host couldn't vouch for stays: a daemon hiccup shouldn't empty the cache, so
/// [loose] is null when the loose-agent list was incomplete, and a running rig
/// with no seats means its seat lookup failed. A rig or seat that only stopped
/// stays, so rig details still lists what it made.
List<String> goneChats(Iterable<String> keys, List<RigWithSeats> rigs, List<LooseAgent>? loose) {
  final looseKeys = loose?.map((a) => 'loose/${a.id}').toSet();
  final rigsById = {for (final r in rigs) r.rig.id: r};
  bool gone(String key) {
    if (key.startsWith('loose/')) return looseKeys != null && !looseKeys.contains(key);
    final rig = rigsById[key.substring(0, key.indexOf('/'))];
    if (rig == null) return true;
    if (rig.seats.isEmpty) return false;
    return !rig.seats.any((s) => chatKey(s) == key);
  }

  return keys.where(gone).toList();
}

@DataClassName('ChatRow')
class Chats extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get hostId => text()();
  TextColumn get chatKey => text()();
  TextColumn get logPath => text()();

  /// The log byte after the last line read: where the tail resumes.
  IntColumn get logOffset => integer().withDefault(const Constant(0))();

  /// True when the start of the conversation isn't here.
  BoolColumn get truncated => boolean().withDefault(const Constant(false))();

  /// 0 for a chat only background sync has pulled: evicted before opened ones.
  IntColumn get openedAt => integer()();

  /// Started from the last part of the log by background sync.
  BoolColumn get seeded => boolean().withDefault(const Constant(false))();

  @override
  List<Set<Column>> get uniqueKeys => [
        {hostId, chatKey}
      ];
}

/// One slimmed log line (see `slimLogLine`), oldest first by id.
@TableIndex(name: 'chat_lines_chat', columns: {#chatId})
class ChatLines extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get chatId => integer()();
  TextColumn get line => text()();
  IntColumn get size => integer()();
}

/// An image, video, file or artifact a chat made or mentions.
class ChatMedia extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get chatId => integer()();

  /// `image | video | file | artifact`.
  TextColumn get kind => text()();

  /// The host path, or an artifact's claude.ai URL ('pending:<toolId>' until it is known).
  TextColumn get ref => text()();
  TextColumn get name => text().nullable()();
  TextColumn get toolId => text().nullable()();

  /// The newest log line that mentioned it, in ms since epoch.
  IntColumn get touchedAt => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {chatId, kind, ref}
      ];
}

/// A downloaded file, kept in the media folder as `<id>`.
class MediaFiles extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get hostId => text()();
  TextColumn get path => text()();
  IntColumn get size => integer()();
  IntColumn get fetchedAt => integer()();
  IntColumn get openedAt => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {hostId, path}
      ];
}

class CachedChat {
  CachedChat(this.path, this.offset, this.truncated, this.lines, {this.seeded = false});
  final String path;
  final int offset;
  final bool truncated;
  final List<String> lines;

  /// Only the end of the log, pulled by background sync.
  final bool seeded;
}

/// Something the rig's chats made, for the rig details section.
class RigMedia {
  RigMedia(this.kind, this.ref, this.name, this.touchedAt, this.chatKey);
  final String kind;
  final String ref;
  final String? name;
  final DateTime touchedAt;
  final String chatKey;
}

/// Chats and downloaded media saved on the phone so they open before SSH
/// connects. Only a copy of what the host has, so it lives in the OS cache
/// folder: never backed up, and the OS may reclaim it.
@DriftDatabase(tables: [Chats, ChatLines, ChatMedia, MediaFiles])
class ChatCache extends _$ChatCache {
  ChatCache(
    super.e, {
    this.maxChatBytes = 4 * 1024 * 1024,
    this.maxTotalBytes = 64 * 1024 * 1024,
    Future<Directory> Function()? mediaDir,
  }) : mediaDir = mediaDir ?? _defaultMediaDir;

  factory ChatCache.open() => ChatCache(driftDatabase(
        name: 'chat_cache',
        native: DriftNativeOptions(
          databaseDirectory: getApplicationCacheDirectory,
          // Deleted rows give the space back instead of growing the file.
          setup: (db) => db.execute('PRAGMA auto_vacuum = FULL'),
        ),
      ));

  static Future<Directory> _defaultMediaDir() async =>
      Directory('${(await getApplicationCacheDirectory()).path}/media');

  final int maxChatBytes;
  final int maxTotalBytes;

  /// Where downloaded files live. Created when first needed.
  final Future<Directory> Function() mediaDir;

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // One transaction: a crash half way must not leave a column that is added twice.
            await transaction(() async {
              // Old lines have no media index and can't be backfilled from clipped lines.
              await delete(chatLines).go();
              await delete(chats).go();
              await m.addColumn(chats, chats.seeded);
              await m.createTable(chatMedia);
              await m.createTable(mediaFiles);
            });
          }
        },
      );

  Future<ChatRow?> _row(String hostId, String key) =>
      (select(chats)..where((c) => c.hostId.equals(hostId) & c.chatKey.equals(key))).getSingleOrNull();

  Future<void> _drop(int id) async {
    await (delete(chatLines)..where((l) => l.chatId.equals(id))).go();
    await (delete(chatMedia)..where((m) => m.chatId.equals(id))).go();
    await (delete(chats)..where((c) => c.id.equals(id))).go();
  }

  /// The saved chat, or null. Counts as opening it for eviction.
  Future<CachedChat?> load(String hostId, String key) => transaction(() async {
        final row = await _row(hostId, key);
        if (row == null) return null;
        await (update(chats)..where((c) => c.id.equals(row.id)))
            .write(ChatsCompanion(openedAt: Value(DateTime.now().millisecondsSinceEpoch)));
        final lines = await (select(chatLines)
              ..where((l) => l.chatId.equals(row.id))
              ..orderBy([(l) => OrderingTerm.asc(l.id)]))
            .map((l) => l.line)
            .get();
        return CachedChat(row.logPath, row.logOffset, row.truncated, lines, seeded: row.seeded);
      });

  /// The last [n] saved lines, oldest first, without counting as opening the chat (previews).
  Future<List<String>> lastLines(String hostId, String key, int n) async {
    final row = await _row(hostId, key);
    if (row == null) return const [];
    final lines = await (select(chatLines)
          ..where((l) => l.chatId.equals(row.id))
          ..orderBy([(l) => OrderingTerm.desc(l.id)])
          ..limit(n))
        .map((l) => l.line)
        .get();
    return lines.reversed.toList();
  }

  /// Where a chat's saved lines end, without loading them: sync's cursor.
  /// Null when there is no row.
  Future<({String path, int offset, bool truncated})?> cursor(String hostId, String key) async {
    final row = await _row(hostId, key);
    return row == null ? null : (path: row.logPath, offset: row.logOffset, truncated: row.truncated);
  }

  /// Deletes one chat and what was indexed from it.
  Future<void> drop(String hostId, String key) => transaction(() async {
        final row = await _row(hostId, key);
        if (row != null) await _drop(row.id);
      });

  /// Starts this chat over from [path]: a new log, or the old one rewritten.
  Future<void> restart(String hostId, String key, String path) => transaction(() async {
        final row = await _row(hostId, key);
        if (row != null) await _drop(row.id);
        await into(chats).insert(ChatsCompanion.insert(
          hostId: hostId,
          chatKey: key,
          logPath: path,
          openedAt: DateTime.now().millisecondsSinceEpoch,
        ));
      });

  /// Adds the full log [lines] that run from byte [fromOffset] to [toOffset]
  /// of [path], then trims to the budgets. They are slimmed here and their
  /// media is indexed in the same transaction.
  ///
  /// Compare-and-set: it writes only when the row still has this [path] and
  /// [fromOffset], so two writers can't duplicate or skip lines. False means
  /// drop the batch and read the row again: the chat is gone (its agent
  /// disconnected, or the cache was cleared), or someone else moved it.
  /// [earlier] is the media index of older lines the caller no longer holds; it is stored with these.
  /// With [seed], a missing row is created (opened at 0, so it is evicted
  /// first); an existing row is left alone.
  Future<bool> append(
    String hostId,
    String key,
    String path,
    int fromOffset,
    int toOffset,
    bool truncated,
    List<String> lines, {
    bool seed = false,
    LogIndex? earlier,
  }) async {
    final done = lines.length > 150 ? await compute(slimAndIndex, lines) : slimAndIndex(lines);
    final index = earlier == null ? done.index : mergeLogIndex(earlier, done.index);
    return transaction(() async {
      var row = await _row(hostId, key);
      if (row == null) {
        if (!seed) return false;
        await into(chats).insert(ChatsCompanion.insert(
          hostId: hostId,
          chatKey: key,
          logPath: path,
          openedAt: 0,
          seeded: const Value(true),
        ));
        row = (await _row(hostId, key))!;
      } else if (seed || row.logPath != path || row.logOffset != fromOffset) {
        return false;
      }
      await batch((b) => b.insertAll(chatLines, [
            for (final l in done.slim) ChatLinesCompanion.insert(chatId: row!.id, line: l, size: _bytes(l)),
          ]));
      await _index(row.id, index);
      final trimmed = await _trimChat(row.id);
      await (update(chats)..where((c) => c.id.equals(row!.id)))
          .write(ChatsCompanion(logOffset: Value(toOffset), truncated: Value(truncated || trimmed)));
      await _trimTotal(keep: row.id);
      return true;
    });
  }

  Future<void> _index(int chatId, LogIndex index) async {
    final failed = index.errorIds;
    final hits = index.hits.where((h) => h.toolId == null || !failed.contains(h.toolId));
    await batch((b) {
      for (final h in hits) {
        final ref = h.ref.isEmpty ? 'pending:${h.toolId}' : h.ref;
        b.insert(
          chatMedia,
          ChatMediaCompanion.insert(
              chatId: chatId, kind: h.kind, ref: ref, name: Value(h.name), toolId: Value(h.toolId), touchedAt: h.at),
          mode: InsertMode.insertOrIgnore,
        );
        b.customStatement(
          // A name in prose first, then a tool on it: the row takes the tool, so the panels count it.
          'UPDATE chat_media SET touched_at = MAX(touched_at, ?), tool_id = COALESCE(tool_id, ?) '
              'WHERE chat_id = ? AND kind = ? AND ref = ?',
          [h.at, h.toolId, chatId, h.kind, ref],
        );
      }
    });
    if (failed.isNotEmpty) {
      await (delete(chatMedia)..where((m) => m.chatId.equals(chatId) & m.toolId.isIn(failed))).go();
    }
    for (final e in index.artifactUrls.entries) {
      await customStatement(
        "UPDATE OR IGNORE chat_media SET ref = ? WHERE chat_id = ? AND kind = 'artifact' AND tool_id = ? AND ref LIKE 'pending:%'",
        [e.value, chatId, e.key],
      );
      await customStatement(
        "DELETE FROM chat_media WHERE chat_id = ? AND kind = 'artifact' AND tool_id = ? AND ref LIKE 'pending:%'",
        [chatId, e.key],
      );
    }
  }

  static int _bytes(String s) => utf8.encode(s).length;

  Future<int> _chatBytes(int id) {
    final size = chatLines.size.sum();
    final q = selectOnly(chatLines)
      ..addColumns([size])
      ..where(chatLines.chatId.equals(id));
    return q.map((r) => r.read(size) ?? 0).getSingle();
  }

  /// Over budget, drops the oldest lines down to 3/4 so this doesn't run on every write.
  Future<bool> _trimChat(int id) async {
    var used = await _chatBytes(id);
    if (used <= maxChatBytes) return false;
    final q = selectOnly(chatLines)
      ..addColumns([chatLines.id, chatLines.size])
      ..where(chatLines.chatId.equals(id))
      ..orderBy([OrderingTerm.asc(chatLines.id)]);
    var last = 0;
    for (final r in await q.get()) {
      if (used <= maxChatBytes * 3 ~/ 4) break;
      used -= r.read(chatLines.size)!;
      last = r.read(chatLines.id)!;
    }
    await (delete(chatLines)..where((l) => l.chatId.equals(id) & l.id.isSmallerOrEqualValue(last))).go();
    return true;
  }

  /// Over budget, drops the chats opened longest ago (synced-only chats first).
  Future<void> _trimTotal({required int keep}) async {
    // Chat lines only: downloaded media has its own budget.
    var used = (await customSelect('SELECT COALESCE(SUM(size), 0) AS n FROM chat_lines').getSingle()).read<int>('n');
    if (used <= maxTotalBytes) return;
    final oldest = await (select(chats)
          ..where((c) => c.id.equals(keep).not())
          ..orderBy([(c) => OrderingTerm.asc(c.openedAt)]))
        .get();
    for (final c in oldest) {
      if (used <= maxTotalBytes) break;
      used -= await _chatBytes(c.id);
      await _drop(c.id);
    }
  }

  /// Deletes the chats of agents that are gone from this host.
  Future<void> prune(String hostId, List<RigWithSeats> rigs, List<LooseAgent>? loose) => transaction(() async {
        final rows = await (select(chats)..where((c) => c.hostId.equals(hostId))).get();
        final gone = goneChats(rows.map((r) => r.chatKey), rigs, loose).toSet();
        for (final r in rows.where((r) => gone.contains(r.chatKey))) {
          await _drop(r.id);
        }
      });

  Future<void> forgetHost(String hostId) async {
    final files = await transaction(() async {
      final rows = await (select(chats)..where((c) => c.hostId.equals(hostId))).get();
      for (final r in rows) {
        await _drop(r.id);
      }
      final files = await (select(mediaFiles)..where((f) => f.hostId.equals(hostId))).get();
      await (delete(mediaFiles)..where((f) => f.hostId.equals(hostId))).go();
      return files;
    });
    await deleteMediaFiles(files);
  }

  Future<void> clear() async {
    final files = await transaction(() async {
      await delete(chatLines).go();
      await delete(chatMedia).go();
      await delete(chats).go();
      final files = await select(mediaFiles).get();
      await delete(mediaFiles).go();
      return files;
    });
    await deleteMediaFiles(files);
  }

  /// Removes the files behind [rows]. A file that is already gone is fine.
  Future<void> deleteMediaFiles(Iterable<MediaFile> rows) async {
    if (rows.isEmpty) return;
    final dir = await mediaDir();
    for (final r in rows) {
      for (final name in ['${r.id}', '${r.id}.part']) {
        try {
          await File('${dir.path}/$name').delete();
        } on FileSystemException {
          // Already gone.
        }
      }
    }
  }

  Selectable<(int, int)> _usage() => customSelect(
        'SELECT (SELECT COALESCE(SUM(size), 0) FROM chat_lines) '
        '+ (SELECT COALESCE(SUM(size), 0) FROM media_files) AS bytes, (SELECT COUNT(*) FROM chats) AS n',
        readsFrom: {chats, chatLines, mediaFiles},
      ).map((r) => (r.read<int>('bytes'), r.read<int>('n')));

  /// Bytes (chat lines and downloaded media) and chats stored, live.
  Stream<(int, int)> watchUsage() => _usage().watchSingle();

  /// Everything the chats of rig [rigId] made that is cached, newest first.
  /// Only what was pulled: a chat never pulled, or evicted, is missing.
  Stream<List<RigMedia>> watchRigMedia(String hostId, String rigId) {
    final prefix = '$rigId/';
    return customSelect(
      'SELECT m.kind AS kind, m.ref AS ref, m.name AS name, MAX(m.touched_at) AS at, c.chat_key AS chat_key '
      'FROM chat_media m JOIN chats c ON c.id = m.chat_id '
      "WHERE c.host_id = ? AND substr(c.chat_key, 1, ?) = ? AND m.ref NOT LIKE 'pending:%' "
      'GROUP BY m.kind, m.ref ORDER BY at DESC',
      variables: [Variable<String>(hostId), Variable<int>(prefix.length), Variable<String>(prefix)],
      readsFrom: {chats, chatMedia},
    ).watch().map((rows) => [
          for (final r in rows)
            RigMedia(r.read<String>('kind'), r.read<String>('ref'), r.readNullable<String>('name'),
                DateTime.fromMillisecondsSinceEpoch(r.read<int>('at')), r.read<String>('chat_key')),
        ]);
  }

  /// The images and videos chat [key]'s tool calls touched (read, wrote, named), and the files it wrote, newest first.
  /// Names only in the agent's prose are left out: they are often of files that never existed.
  Stream<List<RigMedia>> watchChatMedia(String hostId, String key) => customSelect(
        'SELECT m.kind AS kind, m.ref AS ref, m.name AS name, m.touched_at AS at, c.chat_key AS chat_key '
        'FROM chat_media m JOIN chats c ON c.id = m.chat_id '
        "WHERE c.host_id = ? AND c.chat_key = ? AND (m.kind = 'file' OR (m.kind IN ('image', 'video') "
        'AND m.tool_id IS NOT NULL)) ORDER BY at DESC',
        variables: [Variable<String>(hostId), Variable<String>(key)],
        readsFrom: {chats, chatMedia},
      ).watch().map((rows) => [
            for (final r in rows)
              RigMedia(r.read<String>('kind'), r.read<String>('ref'), r.readNullable<String>('name'),
                  DateTime.fromMillisecondsSinceEpoch(r.read<int>('at')), r.read<String>('chat_key')),
          ]);

  /// The newest chat line, in ms since epoch, that mentions [ref] on [hostId]. Null: none.
  Future<int?> mentionedAt(String hostId, String ref) async {
    final rows = await customSelect(
      'SELECT MAX(m.touched_at) AS at FROM chat_media m JOIN chats c ON c.id = m.chat_id '
      'WHERE c.host_id = ? AND m.ref = ?',
      variables: [Variable<String>(hostId), Variable<String>(ref)],
      readsFrom: {chats, chatMedia},
    ).get();
    return rows.single.readNullable<int>('at');
  }
}
