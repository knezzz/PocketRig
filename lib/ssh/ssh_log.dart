import 'package:borealis/borealis.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/ux_log.dart';
import '../models.dart';

/// One SSH connection or command, as shown in the Borealis SSH tab.
class SshCall {
  SshCall(this.host, this.command) : started = DateTime.now();
  final String host;
  final String command;
  final DateTime started;
  Duration? duration;
  String? output;
  Object? error;
  bool get done => duration != null;
}

/// Every SSH call the app makes, newest first, the last 300, in memory only.
/// Kept in release builds too (eaa4af0).
class SshLog extends ChangeNotifier {
  SshLog._();
  static final instance = SshLog._();
  static const _max = 300;

  final List<SshCall> calls = [];

  /// Runs [body] and records it under [command]; [show] renders its result.
  Future<T> track<T>(Host host, String command, Future<T> Function() body, {String Function(T)? show}) async {
    final call = SshCall(host.name, command);
    calls.insert(0, call);
    if (calls.length > _max) calls.removeLast();
    notifyListeners();
    try {
      final out = await body();
      call.output = show?.call(out);
      return out;
    } catch (e) {
      call.error = e;
      rethrow;
    } finally {
      call.duration = DateTime.now().difference(call.started);
      // First word only: SSH commands can carry paths and arguments.
      uxLog.call('ssh ${command.split(' ').first}', call.duration!, error: call.error);
      notifyListeners();
    }
  }

  void clear() {
    calls.clear();
    notifyListeners();
  }
}

/// The **SSH** tab of the Borealis panel.
class SshBorealisPage extends BorealisPage {
  const SshBorealisPage() : super(title: 'SSH', icon: Icons.terminal);

  static final _badge = CountListenable(SshLog.instance, () => SshLog.instance.calls.length);

  @override
  ValueListenable<int>? get badgeListenable => _badge;

  @override
  VoidCallback? get onClearTap => SshLog.instance.clear;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: SshLog.instance,
        builder: (context, _) {
          final calls = SshLog.instance.calls;
          if (calls.isEmpty) return const Center(child: Text('No SSH calls yet'));
          return ListView.builder(
            itemCount: calls.length,
            itemBuilder: (context, i) {
              final c = calls[i];
              final status = !c.done ? '…' : (c.error != null ? 'failed' : 'ok');
              final color = c.error != null ? Colors.redAccent : (c.done ? Colors.greenAccent : Colors.amber);
              const mono = TextStyle(fontFamily: 'monospace', fontSize: 12);
              return ExpansionTile(
                dense: true,
                title: Text(c.command, maxLines: 2, overflow: TextOverflow.ellipsis, style: mono),
                subtitle: Text(
                  '${c.host} · ${c.started.toIso8601String().substring(11, 19)} · '
                  '${c.duration?.inMilliseconds ?? 0} ms · $status',
                  style: TextStyle(color: color, fontSize: 11),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(c.command, style: mono),
                  if (c.error != null) SelectableText('${c.error}', style: mono.copyWith(color: Colors.redAccent)),
                  if (c.output != null && c.output!.isNotEmpty) SelectableText(c.output!, style: mono),
                ],
              );
            },
          );
        },
      );
}
