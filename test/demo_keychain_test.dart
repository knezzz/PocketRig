import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/host_store.dart';
import 'package:pocket_rig/main.dart' show PocketRigApp;
import 'package:pocket_rig/ui/chat_screen.dart';

import '../tool/demo/main_demo.dart' show demoKeychainService, demoSetup;
import 'golden/fixtures.dart';

/// The demo build must never ask the person for the keychain: it runs on the in-memory storage (installFakes), and if a
/// read ever got past that it would still be under a service name of its own, never the real app's.
void main() {
  tearDown(() => HostStore.keychainService = AppleOptions.defaultAccountName);

  test('the demo keeps to its own keychain service; the real app keeps the default one', () async {
    expect(hostStoreMacOptions().toMap()['accountName'], AppleOptions.defaultAccountName, reason: 'the real app\'s saved hosts stay where they are');
    await demoSetup();
    expect(hostStoreMacOptions().toMap()['accountName'], demoKeychainService);
    expect(demoKeychainService, isNot(AppleOptions.defaultAccountName));
  });

  testWidgets('with the demo\'s fakes installed, the app and its chat leave the secure storage on the in-memory one', (tester) async {
    final store = await installFakes();
    bool inMemory() => FlutterSecureStoragePlatform.instance.runtimeType.toString().contains('Test');
    expect(inMemory(), isTrue, reason: 'installFakes switches it');
    await tester.pumpWidget(PocketRigApp(store: store, deepLinks: false));
    await tester.pump(const Duration(seconds: 1));
    final lead = seatFromFixture('r-conveyor', 'lead');
    await tester.pumpWidget(MaterialApp(home: phone(store, ChatScreen(rigName: 'conveyor', seat: lead, asChat: true))));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(inMemory(), isTrue, reason: 'nothing in the app or the chat put the real platform back');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
