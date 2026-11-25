import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/push.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('devices: mine replaces the same platform and keeps the others', () {
    final existing = jsonEncode({
      'devices': [
        {'platform': 'ios', 'token': 'old'},
        {'platform': 'android', 'token': 'a1'},
      ]
    });
    final merged = mergeDevices(existing, PushDevice('ios', 'new', 'sandbox'));
    expect(merged, [
      {'platform': 'android', 'token': 'a1'},
      {'platform': 'ios', 'token': 'new', 'env': 'sandbox'},
    ]);
    expect(mergeDevices('not json', null), isEmpty);
    expect(mergeDevices(existing, null), hasLength(2));
  });

  test('the channel: register on start; token, open and a fallback answer reach the app', () async {
    const ch = MethodChannel('dev.pocketrig/push');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, (c) async {
      calls.add(c.method);
      return {'granted': true};
    });
    final opened = <String>[], devices = <PushDevice>[], posted = <(String, String)>[];
    final push = Push(
      onOpen: opened.add,
      onDevice: devices.add,
      post: (u, b) async {
        posted.add((u, b));
        return true;
      },
    );
    await push.start();
    expect(calls, ['register']);

    Future<void> fromNative(String m, Object args) => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage('dev.pocketrig/push', const StandardMethodCodec().encodeMethodCall(MethodCall(m, args)), (_) {});
    await fromNative('token', {'platform': 'ios', 'token': 'abc', 'env': 'sandbox'});
    await fromNative('activityStartToken', {'token': 'start1'});
    await fromNative('activityToken', {'token': 'act1'});
    await fromNative('open', {'link': 'pocketrig://seat/lead%40r'});
    await fromNative('action', {'id': 'allow', 'url': 'http://h:7434/answer', 'body': '{"x":1}', 'seat': null});
    await Future<void>.delayed(Duration.zero);

    expect(devices.first.token, 'abc');
    expect(Push.device?.env, 'sandbox');
    expect(Push.device?.toJson(), {
      'platform': 'ios', 'token': 'abc', 'env': 'sandbox', 'activityStartToken': 'start1', 'activityToken': 'act1',
    });
    expect(opened, ['pocketrig://seat/lead%40r']);
    expect(posted, [('http://h:7434/answer', '{"x":1}')]);
  });
}
