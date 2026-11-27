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
    expect(lead.color, k.accent.withValues(alpha: 0.08), reason: 'lead waits on you');
    // Edge to edge: it fills the row's own width, not just the text.
    final r = tester.getRect(rowOf('lead'));
    expect(r.width, greaterThan(150));
    expect(tester.getRect(find.descendant(of: rowOf('lead'), matching: find.text('lead'))).right, lessThan(r.right));
    expect(contrastRatio(k.ink, Color.alphaBlend(lead.color!, k.surface)), greaterThanOrEqualTo(4.5));
    expect(tester.widget<Material>(rowOf('impl')).color, Colors.transparent, reason: 'a normal row has no fill');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
