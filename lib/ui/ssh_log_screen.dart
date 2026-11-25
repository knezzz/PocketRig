import 'package:flutter/material.dart';

import '../ssh/ssh_log.dart';
import 'common.dart';
import 'kit.dart';
import 'theme.dart';

/// Settings › host › SSH log: the app's SSH calls to one host, newest first,
/// with what each printed or why it failed. Empty in release builds.
class SshLogScreen extends StatelessWidget {
  const SshLogScreen({super.key, required this.hostName});
  final String hostName;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return Scaffold(
      body: Column(children: [
        PageHeader(overline: hostName, title: 'SSH log'),
        Expanded(
          child: ListenableBuilder(
            listenable: SshLog.instance,
            builder: (context, _) {
              final calls = SshLog.instance.calls.where((c) => c.host == hostName).toList();
              if (calls.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('No SSH calls to $hostName yet in this session.', style: TextStyle(color: k.muted)),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                itemCount: calls.length,
                separatorBuilder: (_, __) => Divider(color: k.divider),
                itemBuilder: (context, i) {
                  final c = calls[i];
                  final failed = c.error != null;
                  final state = !c.done ? 'running' : (failed ? 'failed' : 'ok');
                  return Theme(
                    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text(c.command,
                          maxLines: 2, overflow: TextOverflow.ellipsis, style: mono(context, size: 12, color: k.ink)),
                      subtitle: Text(
                        '$state · ${agoPhrase(c.started)}${c.duration == null ? '' : ' · ${c.duration!.inMilliseconds} ms'}',
                        style: TextStyle(fontSize: 12, color: failed ? k.removed : k.muted),
                      ),
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: k.fill, borderRadius: BorderRadius.circular(kRadius)),
                          child: SelectableText(
                            failed ? '${c.error}' : (c.output?.trim().isEmpty ?? true ? '(no output)' : c.output!.trim()),
                            style: mono(context, size: 11, color: k.ink),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}
