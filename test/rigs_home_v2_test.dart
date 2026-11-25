import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/agent_jobs.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/home_order.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/data/usage_rings.dart';
import 'package:pocket_rig/ui/common.dart' show debugAgoClock;
import 'package:pocket_rig/ui/usage_strip.dart' show HostUsageBars, HostUsageLine, debugUsageClock;
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;
import 'package:pocket_rig/ui/needs_you_banner.dart' show inboxRequests;
import 'package:pocket_rig/ui/kit.dart' show AgentRow, Segmented, labelFor;
import 'package:pocket_rig/ui/status_shape.dart';
import 'package:pocket_rig/ui/theme.dart' show Tokens;
import 'package:pocket_rig/ui/rigs_home.dart';

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

void main() {
  final now = DateTime(2026, 11, 23, 12);

  Seat seat(String activity, {DateTime? at, String status = 'running'}) => Seat(
      rigId: 'r', logicalId: 'a', runtime: 'claude-code', sessionName: 'a@r', activity: activity, lastActivityAt: at, sessionStatus: status);

  test('the home measures recency against the pinned clock, so a slow run cannot tip a 9-minute-old agent over the 10-minute line', () {
    final pinned = DateTime(2026, 11, 23, 12);
    debugAgoClock = pinned;
    addTearDown(() => debugAgoClock = null);
    expect(homeNow(), pinned);
    final s = seat('idle-at-prompt', at: pinned.subtract(const Duration(minutes: 9)));
    expect(seatVisible(s, homeNow()), isTrue);
    // The wall clock moving on does not change what the home thinks of it.
    expect(seatVisible(s, homeNow()), isTrue);
  });

  test('a seat\'s tier: needs you, working, shell, idle; stopped counts as idle', () {
    expect(seatTier(Seat(rigId: 'r', logicalId: 'a', needsInput: true)), 0);
    expect(seatTier(seat('working')), 1);
    expect(seatTier(seat('idle-at-prompt')), 3);
  });

  test('an idle agent is shown only when its last real activity is within 10 minutes; stopped ones are folded', () {
    expect(seatVisible(seat('idle-at-prompt', at: now.subtract(const Duration(minutes: 9, seconds: 59))), now), isTrue);
    expect(seatVisible(seat('idle-at-prompt', at: now.subtract(const Duration(minutes: 10, seconds: 1))), now), isFalse);
    expect(seatVisible(seat('idle-at-prompt'), now), isFalse, reason: 'no activity known: not recent');
    expect(seatVisible(seat('working', at: now.subtract(const Duration(hours: 3))), now), isTrue, reason: 'working is always shown');
    expect(seatVisible(Seat(rigId: 'r', logicalId: 'a', runtime: 'claude-code', sessionName: 'a@r', intentionallyStopped: true, lastActivityAt: now), now),
        isFalse, reason: 'a stopped agent of a running rig folds');
  });

  testWidgets('a rig card folds its stopped and idle agents into "+N idle  show ▾", which opens in place, dimmed, and is remembered',
      (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('attacker').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final home = find.byKey(const ValueKey('rigs-cards'));
    Finder inHome(Finder f) => find.descendant(of: home, matching: f);
    // adversarial-review: attacker works, defender is stopped: folded.
    expect(inHome(find.text('attacker')), findsOneWidget);
    expect(inHome(find.text('defender')), findsNothing);
    Finder card(String rig) => find.ancestor(of: inHome(find.text(rig)), matching: find.byType(Column)).first;
    expect(find.descendant(of: card('adversarial-review'), matching: find.text('+1 idle')), findsOneWidget);
    await tester.tap(find.descendant(of: card('adversarial-review'), matching: find.text('show ▾')));
    await tester.pump();
    expect(inHome(find.text('defender')), findsOneWidget, reason: 'opened in place');
    expect(homeIdleOpen, hasLength(1), reason: 'remembered for the session');
    expect(find.descendant(of: card('adversarial-review'), matching: find.text('fewer ▴')), findsOneWidget);
    // Remembered: a rebuilt home keeps it open.
    await tester.pumpWidget(const SizedBox());
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('attacker').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.descendant(of: find.byType(RigsHome), matching: find.text('defender')), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(RigsHome), matching: find.text('fewer ▴')).first);
    await tester.pump();
    expect(find.descendant(of: find.byType(RigsHome), matching: find.text('defender')), findsNothing, reason: 'closed again');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('with nothing running the home says so, with New rig and New agent, and points to Projects', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    OpenRigClient.factory = (h) => OpenRigClient(h,
        httpClient: MockClient((req) async => http.Response(req.url.path.startsWith('/api/discovery') ? jsonEncode({'sessions': []}) : '[]', 200)),
        eventSource: ({rigId, replay, lastEventId}) => const Stream.empty());
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final home = find.byKey(const ValueKey('rigs-cards'));
    expect(find.descendant(of: home, matching: find.text('Nothing is running')), findsOneWidget);
    expect(find.descendant(of: home, matching: find.text('New rig')), findsOneWidget);
    expect(find.descendant(of: home, matching: find.text('New agent')), findsOneWidget);
    expect(find.descendant(of: home, matching: find.textContaining('under their host')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('on a phone the home has the "N agents need you · Answer ›" strip and no Inbox column', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    await tester.pumpWidget(MaterialApp(home: phone(store, const RigsHome())));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.textContaining('agents need you'), findsOneWidget);
    expect(find.textContaining('INBOX · '), findsNothing, reason: 'the column is for a wide window');
    final before = inboxRequests.value;
    await tester.tap(find.textContaining('agents need you'));
    await tester.pump();
    expect(inboxRequests.value, before + 1, reason: 'Answer › asks the shell for the Inbox');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the Rigs home banner counts the structured questions too, as the badge and the Inbox do', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    await tester.pumpWidget(MaterialApp(home: phone(store, const RigsHome())));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    int shown() => int.parse(RegExp(r'^(\d+) agents need you').firstMatch(tester.widget<Text>(find.textContaining('agents need you')).data!)!.group(1)!);
    final before = shown();
    fleet.feedFor(homelab).setCoreAsks(2);
    await tester.pump(const Duration(milliseconds: 300));
    expect(shown(), before + 2, reason: 'one asking seat plus structured questions: the number the Inbox shows');
    fleet.feedFor(homelab).setCoreAsks(0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the Rigs home has a slim title bar with a + and nothing pinned under it: no tabs', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    await pumpDesktop(tester, store);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final home = find.byType(RigsHome);
    expect(find.descendant(of: home, matching: find.byType(Segmented<Object?>)), findsNothing);
    expect(find.descendant(of: home, matching: find.byTooltip('New…')), findsOneWidget, reason: 'the + is in the bar');
    expect(tester.getSize(find.descendant(of: home, matching: find.byKey(const ValueKey('rigs-bar')))).height, lessThan(80),
        reason: 'one page-header bar, not a 144dp pinned block');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  test('an agent waiting on a shell is tier 2 and is never folded into +N idle, however old its last activity; one blue for the ring and the shell icon', () {
    final waiting = Seat(rigId: 'r', logicalId: 'a', runtime: 'claude-code', sessionName: 'a@r', activity: 'idle-at-prompt', lastActivityAt: now.subtract(const Duration(hours: 5)))
      ..waitingSubagents = 1;
    expect(waiting.state, SeatState.shell);
    expect(seatTier(waiting), 2);
    expect(seatVisible(waiting, now), isTrue, reason: 'shown, not folded');
    for (final k in [Tokens.light, Tokens.dark]) {
      expect(k.shell, k.terminal);
    }
    expect(labelFor(SeatState.shell), 'waiting on shell');
  });

  testWidgets('a row without a context reading keeps the right column, so its age lines up with the rows that have one',
      (tester) async {
    final store = await installFakes();
    await tester.pumpWidget(MaterialApp(
        home: phone(
            store,
            const Column(children: [
              Material(child: AgentRow(name: 'with', status: Status.working, age: 'now', context: 40)),
              Material(child: AgentRow(name: 'without', status: Status.working, age: 'now')),
            ]))));
    await tester.pump();
    final ages = find.text('now');
    expect(ages, findsNWidgets(2), reason: 'both rows show their age');
    expect(tester.getTopRight(ages.at(0)).dx, tester.getTopRight(ages.at(1)).dx, reason: 'in one column');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the whole "+N idle" line opens the fold, not only its words', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('attacker').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final card = find.byKey(const ValueKey('rigs-cards'));
    final line = find.ancestor(of: find.descendant(of: card, matching: find.text('+1 idle')).first, matching: find.byType(InkWell)).first;
    final r = tester.getRect(line);
    await tester.tapAt(Offset(r.center.dx, r.center.dy));
    await tester.pump();
    expect(find.descendant(of: card, matching: find.text('fewer ▴')), findsOneWidget, reason: 'a tap in the middle of the line, on neither word');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an agent waiting on a shell says what it waits on, in the muted second line', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    await pumpDesktop(tester, store);
    final feed = fleet.feedFor(homelab);
    for (var i = 0; i < 5 && feed.rigs.isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final tests = feed.rigs.firstWhere((r) => r.rig.name == 'conveyor').seats.firstWhere((s) => s.logicalId == 'tests');
    tests.jobs = AgentJob.parse('J\t1\tS\t05:00\t0\t0\t/bin/zsh -c source /h/.claude/shell-snapshots/s.sh && eval \'sleep 99\' < /dev/null && pwd -P >| /tmp/x\n');
    expect(tests.state, SeatState.shell);
    fleet.toggleRig('r:${homelab.id}|r-conveyor', allShown: false);
    await tester.pump(const Duration(seconds: 1));
    final card = find.byKey(const ValueKey('rigs-cards'));
    expect(find.descendant(of: card, matching: find.text('waiting on sleep 99')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('idle agents outside a rig fold into one "+N idle agents" line at the project: it opens in place (dimmed rows) and '
      'never counts the agents that need you or work', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    showLoose = true;
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('scratch').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final card = find.byKey(const ValueKey('rigs-cards'));
    // scratch needs you: always a row. codex-fix is idle and old: folded.
    expect(find.descendant(of: card, matching: find.text('scratch')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('codex-fix')), findsNothing);
    final line = find.descendant(of: card, matching: find.text('+1 idle agents'));
    expect(line, findsOneWidget);
    await tester.tap(line);
    await tester.pump();
    expect(find.descendant(of: card, matching: find.text('codex-fix')), findsOneWidget, reason: 'opened in place');
    expect(find.descendant(of: card, matching: find.text('1 idle agents')), findsOneWidget, reason: 'the count stays when open');
    expect(find.descendant(of: card, matching: find.text('fewer ▴')), findsWidgets);
    await tester.tap(find.descendant(of: card, matching: find.text('1 idle agents')));
    await tester.pump();
    expect(find.descendant(of: card, matching: find.text('codex-fix')), findsNothing, reason: 'closed again');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a card\'s tally and tint come from its agents: a rig that only a queue item asks about is not "needs you" there; '
      'and the sidebar lists a rig\'s agents in the card\'s order; ages sit in one column', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('implementation-pair').evaluate().length < 2; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final card = find.byKey(const ValueKey('rigs-cards'));
    await tester.scrollUntilVisible(find.descendant(of: card, matching: find.text('implementation-pair')), 200,
        scrollable: find.descendant(of: card, matching: find.byType(Scrollable)).first);
    // implementation-pair: no seat needs you (an action item from impl does): no needs-you in its card's tally.
    final pair = find.ancestor(of: find.descendant(of: card, matching: find.text('implementation-pair')), matching: find.byType(Column)).first;
    final tally = tester.widget<StatusTally>(find.descendant(of: pair, matching: find.byType(StatusTally)));
    expect(tally.counts[Status.needsYou] ?? 0, 0, reason: 'the header does not contradict its rows');

    // The same order in the sidebar and in the card (tier, then the oldest ask): conveyor's agents.
    await tester.drag(find.descendant(of: card, matching: find.byType(ListView)).first, const Offset(0, 3000));
    await tester.pump();
    List<String> order(Finder within) {
      final names = ['lead', 'impl', 'review'];
      final ys = {for (final n in names) n: tester.getTopLeft(find.descendant(of: within, matching: find.byWidgetPredicate((w) => w is Text && (w.data ?? w.textSpan?.toPlainText() ?? '').trim().split(RegExp(r'\s+')).first == n)).first).dy};
      return ([...names]..sort((a, b) => ys[a]!.compareTo(ys[b]!)));
    }
    final sidebar = find.ancestor(of: find.text('Add project folder'), matching: find.byType(ListView));
    expect(order(sidebar), order(card), reason: 'one order for both');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('on a phone the host header shows its usage as text on the right; wide, the bars', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    final t0 = DateTime.utc(2026, 11, 2, 12);
    debugUsageClock = t0;
    addTearDown(() {
      debugUsageClock = null;
      usageNow.reset();
    });
    usageNow.set([
      (homelab, [
        HostUsage(host: 'local', provider: 'claude', windows: [
          UsageWindow(window: 'five_hour', usedPercent: 71, resetsAt: t0.add(const Duration(hours: 1)), asOf: t0),
          UsageWindow(window: 'weekly', usedPercent: 34, resetsAt: t0.add(const Duration(days: 3)), asOf: t0),
        ])
      ])
    ]);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: phone(store, const RigsHome())));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('5h 71% · week 34%'), findsOneWidget, reason: 'the phone\'s host header');
    expect(find.byType(HostUsageBars), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));

    await pumpDesktop(tester, store);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.descendant(of: find.byKey(const ValueKey('rigs-cards')), matching: find.byType(HostUsageLine)), findsWidgets);
    expect(find.byType(HostUsageBars), findsNothing, reason: 'wide: the sidebar\'s compact line, not the two-bar block');
    expect(find.text('5h 71% · week 34%'), findsNothing, reason: 'wide: the line, not the phone\'s text');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a host that is offline sorts after the live ones', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    // homelab (first in the list) cannot be reached; macbook answers (an empty daemon).
    OpenRigClient.factory = (h) => OpenRigClient(h,
        httpClient: MockClient((req) async {
          if (h.id == homelab.id) throw Exception('connection refused');
          return http.Response(req.url.path.startsWith('/api/discovery') ? jsonEncode({'sessions': []}) : '[]', 200);
        }),
        eventSource: ({rigId, replay, lastEventId}) => const Stream.empty());
    await pumpDesktop(tester, store);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final card = find.byKey(const ValueKey('rigs-cards'));
    final mac = find.descendant(of: card, matching: find.text('MACBOOK'));
    final lab = find.descendant(of: card, matching: find.text('HOMELAB'));
    expect(mac, findsOneWidget);
    expect(lab, findsOneWidget);
    expect(tester.getTopLeft(mac).dy, lessThan(tester.getTopLeft(lab).dy), reason: 'the live host first, the offline one after');
    expect(find.descendant(of: card, matching: find.textContaining('is offline')), findsOneWidget);
    // The sidebar does the same.
    final side = find.ancestor(of: find.text('Add project folder'), matching: find.byType(ListView));
    final sideMac = find.descendant(of: side, matching: find.text('MACBOOK'));
    final sideLab = find.descendant(of: side, matching: find.text('HOMELAB'));
    expect(tester.getTopLeft(sideMac).dy, lessThan(tester.getTopLeft(sideLab).dy), reason: 'the sidebar lists the live host first too');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 11));
  });
}
