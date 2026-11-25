import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/chat_cache.dart';
import 'package:pocket_rig/data/media_cache.dart';
import 'package:pocket_rig/models.dart';

late Directory dir;

ChatCache memory({int chat = 4 << 20, int total = 64 << 20}) =>
    ChatCache(NativeDatabase.memory(), maxChatBytes: chat, maxTotalBytes: total, mediaDir: () async => dir);

final host = Host(id: 'h', name: 'h', address: 'h', sshUser: 'u');
const t0 = '2026-11-07T10:00:00.000Z', t1 = '2026-11-07T10:05:00.000Z';

String toolUse(String id, String name, Map<String, Object?> input, {String at = t0}) => jsonEncode({
      'type': 'assistant',
      'uuid': 'u$id',
      'timestamp': at,
      'cwd': '/w',
      'message': {
        'id': 'm$id',
        'content': [
          {'type': 'tool_use', 'id': id, 'name': name, 'input': input}
        ],
      },
    });

String toolResult(String id, String text, {bool error = false, String at = t0}) => jsonEncode({
      'type': 'user',
      'uuid': 'r$id',
      'timestamp': at,
      'cwd': '/w',
      'message': {
        'content': [
          {'type': 'tool_result', 'tool_use_id': id, 'content': text, if (error) 'is_error': true}
        ],
      },
    });

Future<List<RigMedia>> media(ChatCache c) => c.watchRigMedia('h', 'r1').first;

void main() {
  setUp(() async => dir = await Directory.systemTemp.createTemp('media-cache-test'));
  tearDown(() async => dir.delete(recursive: true));

  group('append is compare-and-set', () {
    test('a write from a stale cursor is refused and changes nothing', () async {
      final c = memory();
      addTearDown(c.close);
      await c.restart('h', 'k', '/a');
      expect(await c.append('h', 'k', '/a', 0, 10, false, ['one']), isTrue);
      expect(await c.append('h', 'k', '/a', 0, 10, false, ['dup']), isFalse, reason: 'another writer got there');
      expect(await c.append('h', 'k', '/b', 10, 20, false, ['other log']), isFalse);
      expect(await c.append('h', 'k', '/a', 10, 20, false, ['two']), isTrue);
      expect((await c.load('h', 'k'))!.lines, ['one', 'two']);
      expect((await c.cursor('h', 'k'))!.offset, 20);
    });

    test('a seed makes a row that sorts first for eviction, and never overwrites one', () async {
      final c = memory(chat: 1000, total: 1500);
      addTearDown(c.close);
      expect(await c.append('h', 'seeded', '/s', 5, 50, true, ['x' * 700], seed: true), isTrue);
      expect(await c.append('h', 'seeded', '/s', 5, 60, true, ['y'], seed: true), isFalse);
      final got = (await c.load('h', 'seeded'))!;
      expect((got.seeded, got.truncated, got.offset), (true, true, 50));

      // load() counted as opening it; an untouched seed row is the one evicted.
      await c.append('h', 'seed2', '/s2', 0, 1, true, ['x' * 700], seed: true);
      await c.restart('h', 'opened', '/o');
      await c.append('h', 'opened', '/o', 0, 1, false, ['x' * 700]);
      expect(await c.load('h', 'seed2'), isNull);
      expect(await c.load('h', 'opened'), isNotNull);
    });
  });

  group('media index', () {
    test('files written, images mentioned and artifacts published are indexed from full lines', () async {
      final c = memory();
      addTearDown(c.close);
      await c.restart('h', 'r1/lead', '/a');
      await c.append('h', 'r1/lead', '/a', 0, 1, false, [
        toolUse('w', 'Write', {'file_path': '/w/notes.md', 'content': 'x' * 5000}),
        toolUse('b', 'Bash', {'command': 'ls'}),
        toolResult('b', 'made /w/out/chart.png and ./clip.mp4'),
        toolUse('a', 'Artifact', {'file_path': '/w/page.html'}),
        toolResult('a', 'Published https://claude.ai/artifact/abc-123', at: t1),
      ]);
      final got = {for (final m in await media(c)) m.kind: m};
      expect(got.keys, containsAll(['file', 'image', 'video', 'artifact']));
      expect(got['file']!.ref, '/w/notes.md');
      expect(got['image']!.ref, '/w/out/chart.png');
      expect(got['video']!.ref, '/w/clip.mp4');
      expect(got['artifact']!.ref, 'https://claude.ai/artifact/abc-123');
      expect(got['artifact']!.name, 'page.html');
      expect((await media(c)).first.kind, 'artifact', reason: 'newest touch first');
    });

    test('an artifact whose result arrives in a later batch still gets its link', () async {
      final c = memory();
      addTearDown(c.close);
      await c.restart('h', 'r1/lead', '/a');
      await c.append('h', 'r1/lead', '/a', 0, 1, false, [toolUse('a', 'Artifact', {'file_path': '/w/p.html'})]);
      expect(await media(c), isEmpty, reason: 'no link yet');
      await c.append('h', 'r1/lead', '/a', 1, 2, false, [toolResult('a', 'https://claude.ai/artifact/zzz')]);
      expect((await media(c)).single.ref, 'https://claude.ai/artifact/zzz');
    });

    test('a failed call is not listed, even when its error arrives in a later batch', () async {
      final c = memory();
      addTearDown(c.close);
      await c.restart('h', 'r1/lead', '/a');
      await c.append('h', 'r1/lead', '/a', 0, 1, false, [
        toolUse('ok', 'Write', {'file_path': '/w/ok.txt'}),
        toolUse('bad', 'Write', {'file_path': '/w/bad.txt'}),
        toolResult('ok', 'ok'),
      ]);
      expect((await media(c)).map((m) => m.ref), containsAll(['/w/ok.txt', '/w/bad.txt']));
      await c.append('h', 'r1/lead', '/a', 1, 2, false, [toolResult('bad', 'denied', error: true)]);
      expect((await media(c)).map((m) => m.ref), ['/w/ok.txt']);
    });

    test('a rig lists only its own chats, and a dropped chat takes its media with it', () async {
      final c = memory();
      addTearDown(c.close);
      for (final k in ['r1/lead', 'r10/lead']) {
        await c.restart('h', k, '/$k');
        await c.append('h', k, '/$k', 0, 1, false, [toolUse('w', 'Write', {'file_path': '/w/$k.txt'})]);
      }
      expect((await media(c)).map((m) => m.ref), ['/w/r1/lead.txt'], reason: 'r1 is not a prefix of r10');
      await c.restart('h', 'r1/lead', '/new');
      expect(await media(c), isEmpty);
    });

    test('repeat mentions bump the time instead of adding rows', () async {
      final c = memory();
      addTearDown(c.close);
      await c.restart('h', 'r1/lead', '/a');
      await c.append('h', 'r1/lead', '/a', 0, 1, false, [toolUse('1', 'Write', {'file_path': '/w/f'})]);
      await c.append('h', 'r1/lead', '/a', 1, 2, false, [toolUse('2', 'Edit', {'file_path': '/w/f'}, at: t1)]);
      final m = (await media(c)).single;
      expect(m.touchedAt.toUtc(), DateTime.parse(t1));
      expect(await c.mentionedAt('h', '/w/f'), DateTime.parse(t1).millisecondsSinceEpoch);
    });
  });

  group('MediaCache', () {
    Future<Uint8List> Function() source(List<String> calls, String body) => () async {
          calls.add(body);
          return Uint8List.fromList(utf8.encode(body));
        };

    test('a second open comes from disk with no fetch', () async {
      final c = memory();
      addTearDown(c.close);
      final cache = MediaCache(c);
      final calls = <String>[];
      expect(utf8.decode(await cache.get(host, '/w/a.png', fetch: source(calls, 'one'))), 'one');
      expect(utf8.decode(await cache.get(host, '/w/a.png', fetch: source(calls, 'two'))), 'one');
      expect(calls, ['one']);
    });

    test('a newer chat line makes it stale; Reload forces a fetch', () async {
      final c = memory();
      addTearDown(c.close);
      final cache = MediaCache(c);
      final calls = <String>[];
      await cache.get(host, '/w/f.md', fetch: source(calls, 'v1'));
      expect(calls, ['v1']);

      // The log mentions the file just after the fetch; the refetch is later still.
      await c.restart('h', 'r1/lead', '/a');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final mentioned = DateTime.now().toUtc().toIso8601String();
      await c.append('h', 'r1/lead', '/a', 0, 1, false, [toolUse('e', 'Edit', {'file_path': '/w/f.md'}, at: mentioned)]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(utf8.decode(await cache.get(host, '/w/f.md', fetch: source(calls, 'v2'))), 'v2');
      expect(utf8.decode(await cache.get(host, '/w/f.md', fetch: source(calls, 'v3'))), 'v2', reason: 'fresh again');
      expect(utf8.decode(await cache.get(host, '/w/f.md', fetch: source(calls, 'v3'), force: true)), 'v3');
      expect(calls, ['v1', 'v2', 'v3']);
    });

    test('staleness compares host times only: a host clock minutes ahead refetches nothing', () async {
      final c = memory();
      addTearDown(c.close);
      final cache = MediaCache(c);
      final calls = <String>[];
      final ahead = DateTime.now().toUtc().add(const Duration(minutes: 5));
      await c.restart('h', 'r1/lead', '/a');
      await c.append('h', 'r1/lead', '/a', 0, 1, false,
          [toolUse('e', 'Edit', {'file_path': '/w/f.md'}, at: ahead.toIso8601String())]);
      for (var i = 0; i < 3; i++) {
        await cache.get(host, '/w/f.md', fetch: source(calls, 'v$i'));
      }
      expect(calls, ['v0'], reason: 'the mention is not newer than itself');
      await c.append('h', 'r1/lead', '/a', 1, 2, false,
          [toolUse('f', 'Edit', {'file_path': '/w/f.md'}, at: ahead.add(const Duration(seconds: 1)).toIso8601String())]);
      await cache.get(host, '/w/f.md', fetch: source(calls, 'v9'));
      expect(calls, ['v0', 'v9'], reason: 'a newer host-time mention is stale even though the phone clock is far behind');
    });

    test('downloaded media does not count against the chat budget', () async {
      final c = memory(total: 1 << 20);
      addTearDown(c.close);
      final cache = MediaCache(c);
      await cache.get(host, '/w/big.png', fetch: () async => Uint8List(2 << 20));
      await c.restart('h', 'r1/a', '/a');
      await c.append('h', 'r1/a', '/a', 0, 1, false, [toolUse('a', 'Edit', {'file_path': '/w/a'})]);
      await c.restart('h', 'r1/b', '/b');
      await c.append('h', 'r1/b', '/b', 0, 1, false, [toolUse('b', 'Edit', {'file_path': '/w/b'})]);
      expect(await c.load('h', 'r1/a'), isNotNull, reason: 'the chat stays');
    });

    test('a failed fetch stores nothing, and a purged file is fetched again', () async {
      final c = memory();
      addTearDown(c.close);
      final cache = MediaCache(c);
      await expectLater(cache.get(host, '/w/x', fetch: () async => throw StateError('offline')), throwsStateError);
      expect(await c.select(c.mediaFiles).get(), isEmpty);

      final calls = <String>[];
      await cache.get(host, '/w/x', fetch: source(calls, 'a'));
      for (final f in dir.listSync()) {
        f.deleteSync();
      }
      expect(utf8.decode(await cache.get(host, '/w/x', fetch: source(calls, 'b'))), 'b');
      expect(calls, ['a', 'b']);
    });

    test('over the budget the least recently opened go; a huge file is shown but not kept', () async {
      final c = memory();
      addTearDown(c.close);
      final cache = MediaCache(c, maxBytes: 25, maxFileBytes: 20);
      final calls = <String>[];
      await cache.get(host, '/old', fetch: source(calls, 'x' * 10));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await cache.get(host, '/mid', fetch: source(calls, 'y' * 10));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await cache.get(host, '/new', fetch: source(calls, 'z' * 10));
      expect((await c.select(c.mediaFiles).get()).map((r) => r.path), unorderedEquals(['/mid', '/new']));
      expect(dir.listSync().where((f) => f.path.endsWith('.part')), isEmpty);

      expect((await cache.get(host, '/big', fetch: source(calls, 'b' * 30))).length, 30);
      expect((await c.select(c.mediaFiles).get()).map((r) => r.path), isNot(contains('/big')));
    });

    test('forgetHost and clear remove the files too, and the usage counts them', () async {
      final c = memory();
      addTearDown(c.close);
      final cache = MediaCache(c);
      await cache.get(host, '/w/a', fetch: source([], 'hello'));
      expect((await c.watchUsage().first).$1, 5);
      expect(dir.listSync(), hasLength(1));
      await c.forgetHost('h');
      expect(dir.listSync(), isEmpty);
      await cache.get(host, '/w/a', fetch: source([], 'hello'));
      await c.clear();
      expect(dir.listSync(), isEmpty);
      expect((await c.watchUsage().first).$1, 0);
    });
  });
}
