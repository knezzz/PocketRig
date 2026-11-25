import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/ui/rigs_home.dart';

import 'golden/fixtures.dart';

void main() {
  testWidgets('the host header count includes the structured questions waiting on the person', (tester) async {
    await installFakes();
    final feed = fleet.feedFor(homelab);
    await feed.refresh();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: feed, builder: (_, __) => HostActiveCount(homelab)))));
    final before = int.parse(tester.widget<Text>(find.byType(Text)).data!);
    feed.setCoreAsks(2);
    await tester.pump();
    expect(int.parse(tester.widget<Text>(find.byType(Text)).data!), before + 2);
    feed.setCoreAsks(0);
  });
}
