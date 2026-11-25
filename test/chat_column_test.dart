import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/agent_header.dart';
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/info_bar.dart';
import 'package:pocket_rig/ui/page_column.dart';

import 'golden/fixtures.dart';

void main() {
  testWidgets('chat: the messages and the composer stay in the 720 column on a wide window; the bars share one height',
      (tester) async {
    final store = await installFakes();
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: phone(store, ChatScreen(rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'impl'), asChat: true))));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final list = find.descendant(of: find.byType(PageColumn).first, matching: find.byType(ListView));
    expect(tester.getSize(list.first).width, chatColumnWidth, reason: 'no line runs past the column');
    expect(tester.getSize(find.byType(Composer)).width, chatColumnWidth, reason: 'the composer lines up with it');
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
