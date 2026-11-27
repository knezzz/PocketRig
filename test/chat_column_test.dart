import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/host_store.dart' show isDesktop;
import 'package:pocket_rig/ui/agent_header.dart';
import 'package:pocket_rig/ui/chat/message_views.dart' show UserBubble;
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/info_bar.dart';

import 'golden/fixtures.dart';

void main() {
  for (final w in [1280.0, 1800.0]) {
    testWidgets('chat at $w wide: the transcript, the git line and the composer fill the main area, left edges and right edges together; the bars share one height',
        (tester) async {
      final store = await installFakes();
      await tester.binding.setSurfaceSize(Size(w, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
          home: phone(store, ChatScreen(rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'impl'), asChat: true))));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final area = tester.getRect(find.byType(ChatPage));
      final list = tester.getRect(find.descendant(of: find.byType(ChatPage), matching: find.byType(ListView)).first);
      final composer = tester.getRect(find.byType(Composer));
      expect(list.left, area.left, reason: 'the transcript starts at the main area\'s left edge');
      expect(list.right, area.right, reason: 'and runs to its right edge: no centred column');
      expect(composer.left, list.left, reason: 'the composer lines up with the transcript');
      expect(composer.right, list.right);
      expect(composer.width, greaterThan(720));
      final bars = find.byType(InfoBar);
      expect(bars, findsNWidgets(2), reason: 'the git line and the tool-call fold');
      for (final b in bars.evaluate()) {
        expect((b.renderObject! as RenderBox).size.height, InfoBar.height);
      }
      final branch = tester.widget<AgentHeader>(find.byType(AgentHeader)).branch!;
      expect(find.text(branch), findsOneWidget, reason: 'the header chip shows the branch; the git line does not repeat it');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  }

  testWidgets('a user bubble is at most 80% of the chat\'s own width, not of the window\'s', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Align(alignment: Alignment.centerLeft, child: SizedBox(width: 500, child: UserBubble('word ' * 40))))));
    final bubble = tester.getRect(find.byType(SelectableText));
    expect(bubble.width, lessThanOrEqualTo(500 * 0.8), reason: 'the box is 500 wide in a 1800 window');
  });

  for (final (desktop, inset) in [(true, 20.0), (false, 10.0)]) {
    testWidgets('the composer box\'s edges: ${desktop ? 'on the Mac the chat gutter, as the transcript\'s and the cards\'' : 'on the phone 10'}', (tester) async {
      final store = await installFakes();
      isDesktop = desktop;
      addTearDown(() => isDesktop = false);
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
          home: phone(store, ChatScreen(rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'impl'), asChat: true))));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final composer = tester.getRect(find.byType(Composer));
      final box = tester.getRect(find.descendant(
          of: find.byType(Composer),
          matching: find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).border != null)).first);
      expect(box.left - composer.left, inset);
      expect(composer.right - box.right, inset);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  }
}
