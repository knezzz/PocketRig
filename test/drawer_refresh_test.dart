import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;

import 'golden/fixtures.dart';

void main() {
  testWidgets('a pull on the drawer tree rescans every host (refresh with scan)', (tester) async {
    final store = await installFakes();
    final asked = <String>[];
    OpenRigClient.factory = (h) {
      final fake = fakeDaemon(h);
      return OpenRigClient(h,
          httpClient: MockClient((req) {
            asked.add('${h.id} ${req.url.path}');
            return fake.send(http.Request(req.method, req.url)).then(http.Response.fromStream);
          }),
          eventSource: ({rigId, replay, lastEventId}) => const Stream.empty());
    };
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(AppScope(store: store, child: const MaterialApp(home: AppShell())));
    await tester.pumpAndSettle();
    await openDrawer(tester);

    int scans() => asked.where((a) => a.endsWith('/api/discovery/scan')).length;
    final before = scans();
    // The drawer's list, pulled down from its top.
    await tester.fling(find.descendant(of: find.byType(Drawer), matching: find.byType(ListView)).first, const Offset(0, 500), 1000);
    await tester.pumpAndSettle();
    expect(scans(), greaterThan(before), reason: 'the pull scans the reachable host');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
