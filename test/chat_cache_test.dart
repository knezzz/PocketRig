import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/chat/session_log.dart';
import 'package:pocket_rig/chat/transcript.dart';
import 'package:pocket_rig/data/chat_cache.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/chat_screen.dart';

import 'golden/fixtures.dart';

ChatCache memory({int chat = 1000000, int total = 1000000}) =>
    ChatCache(NativeDatabase.memory(), maxChatBytes: chat, maxTotalBytes: total);

/// A cache whose media list is a plain empty stream: the phone chat's panels strip watches it, and drift's live query leaves
/// timers that a widget test's clock can't drain.
class _QuietMedia extends ChatCache {
  _QuietMedia() : super(NativeDatabase.memory(), maxChatBytes: 1000000, maxTotalBytes: 1000000);
  @override
  Stream<List<RigMedia>> watchChatMedia(String hostId, String key) => Stream.value(const []);
}

String use(String id, Map<String, Object?> input, {String name = 'Read'}) => jsonEncode({
      'type': 'assistant',
      'uuid': 'u$id',
      'cwd': '/w',
      'costUSD': 1,
      'message': {
        'id': 'm$id',
        'usage': {'input_tokens': 1},
        'content': [
          {'type': 'thinking', 'thinking': 'x' * 5000},
          {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
        ],
      },
    });

String result(String id, Object? content) => jsonEncode({
      'type': 'user',
      'uuid': 'r$id',
      'toolUseResult': {'stdout': 'x' * 5000},
      'message': {
        'content': [
          {'type': 'tool_result', 'tool_use_id': id, 'content': content},
        ],
      },
    });

Seat seat(String rig, String id, {String? status}) => Seat(rigId: rig, logicalId: id, rawSessionStatus: status);

RigWithSeats rig(String id, List<Seat> seats, {String status = 'running'}) =>
    RigWithSeats(Rig.fromJson({'rigId': id, 'name': id, 'status': status}), seats);

void main() {
  group('slimLogLine', () {
    test('a slim log reads the same, smaller', () {
      final log = [
        jsonEncode({
          'type': 'user',
          'uuid': 'a',
          'cwd': '/w',
          'gitBranch': 'main',
          'message': {
            'content': [
              {'type': 'text', 'text': 'look'},
              {
                'type': 'image',
                'source': {'data': 'A' * 100000}
              },
            ]
          },
        }),
        use('t1', {'file_path': '/w/a.dart'}),
        result('t1', 'short'),
        jsonEncode({
          'type': 'assistant',
          'uuid': 'b',
          'message': {
            'id': 'm9',
            'content': [
              {'type': 'text', 'text': 'y' * 9000}
            ]
          },
        }),
        jsonEncode({'type': 'system', 'uuid': 'c', 'content': 'Compacted', 'level': 'info'}),
      ];
      final slim = log.map(slimLogLine).toList();
      final a = ChatTranscript()..addAll(log), b = ChatTranscript()..addAll(slim);

      expect(utf8.encode(slim.join()).length, lessThan(utf8.encode(log.join()).length ~/ 5));
      expect(b.items.map((i) => i.runtimeType), a.items.map((i) => i.runtimeType));
      expect(b.cwd, '/w');
      expect(b.gitBranch, 'main');
      expect((b.items[0] as UserMessage).text, 'look');
      expect((b.items[1] as ToolCall).result, 'short');
      expect((b.items[1] as ToolCall).clipped, isFalse);
      expect((b.items[2] as AssistantMessage).text, hasLength(9000), reason: 'what was said stays whole');
      expect(slim.join(), isNot(contains('thinking')));
      expect(slim.join(), isNot(contains('AAAA')));
    });

    test('long tool text is cut and marked, and the summary still tells the truth', () {
      final big = List.generate(500, (i) => 'line $i').join('\n');
      final t = ChatTranscript()
        ..addAll([
          use('t', {'file_path': '/w/a.dart', 'content': 'c' * 5000}, name: 'Write'),
          use('r', {'file_path': '/w/b.dart'}),
          result('r', big),
          use('i', {'file_path': '/w/c.png'}),
          result('i', [
            {'type': 'text', 'text': 'small'},
            {
              'type': 'image',
              'source': {'data': 'B' * 90000}
            },
          ]),
        ].map(slimLogLine));
      final calls = t.items.whereType<ToolCall>().toList();
      expect(calls[0].clipped, isTrue);
      expect(calls[0].writtenPath, '/w/a.dart');
      expect(calls[0].changes, (1, 0));
      expect((calls[0].input['content'] as String).length, lessThan(500));
      expect(calls[1].clipped, isTrue);
      expect(calls[1].result!.length, lessThan(500));
      expect(calls[1].shortResult, '500 lines');
      expect(calls[2].clipped, isFalse);
      expect(calls[2].result, 'small\n[image]');
    });

    test('edits count the lines they changed, even when the cache cut them', () {
      expect(lineChanges('Edit', {'old_string': 'a\nb\nc', 'new_string': 'a\nB\nc\nd\n'}), (2, 1));
      expect(lineChanges('Edit', {'old_string': '', 'new_string': 'a'}), (1, 0));
      expect(lineChanges('Write', {'content': 'a\nb\n'}), (2, 0));
      expect(
          lineChanges('MultiEdit', {
            'edits': [
              {'old_string': 'a', 'new_string': 'b'},
              {'old_string': 'c', 'new_string': ''},
            ]
          }),
          (1, 2));
      expect(lineChanges('Read', {'file_path': '/a'}), isNull);

      final big = List.generate(600, (i) => 'line $i').join('\n');
      final t = ChatTranscript()
        ..addAll([
          use('e', {'file_path': '/w/a.dart', 'old_string': 'old', 'new_string': big}, name: 'Edit'),
        ].map(slimLogLine));
      final call = t.items.whereType<ToolCall>().single;
      expect(call.clipped, isTrue);
      expect(call.changes, (600, 1));
    });

    test('the full call comes back from the log', () async {
      SshExec.debugConnect = (_) async => SshExec.fake((cmd) async {
            expect(cmd, contains("grep -F -- 'r' '/x.jsonl'"));
            return '${use('r', {'file_path': '/w/b.dart'})}\n${result('r', 'all of it')}\n';
          });
      addTearDown(() => SshExec.debugConnect = null);
      final full = await fetchToolCall(Host(id: 'h', name: 'h', address: 'h', sshUser: 'u'), '/x.jsonl', 'r');
      expect(full?.result, 'all of it');
      expect(full?.clipped, isFalse);
    });
  });

  group('ChatCache', () {
    test('round trip, in order, and a new log starts over', () async {
      final c = memory();
      addTearDown(c.close);
      expect(await c.load('h', 'k'), isNull);
      await c.restart('h', 'k', '/a.jsonl');
      expect(await c.append('h', 'k', '/a.jsonl', 0, 10, false, ['one', 'two']), isTrue);
      expect(await c.append('h', 'k', '/a.jsonl', 10, 20, true, ['three']), isTrue);
      final got = (await c.load('h', 'k'))!;
      expect(got.lines, ['one', 'two', 'three']);
      expect((got.path, got.offset, got.truncated), ('/a.jsonl', 20, true));

      await c.restart('h', 'k', '/b.jsonl');
      final fresh = (await c.load('h', 'k'))!;
      expect((fresh.path, fresh.offset), ('/b.jsonl', 0));
      expect(fresh.lines, isEmpty);
    });

    test('a chat over its budget loses its oldest lines and says so', () async {
      final c = memory(chat: 1000);
      addTearDown(c.close);
      await c.restart('h', 'k', '/a');
      await c.append('h', 'k', '/a', 0, 1, false, [for (var i = 0; i < 11; i++) '$i'.padRight(100, '-')]);
      final got = (await c.load('h', 'k'))!;
      expect(got.truncated, isTrue);
      expect(got.lines.length, lessThanOrEqualTo(8));
      expect(got.lines.last, startsWith('10'));
      expect(got.offset, 1);
    });

    test('over the total budget, the chats opened longest ago go first', () async {
      final c = memory(chat: 1000, total: 1500);
      addTearDown(c.close);
      for (final k in ['old', 'mid', 'new']) {
        await c.restart('h', k, '/$k');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await c.append('h', k, '/$k', 0, 1, false, ['x' * 700]);
      }
      expect(await c.load('h', 'old'), isNull);
      expect(await c.load('h', 'mid'), isNotNull);
      expect(await c.load('h', 'new'), isNotNull);
      expect(await c.watchUsage().first, (1400, 2));
    });

    test('a write after the chat was deleted does not bring it back', () async {
      final c = memory();
      addTearDown(c.close);
      await c.restart('h', 'k', '/a');
      await c.clear();
      expect(await c.append('h', 'k', '/a', 0, 5, false, ['late']), isFalse);
      expect(await c.load('h', 'k'), isNull);
      expect(await c.watchUsage().first, (0, 0));
    });

    test('prune and forgetHost stay on their host', () async {
      final c = memory();
      addTearDown(c.close);
      for (final (h, k) in [('h1', 'r/gone'), ('h2', 'r/gone'), ('h1', 'loose/x')]) {
        await c.restart(h, k, '/a');
      }
      await c.prune('h1', [rig('r', [seat('r', 'other')])], null);
      expect(await c.load('h1', 'r/gone'), isNull);
      expect(await c.load('h1', 'loose/x'), isNotNull);
      expect(await c.load('h2', 'r/gone'), isNotNull);
      await c.forgetHost('h2');
      expect(await c.load('h2', 'r/gone'), isNull);
    });
  });

  group('goneChats', () {
    final keys = ['r1/live', 'r1/stopped', 'r1/removed', 'r2/a', 'r3/a', 'r4/a', 'loose/tmux1', 'loose/tmux2'];

    test('an agent that left or lost its rig is gone, a stopped one stays', () {
      final gone = goneChats(
        keys,
        [
          rig('r1', [seat('r1', 'live'), seat('r1', 'stopped', status: 'stopped')]),
          rig('r3', [], status: 'stopped'),
          rig('r4', []),
        ],
        [LooseAgent(id: 'tmux1')],
      );
      expect(gone, ['r1/removed', 'r2/a', 'loose/tmux2']);
    });

    test('what the host could not vouch for stays', () {
      final gone = goneChats(['r4/a', 'loose/tmux1'], [rig('r4', [])], null);
      expect(gone, isEmpty, reason: 'seat lookup failed for a running rig; loose list incomplete');
    });

    test('a loose agent is filed where the list finds it', () {
      final inTmux = LooseAgent(id: 't', tmuxSession: 't', claudeSessionId: 's');
      final tab = LooseAgent(id: 's', claudeSessionId: 's');
      expect(chatKey(inTmux.toSeat()), 'loose/t');
      expect(chatKey(tab.toSeat()), 'loose/s');
      expect(goneChats([chatKey(inTmux.toSeat()), chatKey(tab.toSeat())], [], [inTmux, tab]), isEmpty);
    });
  });

  test('the resume point never splits a line', () {
    final tail = SessionLogTail(Host(id: 'h', name: 'h', address: 'h', sshUser: 'u'), '/x');
    tail.feed(Uint8List.fromList(utf8.encode('one\ntw')));
    expect(tail.committedOffset, 4);
    tail.feed(Uint8List.fromList(utf8.encode('o\n')));
    expect(tail.committedOffset, 8);
  });

  group('opening a chat', () {
    late ChatCache cache;
    setUp(() async {
      cache = _QuietMedia();
      chatCache = cache;
    });
    tearDown(() async {
      chatCache = null;
      SshExec.debugConnect = null;
      await cache.close();
    });

    Seat lead() => seatFromFixture('r-conveyor', 'lead');

    testWidgets('shows the saved chat while the host is unreachable', (tester) async {
      final store = await installFakes();
      await tester.runAsync(() async {
        await cache.restart(store.active!.id, chatKey(lead()), '/log.jsonl');
        await cache.append(store.active!.id, chatKey(lead()), '/log.jsonl', 0, 100, false, [
          jsonEncode({
            'type': 'user',
            'uuid': 'saved',
            'message': {'content': 'from the cache'}
          })
        ]);
      });
      SshExec.debugConnect = (_) async => throw StateError('no route to host');

      await tester.pumpWidget(MaterialApp(home: phone(store, ChatScreen(rigName: 'conveyor', seat: lead(), asChat: true))));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      await tester.pump();

      expect(find.text('from the cache'), findsOneWidget);
      expect(find.textContaining('offline'), findsOneWidget);
      expect(find.textContaining('Couldn\'t open'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a saved chat from another log is replaced', (tester) async {
      final store = await installFakes();
      await tester.runAsync(() async {
        await cache.restart(store.active!.id, chatKey(lead()), '/older-session.jsonl');
        await cache.append(store.active!.id, chatKey(lead()), '/older-session.jsonl', 0, 100, false, [
          jsonEncode({
            'type': 'user',
            'uuid': 'saved',
            'message': {'content': 'from the old session'}
          })
        ]);
      });
      final gate = Completer<void>();
      final real = SshExec.debugConnect!;
      SshExec.debugConnect = (h) async {
        await gate.future;
        return real(h);
      };

      await tester.pumpWidget(MaterialApp(home: phone(store, ChatScreen(rigName: 'conveyor', seat: lead(), asChat: true))));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(find.text('from the old session'), findsOneWidget);

      gate.complete();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('from the old session'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
