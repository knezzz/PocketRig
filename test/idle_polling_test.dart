import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/chat_sync.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';

var _n = 0;
final _host = Host(id: 'h', name: 'h', address: 'h', sshUser: 'u', privateKeyPem: 'k');
// The client cache is per host id: a fresh id per feed keeps each test's daemon its own.
Host _newHost() => Host(id: 'h${_n++}', name: 'h', address: 'h', sshUser: 'u', privateKeyPem: 'k');

/// A feed over a daemon with [n] rigs; [nodeHits] and [scans] count its calls.
HostFeed _feed(int n, List<String> nodeHits, List<int> scans, {int delayMs = 0}) {
  OpenRigClient.factory = (h) => OpenRigClient(h,
      eventSource: ({rigId, replay, lastEventId}) => const Stream.empty(),
      httpClient: MockClient((r) async {
        final p = r.url.path;
        if (p == '/api/ps') {
          return http.Response(
              jsonEncode([
                for (var i = 0; i < n; i++) {'rigId': 'r$i', 'name': 'r$i'}
              ]),
              200);
        }
        if (p.endsWith('/nodes')) {
          nodeHits.add(p.split('/')[3]);
          return http.Response(jsonEncode([]), 200);
        }
        if (p == '/api/discovery/scan') {
          scans.add(1);
          await Future<void>.delayed(Duration(milliseconds: delayMs));
        }
        return http.Response('[]', 200);
      }));
  return HostFeed(_newHost());
}

void main() {
  setUp(() => SshExec.debugConnect = (_) async => SshExec.fake((_) async => ''));
  tearDown(() => SshExec.debugConnect = null);

  test('a timer poll fetches seats only for open and changed rigs; an event fetches all', () async {
    final hits = <String>[];
    final feed = _feed(5, hits, []);
    await feed.refresh();
    expect(hits, hasLength(5), reason: 'first load: every rig');

    hits.clear();
    final close = feed.focus('r2');
    await feed.refresh();
    expect(hits, ['r2'], reason: 'only the rig a screen has open');

    close();
    hits.clear();
    await feed.refresh();
    expect(hits, isEmpty, reason: 'nothing open: seats are fresh');

    await feed.refresh(scan: true);
    expect(hits, hasLength(5), reason: 'pull-to-refresh loads everything');
  });

  test('overlapping refreshes share one load and one scan, and the scan waits 10 minutes', () async {
    final scans = <int>[];
    final feed = _feed(1, [], scans, delayMs: 30);
    await Future.wait([feed.refresh(), feed.refresh(), feed.refresh()]);
    expect(feed.error, isNull);
    expect(scans, hasLength(1));
    await feed.refresh();
    expect(scans, hasLength(1), reason: 'not again for ${HostFeed.scanEvery.inMinutes} minutes');
  });

  test('rigsWithSeats fetches a few rigs at a time and keeps the reused ones', () async {
    var live = 0, peak = 0;
    final hits = <String>[];
    final api = OpenRigClient(_host,
        eventSource: ({rigId, replay, lastEventId}) => const Stream.empty(),
        httpClient: MockClient((r) async {
          if (r.url.path == '/api/ps') {
            return http.Response(
                jsonEncode([
                  for (var i = 0; i < 8; i++) {'rigId': 'r$i', 'name': 'r$i'}
                ]),
                200);
          }
          hits.add(r.url.path);
          peak = ++live > peak ? live : peak;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          live--;
          return http.Response('[]', 200);
        }));
    final got = await api.rigsWithSeats(known: {'r0': [], 'r1': []}, reuse: (r) => r.id == 'r0' || r.id == 'r1');
    expect(got, hasLength(8));
    expect(hits, hasLength(6));
    expect(peak, lessThanOrEqualTo(3));
  });

  test('ChatSync starts the next timed cycle `every` after the last one ended, not while it ran', () async {
    var cycles = 0;
    final s = ChatSync(
        host: () {
          cycles++;
          return _host;
        },
        seats: () => [],
        every: const Duration(milliseconds: 300));
    await s.tick(timer: true);
    await s.tick(timer: true);
    expect(cycles, 1, reason: 'a tick right after a finished cycle waits');
    await s.tick();
    expect(cycles, 2, reason: 'a host event still syncs at once');
    await Future<void>.delayed(const Duration(milliseconds: 320));
    await s.tick(timer: true);
    expect(cycles, 3);
  });
}
