import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/subagents.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

/// The sidebar's grid: every row's icon and label on the column its level sets, one trailing-icon column, one edge for the
/// numbers. Mouse: fill margin 10 + fill inset 6, 12 per level, 24 trailing column. Finger: 16 + 6, 14, 44.
void main() {
  testWidgets('Mac sidebar: label x by kind and level, numbers end at one edge, trailing icons are centred in one column',
      (tester) async {
    final store = await installFakes();
    showLoose = true;
    fleet.toggleRig('r:${homelab.id}|r-conveyor', allShown: false);
    fleet.feedFor(homelab).subagents = {
      'sess-lead': [Subagent(sessionId: 'sess-lead', agentId: 'a1', description: 'Write the parser', type: 'general-purpose')],
    };
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('scratch').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final sidebar = find.ancestor(of: find.text('Add project folder').first, matching: find.byType(ListView)).first;
    final box = tester.getRect(sidebar);
    expect(box.width, 264);
    double labelX(String t) => tester.getTopLeft(find.descendant(of: sidebar, matching: find.text(t)).first).dx - box.left;
    // Origin 16 (10 + 6): an icon in the 16 slot, then the 9 gap: the label at 41; +12 a level; a logo's 18 gap puts an agent at 50 + 12/level.
    expect(labelX('Rigs'), 41);
    expect(labelX('Inbox'), 41);
    expect(labelX('app'), 41);
    expect(labelX('Add project folder'), 41);
    expect(labelX('conveyor'), 53, reason: 'a rig, one level in');
    expect(labelX('lead'), 74, reason: 'an agent under a rig, two in');
    expect(labelX('scratch'), 62, reason: 'an agent outside a rig is the rig\'s sibling: its logo where the rig\'s icon is (the label 9 on for the logo\'s wider gap), not level with the rig\'s seats');
    expect(labelX('Write the parser'), 86, reason: 'a subagent, one more');
    // The search row is on the grid: its icon in the 16 slot, level with the Inbox row's icon, its label at 41.
    expect(tester.getTopLeft(find.descendant(of: sidebar, matching: find.byIcon(Icons.search))).dx,
        tester.getTopLeft(find.descendant(of: sidebar, matching: find.byIcon(Icons.inbox_outlined))).dx);
    expect(labelX('Search'), 41);

    // Content ends at 248 (264 - 16); the trailing column is 24 wide, so numbers end at 224 and icons are centred at 236.
    final edge = box.width - 16 - 24;
    for (final e in find.descendant(of: sidebar, matching: find.byWidgetPredicate((w) => w is SizedBox && w.width == 28 && w.child is Text)).evaluate()) {
      expect(tester.getRect(find.byWidget(e.widget)).right - box.left, edge, reason: 'an age ends at the number edge');
    }
    final count = find.descendant(of: sidebar, matching: find.byWidgetPredicate((w) => w is Text && w.data == '2'));
    expect(count, findsWidgets);
    for (final e in count.evaluate()) {
      expect(tester.getRect(find.byWidget(e.widget)).right - box.left, edge, reason: 'the Inbox count too');
    }
    final chevrons = find.descendant(of: sidebar, matching: find.byIcon(Icons.chevron_right));
    expect(chevrons, findsWidgets);
    for (final e in chevrons.evaluate()) {
      expect(tester.getCenter(find.byWidget(e.widget)).dx - box.left, 236);
    }
    expect(tester.getCenter(find.byIcon(Icons.keyboard_double_arrow_left)).dx, 236, reason: 'the collapse icon is in the column');
    // The hover ⋯ (hidden until hovered) and the footer's ⋯ are in the same column.
    final more = find.byIcon(Icons.more_horiz);
    var inSidebar = 0;
    for (final e in more.evaluate()) {
      final c = tester.getCenter(find.byWidget(e.widget));
      if (c.dx > box.width) continue;
      inSidebar++;
      expect(c.dx, 236, reason: 'a ⋯ in the sidebar');
    }
    expect(inSidebar, greaterThan(1), reason: 'the footer and an agent row have one');
    // The first project sits under the usage line (18 tall, 5 gap, a 32 row): 9 + 5 + 16 between their centres.
    expect(tester.getCenter(find.descendant(of: sidebar, matching: find.text('app')).first).dy -
        tester.getCenter(find.descendant(of: sidebar, matching: find.text('5h')).first).dy, 30);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('phone drawer: the same grid on the finger constants (16 + 6, 14 a level, a 44 trailing column)', (tester) async {
    final store = await installFakes();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(AppScope(store: store, child: const MaterialApp(home: AppShell())));
    await tester.pumpAndSettle();
    await openDrawer(tester);
    final drawer = find.byType(Drawer);
    final box = tester.getRect(drawer);
    double labelX(String t) => tester.getTopLeft(find.descendant(of: drawer, matching: find.text(t)).first).dx - box.left;
    // Origin 22 (16 + 6): 16 slot + 9 gap = 47; 14 a level.
    expect(labelX('Rigs'), 47);
    expect(labelX('Inbox'), 47);
    expect(labelX('app'), 47);
    expect(labelX('Add project folder'), 47);
    const trailing = 44.0;
    final inboxCount = find.descendant(of: drawer, matching: find.byWidgetPredicate((w) => w is Text && w.data == '2'));
    for (final e in inboxCount.evaluate()) {
      expect(tester.getRect(find.byWidget(e.widget)).right - box.left, box.width - 22 - trailing, reason: 'the count ends at the number edge');
    }
    for (final e in find.descendant(of: drawer, matching: find.byIcon(Icons.chevron_right)).evaluate()) {
      expect(tester.getCenter(find.byWidget(e.widget)).dx - box.left, box.width - 22 - trailing / 2);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the host header has a visible ⋯ in the trailing column that opens the host list (Restore all stopped rigs…)', (tester) async {
    final store = await installFakes();
    await pumpDesktop(tester, store);
    final sidebar = find.ancestor(of: find.text('Add project folder').first, matching: find.byType(ListView)).first;
    final more = find.descendant(of: sidebar, matching: find.byTooltip('Actions for ${homelab.name}'));
    expect(more, findsOneWidget);
    final box = tester.getRect(sidebar);
    expect(tester.getCenter(more).dx - box.left, 236, reason: 'the 24 column\'s centre, as every trailing icon');
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('Restore all stopped rigs…'), findsOneWidget);
    expect(find.text('Edit host'), findsOneWidget);
  });
}
