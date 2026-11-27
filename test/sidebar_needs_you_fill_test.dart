import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/ui/host_color.dart' show contrastRatio;
import 'package:pocket_rig/ui/theme.dart';

import 'desktop_test.dart' show pumpDesktop;
import 'golden/fixtures.dart';

void main() {
  testWidgets('sidebar: an agent that needs you has the needs-you tint across its whole row; one that does not, none', (tester) async {
    final store = await installFakes();
    fleet.toggleRig('r:${homelab.id}|r-conveyor', allShown: false);
    await pumpDesktop(tester, store);
    for (var i = 0; i < 5 && find.text('lead').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final k = Tokens.light;
    final sidebar = find.ancestor(of: find.text('Add project folder'), matching: find.byType(ListView));
    Finder rowOf(String name) => find.ancestor(of: find.descendant(of: sidebar, matching: find.text(name)).first, matching: find.byType(Material)).first;
    final lead = tester.widget<Material>(rowOf('lead'));
    expect(lead.color, k.accent.withValues(alpha: 0.14), reason: 'lead waits on you');
    // Edge to edge: it fills the row's own width, not just the text.
    final r = tester.getRect(rowOf('lead'));
    expect(r.width, greaterThan(150));
    expect(tester.getRect(find.descendant(of: rowOf('lead'), matching: find.text('lead'))).right, lessThan(r.right));
    // The name and the age (ink on a needs-you row, not muted) stay over 4.5:1 on the tint, light and dark.
    for (final t in [Tokens.light, Tokens.dark]) {
      final onTint = Color.alphaBlend(t.accent.withValues(alpha: 0.14), t.surface);
      expect(contrastRatio(t.ink, onTint), greaterThanOrEqualTo(4.5), reason: 'ink on the tint');
    }
    // Any age on a needs-you row is ink, not muted (when the fixtures show one).
    for (final e in find.descendant(of: sidebar, matching: find.byWidgetPredicate((w) => w is Text && RegExp(r'^\d+[smhd]$').hasMatch(w.data ?? ''))).evaluate()) {
      final row = find.ancestor(of: find.byWidget(e.widget), matching: find.byType(Material)).first;
      final needs = tester.widget<Material>(row).color == k.accent.withValues(alpha: 0.14);
      expect((e.widget as Text).style!.color, needs ? k.ink : k.muted);
    }
    expect(tester.widget<Material>(rowOf('impl')).color, Colors.transparent, reason: 'a normal row has no fill');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
