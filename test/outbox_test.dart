import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/outbox.dart';

void main() {
  /// Waits for [ok] by what happened, not by how long it took: under load a fixed wait is too short (this test flaked), a
  /// condition is not. Gives up (and the expectation after it fails) only after 10 s.
  Future<void> until(bool Function() ok) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!ok() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  test('tries three times, then waits for Retry', () async {
    final box = Outbox(delays: const [Duration.zero]);
    var calls = 0;
    box.send('c', 'hi', () async {
      calls++;
      throw 'offline';
    });
    await until(() => box.of('c').isNotEmpty && box.of('c').single.failed);
    expect(calls, 3);
    final m = box.of('c').single;
    expect(m.failed, isTrue);
    expect(m.error, 'offline');

    box.retry('c', m, () async => calls++);
    await until(() => box.of('c').isEmpty);
    expect(calls, 4);
    expect(box.of('c'), isEmpty);
  });

  test('a send that may have arrived is not retried on its own', () async {
    final box = Outbox(delays: const [Duration.zero]);
    var calls = 0;
    box.send('c', 'hi', () async {
      calls++;
      throw OpenRigException('Request failed: TimeoutException', maybeSent: !neverConnected('TimeoutException'));
    });
    await until(() => box.of('c').isNotEmpty && box.of('c').single.failed);
    expect(calls, 1);
    expect(box.of('c').single.failed, isTrue);
    expect(neverConnected(const SocketException('Connection refused')), isTrue);
  });

  test('delete stops the retries', () async {
    final box = Outbox(delays: const [Duration(milliseconds: 20)]);
    var calls = 0;
    box.send('c', 'hi', () async {
      calls++;
      throw 'offline';
    });
    await Future<void>.delayed(Duration.zero);
    box.remove('c', box.of('c').single);
    // A cancelled retry never fires, however long we wait: 100 ms is enough to see it didn't.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(calls, 1);
  });

  test('unsent messages survive a restart as failed', () async {
    final dir = await Directory.systemTemp.createTemp('outbox');
    final file = File('${dir.path}/outbox.json');
    final box = Outbox(file: file, delays: const [Duration(seconds: 10)]);
    box.send('c', 'hi', () async => throw 'offline');
    await until(() => box.of('c').isNotEmpty && box.of('c').single.failed && file.existsSync());

    final again = Outbox(file: file)..load();
    expect(again.of('c').single.text, 'hi');
    expect(again.of('c').single.failed, isTrue);
    box.remove('c', box.of('c').single);
    await until(() => box.of('c').isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 50)); // the last write of the file
    await dir.delete(recursive: true);
  });
}
