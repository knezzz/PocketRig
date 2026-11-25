import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/theme.dart';
import 'package:pocket_rig/ui/kit.dart';

void main() {
  testWidgets('showActionSheet: rows run after the sheet closes, a null action is disabled, danger stays red',
      (tester) async {
    final log = <String>[];
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    Future<void> open() async {
      unawaited(showActionSheet(ctx, 'Menu', [
        (Icons.terminal_outlined, 'Shell', 'here', () => log.add('shell')),
        (Icons.open_in_new_outlined, 'Off', null, null),
      ], danger: [('Remove…', Icons.delete_outline, () => log.add('remove'))]));
      await tester.pumpAndSettle();
    }

    await open();
    expect(tester.widget<OptionRow>(find.widgetWithText(OptionRow, 'Off')).onTap, isNull);
    expect(tester.widget<Icon>(find.byIcon(Icons.terminal_outlined)).size, 24);
    final remove = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(remove.style!.backgroundColor!.resolve({}), Tokens.light.kill);
    await tester.tap(find.text('Shell'));
    await tester.pumpAndSettle();
    expect(log, ['shell']);
    expect(find.text('Menu'), findsNothing, reason: 'the sheet closed');

    await open();
    await tester.tap(find.text('Remove…'));
    await tester.pumpAndSettle();
    expect(log, ['shell', 'remove']);
  });

  testWidgets('a row whose screen is gone does not run', (tester) async {
    final log = <String>[];
    late BuildContext ctx;
    late StateSetter gone;
    var alive = true;
    await tester.pumpWidget(MaterialApp(home: StatefulBuilder(builder: (c, set) {
      gone = set;
      return alive
          ? Builder(builder: (c) {
              ctx = c;
              return const SizedBox();
            })
          : const SizedBox();
    })));
    unawaited(showActionSheet(ctx, 'Menu', [(Icons.terminal_outlined, 'Shell', null, () => log.add('shell'))]));
    await tester.pumpAndSettle();
    gone(() => alive = false); // the screen that opened the sheet is removed while it is open
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shell'));
    await tester.pumpAndSettle();
    expect(log, isEmpty);
  });
}
