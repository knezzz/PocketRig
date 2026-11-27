import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart' show Project;
import 'package:pocket_rig/ui/progress_bar.dart' show ContextBar;
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/chat_cache.dart' show chatKey;
import 'package:pocket_rig/ui/app_icon.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;
import 'package:pocket_rig/ui/recent_screen.dart';
import 'package:pocket_rig/ui/rigs_home.dart';
import 'package:pocket_rig/ui/kit.dart' show AgentRow;
import 'package:pocket_rig/ui/theme.dart' show Tokens;

import 'app_icon_finders.dart';
import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

void main() {
  test('a project is named as the sidebar lists it, whether or not it is pinned or has a rig; only agents with no folder are '
      '"not a known project"', () {
    final derived = projectHeading(Project(path: '/Users/me/code/app'));
    expect((derived.title, derived.sub, derived.unknown), ('app', '~/code/app', false), reason: 'a folder agents run in is a project');
    final pinned = projectHeading(Project(path: '/Users/me/code/site', pinned: true));
    expect((pinned.title, pinned.sub, pinned.unknown), ('site', '~/code/site', false));
    final none = projectHeading(Project(path: '(no folder)'));
    expect((none.title, none.sub, none.unknown), ('No folder', 'not a known project', true));
  });

  test('a home directory shows as ~ (macOS and Linux)', () {
    expect(tildePath('/Users/me/code/app'), '~/code/app');
    expect(tildePath('/home/me/x'), '~/x');
    expect(tildePath('/srv/app'), '/srv/app');
    expect(tildePath('~/notes'), '~/notes');
  });

  testWidgets('Rigs home: every host, its projects with their rigs as cards of agent rows (no rig badge), then what runs '
      'outside a rig; the strip leads to the Inbox', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    showLoose = true;
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final home = find.byKey(const ValueKey('rigs-cards'));
    Finder inHome(Finder f) => find.descendant(of: home, matching: f);
    expect(home, findsOneWidget, reason: 'the Rigs home is the start screen');
    expect(inHome(find.text('HOMELAB')), findsOneWidget, reason: 'a host header when there are several hosts');
    expect(inHome(find.text('app')), findsOneWidget, reason: 'its project, with its path');
    const k = Tokens.light;
    Color? folderOf(String project) => tester
        .widget<AppIcon>(find.descendant(
            of: find.ancestor(of: inHome(find.text(project)), matching: find.byType(InkWell)).first, matching: appIcon(AppIconKind.folder)))
        .color;
    expect(folderOf('app'), k.accent, reason: 'a project with work: the accent');
    // An empty project, or one with only stopped rigs (loyalty), is not on the home at all.
    await tester.scrollUntilVisible(inHome(find.text('site')), 200, scrollable: inHome(find.byType(Scrollable)).first);
    expect(inHome(find.text('dotfiles'), ), findsNothing);
    expect(inHome(find.text('loyalty')), findsNothing);
    await tester.drag(inHome(find.byType(ListView)).first, const Offset(0, 3000));
    await tester.pump();
    expect(inHome(find.text('~/code/app')), findsOneWidget, reason: 'the path in the host\'s ~ form, not /Users/…');
    expect(inHome(find.textContaining('/Users/')), findsNothing);
    expect(inHome(find.text('conveyor')), findsOneWidget, reason: 'the rig as a card');
    expect(inHome(find.byType(AgentRow)), findsWidgets, reason: 'its agents as rows');
    expect(inHome(agentIcon()), findsWidgets);
    expect(find.descendant(of: inHome(find.byType(AgentRow)).first, matching: appIcon(AppIconKind.rig)), findsNothing,
        reason: 'no rig badge inside the rig\'s own card');

    // No tabs: one list. On a wide window the Inbox is a column beside the cards, in place of the strip.
    expect(inHome(find.text('Working')), findsNothing, reason: 'no All / Needs you / Working tabs');
    expect(inHome(find.textContaining('agents need you')), findsNothing);
    expect(find.descendant(of: find.byType(RigsHome), matching: find.textContaining('INBOX · ')), findsOneWidget);

    await tester.scrollUntilVisible(inHome(find.text('scratch')), 200, scrollable: inHome(find.byType(Scrollable)).first);
    expect(inHome(find.text('scratch')), findsOneWidget, reason: 'an agent outside a rig, directly under the project');
    await tester.drag(inHome(find.byType(ListView)).first, const Offset(0, 3000));
    await tester.pump();

    // The column's Open › goes to the whole Inbox.
    await tester.tap(find.descendant(of: find.byType(RigsHome), matching: find.text('Open ›')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(RecentScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a row\'s context bar ends its first line (one width, the % beside it), and its second line says what the agent '
      'last did when the chat log is cached, else its state', (tester) async {
    final store = await installFakes();
    AppShell.debugStartOnInbox = false;
    await pumpDesktop(tester, store);
    final feed = fleet.feedFor(homelab);
    for (var i = 0; i < 5 && feed.rigs.isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final impl = feed.rigs.firstWhere((r) => r.rig.name == 'conveyor').seats.firstWhere((s) => s.logicalId == 'impl');
    final lead = feed.rigs.firstWhere((r) => r.rig.name == 'conveyor').seats.firstWhere((s) => s.logicalId == 'lead');
    feed.lastMessages = {
      chatKey(impl): LastMessage(text: 'Done with the kit', fromUser: false, tool: 'EDIT lib/ui/kit.dart'),
      chatKey(lead): LastMessage(text: 'I would like to push this to main.', fromUser: false),
    };
    fleet.toggleRig('r:${homelab.id}|r-conveyor', allShown: false);
    await tester.pump(const Duration(seconds: 1));
    final home = find.byKey(const ValueKey('rigs-cards'));
    expect(find.descendant(of: home, matching: find.text('EDIT lib/ui/kit.dart')), findsOneWidget, reason: 'the newest tool call');
    expect(find.descendant(of: home, matching: find.text('working · now')), findsNothing, reason: 'in place of the state words');
    // Every bar is 56 wide, under its row's age, and ends at one x; each % sits right of its bar.
    final bars = find.descendant(of: home, matching: find.byType(ContextBar));
    expect(bars, findsWidgets);
    final rights = {for (final e in bars.evaluate()) tester.getRect(find.byWidget(e.widget)).right.round()};
    expect(rights.length, 1, reason: 'one x for every bar: $rights');
    final lefts = {for (final e in bars.evaluate()) tester.getRect(find.byWidget(e.widget)).left.round()};
    expect(lefts.length, 1, reason: 'and every bar starts at one x, whatever the age beside it says: $lefts');
    for (final e in bars.evaluate()) {
      expect(tester.getSize(find.byWidget(e.widget)).width, 56);
    }
    expect(find.descendant(of: home, matching: find.text('62%')), findsOneWidget);
    // A waiting agent says NEEDS YOU in the accent, with what it said under its name.
    expect(find.descendant(of: home, matching: find.textContaining('NEEDS YOU', findRichText: true)), findsWidgets);
    expect(find.descendant(of: home, matching: find.text('I would like to push this to main.')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
