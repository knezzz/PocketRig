import 'dart:convert';

import '../models.dart';

/// A Claude Code subagent (the Agent/Task tool) that is still running.
///
/// Read from Claude Code's own files: `projects/<slug>/<session>/subagents/
/// agent-<id>.jsonl` and the `.meta.json` next to it, which gets
/// `"finished": true` when it's done.
///
/// shortcut: these are Claude Code's internal files; if they move, the app
/// just shows no subagents.
class Subagent {
  Subagent(
      {required this.sessionId,
      required this.agentId,
      this.path,
      this.type,
      this.description,
      this.started,
      this.lastWrite});

  /// Its log on the host.
  final String? path;

  /// The parent Claude session.
  final String sessionId;
  final String agentId;

  /// `general-purpose`, `Explore`, …
  final String? type;
  final String? description;
  final DateTime? started;
  final DateTime? lastWrite;

  String get title => description ?? type ?? 'subagent';

  /// A read-only seat whose chat is this subagent's log.
  Seat toSeat({String? cwd}) =>
      Seat(rigId: '', logicalId: title, runtime: 'claude-code', cwd: cwd, transcriptPath: path, activity: 'working');

  /// One line per running subagent: `@@sub`, session, agent id, start time,
  /// last write (epoch s), log path, then its meta JSON on the next line.
  ///
  /// shortcut: older Claude Code never writes `finished`, so a log not written
  /// to for [quietMinutes] counts as done; a subagent that long in one tool
  /// call drops off the list until it writes again.
  static String script({int quietMinutes = 15}) => '''
base="\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/projects"
find "\$base" -mindepth 4 -maxdepth 4 -path '*/subagents/agent-*.jsonl' -mmin -$quietMinutes 2>/dev/null | while IFS= read -r f; do
  m="\${f%.jsonl}.meta.json"
  grep -Eq '"(finished|stoppedByUser)" *: *true' "\$m" 2>/dev/null && continue
  s=\${f%/subagents/*}; a=\${f##*/agent-}
  t=\$(head -c 4000 "\$f" | grep -o '"timestamp":"[^"]*"' | head -n 1 | cut -d '"' -f 4)
  printf '@@sub\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "\${s##*/}" "\${a%.jsonl}" "\$t" "\$(date -r "\$f" +%s)" "\$f"
  tr -d '\\n' < "\$m" 2>/dev/null; echo
done''';

  static List<Subagent> parse(String out) {
    final lines = out.split('\n');
    final list = <Subagent>[];
    for (var i = 0; i < lines.length; i++) {
      final f = lines[i].split('\t');
      if (f.length < 5 || f[0] != '@@sub') continue;
      Map<String, Object?> meta = const {};
      if (i + 1 < lines.length && lines[i + 1].startsWith('{')) {
        try {
          meta = (jsonDecode(lines[++i]) as Map).cast<String, Object?>();
        } catch (_) {/* no meta: still running, just unnamed */}
      }
      final epoch = int.tryParse(f[4].trim());
      list.add(Subagent(
        sessionId: f[1],
        agentId: f[2],
        path: f.length > 5 ? f.sublist(5).join('\t') : null,
        type: meta['agentType'] as String?,
        description: meta['description'] as String?,
        started: DateTime.tryParse(f[3])?.toLocal(),
        lastWrite: epoch == null ? null : DateTime.fromMillisecondsSinceEpoch(epoch * 1000),
      ));
    }
    return list;
  }

  /// [all] grouped by parent session, oldest first.
  static Map<String, List<Subagent>> bySession(List<Subagent> all) {
    final m = <String, List<Subagent>>{};
    for (final s in all) {
      m.putIfAbsent(s.sessionId, () => []).add(s);
    }
    for (final l in m.values) {
      l.sort((a, b) => (a.started ?? DateTime(0)).compareTo(b.started ?? DateTime(0)));
    }
    return m;
  }
}

/// The Claude session a seat runs: its log's file name, else its resume token.
String? claudeSessionOf(Seat s) {
  final tp = s.transcriptPath;
  if (tp != null && tp.endsWith('.jsonl')) return tp.split('/').last.replaceFirst(RegExp(r'\.jsonl$'), '');
  return s.resumeToken;
}

/// Whether [path] is a subagent's log rather than a session's.
bool isSubagentLog(String? path) => path != null && path.contains('/subagents/agent-');

/// "2 subagents", or null for none.
String? subagentsLabel(List<Subagent> l) => l.isEmpty ? null : '${l.length} subagent${l.length == 1 ? '' : 's'}';
