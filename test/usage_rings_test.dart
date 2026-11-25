import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/usage_rings.dart';
import 'package:pocket_rig/models.dart';

// The two fixtures are the shared equivalence check: the Swift and Kotlin
// background fetchers must turn usage_rings_input.json (a usage_hosts_v1
// blob plus one /api/provider/status body per host id) into
// usage_rings_expected.json too, with writtenAt fixed at 2026-11-02T00:30:00Z.
Map<String, Object?> fixture(String name) =>
    (jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as Map).cast<String, Object?>();

Map<String, Object?> asMap(Object? o) => (o as Map).cast<String, Object?>();

void main() {
  final input = fixture('usage_rings_input');
  final expected = fixture('usage_rings_expected');
  final hosts = [
    for (final h in (input['hosts'] as List).map(asMap))
      Host(
        id: h['id'] as String,
        name: h['label'] as String,
        address: Uri.parse(h['daemonBase'] as String).host,
        daemonPort: Uri.parse(h['daemonBase'] as String).port,
        sshUser: 'me',
      ),
  ];
  final mini = hosts.single;
  final response = asMap(asMap(input['responses'])[mini.id]);

  test('providerUsage parses hostUsage rows', () async {
    final c = OpenRigClient(mini,
        httpClient: MockClient((req) async {
          expect(req.url.path, '/api/provider/status');
          return http.Response(jsonEncode(response), 200);
        }));
    final rows = await c.providerUsage();
    expect(rows.map((r) => r.provider), ['claude', 'codex', 'gemini']);
    expect(rows.first.windows.length, 7);
    expect(rows.first.windows[1].seatSession, 'dev-android@pocketrig-factory');
  });

  test('reducer keeps the freshest reading per window, rounds usedPercent, drops rings with no known window', () {
    final usages = (response['hostUsage'] as List).map(asMap).map(HostUsage.fromJson).toList();
    final json = usageRingsJson([(mini, usages)], writtenAt: DateTime.utc(2026, 11, 2, 0, 30));
    // Round-trips as the string the widgets read.
    expect(jsonDecode(jsonEncode(json)), expected);
  });

  test('an unreachable host contributes no rings but does not hide the others', () {
    final down = Host(id: 'h2', name: 'Laptop', address: 'lap.tail1.ts.net', sshUser: 'me');
    final usages = [HostUsage.fromJson(asMap((response['hostUsage'] as List)[1]))];
    final json = usageRingsJson([(down, const []), (mini, usages)]);
    expect((json['rings'] as List).map((r) => r['id']), ['h1/build-box/codex']);
  });

  test('usage_hosts_v1 lists every stored host with its daemon base URL and no secrets', () {
    // The fixture's hosts block is a usage_hosts_v1 blob, so it round-trips.
    expect(usageHostsJson(hosts), {'hosts': input['hosts']});
    final laptop = Host(id: 'h2', name: 'Laptop', address: '100.64.0.5', daemonPort: 7500, sshUser: 'me')
      ..privateKeyPem = 'SECRET';
    expect(usageHostsJson([laptop]), {
      'hosts': [
        {'id': 'h2', 'label': 'Laptop', 'daemonBase': 'http://100.64.0.5:7500'},
      ],
    });
    expect(jsonEncode(usageHostsJson([laptop])), isNot(contains('SECRET')));
  });
}
