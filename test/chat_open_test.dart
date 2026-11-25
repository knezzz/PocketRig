import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/chat/media_index.dart';
import 'package:pocket_rig/chat/session_log.dart';
import 'package:pocket_rig/data/chat_cache.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/chat_screen.dart';

import 'golden/fixtures.dart';

const _log = '/Users/me/.claude/projects/-Users-me-code-app/sess-lead.jsonl';

String _user(String id, String text) => jsonEncode({
      'type': 'user',
      'uuid': id,
      'message': {'content': text}
    });

/// Answers `load` with a canned chat and notes whether the screen had claimed
/// the chat by then.
class _Cache extends ChatCache {
  _Cache(this.canned) : super(NativeDatabase.memory());
  final CachedChat? canned;
  bool? claimedOnLoad;
  final appended = <({int from, bool truncated, List<String> lines})>[];
  final earlier = <LogIndex?>[];
  @override
  Future<bool> append(String hostId, String key, String path, int fromOffset, int toOffset, bool truncated, List<String> lines,
      {bool seed = false, LogIndex? earlier}) {
    if (!seed) this.earlier.add(earlier);
    if (!seed) appended.add((from: fromOffset, truncated: truncated, lines: List.of(lines)));
    return super.append(hostId, key, path, fromOffset, toOffset, truncated, lines, seed: seed, earlier: earlier);
  }
  @override
  Future<CachedChat?> load(String hostId, String key) async {
    claimedOnLoad = openChatKeys.contains(openKey(hostId, key));
    return canned;
  }
}

/// A tail that waits for [gate], then replays [chatLog]; tests feed more later.
class _GatedTail extends SessionLogTail {
  _GatedTail(super.host, super.path);
  static var gate = Completer<void>();
  static _GatedTail? last;
  @override
  Future<void> start() async {
    last = this;
    await gate.future;
    reportStatus('live');
    feed(Uint8List.fromList(utf8.encode('${chatLog.join('\n')}\n')));
  }
}

void main() {
  late _Cache cache;
  tearDown(() async {
    chatFreshCap = 4 << 20;
    chatCache = null;
    SshExec.debugConnect = null;
    await cache.close();
  });

  Seat lead() => seatFromFixture('r-conveyor', 'lead');

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('the screen claims its chat before it loads the cache, and lets go on dispose', (tester) async {
    cache = _Cache(null);
    chatCache = cache;
    final store = await installFakes();
    await tester.pumpWidget(MaterialApp(home: phone(store, ChatScreen(rigName: 'conveyor', seat: lead(), asChat: true))));
    await settle(tester);
    expect(cache.claimedOnLoad, isTrue);
    expect(openChatKeys, contains(openKey(store.active!.id, chatKey(lead()))));

    await tester.pumpWidget(const SizedBox.shrink());
    expect(openChatKeys, isEmpty);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a seeded chat paints first, then the full read replaces it', (tester) async {
    cache = _Cache(CachedChat(_log, 5, false, [_user('seed', 'only in the seed')], seeded: true));
    chatCache = cache;
    final store = await installFakes();
    extraChatLog = [
      {'type': 'user', 'uuid': 'nw', 'message': {'content': 'newest of the full read'}},
    ];
    _GatedTail.gate = Completer<void>();
    SessionLogTail.factory = (h, p) => _GatedTail(h, p);
    await tester.pumpWidget(MaterialApp(home: phone(store, ChatScreen(rigName: 'conveyor', seat: lead(), asChat: true))));
    await settle(tester);
    expect(find.text('only in the seed', findRichText: true), findsOneWidget);

    _GatedTail.gate.complete();
    await settle(tester);
    await settle(tester);
    expect(find.text('only in the seed', findRichText: true), findsNothing);
    // Scroll up to the message (the outer, vertical list; tool rows scroll sideways inside it).
    await tester.scrollUntilVisible(find.text('newest of the full read', findRichText: true), 100,
        scrollable: find.descendant(of: find.byWidgetPredicate((w) => w is ListView && w.reverse), matching: find.byType(Scrollable)).first);
    expect(find.text('newest of the full read', findRichText: true), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a log shorter than the seed still replaces it once the read goes quiet', (tester) async {
    cache = _Cache(CachedChat(_log, 999999999, false, [_user('seed', 'only in the seed')], seeded: true));
    chatCache = cache;
    final store = await installFakes();
    _GatedTail.gate = Completer<void>()..complete();
    SessionLogTail.factory = (h, p) => _GatedTail(h, p);
    await tester.pumpWidget(MaterialApp(home: phone(store, ChatScreen(rigName: 'conveyor', seat: lead(), asChat: true))));
    await settle(tester);
    expect(find.text('only in the seed', findRichText: true), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
    expect(find.text('only in the seed', findRichText: true), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the full read keeps only the newest lines for the cache and marks it truncated', (tester) async {
    cache = _Cache(CachedChat(_log, 5, false, [_user('seed', 'only in the seed')], seeded: true));
    chatCache = cache;
    final store = await installFakes();
    chatFreshCap = 1500;
    extraChatLog = [
      for (var i = 0; i < 60; i++) {'type': 'user', 'uuid': 'x$i', 'message': {'content': 'filler number $i'}},
    ];
    _GatedTail.gate = Completer<void>()..complete();
    SessionLogTail.factory = (h, p) => _GatedTail(h, p);
    await tester.pumpWidget(MaterialApp(home: phone(store, ChatScreen(rigName: 'conveyor', seat: lead(), asChat: true))));
    await settle(tester);
    await settle(tester);
    await settle(tester);

    expect(cache.appended, isNotEmpty);
    final first = cache.appended.first;
    expect(first.from, 0);
    expect(first.truncated, isTrue);
    final bytes = first.lines.fold<int>(0, (a, l) => a + l.length);
    expect(bytes, lessThanOrEqualTo(1500 * 3 ~/ 2));
    expect(first.lines.last, contains('filler number 59'));
    expect(first.lines.any((l) => l.contains('filler number 0"')), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('media named only in the dropped older lines is still indexed', (tester) async {
    cache = _Cache(CachedChat(_log, 5, false, [_user('seed', 'only in the seed')], seeded: true));
    chatCache = cache;
    final store = await installFakes();
    chatFreshCap = 1500;
    extraChatLog = [
      {
        'type': 'assistant',
        'uuid': 'early',
        'timestamp': '2026-11-07T10:00:00Z',
        'message': {
          'content': [
            {'type': 'text', 'text': 'saved the chart to /tmp/early-chart.png'},
          ],
        },
      },
      for (var i = 0; i < 60; i++) {'type': 'user', 'uuid': 'x$i', 'message': {'content': 'filler number $i'}},
    ];
    _GatedTail.gate = Completer<void>()..complete();
    SessionLogTail.factory = (h, p) => _GatedTail(h, p);
    await tester.pumpWidget(MaterialApp(home: phone(store, ChatScreen(rigName: 'conveyor', seat: lead(), asChat: true))));
    await settle(tester);
    await settle(tester);
    await settle(tester);

    expect(cache.appended.expand((a) => a.lines).join('\n'), isNot(contains('early-chart')), reason: 'cut from the saved lines');
    final dropped = cache.earlier.whereType<LogIndex>().expand((i) => i.hits).map((h) => h.ref);
    expect(dropped, contains('/tmp/early-chart.png'));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('two screens on one chat: closing the top one keeps the chat claimed', (tester) async {
    cache = _Cache(null);
    chatCache = cache;
    final store = await installFakes();
    await tester.pumpWidget(MaterialApp(home: phone(store, ChatScreen(rigName: 'conveyor', seat: lead(), asChat: true))));
    await settle(tester);
    final key = openKey(store.active!.id, chatKey(lead()));
    final nav = Navigator.of(tester.element(find.byType(ChatScreen)));
    nav.push(MaterialPageRoute<void>(builder: (_) => phone(store, ChatScreen(rigName: 'conveyor', seat: lead(), asChat: true))));
    await settle(tester);
    await settle(tester);
    expect(openChatKeys.where((k) => k == key).length, 2);

    nav.pop();
    await settle(tester);
    expect(openChatKeys, contains(key));

    await tester.pumpWidget(const SizedBox.shrink());
    expect(openChatKeys, isEmpty);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a screen that retries opening still holds its chat once, and one dispose lets go', (tester) async {
    cache = _Cache(null);
    chatCache = cache;
    final store = await installFakes();
    SshExec.debugConnect = (h) async => SshExec.fake((c) async => ''); // no log yet: the screen polls
    await tester.pumpWidget(MaterialApp(home: phone(store, ChatScreen(rigName: 'conveyor', seat: lead(), waitForLog: true, asChat: true))));
    await settle(tester);
    final key = openKey(store.active!.id, chatKey(lead()));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 3));
      await settle(tester);
    }
    expect(openChatKeys.where((k) => k == key).length, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(openChatKeys, isEmpty);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a log that is rewound during the seed window is not mixed with the old one', (tester) async {
    cache = _Cache(CachedChat(_log, 999999999, false, [_user('seed', 'only in the seed')], seeded: true));
    chatCache = cache;
    final store = await installFakes();
    _GatedTail.gate = Completer<void>()..complete();
    SessionLogTail.factory = (h, p) => _GatedTail(h, p);
    await tester.pumpWidget(MaterialApp(home: phone(store, ChatScreen(rigName: 'conveyor', seat: lead(), asChat: true))));
    await settle(tester);
    await tester.runAsync(() async {
      final live = _GatedTail.last!;
      live.feed(Uint8List.fromList(utf8.encode('${_user('old', 'from the old log')}\n')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 300));
    _GatedTail.last!.onRewound!();
    await tester.runAsync(() async {
      _GatedTail.last!.feed(Uint8List.fromList(utf8.encode('${_user('new', 'from the new log')}\n')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);

    await tester.scrollUntilVisible(find.text('from the new log', findRichText: true), 100,
        scrollable: find.descendant(of: find.byWidgetPredicate((w) => w is ListView && w.reverse), matching: find.byType(Scrollable)).first);
    expect(find.text('from the new log', findRichText: true), findsOneWidget);
    expect(find.text('from the old log', findRichText: true), findsNothing);
    expect(find.text('only in the seed', findRichText: true), findsNothing);
    final saved = cache.appended.expand((a) => a.lines).join('\n');
    expect(saved, contains('from the new log'));
    expect(saved, isNot(contains('from the old log')));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the swap holds the reading position when the full read has rows past the seed', (tester) async {
    final seedLines = [for (var i = 0; i < 30; i++) _user('x$i', 'filler $i')];
    cache = _Cache(CachedChat(_log, 5, false, seedLines, seeded: true));
    chatCache = cache;
    final store = await installFakes();
    extraChatLog = [
      for (var i = 0; i < 30; i++) {'type': 'user', 'uuid': 'x$i', 'message': {'content': 'filler $i'}},
      for (var i = 0; i < 4; i++) {'type': 'user', 'uuid': 'n$i', 'message': {'content': 'newer $i\nsecond line\nthird line'}},
    ];
    _GatedTail.gate = Completer<void>();
    SessionLogTail.factory = (h, p) => _GatedTail(h, p);
    await tester.pumpWidget(MaterialApp(home: phone(store, ChatScreen(rigName: 'conveyor', seat: lead(), asChat: true))));
    await settle(tester);
    final chatList = find.byWidgetPredicate((w) => w is ListView && w.reverse);
    await tester.drag(chatList, const Offset(0, 400));
    await tester.pump(const Duration(seconds: 1));
    final text = [for (var i = 0; i < 30; i++) 'filler $i']
        .firstWhere((t) => find.text(t, findRichText: true).evaluate().isNotEmpty);
    final y = tester.getTopLeft(find.text(text, findRichText: true)).dy;

    _GatedTail.gate.complete();
    await settle(tester);
    await settle(tester);

    final moved = find.text(text, findRichText: true);
    expect(moved, findsOneWidget);
    expect(tester.getTopLeft(moved).dy, y);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a message that arrives while scrolled up does not move the page', (tester) async {
    cache = _Cache(null);
    chatCache = cache;
    final store = await installFakes();
    extraChatLog = [
      for (var i = 0; i < 30; i++) {'type': 'user', 'uuid': 'x$i', 'message': {'content': 'filler $i'}},
    ];
    _GatedTail.gate = Completer<void>()..complete();
    SessionLogTail.factory = (h, p) => _GatedTail(h, p);
    await tester.pumpWidget(MaterialApp(home: phone(store, ChatScreen(rigName: 'conveyor', seat: lead(), asChat: true))));
    await settle(tester);
    final chatList = find.byWidgetPredicate((w) => w is ListView && w.reverse);
    await tester.drag(chatList, const Offset(0, 300));
    await tester.pump();
    final text = [for (var i = 0; i < 30; i++) 'filler $i']
        .firstWhere((t) => find.text(t, findRichText: true).evaluate().isNotEmpty);
    final y = tester.getTopLeft(find.text(text, findRichText: true)).dy;

    // The tail's own offset keeps counting; feeding it appends a line to the chat.
    await tester.runAsync(() async {
      final live = _GatedTail.last!;
      live.feed(Uint8List.fromList(utf8.encode('${_user('late', 'a late message\nwith a second line\nand a third')}\n')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    final moved = find.text(text, findRichText: true);
    expect(moved, findsOneWidget);
    expect(tester.getTopLeft(moved).dy, y);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });
}
