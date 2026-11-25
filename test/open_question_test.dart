import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/prompt_screen.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/rig/rig_room.dart' show broadcastToRig;
import 'package:pocket_rig/ui/send_guard.dart';

import 'golden/fixtures.dart';

const _question = '''
 ☐ Which retry policy?

Which retry policy should the router use?

❯ 1. Exponential backoff
  2. Fixed delay
  3. Type something.

Enter to select · ↑/↓ to navigate · Esc to cancel
''';
const _permission = '''
 Bash command

   npm run test:integration

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for npm run test:integration commands
   3. No, and tell Claude what to do differently (esc)
''';
const _idle = '''
╭──────────────────────────────────────────────╮
│ >                                            │
╰──────────────────────────────────────────────╯
  ? for shortcuts
''';

void main() {
  test('the screen detector: a question menu, a permission dialog and a trust prompt are open dialogs; an idle prompt and an empty screen are not', () {
    expect(dialogOnScreen(_question), isTrue);
    expect(dialogOnScreen(_permission), isTrue);
    expect(dialogOnScreen('Do you trust the files in this folder?\n  Press Enter to continue · Esc to cancel'), isTrue);
    expect(dialogOnScreen(_idle), isFalse);
    expect(dialogOnScreen(''), isFalse, reason: 'an empty screen proves nothing');
    expect(dialogOnScreen('   \n'), isFalse);
    // The two readings are opposites for any screen that has text.
    for (final s in [_question, _permission, _idle]) {
      expect(dialogOnScreen(s), !noDialogOnScreen(s));
    }
  });

  test('seatHasOpenQuestion: the daemon\'s needs-you counts, else the screen read over SSH; a failed read says no', () async {
    final store = await installFakes();
    await fleet.feedFor(homelab).refresh();
    final rig = fleet.feedFor(homelab).rigs.firstWhere((r) => r.rig.name == 'conveyor');
    Seat seat(String id) => rig.seats.firstWhere((s) => s.logicalId == id);
    expect(await seatHasOpenQuestion(homelab, seat('lead')), isTrue, reason: 'the daemon says lead needs a person');
    // review is a Claude seat the daemon calls clear here: only the screen can tell.
    final review = Seat.fromJson({'rigId': 'r', 'logicalId': 'x', 'canonicalSessionName': 'x@r', 'runtime': 'claude-code', 'sessionStatus': 'running'});
    final keyed = Host(id: 'k', name: 'k', address: 'a', sshUser: 'u', privateKeyPem: 'pem');
    var screen = _question;
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async => '@@screen\tx@r\n$screen');
    addTearDown(() => SshExec.debugConnect = null);
    expect(await seatHasOpenQuestion(keyed, review), isTrue, reason: 'its screen shows a question');
    screen = _idle;
    expect(await seatHasOpenQuestion(keyed, review), isFalse);
    SshExec.debugConnect = (h) async => throw Exception('no route');
    expect(await seatHasOpenQuestion(keyed, review), isFalse, reason: 'unreadable: the daemon\'s word stands');
    expect(store.hosts, isNotEmpty);
  });

  test('a seat the daemon says asks is never taken for clear when its screen can\'t be read (SSH failure, empty output, no key)', () async {
    await installFakes();
    final keyed = Host(id: 'k', name: 'k', address: 'a', sshUser: 'u', privateKeyPem: 'pem');
    Seat asking() => Seat.fromJson({
          'rigId': 'r',
          'logicalId': 'x',
          'canonicalSessionName': 'x@r',
          'runtime': 'claude-code',
          'sessionStatus': 'running',
          'activityState': {'activity': 'needs_input', 'display': 'needs input', 'needsInput': {'count': 1, 'reason': 'permission_prompt'}},
        })
          ..screenClear = true; // the fleet's read said clear, so needsInput is false: only a fresh read can say
    addTearDown(() => SshExec.debugConnect = null);
    expect(asking().needsInput, isFalse);
    expect(asking().daemonAsks, isTrue);
    SshExec.debugConnect = (h) async => throw Exception('no route');
    expect(await seatHasOpenQuestion(keyed, asking()), isTrue, reason: 'SSH failed');
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async => '');
    expect(await seatHasOpenQuestion(keyed, asking()), isTrue, reason: 'empty output');
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async => '@@screen\tx@r\n');
    expect(await seatHasOpenQuestion(keyed, asking()), isTrue, reason: 'an empty screen');
    expect(await seatHasOpenQuestion(Host(id: 'n', name: 'n', address: 'a', sshUser: 'u'), asking()), isTrue, reason: 'no key');
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async => '@@screen\tx@r\n$_idle');
    expect(await seatHasOpenQuestion(keyed, asking()), isFalse, reason: 'a screen that was read and shows no dialog');
  });

  test('the send guard needs a real dialog: a numbered list in the agent\'s output is not one; the watcher\'s rule is unchanged', () {
    const list = 'Plan:\n  1. Fix x\n  2. Fix y\n';
    expect(dialogOnScreen(list), isFalse);
    expect(noDialogOnScreen(list), isFalse, reason: 'the watcher still takes a list for a dialog');
    expect(dialogOnScreen('Pick one\n ❯ 1. Yes\n   2. No'), isTrue);
    expect(dialogOnScreen('Do you trust this folder?\n  Esc to cancel'), isTrue);
  });

  test('seatsWithOpenQuestion reads every seat\'s screen in one SSH call', () async {
    await installFakes();
    final keyed = Host(id: 'k', name: 'k', address: 'a', sshUser: 'u', privateKeyPem: 'pem');
    Seat seat(String id) => Seat.fromJson({'rigId': 'r', 'logicalId': id, 'canonicalSessionName': '$id@r', 'runtime': 'claude-code', 'sessionStatus': 'running'});
    final a = seat('a'), b = seat('b'), c = seat('c');
    var calls = 0;
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          calls++;
          return '@@screen\ta@r\n$_question@@screen\tb@r\n$_idle@@screen\tc@r\n$_permission';
        });
    addTearDown(() => SshExec.debugConnect = null);
    expect(await seatsWithOpenQuestion(keyed, [a, b, c]), {a, c});
    expect(calls, 1);
  });

  testWidgets('askBeforeSending cancels, not sends, when the page is gone after a question was found', (tester) async {
    await installFakes();
    final lead = Seat.fromJson({'rigId': 'r', 'logicalId': 'x', 'canonicalSessionName': 'x@r', 'runtime': 'claude-code', 'sessionStatus': 'running'});
    SendGuard? got;
    final gate = Completer<void>();
    SshExec.debugConnect = (h) async {
      await gate.future;
      return SshExec.fake((cmd) async => '@@screen\tx@r\n$_question');
    };
    homelab.privateKeyPem = 'pem';
    addTearDown(() {
      homelab.privateKeyPem = null;
      SshExec.debugConnect = null;
    });
    final shown = ValueNotifier(true);
    await tester.pumpWidget(MaterialApp(
        home: ValueListenableBuilder<bool>(
            valueListenable: shown,
            builder: (_, on, __) => on
                ? Builder(builder: (context) => TextButton(onPressed: () async => got = await askBeforeSending(context, homelab, lead), child: const Text('go')))
                : const SizedBox())));
    await tester.tap(find.text('go'));
    await tester.pump();
    shown.value = false;
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();
    expect(got, SendGuard.cancel);
  });

  testWidgets('askBeforeSending says the seat is showing a question and offers Answer in Chat and Send anyway; nothing open sends at once', (tester) async {
    await installFakes();
    await fleet.feedFor(homelab).refresh();
    final rig = fleet.feedFor(homelab).rigs.firstWhere((r) => r.rig.name == 'conveyor');
    final lead = rig.seats.firstWhere((s) => s.logicalId == 'lead');
    final tests = rig.seats.firstWhere((s) => s.logicalId == 'tests');
    final got = <SendGuard>[];
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Column(children: [
                  TextButton(onPressed: () async => got.add(await askBeforeSending(context, homelab, lead)), child: const Text('lead')),
                  TextButton(onPressed: () async => got.add(await askBeforeSending(context, homelab, tests)), child: const Text('tests')),
                  TextButton(onPressed: () async => got.add(await askBeforeSending(context, homelab, lead, inChat: true)), child: const Text('chat')),
                ]))));
    await tester.tap(find.text('tests'));
    await tester.pumpAndSettle();
    expect(got, [SendGuard.send], reason: 'nothing open: no sheet');
    await tester.tap(find.text('lead'));
    await tester.pumpAndSettle();
    expect(find.text('lead is showing a question'), findsOneWidget);
    expect(find.text('A message now would answer it.'), findsOneWidget);
    for (final b in ['Answer in Chat', 'Send anyway']) {
      expect(tester.getSize(find.ancestor(of: find.text(b), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)).first).height, 48, reason: '$b: a sheet button, like every other sheet\'s');
    }
    await tester.tap(find.text('Answer in Chat'));
    await tester.pumpAndSettle();
    expect(got.last, SendGuard.answer);
    await tester.tap(find.text('lead'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send anyway'));
    await tester.pumpAndSettle();
    expect(got.last, SendGuard.send);
    await tester.tap(find.text('chat'));
    await tester.pumpAndSettle();
    expect(find.text('Answer in Chat'), findsNothing, reason: 'in the chat the answer card is already there');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(got.last, SendGuard.cancel);
  });

  testWidgets('Message all sends to the seats that are free and names the ones showing a question', (tester) async {
    final store = await installFakes();
    final sent = <String>[];
    var broadcasts = 0;
    final inner = OpenRigClient.factory;
    OpenRigClient.factory = (h) => OpenRigClient(h,
        httpClient: MockClient((req) async {
          if (req.url.path == '/api/transport/send') {
            sent.add((jsonDecode(req.body) as Map)['session'] as String);
            return http.Response('{"ok": true}', 200);
          }
          if (req.url.path == '/api/transport/broadcast') {
            broadcasts++;
            return http.Response('{"results": []}', 200);
          }
          final copy = http.Request(req.method, req.url)
            ..headers.addAll(req.headers)
            ..bodyBytes = req.bodyBytes;
          return http.Response.fromStream(await fakeDaemon(h).send(copy));
        }),
        eventSource: ({rigId, replay, lastEventId}) => const Stream.empty());
    addTearDown(() => OpenRigClient.factory = inner);
    AppScope.resetClients();
    await fleet.feedFor(homelab).refresh();
    final rig = fleet.feedFor(homelab).rigs.firstWhere((r) => r.rig.name == 'conveyor').rig;
    await tester.pumpWidget(AppScope(
        store: store,
        child: MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () => broadcastToRig(context, rig), child: const Text('all')))))));
    await tester.tap(find.text('all'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'status please');
    await tester.tap(find.text('Send to all'));
    await tester.pumpAndSettle();
    expect(sent.toSet(), {'impl@conveyor', 'tests@conveyor'}, reason: 'lead and review have a question open');
    expect(broadcasts, 0, reason: 'a rig broadcast would have answered them');
    expect(find.textContaining('Skipped, showing a question: lead, review'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Message all with no seat list (the rig isn\'t in the feed) asks before broadcasting', (tester) async {
    final store = await installFakes();
    var broadcasts = 0;
    final inner = OpenRigClient.factory;
    OpenRigClient.factory = (h) => OpenRigClient(h,
        httpClient: MockClient((req) async {
          if (req.url.path == '/api/transport/broadcast') {
            broadcasts++;
            return http.Response('{"results": []}', 200);
          }
          final copy = http.Request(req.method, req.url)
            ..headers.addAll(req.headers)
            ..bodyBytes = req.bodyBytes;
          return http.Response.fromStream(await fakeDaemon(h).send(copy));
        }),
        eventSource: ({rigId, replay, lastEventId}) => const Stream.empty());
    addTearDown(() => OpenRigClient.factory = inner);
    AppScope.resetClients();
    await fleet.feedFor(homelab).refresh();
    final ghost = Rig.fromJson({'rigId': 'r-nowhere', 'name': 'nowhere', 'nodeCount': 1, 'runningCount': 1, 'attentionCount': 0, 'status': 'running'});
    await tester.pumpWidget(AppScope(
        store: store,
        child: MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () => broadcastToRig(context, ghost), child: const Text('all')))))));
    await tester.tap(find.text('all'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'hi');
    await tester.tap(find.text('Send to all'));
    await tester.pumpAndSettle();
    expect(find.text('Can\'t check whether anyone is showing a question'), findsOneWidget);
    for (final b in ['Send anyway', 'Cancel']) {
      expect(tester.getSize(find.ancestor(of: find.text(b), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)).first).height, 48, reason: b);
    }
    expect(broadcasts, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(broadcasts, 0, reason: 'Cancel sends nothing');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the chat composer asks first when the seat\'s screen shows a question the daemon has not seen; Send anyway sends, Cancel keeps the text', (tester) async {
    final store = await installFakes();
    final sent = <String>[];
    final inner = OpenRigClient.factory;
    OpenRigClient.factory = (h) => OpenRigClient(h,
        httpClient: MockClient((req) async {
          if (req.url.path == '/api/transport/send') {
            sent.add((jsonDecode(req.body) as Map)['text'] as String);
            return http.Response('{"ok": true}', 200);
          }
          final copy = http.Request(req.method, req.url)
            ..headers.addAll(req.headers)
            ..bodyBytes = req.bodyBytes;
          return http.Response.fromStream(await fakeDaemon(h).send(copy));
        }),
        eventSource: ({rigId, replay, lastEventId}) => const Stream.empty());
    addTearDown(() => OpenRigClient.factory = inner);
    AppScope.resetClients();
    // attacker is a working Claude seat the daemon does not flag; its screen shows a question.
    homelab.privateKeyPem = 'pem';
    addTearDown(() => homelab.privateKeyPem = null);
    var screen = _question;
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async => cmd.contains('capture-pane') ? '@@screen\tattacker@adversarial-review\n$screen' : await fakeShell(cmd));
    addTearDown(() => SshExec.debugConnect = null);
    await tester.pumpWidget(MaterialApp(
        home: phone(store, ChatScreen(key: UniqueKey(), rigName: 'adversarial-review', seat: seatFromFixture('r-adv', 'attacker'), asChat: true))));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.enterText(find.byType(TextField).last, 'hello attacker');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(find.text('attacker is showing a question'), findsOneWidget);
    expect(sent, isEmpty, reason: 'nothing is typed into the seat before the answer');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
    expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, 'hello attacker', reason: 'the text stays in the box');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send anyway'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(sent, ['hello attacker']);
    // Once the dialog is gone, a send goes straight through.
    screen = _idle;
    await tester.enterText(find.byType(TextField).last, 'again');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(find.textContaining('is showing a question'), findsNothing);
    await tester.pump(const Duration(milliseconds: 500));
    expect(sent, ['hello attacker', 'again']);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 20));
  });
}
