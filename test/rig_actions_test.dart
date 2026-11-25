import 'package:flutter/material.dart';
import 'package:pocket_rig/data/fleet.dart' show RigView;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/host_store.dart' show HostStore;
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart' show Rig;
import 'package:pocket_rig/ui/busy.dart';
import 'package:pocket_rig/ui/rig/rig_actions.dart';

import 'golden/fixtures.dart';

class _Spy extends http.BaseClient {
  _Spy(this.inner, this.log);
  final http.Client inner;
  final List<String> log;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    log.add('${request.method} ${request.url.path}');
    return inner.send(request);
  }
}

Future<void> _open(WidgetTester tester, HostStore store, void Function(BuildContext) show) => tester
    .pumpWidget(AppScope(
        store: store,
        child: MaterialApp(
            home: Builder(builder: (context) => TextButton(onPressed: () => show(context), child: const Text('open'))))))
    .then((_) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
});

void main() {
  testWidgets('from a bare row: Open and the view choices come first when asked for, none when not', (tester) async {
    final store = await installFakes();
    var opened = 0;
    final chosen = <RigView>[];
    await _open(tester, store,
        (c) => showRigActions(c, releaseRig, const [], onOpen: () => opened++, view: RigView.active, anyActive: true, onView: chosen.add));
    expect(find.text('Show active only'), findsNothing, reason: 'it is the current view');
    expect(tester.getTopLeft(find.text('Open rig')).dy, lessThan(tester.getTopLeft(find.text('Show all')).dy));
    expect(tester.getTopLeft(find.text('Fold')).dy, lessThan(tester.getTopLeft(find.text('Rename label')).dy));
    await tester.tap(find.text('Fold'));
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(chosen, [RigView.collapsed]);

    await _open(tester, store, (c) => showRigActions(c, releaseRig, const [], view: RigView.collapsed, onView: chosen.add));
    expect(find.text('Show active only'), findsNothing, reason: 'nothing is active');
    expect(find.text('Show all'), findsOneWidget);
    await tester.tap(find.text('Show all'));
    await tester.pumpAndSettle();
    expect(chosen.last, RigView.all);

    await _open(tester, store, (c) => showRigActions(c, releaseRig, const []));
    expect(find.text('Open rig'), findsNothing);
    expect(find.text('Fold'), findsNothing);
    expect(find.text('Show all'), findsNothing);
  });

  testWidgets('two Snapshot taps at once send one request, and the rig is free afterwards', (tester) async {
    final store = await installFakes();
    final log = <String>[];
    final inner = OpenRigClient.factory;
    OpenRigClient.factory = (h) => OpenRigClient(h, httpClient: _Spy(fakeDaemon(h), log));
    addTearDown(() => OpenRigClient.factory = inner);
    AppScope.resetClients();
    late BuildContext ctx;
    await tester.pumpWidget(AppScope(
        store: store,
        child: MaterialApp(
            home: Builder(builder: (context) {
          ctx = context;
          return const SizedBox();
        }))));
    final a = snapshotRig(ctx, releaseRig);
    final b = snapshotRig(ctx, releaseRig);
    await tester.pumpAndSettle();
    await Future.wait([a, b]);
    await tester.pumpAndSettle();
    expect(log.where((l) => l.startsWith('POST') && l.endsWith('/snapshots')).length, 1);
    expect(busyKeys.value, isEmpty);
  });

  testWidgets('a stopped rig\'s list shows Restore and Delete rig… (no Stop), and Restore asks the daemon to bring it up once',
      (tester) async {
    final store = await installFakes();
    final log = <String>[];
    final inner = OpenRigClient.factory;
    OpenRigClient.factory = (h) => OpenRigClient(h,
        httpClient: _Spy(
            MockClient((req) async => req.url.path == '/api/up'
                ? http.Response('{"status":"restored","stages":[]}', 200)
                : fakeDaemon(h).get(req.url).then((r) => r)),
            log));
    addTearDown(() => OpenRigClient.factory = inner);
    AppScope.resetClients();
    final stopped = Rig(id: 'r-old', name: 'old-train', nodeCount: 3, runningCount: 0, attentionCount: 0, status: 'stopped');
    await _open(tester, store, (c) => showRigActions(c, stopped, const []));
    expect(find.text('Restore'), findsOneWidget);
    expect(find.text('Delete rig…'), findsOneWidget);
    expect(find.text('Stop rig…'), findsNothing);
    expect(find.text('Snapshot'), findsNothing);

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(log.where((l) => l == 'POST /api/up').length, 1);
    expect(find.text('Restored old-train'), findsOneWidget, reason: 'the toast says it came back');
    expect(busyKeys.value, isEmpty);
    await tester.pump(const Duration(seconds: 5));
  });
}
