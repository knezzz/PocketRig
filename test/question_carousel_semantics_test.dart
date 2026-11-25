import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/chat/question_card.dart' show AskQuestion;
import 'package:pocket_rig/ui/inbox/question_carousel.dart';

/// Nodes under [n] whose label mentions [text].
int _nodesNaming(SemanticsNode n, String text) {
  var count = n.getSemanticsData().label.contains(text) ? 1 : 0;
  n.visitChildren((c) {
    count += _nodesNaming(c, text);
    return true;
  });
  return count;
}

void main() {
  testWidgets('each carousel option is one screen-reader node: its label, checked, and a tap', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: QuestionCarousel(
            seatName: 'reviewer',
            questions: const [
              AskQuestion('Squash the fixups?', 'Commits', false, [('Combine', 'One clean commit'), ('Keep them', null)]),
            ],
            onSend: (_, __) {},
            onDecline: () {},
          ),
        ),
      ),
    ));
    final root = tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!;
    for (final label in ['Combine', 'Keep them']) {
      expect(_nodesNaming(root, label), 1, reason: '$label is exactly one node (not an unlabeled wrapper plus a labeled row)');
      final d = tester.getSemantics(find.text(label)).getSemanticsData();
      expect(d.label, contains(label));
      expect(d.hasAction(SemanticsAction.tap), isTrue, reason: '$label can be activated');
      expect(d.flagsCollection.isChecked, isNot(ui.CheckedState.none), reason: '$label says whether it is selected');
    }
    expect(tester.getSemantics(find.text('Combine')).getSemanticsData().flagsCollection.isChecked, ui.CheckedState.isFalse);
    await tester.tap(find.text('Combine'));
    await tester.pump();
    expect(tester.getSemantics(find.text('Combine')).getSemanticsData().flagsCollection.isChecked, ui.CheckedState.isTrue,
        reason: 'the node that names the option says it is selected');
    handle.dispose();
  });
}
