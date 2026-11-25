import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/host_store.dart' show isDesktop;
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell, panelShows;

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

/// Row heights and the first line's centre, with a mouse: plain 32; a context bar 36; a worktree line 40; both 44; the usage line 18;
/// the search field 32 (block 42). The first line (icon, name, count, age, chevron, ⋯) is centred on the name line: y 16 plain, 13
/// with a second line. A finger's rows stay 48, the first line at y 24 plain and 17 with a second line.
void main() {
  Seat seat(String rig, String id, String cwd, {double? ctx}) => Seat.fromJson({
        'rigId': rig,
        'logicalId': id,
        'canonicalSessionName': '$id@$rig',
        'runtime': 'claude-code',
        'sessionStatus': 'running',
        'cwd': cwd,
        'activityState': {'activity': 'working', 'display': 'working', 'needsInput': {'count': 0, 'reason': null}},
        'contextUsage': ctx == null ? {'availability': 'unknown'} : {'availability': 'known', 'usedPercentage': ctx},
      });

  Future<void> feedWith(WidgetTester tester) async {
    final feed = fleet.feedFor(homelab);
    const repo = '/w/app', x = '$repo/.claude/worktrees/x', y = '$repo/.claude/worktrees/y';
    feed.rigs = [
      RigWithSeats(Rig(id: 'ra', name: 'inx', nodeCount: 3, runningCount: 3, attentionCount: 0, status: 'running'), [
        seat('inx', 'plain', x),
        seat('inx', 'bar', x, ctx: 30),
        seat('inx', 'away', y, ctx: 40), // in another worktree than its rig: a second line AND a context bar
      ]),
    ];
    // ignore: invalid_use_of_protected_member
    feed.notifyListeners();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('mouse: heights 32 / 36 / 40 / 44, the first line centred on the name line (16, or 13 with a second line)', (tester) async {
    final store = await installFakes();
    panelShows.value = null;
    await pumpDesktop(tester, store);
    await feedWith(tester);
    final sidebar = find.byKey(const ValueKey('sidebar'));
    Finder row(String t) => find.ancestor(of: find.descendant(of: sidebar, matching: find.text(t, findRichText: true)).first, matching: find.byType(InkWell)).first;
    double h(String t) => tester.getSize(row(t)).height;
    double nameY(String t) => tester.getCenter(find.descendant(of: sidebar, matching: find.text(t, findRichText: true)).first).dy - tester.getTopLeft(row(t)).dy;
    expect(h('Rigs'), 32, reason: 'a plain row');
    expect(nameY('Rigs'), closeTo(16, 0.6));
    expect(h('plain'), 32, reason: 'an agent in its rig\'s worktree, no bar: plain');
    expect(nameY('plain'), closeTo(16, 0.6));
    expect(h('bar'), 36, reason: 'a context bar');
    expect(nameY('bar'), closeTo(13, 0.6));
    expect(h('inx'), 40, reason: 'a rig in a worktree: the worktree line');
    expect(nameY('inx'), closeTo(13, 0.6));
    expect(h('away'), 44, reason: 'a worktree line and a context bar');
    expect(nameY('away'), closeTo(13, 0.6));
    // The icon, the age and the chevron are centred on the same line as the name.
    final rigRow = tester.getTopLeft(row('inx'));
    expect(tester.getCenter(find.descendant(of: row('inx'), matching: find.byIcon(Icons.chevron_right))).dy - rigRow.dy, closeTo(13, 0.6), reason: 'the chevron');
    // The usage line is 18; the search field 32 inside a 42 block.
    final usage = find.ancestor(of: find.text('5h').first, matching: find.byType(InkWell));
    if (usage.evaluate().isNotEmpty) expect(tester.getSize(usage.first).height, 18);
    final search = find.ancestor(of: find.text('Search'), matching: find.byType(InkWell)).first;
    expect(tester.getSize(search).height, 32);
    // The wt line: glyph then name, from the label column; no line in the main checkout (the fixtures' conveyor is in app's main).
    expect(find.descendant(of: sidebar, matching: find.text('x')), findsOneWidget, reason: 'the rig\'s worktree');
    expect(find.descendant(of: sidebar, matching: find.text('y')), findsOneWidget, reason: 'the agent\'s own, because it differs');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('which rows get the worktree line: a rig, loose agent and shell in a worktree; not the main checkout, not an agent in its rig\'s worktree', (tester) async {
    final store = await installFakes();
    panelShows.value = null;
    showLoose = true;
    await pumpDesktop(tester, store);
    final feed = fleet.feedFor(homelab);
    const repo = '/w/app', x = '$repo/.claude/worktrees/x';
    feed.rigs = [
      RigWithSeats(Rig(id: 'rm', name: 'inmain', nodeCount: 1, runningCount: 1, attentionCount: 0, status: 'running'), [seat('inmain', 'm1', repo)]),
      RigWithSeats(Rig(id: 'rw', name: 'inwt', nodeCount: 1, runningCount: 1, attentionCount: 0, status: 'running'), [seat('inwt', 'w1', x)]),
    ];
    // ignore: invalid_use_of_protected_member
    feed.notifyListeners();
    await tester.pump(const Duration(milliseconds: 400));
    final sidebar = find.byKey(const ValueKey('sidebar'));
    Finder row(String t) => find.ancestor(of: find.descendant(of: sidebar, matching: find.text(t, findRichText: true)).first, matching: find.byType(InkWell)).first;
    expect(tester.getSize(row('inmain')).height, 32, reason: 'a rig in the main checkout: no line');
    expect(tester.getSize(row('inwt')).height, 40, reason: 'a rig in a worktree: the line');
    expect(find.descendant(of: row('inwt'), matching: find.text('x')), findsOneWidget);
    expect(tester.getSize(row('w1')).height, greaterThanOrEqualTo(32));
    expect(find.descendant(of: row('w1'), matching: find.text('x')), findsNothing, reason: 'an agent in its rig\'s own worktree: no line');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('touch: rows stay 48, the first line at y 24 plain and 17 with a second line', (tester) async {
    final store = await installFakes();
    panelShows.value = null;
    await tester.binding.setSurfaceSize(const Size(390, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    isDesktop = false;
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: AppShell(key: UniqueKey()))));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await feedWith(tester);
    await tester.tap(find.byIcon(Icons.menu).first);
    await tester.pumpAndSettle();
    final drawer = find.byType(Drawer);
    Finder row(String t) => find.ancestor(of: find.descendant(of: drawer, matching: find.text(t, findRichText: true)).first, matching: find.byType(InkWell)).first;
    double nameY(String t) => tester.getCenter(find.descendant(of: drawer, matching: find.text(t, findRichText: true)).first).dy - tester.getTopLeft(row(t)).dy;
    for (final t in ['Rigs', 'plain', 'bar', 'inx', 'away']) {
      expect(tester.getSize(row(t)).height, 48, reason: t);
    }
    expect(nameY('Rigs'), closeTo(24, 0.6));
    expect(nameY('plain'), closeTo(24, 0.6));
    expect(nameY('bar'), closeTo(17, 0.6));
    expect(nameY('inx'), closeTo(17, 0.6));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an offline host\'s address is a second line in the same pattern: mono 11, muted, from the name\'s column; the header is 40 with a mouse', (tester) async {
    final store = await installFakes();
    panelShows.value = null;
    await pumpDesktop(tester, store);
    final feed = fleet.feedFor(homelab);
    feed.error = 'unreachable';
    // ignore: invalid_use_of_protected_member
    feed.notifyListeners();
    await tester.pump(const Duration(milliseconds: 400));
    final sidebar = find.byKey(const ValueKey('sidebar'));
    final addr = find.descendant(of: sidebar, matching: find.textContaining('offline · ${homelab.address}'));
    expect(addr, findsOneWidget);
    final text = tester.widget<Text>(addr);
    expect(text.style!.fontSize, 11);
    final header = find.ancestor(of: addr, matching: find.byType(InkWell)).first;
    expect(tester.getSize(header).height, 40);
    final name = find.descendant(of: header, matching: find.text(homelab.name.toUpperCase()));
    expect(tester.getTopLeft(addr).dx, tester.getTopLeft(name.first).dx, reason: 'from the name\'s column');
    expect(tester.getCenter(name.first).dy - tester.getTopLeft(header).dy, closeTo(13, 0.6));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
