import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/agent_jobs.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/agent_details.dart';
import 'package:pocket_rig/ui/kit.dart' show BorderedList;

import 'golden/fixtures.dart';

/// A tappable card row's ripple fills the whole card: its InkWell is as wide as the card it sits in.
void main() {
  testWidgets('seat sheet action and shell rows ripple across the full card', (tester) async {
    final store = await installFakes();
    final seat = Seat(rigId: '', logicalId: 'dev.impl', sessionName: 'impl@app', runtime: 'claude-code');
    final details = AgentDetails(
      seat: seat,
      jobs: AgentJob.parse('J\t1\tS\t05:00\t0\t0\t/bin/zsh -c source /h/.claude/shell-snapshots/s.sh && eval '
          "'flutter test' < /dev/null\n"),
    );
    await tester.pumpWidget(AppScope(
        store: store, child: MaterialApp(home: SeatDetailsScreen(details: details, rigName: 'app-rig', onJobs: () {}))));
    await tester.pump();

    Future<void> fills(Finder text) async {
      await tester.scrollUntilVisible(text, 100);
      final ink = find.ancestor(of: text, matching: find.byType(InkWell)).first;
      final card = find.ancestor(of: ink, matching: find.byType(BorderedList)).first;
      expect(tester.getSize(ink).width, tester.getSize(card).width, reason: 'ripple spans the card');
    }

    await fills(find.text('1 monitor')); // above the actions: scroll down to each in page order
    await fills(find.text('Add to queue…'));
    expect(find.byIcon(Icons.playlist_add), findsOneWidget, reason: 'action row icon');
  });
}
