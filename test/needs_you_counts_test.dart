import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/host_store.dart' show isDesktop;
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/kit.dart' show RowTile;
import 'package:pocket_rig/ui/project_screen.dart' show ProjectScreen;
import 'package:pocket_rig/ui/project_tally.dart';
import 'package:pocket_rig/ui/rig/overview_tab.dart' show CountTile;
import 'package:pocket_rig/ui/status_shape.dart';
import 'package:pocket_rig/ui/theme.dart' show animateStatusSpinners;

import 'golden/fixtures.dart';

void main() {
  setUp(() => animateStatusSpinners = false);

  testWidgets('one needs-you list: the Inbox section, the tab badge, the cards and the rig rows all count it',
      (tester) async {
    final store = await installFakes();
    showLoose = true; // scratch waits on a permission
    // Daemon items: one asked by a conveyor seat, one naming only a folder, one that is just news.
    extraAttention = [
      {'id': 'a1', 'kind': 'action', 'summary': 'Approve the release', 'asker': 'tests@conveyor'},
      {
        'id': 'a2',
        'kind': 'action',
        'summary': 'Pick a branch',
        'project': {'root': app}
      },
      {'id': 'u1', 'kind': 'update', 'summary': 'Build finished'},
    ];
    final feed = fleet.feedFor(homelab);
    await tester
        .pumpWidget(AppScope(store: store, child: MaterialApp(home: phone(store, const AppShell()))));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final items = feed.needsYouItems;
    final seats = items.where((i) => i.seat != null).length, loose = items.where((i) => i.loose != null).length;
    expect(items.where((i) => i.action != null), hasLength(3),
        reason: 'the fixtures own item, plus two of ours; the update is no ask');
    expect(loose, greaterThan(0));
    final badge = items.length;
    expect(feed.needsYou, badge);
    expect(badge, seats + loose + 3);

    // The Inbox section lists exactly them.
    final shown = find.textContaining('NEEDS YOU ·').evaluate().map((e) => (e.widget as Text).data).toList();
    expect(shown, ['NEEDS YOU · $badge']);

    // Cards: the sum of every project's count is the badge, and their tallies say the same.
    final projects = feed.projects;
    expect(projects.fold(0, (n, p) => n + p.attention), badge);
    for (final p in projects) {
      expect(SeatTally(homelab, p.rigs, p.loose, project: p).needs, p.attention, reason: p.name);
    }
    expect(projects.firstWhere((p) => p.path == app).attention, greaterThanOrEqualTo(2),
        reason: 'the folder-only item counts on its project');

    // Rig rows: tests@conveyor's item counts on conveyor, and a rig with only an item reads as needing you.
    final conveyor = feed.rigs.firstWhere((r) => r.rig.name == 'conveyor');
    expect(SeatTally(homelab, [conveyor], const []).needs,
        conveyor.seats.where((s) => s.isAgent && s.state == SeatState.needsYou).length + 1);
    final adv = feed.rigs.firstWhere((r) => r.rig.name == 'adversarial-review');
    expect(rigStatus(adv, homelab), isNot(Status.needsYou), reason: 'nothing waits in it');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('ProjectScreen counts the same items: its Needs you section, the need you tile and the rig badges',
      (tester) async {
    final store = await installFakes();
    extraAttention = [
      {'id': 'a1', 'kind': 'action', 'summary': 'Approve the release', 'asker': 'tests@conveyor'},
      {
        'id': 'a2',
        'kind': 'action',
        'summary': 'Pick a branch',
        'project': {'root': app}
      },
      {'id': 'u1', 'kind': 'update', 'summary': 'Build finished'},
    ];
    final feed = fleet.feedFor(homelab);
    await tester.pumpWidget(MaterialApp(home: phone(store, const ProjectScreen(path: app))));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final project = feed.projects.firstWhere((p) => p.path == app);
    final n = project.attention;
    expect(n, greaterThan(2), reason: 'two seats wait, plus our two action items');
    final shown =
        find.textContaining(RegExp('needs you ·', caseSensitive: false)).evaluate().map((e) => (e.widget as Text).data);
    expect(shown.map((t) => t!.toUpperCase()), ['NEEDS YOU · $n']);
    final tile = find.byWidgetPredicate((w) => w is CountTile && w.label == 'need you');
    await tester.scrollUntilVisible(tile, 200, scrollable: find.byType(Scrollable).first);
    expect(tester.widget<CountTile>(tile).value, '$n');

    // A rig with only an action item asked of it reads as needing you on its row.
    final adv = feed.rigs.firstWhere((r) => r.rig.name == 'adversarial-review');
    expect(rigStatus(adv, homelab), isNot(Status.needsYou));
    final pair = feed.rigs.firstWhere((r) => r.rig.name == 'implementation-pair');
    expect(pair.seats.any((s) => s.state == SeatState.needsYou), isFalse);
    expect(rigStatus(pair, homelab), Status.needsYou,
        reason: 'the fixture action item was asked by impl@implementation-pair');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a rig that only an action item asks about (q9 on implementation-pair) reads the same on every surface',
      (tester) async {
    final store = await installFakes();
    Finder rigRow() => find.ancestor(of: find.text('implementation-pair'), matching: find.byType(RowTile)).first;
    Status icon() => tester.widget<StatusIcon>(find.descendant(of: rigRow(), matching: find.byType(StatusIcon))).status;
    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // ProjectScreen: the Overview tile and the Agents tab's icon.
    await tester.pumpWidget(MaterialApp(home: phone(store, const ProjectScreen(path: site))));
    await settle();
    await tester.scrollUntilVisible(find.text('RUNNING'), 200, scrollable: find.byType(Scrollable).first);
    expect(tester.widget<CountTile>(find.byWidgetPredicate((w) => w is CountTile && w.label == 'need you')).value, '1');
    await tester.tap(find.text('Agents'));
    await settle();
    expect(icon(), Status.needsYou);

    // The desktop sidebar.
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: AppShell(key: UniqueKey()))));
    await settle();
        // The bars say what is under them: site's agents, and the rig the action item asks about.
    expect(_bar('site · 1 needs you · 1 working'), findsOneWidget);
    expect(_bar('implementation-pair · 1 need you'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}

/// A sidebar bar, by its tooltip (name and the states under it): the same words its screen-reader label has.
Finder _bar(String startsWith) =>
    find.byWidgetPredicate((w) => w is Semantics && (w.properties.label ?? '').startsWith(startsWith.replaceFirst(' · ', ', ')));
