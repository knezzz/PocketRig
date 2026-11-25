import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/kit.dart';

void main() {
  testWidgets('every NavRow is one height and one label x; dashed only adds the border; no tap is inert', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          NavRow(leading: const Icon(Icons.inbox_outlined, size: 16), label: 'Inbox', count: 2, selected: true, onTap: () => taps++),
          NavRow(leading: const Icon(Icons.settings_outlined, size: 16), label: 'Hosts and settings', onTap: () => taps++),
          NavRow(leading: const Icon(Icons.add, size: 16), label: 'Add project folder', dashed: true, onTap: () => taps++),
          const NavRow(leading: Icon(Icons.add, size: 16), label: 'Offline add', dashed: true, dimmed: true),
        ]),
      ),
    ));
    final rows = find.byType(NavRow);
    final heights = {for (final e in rows.evaluate()) tester.getSize(find.byWidget(e.widget)).height};
    expect(heights, {navRowHeight()});
    final xs = {for (final l in ['Inbox', 'Hosts and settings', 'Add project folder', 'Offline add']) tester.getTopLeft(find.text(l)).dx};
    expect(xs.length, 1);
    await tester.tap(find.text('Add project folder'));
    await tester.tap(find.text('Offline add'), warnIfMissed: false);
    expect(taps, 1);
  });
}
