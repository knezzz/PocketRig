import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/chat/permission_dock.dart';
import 'package:pocket_rig/ui/permission_card.dart';
import 'package:pocket_rig/ui/theme.dart';

void main() {
  testWidgets('a permission request: a band that says who wants what, the command in the dark block, three equal buttons; ⌘↵ allows and esc denies',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final log = <String>[];
    final ask = PermissionAsk(tool: 'Bash', detail: 'npm run test:integration');
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: PermissionDock(
            who: 'lead',
            ask: ask,
            question: ask.question('lead'),
            desktop: true,
            onAllow: () => log.add('allow'),
            onDeny: () => log.add('deny'),
            onAlways: () => log.add('always'),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('lead wants to run'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Permission request: Allow lead to run this command\\?')), findsOneWidget,
        reason: 'a screen reader still hears the whole question');
    final code = tester.widget<Container>(
        find.descendant(of: find.byType(PermissionCode), matching: find.byType(Container)).first);
    expect((code.decoration! as BoxDecoration).color, Tokens.light.termBg, reason: 'the dark code block');
    expect(find.text('npm run test:integration'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Deny'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Always'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Allow once'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(log, ['allow', 'deny']);
    semantics.dispose();
  });
}
