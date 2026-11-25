import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/chat_cache.dart';
import 'package:pocket_rig/data/chat_sync.dart';
import 'package:pocket_rig/models.dart';

late Directory dir;
late ChatCache db;
final host = Host(id: 'h', name: 'h', address: 'h', sshUser: 'u', privateKeyPem: 'k');

/// The generated command, run by a real /bin/sh, as the host would.
Future<Uint8List> sh(String script) async =>
    Uint8List.fromList((await Process.run('/bin/sh', ['-c', script], stdoutEncoding: null)).stdout as List<int>);

String line(int i, [String pad = '']) => jsonEncode({
      'type': 'user',
      'uuid': 'u$i',
      'timestamp': '2026-11-07T10:00:00.000Z',
      'message': {'content': 'message $i$pad'},
    });

File log(String name, Iterable<String> lines, {bool endNewline = true}) =>
    File('${dir.path}/$name.jsonl')..writeAsStringSync(lines.join('\n') + (endNewline ? '\n' : ''));

Seat seat(String name) => Seat(
    rigId: 'r1', logicalId: name, runtime: 'claude-code', transcriptPath: '${dir.path}/$name.jsonl', sessionName: name);

ChatSync sync(List<String> names, {List<(String, List<String>)>? saw}) => ChatSync(
      host: () => host,
      seats: () => [for (final n in names) seat(n)],
      cache: db,
      exec: sh,
      onLines: (k, l) => saw?.add((k, l)),
    );

void main() {
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chat-sync-test');
    db = ChatCache(NativeDatabase.memory(), mediaDir: () async => dir);
    openChatKeys.clear();
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('a new chat is seeded, then only what is new comes next', () async {
    final f = log('a', [for (var i = 0; i < 5; i++) line(i)]);
    final saw = <(String, List<String>)>[];
    final s = sync(['a'], saw: saw);
    await s.cycle();
    var got = (await db.load('h', 'r1/a'))!;
    expect(got.lines, hasLength(5));
    expect((got.seeded, got.truncated, got.offset), (true, false, f.lengthSync()));
    expect(saw.single.$1, 'r1/a');

    f.writeAsStringSync('${line(5)}\n${line(6)}\n', mode: FileMode.append);
    await s.cycle();
    got = (await db.load('h', 'r1/a'))!;
    expect(got.lines, hasLength(7));
    expect(got.offset, f.lengthSync());

    await s.cycle();
    expect((await db.load('h', 'r1/a'))!.lines, hasLength(7), reason: 'nothing new, nothing duplicated');
  });

  test('a half-written line waits for its newline', () async {
    final f = log('a', [line(0), line(1)], endNewline: false);
    final s = sync(['a']);
    await s.cycle();
    expect((await db.load('h', 'r1/a'))!.lines, hasLength(1));
    f.writeAsStringSync('\n${line(2)}\n', mode: FileMode.append);
    await s.cycle();
    expect((await db.load('h', 'r1/a'))!.lines.map((l) => jsonDecode(l)['uuid']), ['u0', 'u1', 'u2']);
  });

  test('a big log is seeded from its last megabyte, on a whole line, marked truncated', () async {
    final f = log('a', [for (var i = 0; i < 40; i++) line(i, 'x' * 40000)]);
    expect(f.lengthSync(), greaterThan(1 << 20));
    await sync(['a']).cycle();
    final got = (await db.load('h', 'r1/a'))!;
    expect(got.truncated, isTrue);
    expect(got.lines.length, inInclusiveRange(20, 40));
    for (final l in got.lines) {
      expect(() => jsonDecode(l), returnsNormally, reason: 'every stored line is whole');
    }
    expect(jsonDecode(got.lines.last)['uuid'], 'u39');
    expect(got.offset, f.lengthSync());
  });

  test('a log that got shorter, or another log, starts the chat over', () async {
    final f = log('a', [for (var i = 0; i < 6; i++) line(i)]);
    final s = sync(['a']);
    await s.cycle();
    f.writeAsStringSync('${line(100)}\n');
    await s.cycle();
    expect((await db.load('h', 'r1/a'))!.lines.map((l) => jsonDecode(l)['uuid']), ['u100']);
  });

  test('a chat a screen has open is left alone', () async {
    log('a', [line(0)]);
    log('b', [line(0)]);
    openChatKeys.add(openKey('h', 'r1/a'));
    await sync(['a', 'b']).cycle();
    expect(await db.load('h', 'r1/a'), isNull);
    expect(await db.load('h', 'r1/b'), isNotNull);
  });

  test('one line longer than a read still gets through, and a missing log is skipped', () async {
    final f = log('a', [line(0, 'y' * (300 << 10)), line(1)]);
    final s = sync(['a', 'gone']);
    await s.cycle(); // seeds the whole small log: the long line fits the 1 MB seed
    expect((await db.load('h', 'r1/a'))!.lines, hasLength(2));
    f.writeAsStringSync('${line(2, 'z' * (600 << 10))}\n', mode: FileMode.append);
    for (var i = 0; i < 4; i++) {
      await s.cycle(); // 256 KB, 512 KB, 1 MB reads until the line is whole
    }
    expect((await db.load('h', 'r1/a'))!.lines, hasLength(3));
    expect(await db.load('h', 'r1/gone'), isNull);
  });

  test('the parser follows lengths, not lines, and skips noise', () {
    final body = utf8.encode('{"a":"@@pr-log 9 9 9 9 S x"}');
    final out = BytesBuilder()
      ..add(utf8.encode('Welcome banner\n@@pr-log 0 99 5 ${body.length} D /a b.jsonl\n'))
      ..add(body)
      ..add(utf8.encode('\n@@end\n'))
      ..add(utf8.encode('@@pr-log 1 3 0 0 S /c.jsonl\n\n@@end\n'));
    final chunks = parseSyncOutput(out.toBytes());
    expect(chunks.map((c) => (c.index, c.from, c.seed, c.path)), [(0, 5, false, '/a b.jsonl'), (1, 0, true, '/c.jsonl')]);
    expect(utf8.decode(chunks.first.bytes), utf8.decode(body));
    expect(parseSyncOutput(Uint8List.fromList(utf8.encode('@@pr-log 0 9 0 50 D /x\nshort\n'))), isEmpty,
        reason: 'cut-off output is dropped');
  });

  test('a log ending in one line over the seed size still seeds, growing the read', () async {
    log('a', [line(0, 'q' * (1500 << 10))]);
    final s = sync(['a']);
    for (var i = 0; i < 3; i++) {
      await s.cycle(); // 1 MB, then 2 MB
    }
    expect((await db.load('h', 'r1/a'))!.lines, hasLength(1));
  });

  test('a short read is dropped, not mixed into the next chat', () {
    final out = utf8.encode('@@pr-log 0 9 0 10 D /a\nabc\n@@end\n@@pr-log 1 9 0 1 D /b\nx\n@@end\n');
    expect(parseSyncOutput(Uint8List.fromList(out)), isEmpty);
  });

  test('previews come from lines saved before: after a restart and after a screen closes', () async {
    final f = log('a', [line(0)]);
    await db.append('h', 'r1/a', f.path, 0, f.lengthSync(), false, [line(0)]);
    final previews = <String>[];
    final s = ChatSync(host: () => host, seats: () => [seat('a')], cache: db, exec: sh, onLines: (k, l) => previews.add(k));
    await s.cycle();
    expect(previews, ['r1/a']);
    await s.cycle();
    expect(previews, ['r1/a'], reason: 'nothing moved, nothing to preview again');
  });

  test('previews read the last lines without marking the chat opened', () async {
    log('a', [for (var i = 0; i < 5; i++) line(i)]);
    await sync(['a']).cycle(); // a seed: openedAt 0, first to be evicted
    final last = await db.lastLines('h', 'r1/a', 2);
    expect(last.map((l) => jsonDecode(l)['uuid']), ['u3', 'u4']);
    expect((await db.select(db.chats).getSingle()).openedAt, 0);
  });

  test('failures back off from 10 s to 5 minutes', () async {
    final s = ChatSync(host: () => host, seats: () => [seat('a')], cache: db, exec: (_) async => throw StateError('x'));
    log('a', [line(0)]);
    await s.tick();
    expect(s.backoff, const Duration(seconds: 10));
    s.stop();
  });
}
