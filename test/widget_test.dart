import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/host_store.dart';
import 'package:pocket_rig/main.dart';

void main() {
  testWidgets('first run lands on Settings with the first-host steps', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = HostStore();
    await store.load();
    await tester.pumpWidget(PocketRigApp(store: store, deepLinks: false));
    await tester.pump();

    expect(find.text('Connect your first host'), findsOneWidget);
    expect(find.text('Add host by hand'), findsOneWidget);
    expect(find.byIcon(Icons.menu), findsOneWidget, reason: 'the drawer opens from the header');
  });
}
