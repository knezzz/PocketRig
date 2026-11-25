import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/deep_link.dart';
import 'package:pocket_rig/models.dart';

void main() {
  test('seat links parse the session and host hint', () {
    final l = SeatLink.parse(Uri.parse('pocketrig://seat/impl%40conveyor?host=mini'))!;
    expect(l.session, 'impl@conveyor');
    expect(l.logicalId, 'impl');
    expect(l.rigName, 'conveyor');
    expect(l.host, 'mini');
    expect(SeatLink.parse(Uri.parse('pocketrig://seat/lead@r'))!.host, isNull);
    expect(SeatLink.parse(Uri.parse('pocketrig://rig/x')), isNull);
    expect(SeatLink.parse(Uri.parse('https://seat/x')), isNull);
    expect(SeatLink.parse(Uri.parse('pocketrig://seat/')), isNull);
  });

  test('host hints match the name, the address or its first label', () {
    final h = Host(id: '1', name: 'Mac mini', address: 'mini.tail1234.ts.net', sshUser: 'me');
    expect(h.matchesHint('mini'), isTrue);
    expect(h.matchesHint('Mac mini'), isTrue);
    expect(h.matchesHint('mini.tail1234.ts.net'), isTrue);
    expect(h.matchesHint('studio'), isFalse);
  });

  test('topics are long, random and valid; settings round-trip', () {
    final a = newNtfyTopic(Random(1)), b = newNtfyTopic(Random(2));
    expect(a, startsWith('pocketrig-'));
    expect(a.length, 26);
    expect(a, isNot(b));
    expect(validNtfyTopic(a), isTrue);
    expect(validNtfyTopic('has space'), isFalse);
    final h = Host(id: '1', name: 'n', address: 'a', sshUser: 'u', ntfyTopic: a, ntfyServer: 'https://ntfy.example.com/');
    final back = Host.fromJson(h.toJson());
    expect(back.ntfyTopic, a);
    expect(back.ntfyBase, 'https://ntfy.example.com');
    expect(Host(id: '2', name: 'n', address: 'a', sshUser: 'u').ntfyBase, 'https://ntfy.sh');
  });
}
