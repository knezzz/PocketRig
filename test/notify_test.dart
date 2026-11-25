import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/needs_you.dart' show answerSettle, needsYouCount;
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/needs_you_banner.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart' show installFakes;

Host host([String id = 'h1', String name = 'homelab']) => Host(id: id, name: name, address: '$name.tail1.ts.net', sshUser: 'me');
final rig = Rig(id: 'r1', name: 'conveyor', nodeCount: 2, runningCount: 2, attentionCount: 1, status: 'running');
Seat seat(String id, {String? reason = 'Bash: npm test'}) =>
    Seat(rigId: 'r1', logicalId: id, sessionName: '$id@conveyor', runtime: 'claude-code', needsInput: true, needsInputReason: reason);
SeatAlert alert(Host h, Seat s) => SeatAlert(host: h, rig: rig, seat: s, project: 'app');

void main() {
  setUp(needsYouAlerts.reset);

  test('an alert names role › rig › project › device, and its kind', () {
    final a = alert(host(), seat('lead'));
    expect(a.path, 'lead › conveyor › app › homelab');
    expect(a.title, 'lead needs approval');
    expect(a.kind, 'permission');
    final q = alert(host(), seat('review', reason: 'asked a question'));
    expect(q.title, 'review asked a question');
    expect(q.kind, 'question');
  });

  test('the first report seeds; only seats that start waiting later raise a banner', () {
    final h = host();
    needsYouAlerts.report(h, [alert(h, seat('lead'))]);
    expect(needsYouAlerts.current, isNull, reason: 'already waiting when the app opened');
    needsYouAlerts.report(h, [alert(h, seat('lead')), alert(h, seat('review'))]);
    expect(needsYouAlerts.current?.seat.logicalId, 'review');
    // Answered elsewhere: the banner goes away.
    needsYouAlerts.report(h, [alert(h, seat('lead'))]);
    expect(needsYouAlerts.current, isNull);
  });

  test('a seat that still waits after its answer settles gets a banner for the next ask', () {
    final h = host();
    needsYouAlerts.report(h, []);
    needsYouAlerts.report(h, [alert(h, seat('lead'))]);
    needsYouAlerts.answered(seat('lead'));
    expect(needsYouAlerts.current, isNull);
    needsYouAlerts.report(h, [alert(h, seat('lead'))]);
    expect(needsYouAlerts.current, isNull, reason: 'the daemon lags the keypress');
    needsYouAlerts.report(h, [alert(h, seat('lead', reason: 'Edit: b.dart'))], now: DateTime.now().add(answerSettle * 2));
    expect(needsYouAlerts.current?.seat.logicalId, 'lead', reason: 'the next permission');
  });

  test('answering a seat in the chat, terminal or Needs you tab takes its banner down at once', () {
    final h = host();
    needsYouAlerts.report(h, []);
    needsYouAlerts.report(h, [alert(h, seat('lead')), alert(h, seat('review'))]);
    expect(needsYouAlerts.current?.seat.logicalId, 'lead');
    needsYouAlerts.answered(seat('lead'));
    expect(needsYouAlerts.current?.seat.logicalId, 'review');
    // The daemon still reports lead waiting for a moment; no new banner for it.
    needsYouAlerts.report(h, [alert(h, seat('lead')), alert(h, seat('review'))]);
    expect(needsYouAlerts.current?.seat.logicalId, 'review');
    needsYouAlerts.answered(seat('review'));
    expect(needsYouAlerts.current, isNull);
  });

  test('opening the seat on screen takes its banner down too', () {
    final h = host();
    needsYouAlerts.report(h, []);
    needsYouAlerts.report(h, [alert(h, seat('lead'))]);
    expect(needsYouAlerts.current, isNotNull);
    needsYouAlerts.focusedSession = 'lead@conveyor';
    expect(needsYouAlerts.current, isNull, reason: 'the chat shows the same ask');
    needsYouAlerts.focusedSession = null;
    needsYouAlerts.report(h, [alert(h, seat('lead'))]);
    expect(needsYouAlerts.current, isNull, reason: 'it was already known');
  });

  test('kinds switched off, and the seat already on screen, stay quiet', () {
    final h = host()..notifyKinds = {'question'};
    needsYouAlerts.report(h, []);
    needsYouAlerts.report(h, [alert(h, seat('lead'))]);
    expect(needsYouAlerts.current, isNull, reason: 'permission requests are off for this host');
    h.notifyKinds = {...NotifyKind.defaults};
    needsYouAlerts.focusedSession = 'impl@conveyor';
    needsYouAlerts.report(h, [alert(h, seat('lead')), alert(h, seat('impl'))]);
    expect(needsYouAlerts.current, isNull, reason: 'impl is open in the chat already');
  });

  test('every host is tracked on its own: one host\'s report leaves the other\'s banners alone', () {
    needsYouAlerts.report(host(), []);
    needsYouAlerts.report(host(), [alert(host(), seat('lead'))]);
    expect(needsYouAlerts.current?.seat.logicalId, 'lead');
    final other = host('h2', 'macbook');
    needsYouAlerts.report(other, [alert(other, seat('analyst'))]);
    expect(needsYouAlerts.current?.seat.logicalId, 'lead', reason: 'macbook\'s first report only seeds');
    needsYouAlerts.report(other, [alert(other, seat('analyst')), alert(other, seat('scout'))]);
    needsYouAlerts.dismiss(needsYouAlerts.current!);
    expect(needsYouAlerts.current?.seat.logicalId, 'scout');
    needsYouAlerts.forgetHost('h2');
    expect(needsYouAlerts.current, isNull);
  });

  test('host notification kinds default to permission, question and blocked, and persist', () {
    final h = host();
    expect(h.notifyKinds, {'permission', 'question', 'blocked'});
    h.notifyKinds = {'rig'};
    expect(Host.fromJson(h.toJson()).notifyKinds, {'rig'});
  });

  test('a swipe up snoozes a seat\'s banner for ten minutes; then it comes back if still waiting', () {
    final h = host();
    final t = DateTime(2026, 11, 9, 12);
    needsYouAlerts.report(h, [], now: t);
    needsYouAlerts.report(h, [alert(h, seat('lead'))], now: t);
    needsYouAlerts.snooze(needsYouAlerts.current!, now: t);
    expect(needsYouAlerts.current, isNull);
    needsYouAlerts.report(h, [alert(h, seat('lead'))], now: t.add(const Duration(minutes: 9)));
    expect(needsYouAlerts.current, isNull, reason: 'still snoozed');
    needsYouAlerts.report(h, [alert(h, seat('lead'))], now: t.add(const Duration(minutes: 11)));
    expect(needsYouAlerts.current?.seat.logicalId, 'lead');
    // Answered while snoozed: nothing comes back.
    needsYouAlerts.snooze(needsYouAlerts.current!, now: t);
    needsYouAlerts.report(h, [], now: t.add(const Duration(minutes: 1)));
    needsYouAlerts.report(h, [alert(h, seat('lead'))], now: t.add(const Duration(minutes: 20)));
    expect(needsYouAlerts.current?.seat.logicalId, 'lead', reason: 'a new ask after the old one was answered');
  });

  testWidgets('the banner names who is asking, shows the command and answers it in place', (tester) async {
    final semantics = tester.ensureSemantics();
    final s = Seat(
        rigId: 'r1',
        logicalId: 'lead',
        sessionName: 'lead@conveyor',
        runtime: 'claude-code',
        cwd: '/Users/me/app/.claude/worktrees/fix-flaky-ci',
        needsInput: true,
        needsInputReason: 'Bash: npm run test:integration');
    needsYouAlerts.show(alert(host(), s));
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: const Scaffold(body: Align(alignment: Alignment.topCenter, child: NeedsYouBanner())),
    ));
    await tester.pumpAndSettle();
    expect(find.text('lead'), findsNothing, reason: 'the name is one span of the title line');
    expect(find.textContaining('needs approval · conveyor · app', findRichText: true), findsOneWidget);
    // The ask itself, and its answers.
    expect(find.text('Bash · npm run test:integration'), findsOneWidget);
    // The same bar as the Inbox card and the seat sheet: Deny · Always "scope" · Allow once, then Open.
    for (final answer in ['Deny', 'Always', 'Allow once']) {
      expect(find.text(answer), findsOneWidget, reason: answer);
    }
    expect(find.text('Open'), findsNothing, reason: 'no Open button under a permission: the top line opens the agent');
    expect(find.bySemanticsLabel('Open lead'), findsOneWidget, reason: 'the top line is the way in');
    expect(find.byIcon(Icons.chevron_right), findsOneWidget, reason: 'a chevron says it opens the agent');
    final x = tester.getSize(find.bySemanticsLabel('Dismiss'));
    expect(x.width, greaterThanOrEqualTo(44));
    expect(x.height, greaterThanOrEqualTo(44), reason: 'the dismiss has a 44dp tap area');
    expect(find.textContaining('more waiting'), findsNothing, reason: 'nothing else is waiting');
    expect(tester.getSemantics(find.byIcon(Icons.close)).label, 'Dismiss');
    await tester.tap(find.bySemanticsLabel('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('Allow once'), findsNothing);
    semantics.dispose();
  });

  testWidgets('the banner\'s Always presses the always key once over SSH and takes the banner down', (tester) async {
    await installFakes(); // the daemon answers 503 for this host, so the answer falls back to SSH
    final sent = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          sent.add(cmd);
          return 'POCKETRIG_SENT\n';
        });
    addTearDown(() {
      SshExec.debugConnect = null;
      needsYouCount.value = 0; // the feed refresh after an answer sets it
    });
    final s = Seat(
        rigId: 'r1',
        logicalId: 'lead',
        sessionName: 'lead@conveyor',
        runtime: 'claude-code',
        needsInput: true,
        needsInputReason: 'Bash: npm run test:integration');
    needsYouAlerts.show(alert(host(), s));
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: const Scaffold(body: Align(alignment: Alignment.topCenter, child: NeedsYouBanner())),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Always'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    final keys = sent.where((c) => c.contains('send-keys')).toList();
    expect(keys, hasLength(1), reason: sent.join(' // '));
    expect(keys.single, matches(RegExp(r'send-keys -t \S+ \S*2\S* ')), reason: 'the always key (2)');
    expect(keys.single, isNot(contains('Escape')), reason: 'not a deny');
    expect(needsYouAlerts.current, isNull, reason: 'answered, so the banner is gone');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a question offers Reply and Open; more asks waiting link to the Inbox', (tester) async {
    needsYouAlerts.show(alert(host(), seat('scout')));
    needsYouAlerts.show(alert(host(), seat('review', reason: 'asked a question')));
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: const Scaffold(body: Align(alignment: Alignment.topCenter, child: NeedsYouBanner())),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('asked a question · conveyor', findRichText: true), findsOneWidget);
    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Allow once'), findsNothing);
    expect(find.text('+1 more waiting'), findsOneWidget);
    expect(find.text('Inbox'), findsOneWidget);
  });

  testWidgets('swiping the banner up snoozes it', (tester) async {
    final h = host();
    needsYouAlerts.report(h, []);
    needsYouAlerts.report(h, [alert(h, seat('lead'))]);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: const Scaffold(body: Align(alignment: Alignment.topCenter, child: NeedsYouBanner())),
    ));
    await tester.pumpAndSettle();
    await tester.fling(find.text('Allow once'), const Offset(0, -300), 1000);
    await tester.pumpAndSettle();
    expect(needsYouAlerts.current, isNull);
    needsYouAlerts.report(h, [alert(h, seat('lead'))]);
    expect(needsYouAlerts.current, isNull, reason: 'snoozed for ten minutes');
  });

  testWidgets('opening a seat from the banner swaps out the chat on top instead of stacking', (tester) async {
    final key = GlobalKey<NavigatorState>();
    final observer = TopRouteObserver();
    await tester.pumpWidget(MaterialApp(navigatorKey: key, navigatorObservers: [observer], home: const Text('home')));
    // A seat screen registers its route the way ChatScreen does.
    final chat = MaterialPageRoute<void>(builder: (_) => const Text('chat A'));
    key.currentState!.push(chat);
    await tester.pumpAndSettle();
    seatScreenRoutes.add(chat);
    expect(observer.current, chat);

    topRoute.current = observer.current;
    openSeatScreen(key.currentState!, const Text('chat B'));
    await tester.pumpAndSettle();
    expect(find.text('chat B'), findsOneWidget);
    expect(find.text('chat A'), findsNothing);
    // Back goes home, not to chat A.
    key.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);

    // Over something that isn't a seat screen, it pushes.
    topRoute.current = observer.current;
    openSeatScreen(key.currentState!, const Text('chat C'));
    await tester.pumpAndSettle();
    key.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    seatScreenRoutes.clear();
    topRoute.current = null;
  });
}
