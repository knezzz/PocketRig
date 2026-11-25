import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/core_app.dart';
import 'package:pocket_rig/data/host_store.dart';
import 'package:pocket_rig/models.dart';

void main() {
  final host = Host(id: 'h1', name: 'lab', address: '10.0.0.5', sshUser: 'u');
  late HostStore store;
  late List<String> calls;
  late int capStatus;
  late String? person;
  late int issued;
  final inner = OpenRigClient.factory;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    store = HostStore();
    calls = [];
    capStatus = 200;
    person = 'ana@external';
    issued = 0;
    OpenRigClient.factory = (h) => OpenRigClient(h, httpClient: MockClient((req) async {
          calls.add('${req.method} ${req.url.path}');
          switch ('${req.method} ${req.url.path}') {
            case 'GET /api/apps/v1/capabilities':
              return http.Response(capStatus == 200 ? '{"contract":"openrig.core-app","version":1}' : '{}', capStatus);
            case 'GET /api/gateway/participants':
              return http.Response(
                  jsonEncode({
                    'participants': person == null ? [] : [{'id': 'ana', 'address': person}],
                    'default': {'id': person == null ? null : 'ana'}
                  }),
                  200);
            case 'POST /api/apps/v1/credentials':
              issued++;
              return http.Response(jsonEncode({'credentialId': 'c$issued', 'token': 'orapp_t$issued'}), 201);
            default:
              return http.Response('{"revoked":true}', 200);
          }
        }));
  });
  tearDown(() => OpenRigClient.factory = inner);

  test('a daemon without the job: nothing shown, no credential issued', () async {
    capStatus = 404;
    expect((await coreAppFor(store, host)).state, CoreAppState.unavailable);
    expect(calls, ['GET /api/apps/v1/capabilities']);
  });

  test('no registered person: says so and issues nothing', () async {
    person = null;
    expect((await coreAppFor(store, host)).state, CoreAppState.noPerson);
    expect(issued, 0);
  });

  test('issues once per host, keeps the token in secure storage, reuses it, and re-issues on request', () async {
    final a = await coreAppFor(store, host);
    expect((a.state, a.actor, a.token), (CoreAppState.ready, 'ana@external', 'orapp_t1'));
    final b = await coreAppFor(store, host);
    expect(b.token, 'orapp_t1');
    expect(issued, 1, reason: 'the stored credential is reused');
    expect((await coreAppFor(store, host, forceNew: true)).token, 'orapp_t2');
  });

  test('removing a host revokes its credential and deletes the token', () async {
    await store.upsert(host);
    await coreAppFor(store, host);
    await store.remove('h1');
    await Future<void>.delayed(Duration.zero);
    expect(calls, contains('DELETE /api/apps/v1/credentials/c1'));
    expect(await store.appCredential('h1'), isNull);
  });
}
