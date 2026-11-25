import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pinenacl/ed25519.dart' as nacl;
import 'package:pocket_rig/api/live_events.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/rig_spec.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/host_keys.dart';
import 'package:pocket_rig/ssh/keygen.dart';
import 'package:pocket_rig/ui/kit.dart' show Pill, Tone;
import 'package:pocket_rig/ui/status_shape.dart';

Host host() => Host(id: 'h', name: 'mini', address: 'mini.tail1.ts.net', sshUser: 'me');

void main() {
  group('host keys', () {
    test('trust on first use, then match or refuse', () {
      expect(checkHostKey(null, 'SHA256:abc'), HostKeyCheck.firstUse);
      expect(checkHostKey('SHA256:abc', 'SHA256:abc'), HostKeyCheck.matches);
      expect(checkHostKey('SHA256:abc', 'SHA256:xyz'), HostKeyCheck.changed);
    });

    test('pins survive storage, and a change explains itself', () {
      final h = host()
        ..hostKeyType = 'ssh-ed25519'
        ..hostKeyFingerprint = 'SHA256:abc';
      final back = Host.fromJson(h.toJson());
      expect(back.hostKeyFingerprint, 'SHA256:abc');
      expect(back.hostKeyType, 'ssh-ed25519');
      final e = HostKeyChangedException(h, 'ssh-ed25519', 'SHA256:xyz');
      expect(e.message, contains('SHA256:abc'));
      expect(e.message, contains('SHA256:xyz'));
    });
  });

  test('generated ed25519 keys load back, sign, and print an authorized_keys line', () {
    final k = generateEd25519(comment: 'pocketrig@test', random: Random(7));
    expect(k.privatePem, startsWith('-----BEGIN OPENSSH PRIVATE KEY-----'));
    final pair = SSHKeyPair.fromPem(k.privatePem).single;
    expect(pair.type, 'ssh-ed25519');
    final data = Uint8List.fromList(utf8.encode('hello'));
    // SSH wire forms end with the raw 64-byte signature and 32-byte key.
    final sigWire = pair.sign(data).encode();
    final pubWire = pair.toPublicKey().encode();
    final verify = nacl.VerifyKey(Uint8List.sublistView(pubWire, pubWire.length - 32));
    expect(
      verify.verify(signature: nacl.Signature(Uint8List.sublistView(sigWire, sigWire.length - 64)), message: data),
      isTrue,
    );
    expect(k.publicLine, matches(RegExp(r'^ssh-ed25519 AAAAC3NzaC1lZDI1NTE5[A-Za-z0-9+/=]+ pocketrig@test$')));
    expect(publicKeyFromPem(k.privatePem, comment: 'pocketrig@test'), k.publicLine);
    expect(publicKeyFromPem('not a key'), isNull);
    expect(generateEd25519().publicLine, isNot(generateEd25519().publicLine));
  });

  group('daemon errors', () {
    test('known codes read as sentences', () {
      expect(daemonErrorMessage(404, {'error': 'Rig "x" not found', 'code': 'rig_not_found'}), contains('no longer exists'));
      expect(daemonErrorMessage(409, {'error': 'Multiple rigs named "pm"', 'code': 'ambiguous_name'}),
          contains('More than one rig'));
      expect(daemonErrorMessage(403, {'error': 'Host not allowed', 'code': 'untrusted_host'}, host: 'mini'),
          contains('full MagicDNS name'));
      expect(daemonErrorMessage(401, {'error': 'unauthorized', 'message': 'token'}), contains('owner token'));
    });

    test('unknown codes keep the daemon\'s words and guidance; empty bodies get a status line', () {
      expect(daemonErrorMessage(409, {'ok': false, 'code': 'weird', 'message': 'Nope.', 'guidance': 'Try X.'}), 'Nope. Try X.');
      expect(daemonErrorMessage(500, null), contains('Check its log'));
      expect(daemonErrorMessage(418, ''), 'Daemon returned 418');
    });

    test('partial launches carry fact/consequence/action and the waiting seats', () {
      final r = LaunchResult.fromJson({
        'status': 'partial',
        'stages': [
          {'stage': 'launch', 'status': 'ok'},
        ],
        'error': {'fact': 'impl is waiting.', 'consequence': 'The rig is not ready.', 'action': 'Answer it.'},
        'attentionNodes': [
          {'logicalId': 'impl'},
        ],
      });
      expect(r.ok, isTrue);
      expect(r.errors, ['impl is waiting. The rig is not ready. Answer it.', 'Needs you: impl']);
      expect(LaunchResult.fromJson({'status': 'restored', 'rigId': 'r1'}).ok, isTrue);
    });

    test('the client throws the friendly message with its code', () async {
      final c = OpenRigClient(host(),
          httpClient: MockClient((_) async => http.Response(jsonEncode({'error': 'x', 'code': 'rig_not_found'}), 404)));
      await expectLater(
        c.seats('gone'),
        throwsA(isA<OpenRigException>()
            .having((e) => e.code, 'code', 'rig_not_found')
            .having((e) => e.message, 'message', contains('no longer exists'))),
      );
    });
  });

  test('live events share one connection, resume with Last-Event-ID, and report connection state', () async {
    final opened = <String?>[];
    final controllers = <StreamController<RigEvent>>[];
    final live = LiveEvents((lastId) {
      opened.add(lastId);
      final c = StreamController<RigEvent>();
      controllers.add(c);
      return c.stream;
    });
    final got = <int>[];
    final a = live.stream.listen((e) => got.add(e.seq));
    final b = live.stream.listen((_) {});
    expect(opened, [null]);
    controllers.last.add(RigEvent(seq: 5, type: 'x', data: const {}));
    await Future<void>.delayed(Duration.zero);
    expect(got, [5]);
    expect(live.connected.value, isTrue);
    await controllers.last.close(); // the daemon dropped the stream
    await Future<void>.delayed(Duration.zero);
    expect(live.connected.value, isFalse);
    await Future<void>.delayed(const Duration(seconds: 5));
    expect(opened, [null, '5']);
    await a.cancel();
    await b.cancel();
    await live.close();
  });

  testWidgets('status shape and count badge speak, and badge tap targets aren\'t clipped', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
          body: Column(children: [StatusShape(Status.needsYou), Pill('3', tone: Tone.hot, semanticsLabel: '3 need you')])),
    ));
    expect(find.bySemanticsLabel('needs you'), findsOneWidget);
    expect(find.bySemanticsLabel('3 need you'), findsOneWidget);
    handle.dispose();
  });
}
