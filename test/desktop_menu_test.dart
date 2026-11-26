import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/host_store.dart' show isDesktop;
import 'package:pocket_rig/ui/action_rows.dart';
import 'package:pocket_rig/ui/desktop_menu.dart';
import 'package:pocket_rig/ui/theme.dart';

void main() {
  final ran = <String>[];
  ActionRows rows() => (
        items: [
          (Icons.chat_bubble_outline, 'Open chat', 'a subtitle the popup drops', () => ran.add('chat')),
          menuBreak,
          (Icons.edit_outlined, 'Rename', null, () => ran.add('rename')),
          (Icons.info_outline, 'Disabled one', null, null),
        ],
        danger: [('Kill…', Icons.dangerous_outlined, () => ran.add('kill'))],
      );

  Future<void> open(WidgetTester tester, {bool dark = false}) async {
    ran.clear();
    final k = dark ? Tokens.dark : Tokens.light;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(k, dark ? Brightness.dark : Brightness.light),
      home: Scaffold(body: Builder(builder: (c) => Center(child: TextButton(onPressed: () => showDesktopMenu(c, rows(), at: const Offset(200, 100)), child: const Text('go'))))),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('the popup: 28dp rows, 220dp wide, no subtitles, a separator between groups, the red action last', (tester) async {
    await open(tester);
    expect(find.text('a subtitle the popup drops'), findsNothing);
    final chat = tester.getRect(find.widgetWithText(MenuItemButton, 'Open chat'));
    expect(chat.height, 28);
    final widths = [for (final e in find.ancestor(of: find.text('Open chat'), matching: find.byType(Material)).evaluate()) (e.renderObject as RenderBox).size.width];
    expect(widths.where((w) => w < 400).reduce((a, b) => a > b ? a : b), 220, reason: 'the popup is 220 wide (a 4dp padding and the border inside)');
    expect(find.byType(Divider), findsNWidgets(2), reason: 'one at the break, one before the destructive action');
    final order = ['Open chat', 'Rename', 'Disabled one', 'Kill…'].map((t) => tester.getTopLeft(find.text(t)).dy).toList();
    expect(order, [...order]..sort(), reason: 'in order, the destructive action last');
    final k = Tokens.light;
    expect(tester.widget<Text>(find.text('Kill…')).style?.color ?? DefaultTextStyle.of(tester.element(find.text('Kill…'))).style.color, isNot(k.ink));
  });

  testWidgets('a click runs the action after the menu closed; Escape and an outside click close it; a disabled row does nothing', (tester) async {
    await open(tester);
    await tester.tap(find.text('Disabled one'));
    await tester.pump();
    expect(ran, isEmpty);
    expect(find.text('Rename'), findsOneWidget, reason: 'still open');
    await tester.tap(find.text('Rename'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(ran, ['rename']);
    expect(find.text('Rename'), findsNothing, reason: 'closed');

    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Rename'), findsNothing);
    expect(ran, isEmpty);

    await open(tester);
    await tester.tapAt(const Offset(700, 500));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Rename'), findsNothing);
    expect(ran, isEmpty);
  });

  testWidgets('arrows move and Return activates', (tester) async {
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 200));
    expect(ran.length, 1, reason: 'one action ran');
    expect(find.text('Rename'), findsNothing);
  });

  testWidgets('showActionRows: the popup on the Mac, the bottom sheet on the phone', (tester) async {
    addTearDown(() => isDesktop = false);
    for (final desktop in [true, false]) {
      isDesktop = desktop;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Tokens.light, Brightness.light),
        home: Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => showActionRows(c, 'Title', rows()), child: const Text('go')))),
      ));
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(MenuItemButton), desktop ? findsWidgets : findsNothing, reason: desktop ? 'popup' : 'no popup on the phone');
      expect(find.text('Title'), desktop ? findsNothing : findsOneWidget, reason: desktop ? 'the popup has no title' : 'the sheet shows it');
      expect(find.text('a subtitle the popup drops'), desktop ? findsNothing : findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    }
  });

  testWidgets('a ⋯ opens under its button: left edges together on the left, right edges together on the right', (tester) async {
    trackMenuAnchor();
    Future<void> tapAt(Alignment where, {bool hold = false}) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Tokens.light, Brightness.light),
        home: Scaffold(
            body: Align(
                alignment: where,
                child: Builder(builder: (c) => IconButton(tooltip: 'more', onPressed: () => showDesktopMenu(c, rows()), icon: const Icon(Icons.more_horiz))))),
      ));
      final g = await tester.startGesture(tester.getCenter(find.byTooltip('more')));
      if (hold) await tester.pump(const Duration(milliseconds: 600));
      await g.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    ran.clear();
    await tapAt(Alignment.topLeft);
    var button = tester.getRect(find.byType(IconButton));
    var item = tester.getRect(find.widgetWithText(MenuItemButton, 'Open chat'));
    expect(item.left - 5, closeTo(button.left, 2), reason: 'the menu\'s left edge (4 padding, 1 border) is the button\'s');
    expect(item.top - 5, closeTo(button.bottom + 4, 2), reason: 'under it');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 200));

    await tapAt(Alignment.topRight);
    button = tester.getRect(find.byType(IconButton));
    item = tester.getRect(find.widgetWithText(MenuItemButton, 'Open chat'));
    expect(item.right + 5, closeTo(button.right, 2), reason: 'the right edges together');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('a rebuild while the popup is open keeps the arrow-focused row focused', (tester) async {
    final dark = ValueNotifier(false);
    ran.clear();
    await tester.pumpWidget(ValueListenableBuilder<bool>(
      valueListenable: dark,
      builder: (_, d, __) => MaterialApp(
        theme: buildTheme(d ? Tokens.dark : Tokens.light, d ? Brightness.dark : Brightness.light),
        home: Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => showDesktopMenu(c, rows(), at: const Offset(200, 100)), child: const Text('go')))),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    dark.value = true; // the theme changes: the menu rebuilds
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 200));
    expect(ran, ['rename'], reason: 'the second row was still the focused one');
  });

  test('the highlighted row stands out from the menu in both themes', () {
    for (final k in [Tokens.light, Tokens.dark]) {
      final a = menuHighlight(k).computeLuminance(), b = k.surface.computeLuminance();
      final ratio = (a > b ? a + .05 : b + .05) / (a > b ? b + .05 : a + .05);
      expect(ratio, greaterThanOrEqualTo(1.25), reason: k.isDark ? 'dark' : 'light');
    }
  });
}
