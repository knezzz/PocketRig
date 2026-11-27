import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/action_rows.dart';
import 'package:pocket_rig/ui/app_icon.dart';
import 'package:pocket_rig/ui/desktop_menu.dart';
import 'package:pocket_rig/ui/rig/rig_header.dart';
import 'package:pocket_rig/ui/theme.dart';

void main() {
  // The rig row's buttons wrapped the icon in IconTheme(size: 16), which replaced the button's icon colour: an AppIcon then fell
  // back to grey while a Material Icon took the label's colour.
  for (final dark in [true, false]) {
    testWidgets('every icon in the rig row is its label\'s colour (${dark ? 'dark' : 'light'})', (tester) async {
      final k = dark ? Tokens.dark : Tokens.light;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(k, dark ? Brightness.dark : Brightness.light),
        home: Builder(
          builder: (c) => Row(children: rigHeaderButtons(c, RigActionSet(onNew: () {}, onMessageAll: () {}, onRoom: () {}, onReminders: () {}))),
        ),
      ));
      for (final label in ['New', 'Message all', 'Room', 'Reminders']) {
        final button = find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));
        final text = DefaultTextStyle.of(tester.element(find.text(label))).style.color;
        final icon = find.descendant(of: button, matching: find.byWidgetPredicate((w) => w is Icon || w is AppIcon));
        final c = IconTheme.of(tester.element(icon)).color;
        expect(c, isNotNull, reason: label);
        expect(c, text, reason: '$label: icon vs label');
      }
    });
    testWidgets('a menu row\'s icon is its label\'s colour, red stays red (${dark ? 'dark' : 'light'})', (tester) async {
      final k = dark ? Tokens.dark : Tokens.light;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(k, dark ? Brightness.dark : Brightness.light),
        home: Builder(
          builder: (c) => TextButton(
            onPressed: () => showDesktopMenu(c, (items: [(Icons.edit_outlined, 'Rename', null, () {})], danger: [('Delete', Icons.delete_outline, () {})])),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      for (final label in ['Rename', 'Delete']) {
        final row = find.ancestor(of: find.text(label), matching: find.byType(MenuItemButton));
        final text = DefaultTextStyle.of(tester.element(find.text(label))).style.color;
        final c = IconTheme.of(tester.element(find.descendant(of: row, matching: find.byType(Icon)))).color;
        expect(c, text, reason: '$label: icon vs label');
      }
    });
  }
}
