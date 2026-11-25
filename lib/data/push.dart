import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models.dart';
import '../ssh/ssh_exec.dart';
import 'projects.dart' show shQuote;

/// This phone's push token, as native reports it (host/watcher/PUSH.md).
class PushDevice {
  PushDevice(this.platform, this.token, this.env, {this.activityToken, this.activityStartToken});
  final String platform;
  final String token;
  final String? env;

  /// iOS Live Activity: the token of the running activity, and the one that starts a new one.
  final String? activityToken;
  final String? activityStartToken;

  PushDevice withActivity(String? token, String? start) =>
      PushDevice(platform, this.token, env, activityToken: token, activityStartToken: start);

  static PushDevice? parse(Object? args) {
    if (args is! Map || args['token'] is! String || args['platform'] is! String) return null;
    return PushDevice(args['platform'] as String, args['token'] as String, args['env'] as String?);
  }

  Map<String, Object?> toJson() => {
        'platform': platform,
        'token': token,
        if (env != null) 'env': env,
        if (activityToken != null) 'activityToken': activityToken,
        if (activityStartToken != null) 'activityStartToken': activityStartToken,
      };
}

/// The `devices` for watcher.json: what the host already has, with [mine]
/// replacing the entry of the same platform.
/// shortcut: one device per platform per host, so a second iPhone replaces the first.
List<Map<String, Object?>> mergeDevices(String? existingJson, PushDevice? mine) {
  var old = <Map<String, Object?>>[];
  try {
    final j = jsonDecode(existingJson ?? '');
    if (j is Map && j['devices'] is List) {
      old = [for (final d in j['devices'] as List) if (d is Map) d.cast<String, Object?>()];
    }
  } catch (_) {/* none yet */}
  if (mine == null) return old;
  return [...old.where((d) => d['platform'] != mine.platform), mine.toJson()];
}

/// Writes `~/.config/pocketrig/watcher.json` on [host] over SSH: the name and
/// address notifications should use, which kinds to post, and the phones to push to.
Future<void> writeWatcherConfig(Host host, {PushDevice? device}) async {
  final ssh = await SshExec.connect(host);
  try {
    final existing = await ssh.run('cat "\$HOME/.config/pocketrig/watcher.json" 2>/dev/null; true');
    final json = jsonEncode({
      'hostName': host.name,
      'address': host.address,
      // An off host posts nothing; its stored kinds stay, and turning it on writes them back.
      'kinds': host.enabled ? NotifyKind.values.map((k) => k.id).where(host.notifyKinds.contains).toList() : <String>[],
      'devices': mergeDevices(existing, device ?? Push.device),
    });
    await ssh.run('mkdir -p "\$HOME/.config/pocketrig" && printf \'%s\' ${shQuote(json)} > "\$HOME/.config/pocketrig/watcher.json"');
  } finally {
    ssh.close();
  }
}

/// POSTs a notification button's body to the watcher, as native would have.
Future<bool> postAnswer(String url, String body) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final r = await c.postUrl(Uri.parse(url));
    r.headers.contentType = ContentType.json;
    r.write(body);
    final res = await r.close().timeout(const Duration(seconds: 15));
    await res.drain<void>();
    return res.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    c.close(force: true);
  }
}

/// The app's end of `dev.pocketrig/push`: asks native to register, learns the
/// token, opens tapped links, and posts a tapped button's answer when native
/// couldn't reach the host.
class Push {
  Push({required this.onOpen, required this.onDevice, MethodChannel? channel, Future<bool> Function(String, String)? post})
      : _channel = channel ?? const MethodChannel('dev.pocketrig/push'),
        _post = post ?? postAnswer;

  /// The token native last reported; [writeWatcherConfig] puts it on the host.
  static PushDevice? device;

  final void Function(String link) onOpen;
  final void Function(PushDevice device) onDevice;
  final MethodChannel _channel;
  final Future<bool> Function(String url, String body) _post;

  String? _activityToken, _activityStartToken;

  void _update(PushDevice? d) {
    if (d != null) onDevice(device = d.withActivity(_activityToken, _activityStartToken));
  }

  Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      final a = call.arguments;
      switch (call.method) {
        case 'token':
          _update(PushDevice.parse(a));
        case 'activityToken':
          _activityToken = a is Map && a['token'] is String ? a['token'] as String : null;
          _update(device);
        case 'activityStartToken':
          _activityStartToken = a is Map && a['token'] is String ? a['token'] as String : null;
          _update(device);
        case 'open':
          if (a is Map && a['link'] is String) onOpen(a['link'] as String);
        case 'action':
          if (a is Map && a['url'] is String && a['body'] is String) await _post(a['url'] as String, a['body'] as String);
      }
    });
    try {
      await _channel.invokeMethod<void>('register');
    } on MissingPluginException {/* no native side on this platform yet */} on PlatformException {/* denied */}
  }
}
