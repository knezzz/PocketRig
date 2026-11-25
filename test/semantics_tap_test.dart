// A screen reader activates a button through its semantics node's tap action. A Semantics(button: true,
// excludeSemantics: true) wrapper with no onTap of its own hides its child's tap, so the node says "button" but a
// double-tap does nothing. Walk the semantics tree of the main screens and require that every enabled button
// has a tap action.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;

import 'package:pocket_rig/ui/chat/question_card.dart' show AskQuestion;
import 'package:pocket_rig/ui/inbox/question_carousel.dart';
import 'package:pocket_rig/ui/kit.dart' show Segmented;
import 'package:pocket_rig/ui/needs_you_banner.dart';
import 'package:pocket_rig/ui/project_screen.dart';

import 'golden/fixtures.dart';
import 'ink_ripple_test.dart' show ScreenWalk, screenWalks, settleScreen, walkHeight;

/// Buttons with no tap action under [n], as "label (x,y WxH)".
void _buttonsWithoutTap(SemanticsNode n, String screen, Set<String> out) {
  final d = n.getSemanticsData();
  final disabled = d.flagsCollection.isEnabled == ui.Tristate.isFalse;
  if (d.flagsCollection.isButton && !disabled && !d.hasAction(SemanticsAction.tap)) {
    final r = n.rect;
    out.add('[$screen] "${d.label.replaceAll('\n', ' ')}" ${r.width.toStringAsFixed(0)}x${r.height.toStringAsFixed(0)}'
        ' at ${r.left.toStringAsFixed(0)},${r.top.toStringAsFixed(0)}');
  }
  n.visitChildren((c) {
    _buttonsWithoutTap(c, screen, out);
    return true;
  });
}

void main() {
  testWidgets('every enabled button on the main screens has a tap action for a screen reader', (tester) async {
    tester.view.physicalSize = const ui.Size(390, walkHeight);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final handle = tester.ensureSemantics();

    Future<void> tab(WidgetTester t, String label) async {
      await t.tap(find.descendant(of: find.byType(Segmented<int>), matching: find.text(label)).first);
      await settleScreen(t);
    }

    final walks = <ScreenWalk>[
      ...screenWalks(),
      // The project's other tabs (the shared walk only sees the first).
      for (final label in ['Agents', 'Worktrees', 'Specs'])
        ScreenWalk('ProjectScreen > $label', () => const ProjectScreen(path: app),
            prepare: () => showLoose = true, act: (t) => tab(t, label)),
      // The in-app banner over Projects, as PocketRigApp shows it (with another seat waiting, for "N more").
      ScreenWalk('Banner', () {
        needsYouAlerts.show(SeatAlert(
            host: homelab,
            rig: rigFromFixture('r-conveyor'),
            seat: seatFromFixture('r-conveyor', 'lead'),
            project: 'app'));
        return const Stack(children: [
          AppShell(),
          Positioned(left: 10, right: 10, top: 53, child: NeedsYouBanner()),
        ]);
      }, root: true),
      // The Inbox question card: its previous/next arrows.
      ScreenWalk(
          'Question carousel',
          () => Scaffold(
                body: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 60, 16, 16),
                  child: QuestionCarousel(
                    seatName: 'review',
                    onSend: (_, __) {},
                    onDecline: () {},
                    questions: const [
                      AskQuestion('Which branch?', 'Branch', false, [('main', null), ('release', null)]),
                      AskQuestion('What should it run?', 'Checks', true, [('Unit tests', null)]),
                    ],
                  ),
                ),
              )),
    ];

    final bad = <String>{};
    var screens = 0;
    for (final w in walks) {
      needsYouAlerts.reset();
      final store = await installFakes();
      w.prepare?.call();
      await tester.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false, home: phone(store, w.screen(), root: w.root, height: walkHeight)));
      await settleScreen(tester);
      await w.act?.call(tester);
      final root = tester.binding.renderViews.first.owner?.semanticsOwner?.rootSemanticsNode;
      if (root != null) {
        screens++;
        _buttonsWithoutTap(root, w.name, bad);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    }
    handle.dispose();

    expect(screens, greaterThan(15), reason: 'only $screens screens had a semantics tree');
    expect(bad, isEmpty, reason: '${bad.length} button nodes have no tap action:\n${(bad.toList()..sort()).join('\n')}');
  });
}
