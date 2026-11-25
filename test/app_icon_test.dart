import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/app_icon.dart';

void main() {
  testWidgets('every kind draws at the size asked and takes the colour; a different colour repaints', (tester) async {
    for (final kind in AppIconKind.values) {
      await tester.pumpWidget(MaterialApp(home: Center(child: AppIcon(kind, size: 20, color: Colors.red))));
      expect(tester.getSize(find.byType(AppIcon)), const Size(20, 20), reason: '$kind');
      await tester.pumpWidget(MaterialApp(home: Center(child: AppIcon(kind, size: 20, color: Colors.blue))));
      expect(tester.widget<AppIcon>(find.byType(AppIcon)).color, Colors.blue);
    }
  });

  testWidgets('Room is two conversation bubbles and a node; Message all is one bubble, three lines and a node', (tester) async {
    RenderObject paintOf(AppIconKind kind) {
      return tester.renderObject(find.descendant(of: find.byType(AppIcon), matching: find.byType(CustomPaint)).first);
    }

    await tester.pumpWidget(const MaterialApp(home: Center(child: AppIcon(AppIconKind.room, size: 24, color: Colors.red))));
    expect(paintOf(AppIconKind.room), paints..path()..path()..circle());
    await tester.pumpWidget(const MaterialApp(home: Center(child: AppIcon(AppIconKind.broadcast, size: 24, color: Colors.red))));
    expect(paintOf(AppIconKind.broadcast), paints..path()..line()..line()..line()..circle());
  });
}
