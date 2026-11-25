import '../data/projects.dart' show shQuote;
import '../models.dart';
import '../ssh/ssh_exec.dart';

/// The agent's reply as it is being written, read off its terminal pane.
/// Claude Code writes a text block to its session log only when the block is
/// complete; the pane is the one place the words show up as they are typed.
///
/// Returns plain text, or null when there is nothing to show or the pane
/// isn't in a shape this understands (better no preview than garbage).
// shortcut: matches Claude Code's TUI (2.1.x): ⏺ before a reply, ⎿ under a tool, a "✢ Verb…" status line above the
// input box's two rules. If a release changes them this returns null; update test/fixtures/panes first.
String? parsePanePreview(String pane) {
  final lines = [for (final l in pane.split('\n')) l.trimRight()];
  final rules = [
    for (var i = 0; i < lines.length; i++)
      if (lines[i].startsWith('─')) i
  ];
  if (rules.length < 2) return null;
  final tail = lines.skip(lines.length > 14 ? lines.length - 14 : 0);
  if (tail.any((l) => RegExp(r'^\s*❯ \d\. ').hasMatch(l))) return null; // a permission or choice menu
  // Everything above the input box's top rule.
  final body = lines.sublist(0, rules[rules.length - 2]);
  void trim() {
    while (body.isNotEmpty && body.last.isEmpty) {
      body.removeLast();
    }
  }

  trim();
  // A tip can sit under the status line.
  if (body.isNotEmpty && body.last.startsWith('  ⎿  Tip:')) body.removeLast();
  trim();
  // Working shows "✢ Nucleating… (1m 11s …)"; finished shows "✻ Cogitated for 57s".
  if (body.isEmpty || !RegExp(r'^[✻✢✳✶✽·*] \S.*…').hasMatch(body.last)) return null;
  body.removeLast();
  trim();
  final start = body.lastIndexWhere((l) => l.startsWith('⏺ '));
  if (start < 0 || body.lastIndexWhere((l) => l.startsWith('❯ ')) > start) return null;
  final block = body.sublist(start);
  // A tool call (its line may show without the ⏺ while that blinks) or its result.
  if (RegExp(r'^⏺ [A-Za-z_.:-]+\(').hasMatch(block.first)) return null;
  if (block.any((l) => l.startsWith('  ⎿') || RegExp(r'^ {2}[A-Z][A-Za-z]*\(').hasMatch(l))) return null;

  // The pane hard-wraps at its width: join a paragraph's lines, keep list items and code lines apart.
  final out = <String>[];
  var joining = false, inCode = false;
  for (var i = 0; i < block.length; i++) {
    final l = i == 0
        ? block[i].substring(2)
        : block[i].startsWith('  ')
            ? block[i].substring(2)
            : block[i];
    if (l.trim().isEmpty) {
      if (out.isNotEmpty && out.last.isNotEmpty) out.add('');
      joining = false;
      continue;
    }
    final fence = l.trimLeft().startsWith('```');
    if (fence) inCode = !inCode;
    final item = RegExp(r'^\s*([-*•]|\d+\.)\s').hasMatch(l);
    if (joining && !item && !inCode && !fence) {
      out[out.length - 1] = '${out.last} ${l.trim()}';
    } else {
      out.add(l);
    }
    joining = !item && !inCode && !fence || item;
  }
  final text = out.join('\n').trim();
  if (text.length < 2) return null;
  return text.length > 2000 ? '…${text.substring(text.length - 2000)}' : text;
}

/// The last 120 lines of [seat]'s tmux pane, or null when it has no session.
Future<String?> readPane(Host host, Seat seat) async {
  final session = seat.sessionName;
  if (session == null) return null;
  return SshExec.use(host, (ssh) async {
    final out = await ssh.runLogin('tmux capture-pane -p -J -S -120 -t ${shQuote('=$session:')} 2>/dev/null');
    return out.isEmpty ? null : out;
  });
}
