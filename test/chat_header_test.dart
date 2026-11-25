import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/git_status.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/chat/chat_header.dart';
import 'package:pocket_rig/ui/chat/git_cards.dart';

import 'golden/fixtures.dart';

/// The chat's header is set up once (chatAgentHeader), for the single chat and the rig's paged chat.
void main() {
  testWidgets('title, mono subtitle, Menu, then the seat tabs over the git bar with 4 between; either one alone has no gap; neither, no bottom', (tester) async {
    final store = await installFakes();
    final seat = Seat(rigId: 'r', logicalId: 'lead', sessionName: 'lead@r', runtime: 'claude-code');
    final git = GitStatus(branch: 'main', root: '/w', changedFiles: 1);
    var opened = 0;
    Future<void> show({GitStatus? g, Widget? tabs}) => tester.pumpWidget(AppScope(
        store: store,
        child: MaterialApp(
            home: Scaffold(
                body: Builder(
                    builder: (c) => chatAgentHeader(c,
                        seat: seat, title: 'lead', subtitle: 'conveyor · app', onMenu: () {}, onSwitch: () {}, git: g, onGit: (_) => opened++, tabs: tabs))))));
    final tabs = Container(key: const ValueKey('tabs'), height: 30);
    await show(g: git, tabs: tabs);
    await tester.pump();
    expect(find.text('lead'), findsWidgets);
    expect(find.text('conveyor · app'), findsOneWidget);
    expect(find.byTooltip('Menu'), findsOneWidget);
    final tabsBox = tester.getRect(find.byKey(const ValueKey('tabs')));
    final bar = tester.getRect(find.byType(GitBar));
    expect(bar.top - tabsBox.bottom, 4, reason: 'the tabs over the git bar with 4 between');
    await tester.tap(find.byType(GitBar));
    expect(opened, 1, reason: 'the git sheet callback gets the status');
    await show(g: git);
    await tester.pump();
    expect(find.byType(GitBar), findsOneWidget);
    expect(find.byKey(const ValueKey('tabs')), findsNothing);
    await show(tabs: tabs);
    await tester.pump();
    expect(find.byType(GitBar), findsNothing, reason: 'not a repo: no git bar');
    expect(find.byKey(const ValueKey('tabs')), findsOneWidget);
    await show();
    await tester.pump();
    expect(find.byType(GitBar), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
