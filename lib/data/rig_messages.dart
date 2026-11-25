import 'dart:convert';

import '../chat/session_log.dart';
import '../chat/transcript.dart' show decodeLogLine;
import '../models.dart';
import '../ssh/ssh_exec.dart';

/// One `rig send` between seats, as its recipient received it: OpenRig records sends nowhere, but each lands in
/// the recipient's transcript as a user turn in the From / To / Sent envelope.
class RigMessage {
  RigMessage({required this.from, required this.to, required this.at, required this.body});
  final String from;

  /// Every recipient that received this copy (a fan-out send arrives once per recipient).
  final Set<String> to;
  final DateTime? at;
  final String body;
}

final _envelope = RegExp(r'From: (\S+)\nTo: ([^\n]+)\nSent: ([^\n]*)\n---\n');

/// The shell that prints each seat's newest [limit] received envelopes, from its log's last [bytes] (hours of a
/// busy seat). Only received turns are read: user lines, and the queued_command lines Claude Code writes for a
/// message that arrived while the seat was busy. So a send shows once (from the recipient), never as the
/// sender's own `rig send` call.
String rigMessagesScript(List<Seat> seats, {int limit = 50, int bytes = 64 << 20}) {
  final b = StringBuffer();
  for (final s in seats) {
    b.write('f=\$( ( ${locateLogScript(s, exactOnly: true)} ) ); ');
    b.write(
        '[ -n "\$f" ] && tail -c $bytes "\$f" | grep -E \'"type": ?"user"|"queued_command"\' | grep -v \'"tool_result"\' '
        r"| grep -F 'From: ' | grep -F '\nSent: ' "
        '| tail -n $limit; ');
  }
  b.write('true');
  return b.toString();
}

/// [rigMessagesScript]'s log lines as messages, newest first, each send once.
List<RigMessage> parseRigMessages(String out) {
  final byKey = <String, RigMessage>{};
  for (final line in const LineSplitter().convert(out)) {
    final j = decodeLogLine(line);
    if (j is! Map) continue;
    final queued = j['attachment'] is Map && (j['attachment'] as Map)['type'] == 'queued_command';
    if (j['type'] != 'user' && !queued) continue;
    final content = queued ? (j['attachment'] as Map)['prompt'] : (j['message'] as Map?)?['content'];
    final text = content is String
        ? content
        : [
            if (content is List)
              for (final c in content)
                if (c is Map && c['type'] == 'text' && c['text'] is String) c['text'] as String,
          ].join('\n');
    final m = _envelope.firstMatch(text);
    if (m == null) continue;
    var body = text.substring(m.end);
    // The last one: a body may quote another delivered message, reply line and all.
    final reply = body.lastIndexOf('\n---\n↩ Reply');
    if (reply >= 0) body = body.substring(0, reply);
    body = body.replaceAll(RegExp(r'\s*</pasted_content[^>]*>\s*$'), '').trim();
    final from = m.group(1)!, sent = m.group(3)!;
    final at = DateTime.tryParse('${j['timestamp'] ?? ''}');
    final key = '$from|$sent|$body';
    final recipients = m.group(2)!.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
    (byKey[key] ??= RigMessage(from: from, to: {}, at: at, body: body)).to.addAll(recipients);
  }
  return byKey.values.toList()..sort((a, b) => (b.at ?? DateTime(0)).compareTo(a.at ?? DateTime(0)));
}

/// The newest messages received by [seats] (Claude seats; others keep no transcript the app reads).
Future<List<RigMessage>> loadRigMessages(Host host, List<Seat> seats, {int limit = 50}) async {
  if (seats.isEmpty) return const [];
  final out = await SshExec.use(host, (ssh) => ssh.run(rigMessagesScript(seats, limit: limit)));
  return parseRigMessages(out).take(limit).toList();
}
