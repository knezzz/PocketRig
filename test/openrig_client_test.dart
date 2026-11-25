import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/models.dart';

// Response bodies follow OpenRig 0.7.6 (daemon/dist/routes).
Host host() => Host(id: 'h', name: 'mini', address: 'mini.tail1.ts.net', sshUser: 'me');

OpenRigClient client(Map<String, Object?> Function(http.Request) route) =>
    OpenRigClient(host(), httpClient: MockClient((req) async {
      final body = route(req);
      final status = body['__status'] as int? ?? 200;
      body.remove('__status');
      return http.Response(jsonEncode(body['__list'] ?? body), status);
    }));

void main() {
  test('version reads semver from /healthz', () async {
    final c = client((r) => {'status': 'ok', 'pid': 1, 'semver': '0.7.6'});
    expect(await c.version(), '0.7.6');
  });

  test('permission mode comes from seat status, effective first', () async {
    late Uri asked;
    final c = client((r) {
      asked = r.url;
      return {
        'seat_ref': 'impl@conveyor',
        'permissions': {
          'selectionState': 'explicit',
          'desired': {'mode': 'plan'},
          'effective': {'effectiveMode': 'acceptEdits', 'source': 'explicit'},
        },
      };
    });
    final seat = Seat(rigId: 'r', logicalId: 'impl', sessionName: 'impl@conveyor');
    expect(await c.permissionMode(seat), 'acceptEdits');
    expect(asked.path, '/api/seat/status/impl%40conveyor');
  });

  test('nodes come back as a bare list', () async {
    final c = client((r) => {
          '__list': [
            {'rigId': 'r', 'logicalId': 'lead', 'canonicalSessionName': 'lead@r', 'runtime': 'claude-code'},
          ],
        });
    final seats = await c.seats('r');
    expect(seats.single.sessionName, 'lead@r');
  });

  test('permission changes go through set-permissions, Codex as floor/full_bypass', () async {
    final sent = <(String, Map)>[];
    final c = client((r) {
      sent.add((r.url.path, jsonDecode(r.body) as Map));
      return {'ok': true};
    });
    final claude = Seat(rigId: 'r', logicalId: 'impl', sessionName: 'impl@conveyor', runtime: 'claude-code');
    final codex = Seat(rigId: 'r', logicalId: 'qa', sessionName: 'qa@conveyor', runtime: 'codex');
    await c.setPermissionMode(claude, PermissionMode.plan);
    await c.setPermissionMode(codex, PermissionMode.bypass);
    await c.setPermissionMode(codex, PermissionMode.ask);
    expect(sent[0].$1, '/api/seat/set-permissions/impl%40conveyor');
    expect(sent.map((x) => x.$2['mode']), ['plan', 'full_bypass', 'floor']);
    expect(sent[0].$2['reason'], isNotEmpty);
    expect(sent[0].$2['operator'], isNotEmpty);
    expect(PermissionMode.forSeat(codex), [PermissionMode.ask, PermissionMode.bypass]);
    expect(PermissionMode.fromWire('full_bypass'), PermissionMode.bypass);
  });

  test('relaunch is a fresh launch that stops the live seat first', () async {
    late http.Request req;
    final c = client((r) {
      req = r;
      return {'ok': true};
    });
    await c.relaunchSeat(Seat(rigId: 'r', logicalId: 'impl', sessionName: 'impl@conveyor'), reason: 'why');
    expect(req.url.path, '/api/seat/launch/impl%40conveyor');
    expect(jsonDecode(req.body), {'fresh': true, 'stop': true, 'reason': 'why', 'operator': 'pocketrig'});
  });

  test('a refused relaunch surfaces as an error', () async {
    final c = client((r) => {'__status': 409, 'ok': false, 'code': 'seat_busy', 'message': 'Seat is busy'});
    expect(c.relaunchSeat(Seat(rigId: 'r', logicalId: 'impl'), reason: 'why'), throwsA(isA<OpenRigException>()));
  });

  test('queue history keeps closed items with their bodies; transitions read notes', () async {
    late Uri asked;
    final c = client((r) {
      asked = r.url;
      if (r.url.path.endsWith('/transitions')) {
        return {
          '__list': [
            {'ts': '2026-11-02T08:15:00.870Z', 'state': 'pending', 'transitionNote': 'handoff from q0', 'actorSession': 'dev-ios@f'},
          ],
        };
      }
      return {
        '__list': [
          {
            'qitemId': 'q1',
            'sourceSession': 'dev-ios@f',
            'destinationSession': 'dev-qa@f',
            'state': 'done',
            'summary': 'QA the widget',
            'body': 'OUTCOME for QA: compare.\nMore lines.',
            'tsCreated': '2026-11-02T08:15:00.868Z',
            'closureReason': 'no-follow-on',
          },
        ],
      };
    });
    final items = await c.queueHistory('f');
    expect(asked.queryParameters, {'rig': 'f', 'limit': '200'}, reason: 'no activeOnly: closed items too');
    expect(items.single.body, startsWith('OUTCOME for QA'));
    expect(items.single.created, DateTime.utc(2026, 11, 2, 8, 15, 0, 868));
    expect(items.single.closureReason, 'no-follow-on');
    final t = await c.queueTransitions('q1');
    expect(asked.path, '/api/queue/q1/transitions');
    expect((t.single.state, t.single.note, t.single.actor), ('pending', 'handoff from q0', 'dev-ios@f'));
  });

  test('a rig\'s spec is the file its newest launch came from', () async {
    late Uri asked;
    // Shaped like GET /api/bootstrap on OpenRig: newest first is not guaranteed.
    final c = client((r) {
      asked = r.url;
      return {
        '__list': [
          {'sourceKind': 'rig_spec', 'sourceRef': '/old/rig.yaml', 'rigId': 'r1', 'createdAt': '2026-11-01 23:57:31'},
          {'sourceKind': 'rig_spec', 'sourceRef': '/Users/me/.openrig/specs/factory/rig.yaml', 'rigId': 'r1', 'createdAt': '2026-11-02 00:00:54'},
          {'sourceKind': 'rig_spec', 'sourceRef': '/other/rig.yaml', 'rigId': 'r2', 'createdAt': '2026-11-02 09:00:00'},
          {'sourceKind': 'rig_bundle', 'sourceRef': '/b.rigbundle', 'rigId': 'r1', 'createdAt': '2026-11-02 10:00:00'},
          {'sourceKind': 'rig_spec', 'sourceRef': '/planned/rig.yaml', 'rigId': null, 'createdAt': '2026-11-02 11:00:00'},
        ],
      };
    });
    expect(await c.rigSpecSource('r1'), '/Users/me/.openrig/specs/factory/rig.yaml');
    expect(asked.path, '/api/bootstrap');
    expect(await c.rigSpecSource('nope'), isNull);
  });

  test('broadcast targets the rig by name and reports each seat', () async {
    late Map sent;
    final c = client((r) {
      sent = jsonDecode(r.body) as Map;
      return {
        'results': [
          {'sessionName': 'lead@conveyor', 'ok': true},
          {'sessionName': 'impl@conveyor', 'ok': false, 'error': 'target_needs_input'},
        ],
      };
    });
    final out = await c.broadcast('conveyor', 'stop and commit');
    expect(sent['rig'], 'conveyor');
    expect(sent['text'], 'stop and commit');
    expect(out.where((o) => !o.ok).single.session, 'impl@conveyor');
  });

  test('room history parses SQLite times as UTC; send claims pocketrig', () async {
    final asked = <String>[];
    final c = client((r) {
      asked.add('${r.method} ${r.url.path}');
      if (r.method == 'POST') return {'id': 'm2', '__status': 201};
      return {
        '__list': [
          {'id': 'm1', 'rigId': 'r1', 'sender': 'lead@conveyor', 'kind': 'message', 'body': 'hi', 'topic': null,
           'createdAt': '2026-11-06 10:00:00'},
        ],
      };
    });
    final m = (await c.roomHistory('r1')).single;
    expect(m.sender, 'lead@conveyor');
    expect(m.at, DateTime.utc(2026, 11, 6, 10));
    await c.roomSend('r1', 'hello');
    expect(asked, ['GET /api/rigs/r1/chat/history', 'POST /api/rigs/r1/chat/send']);
  });

  test('compaction refusal surfaces the daemon reason', () async {
    final c = client((r) => {'ok': false, 'reason': 'mid_work', 'error': 'impl@conveyor is working', '__status': 409});
    expect(() => c.compact('impl@conveyor'), throwsA(isA<OpenRigException>()));
  });

  test('a reminder registers a periodic-reminder whose spec round-trips the message', () async {
    late Map sent;
    final c = client((r) {
      sent = jsonDecode(r.body) as Map;
      return {'jobId': 'j1', '__status': 201};
    });
    await c.addReminder('impl@conveyor', 'Report: "status" #1\nthen idle', const Duration(hours: 2));
    expect(sent['policy'], 'periodic-reminder');
    expect(sent['intervalSeconds'], 7200);
    expect(sent['targetSession'], 'impl@conveyor');
    // The list reads the message back out of the same spec.
    final job = WatchdogJob.fromJson({'jobId': 'j1', 'policy': 'periodic-reminder', 'specYaml': sent['specYaml']});
    expect(job.message, 'Report: "status" #1\nthen idle');
  });

  test('an attention item blocked on the person names the queue row\'s owner, not the person', () async {
    final c = client((r) => switch (r.url.path) {
          '/api/attention' => {
              'items': [
                {'id': 'queue:q1', 'kind': 'action', 'recipient': 'human@kernel', 'summary': 'Open the PR?', 'source': '/api/queue/q1'},
              ]
            },
          _ => {'qitemId': 'q1', 'destinationSession': 'orch-pm@sharing', 'waiting': {'owner': 'orch-pm@sharing'}},
        });
    final items = await c.attention();
    expect(items.single.asker, 'orch-pm@sharing');
  });

  test('an update to the person names its sender', () async {
    final c = client((r) => switch (r.url.path) {
          '/api/attention' => {
              'items': [
                {'id': 'queue-update:q2', 'kind': 'update', 'recipient': 'human@kernel', 'summary': 'Shipped', 'source': '/api/queue/q2'},
              ]
            },
          _ => {'qitemId': 'q2', 'destinationSession': 'human@kernel', 'sourceSession': 'lead@conveyor', 'waiting': {'owner': 'human@kernel'}},
        });
    expect((await c.attention()).single.asker, 'lead@conveyor');
  });
}
