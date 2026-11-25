import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsAction;
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/kit.dart';
import 'package:pocket_rig/ui/theme.dart';

/// A RowTile whose content is [height] tall, with a chevron when [fold] is given.
Future<void> _pump(
  WidgetTester tester, {
  double height = 52,
  bool withFold = true,
  List<String>? log,
  bool open = false,
}) =>
    tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 390,
            child: RowTile(
              minHeight: 0,
              padding: EdgeInsets.zero,
              arrow: true,
              fold: withFold ? (name: 'thing', open: open, onTap: () => log?.add('fold')) : null,
              onTap: () => log?.add('open'),
              child: SizedBox(height: height, child: const Text('body')),
            ),
          ),
        ),
      ),
    ));

Finder get _chevron => find.descendant(of: find.byTooltip('Unfold thing'), matching: find.byType(InkWell));

void main() {
  testWidgets('the chevron is a square as tall as the row, clamped to 44..56 and centred', (tester) async {
    for (final (rowH, side) in [(40.0, 44.0), (52.0, 52.0), (80.0, 56.0)]) {
      await _pump(tester, height: rowH);
      expect(tester.getSize(_chevron), Size(side, side), reason: 'a ${rowH}dp row');
      final row = tester.getRect(find.byType(RowTile));
      expect(tester.getCenter(_chevron).dy, closeTo(row.center.dy, 0.01), reason: 'centred');
      expect(row.height, rowH < 44 ? 44 : rowH);
    }
  });

  testWidgets('the slot is always 56 wide, so titles line up across rows of any height', (tester) async {
    final lefts = <double>[];
    for (final h in [40.0, 52.0, 80.0]) {
      await _pump(tester, height: h);
      lefts.add(tester.getTopLeft(find.text('body')).dx);
      final slot = tester.getRect(find.byType(InkWell).last).left - tester.getRect(find.byType(RowTile)).left;
      expect(slot, tileFoldMax, reason: 'a ${h}dp row');
      final chevron = tester.getRect(_chevron);
      expect(chevron.center.dx, closeTo(tileFoldMax / 2, 0.01), reason: 'centred in the slot');
    }
    expect(lefts.toSet(), hasLength(1), reason: lefts.join(', '));
  });

  testWidgets('without a fold there is no chevron slot: the body starts at the left edge', (tester) async {
    await _pump(tester, withFold: false);
    expect(find.byType(Tooltip), findsNothing);
    expect(tester.getTopLeft(find.byType(InkWell)).dx, 0);
  });

  testWidgets('the chevron only folds, the body only opens, and the body starts where the chevron ends',
      (tester) async {
    final log = <String>[];
    await _pump(tester, log: log);
    await tester.tap(_chevron);
    expect(log, ['fold']);
    await tester.tap(find.text('body'));
    expect(log, ['fold', 'open']);
    expect(tester.getTopLeft(find.byType(InkWell).last).dx, tileFoldMax, reason: 'the slot ends, the body starts');
    expect(find.byIcon(Icons.chevron_right), findsNWidgets(2), reason: 'the fold chevron and the ›');
  });

  testWidgets('both are reachable by Tab and Enter and speak as buttons with a tap action', (tester) async {
    final handle = tester.ensureSemantics();
    final log = <String>[];
    await _pump(tester, log: log);
    for (final finder in [_chevron, find.byType(InkWell).last]) {
      expect(tester.getSemantics(finder).getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    }
    for (var i = 0; i < 4 && log.length < 2; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
    }
    expect(log, ['fold', 'open']);
    handle.dispose();
  });

  testWidgets('a plain RowTile is ONE semantics node with label, tap and long press', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: Scaffold(body: RowTile(title: 'Plain', meta: 'meta', onTap: () {}, onLongPress: () {})),
    ));
    final buttons = <SemanticsNode>[];
    void visit(SemanticsNode n) {
      if (n.getSemanticsData().flagsCollection.isButton) buttons.add(n);
      n.visitChildren((c) {
        visit(c);
        return true;
      });
    }

    visit(tester.renderObject(find.byType(Scaffold)).owner!.semanticsOwner!.rootSemanticsNode!);
    expect(buttons, hasLength(1), reason: buttons.map((n) => n.label).join(' | '));
    final d = buttons.single.getSemanticsData();
    expect(d.label, contains('Plain'));
    expect(d.hasAction(SemanticsAction.tap), isTrue);
    expect(d.hasAction(SemanticsAction.longPress), isTrue);
    handle.dispose();
  });

  testWidgets('reserveFold keeps the 56 slot empty so a leaf row lines up with its foldable siblings', (tester) async {
    await _pump(tester);
    final folded = tester.getTopLeft(find.text('body')).dx;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: Scaffold(
        body:
            RowTile(minHeight: 0, padding: EdgeInsets.zero, reserveFold: true, onTap: () {}, child: const Text('body')),
      ),
    ));
    expect(tester.getTopLeft(find.text('body')).dx, folded);
    expect(find.byType(Tooltip), findsNothing, reason: 'a slot, no chevron');
  });

  testWidgets('a fold tile can be measured by Intrinsic* parents', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: Scaffold(
        body: IntrinsicHeight(
          child: RowTile(
              minHeight: 0,
              padding: EdgeInsets.zero,
              fold: (name: 'x', open: false, onTap: () {}),
              onTap: () {},
              child: const SizedBox(height: 70, child: Text('body'))),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(RowTile)).height, 70);
  });

  testWidgets('a plain RowTile is unchanged: title and meta, no chevron, no arrow', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: Scaffold(body: RowTile(title: 'Plain', meta: 'meta', onTap: () {})),
    ));
    expect(find.text('Plain'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(tester.getSize(find.byType(RowTile)).height, 60);
  });

  testWidgets('the › ends tileArrowInset from the right edge whatever the row padding, and is no button',
      (tester) async {
    final handle = tester.ensureSemantics();
    for (final right in [4.0, 8.0, 19.0]) {
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Tokens.light, Brightness.light),
        home: Scaffold(
          body: RowTile(
              minHeight: 0,
              padding: EdgeInsets.fromLTRB(14, 6, right, 6),
              arrow: true,
              onTap: () {},
              child: const Text('body')),
        ),
      ));
      final w = tester.getSize(find.byType(RowTile)).width;
      expect(tester.getRect(find.byIcon(Icons.chevron_right)).right, w - tileArrowInset, reason: 'padding $right');
    }
    handle.dispose();
  });

  testWidgets('semantics: the row is one button that opens, the chevron a second, with expanded state', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Tokens.light, Brightness.light),
      home: Scaffold(
        body: RowTile(
          minHeight: 0,
          padding: EdgeInsets.zero,
          arrow: true,
          openLabel: 'Open thing, 2 seats',
          fold: (name: 'thing', open: true, onTap: () {}),
          onTap: () {},
          child: const SizedBox(height: 50, child: Text('body')),
        ),
      ),
    ));
    final buttons = <SemanticsNode>[];
    void visit(SemanticsNode n) {
      if (n.getSemanticsData().flagsCollection.isButton) buttons.add(n);
      n.visitChildren((c) {
        visit(c);
        return true;
      });
    }

    visit(tester.renderObject(find.byType(Scaffold)).owner!.semanticsOwner!.rootSemanticsNode!);
    final dump = buttons.map((n) => n.getSemanticsData()).toList();
    expect(dump, hasLength(2), reason: buttons.map((n) => n.label).join(' | '));
    final open = dump.firstWhere((d) => d.label == 'Open thing, 2 seats');
    final fold = dump.firstWhere((d) => d.label == 'Fold thing');
    expect(open.hasAction(SemanticsAction.tap), isTrue);
    expect(fold.hasAction(SemanticsAction.tap), isTrue);
    expect(fold.flagsCollection.isExpanded, Tristate.isTrue);
    handle.dispose();
  });

  testWidgets('the chevron turns a quarter when the row opens', (tester) async {
    for (final (open, turns) in [(false, 0.0), (true, 0.25)]) {
      await _pump(tester, open: open);
      await tester.pumpAndSettle();
      final r = tester.widget<AnimatedRotation>(
          find.descendant(of: find.byType(FoldChevron), matching: find.byType(AnimatedRotation)));
      expect(r.turns, turns, reason: open ? 'open' : 'closed');
    }
  });
}
