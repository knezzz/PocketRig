import '../models.dart' show Seat, SeatState;
import 'projects.dart' show shQuote;

/// A process an agent started: a shell from its Bash tool (foreground or in
/// the background), a watcher, a dev server, or an MCP server.
/// Most shells an agent's rows list; more come as one '+N more' row, and any of them opens the agent's full shells list.
const maxShellRows = 3;

/// The shells of [jobs] to list under an agent, at most [maxShellRows], and how many are left out ('+[more] more').
({List<AgentJob> shown, int more}) capShells(List<AgentJob> jobs) {
  final shells = jobs.where((j) => j.isShell).toList();
  return (shown: shells.take(maxShellRows).toList(), more: shells.length > maxShellRows ? shells.length - maxShellRows : 0);
}

class AgentJob {
  final int pid;

  /// `ps` state letters: R running, S sleeping, T stopped, Z zombie.
  final String stat;
  final Duration elapsed;

  /// CPU % of the job and everything under it.
  final double cpu;

  /// Processes under it (a gradle build's JVMs, a test runner's workers).
  final int children;

  /// What it runs. For a Claude Code shell, the command it was given.
  final String command;

  /// When its stdout goes to a file (Claude Code's Bash tasks, foreground or
  /// background, write to `<session>/tasks/<id>.output`): how much it wrote,
  /// and the last line of it.
  final int? outputBytes;
  final String? lastLine;

  /// The last lines of that output, when [script] was asked for more than one.
  final List<String> output;

  /// A Claude Code Bash tool shell, not a helper like an MCP server.
  final bool isShell;

  /// A Claude Code Monitor: a shell whose output goes straight back to the
  /// agent (a socket) instead of a task file.
  bool get isMonitor => isShell && outputBytes == null;

  /// The command's first line, short enough for a row; leading `cd <dir> &&`
  /// and `NAME=value;` steps are skipped, so it starts with what runs.
  String get short {
    final line = command.trim().split('\n').first.trim().replaceFirst(RegExp(r'^((cd\s+|\w+=)\S+\s*(&&|;)\s*)+'), '');
    return line.length > 60 ? '${line.substring(0, 59)}…' : line;
  }

  /// "2 shells · 1 monitor", or for just one, "on shell: flutter test" or
  /// "monitor: tail -f …": what an agent is waiting on.
  static String describe(List<AgentJob> jobs) {
    if (jobs.length == 1) return '${jobs.single.isMonitor ? 'monitor' : 'on shell'}: ${jobs.single.short}';
    return counts(jobs).join(' · ');
  }

  /// "2 shells", "1 monitor": the non-zero counts in [jobs].
  static List<String> counts(List<AgentJob> jobs) {
    final monitors = jobs.where((j) => j.isMonitor).length, shells = jobs.length - monitors;
    return [
      if (shells > 0) '$shells ${shells == 1 ? 'shell' : 'shells'}',
      if (monitors > 0) '$monitors ${monitors == 1 ? 'monitor' : 'monitors'}',
    ];
  }

  /// Whether [s] is waiting rather than idle: on its shells ([jobs]) or on subagents it left running while at its prompt, and how
  /// many of those ([idleSubs]; none when it works, since a working agent is working whatever it left running: Seat.state's rule).
  /// One rule for the seat sheet's and the details card's Status line.
  static ({bool waiting, int idleSubs}) seatWaiting(Seat s, {required int jobs, required int subagents}) {
    final idleSubs = s.activity == 'working' ? 0 : subagents;
    return (
      waiting: !s.needsInput && s.state != SeatState.stopped && s.activity != 'working' && (jobs > 0 || idleSubs > 0),
      idleSubs: idleSubs,
    );
  }

  /// What an agent idle at its prompt is waiting on: its shells and
  /// monitors (spending no tokens), and/or its running subagents (which do).
  static String waitingLine(List<AgentJob> jobs, int subagents) => jobs.isEmpty
      ? 'waiting on ${subagents == 1 ? 'a subagent' : 'subagents'}'
      : '${describe(jobs)}${subagents == 0 ? ' · no tokens' : ' · waiting on subagents'}';

  String get state => switch (stat.isEmpty ? '' : stat[0]) {
        'T' => 'stopped',
        'Z' => 'exited',
        _ when cpu >= 1 || stat.startsWith('R') => 'running',
        _ => 'waiting',
      };

  /// Every agent's processes in tmux session [session], one round trip, with
  /// the last [lines] of each one's output. Runs with [SshExec.runLogin] for Homebrew's tmux.
  static String script(String session, {int lines = 1}) => 'set -- ${shQuote(session)} $lines; $_script';

  /// Every tmux session's processes: `@@jobs<TAB>session` and then that
  /// session's [script] output. Needs a login shell for Homebrew's tmux.
  static const allSessionsScript =
      // ':' separates name and folder: tmux session names can't hold one, and with no UTF-8 locale tmux turns a tab into '_'.
      'tmux -u list-sessions -F "#{session_name}:#{session_path}" 2>/dev/null | while IFS=: read -r s p; do printf \'@@jobs\\t%s:%s\\n\' "\$s" "\$p"; '
      '( set -- "\$s"\n$_script\n); done; true';

  /// Stops [pid] and everything under it (a build's workers too) with TERM,
  /// waits up to 5 s for them to go, and prints `left:` and the pids still alive.
  static String stopScript(int pid) => 'all=$pid; new=$pid; '
      'while [ -n "\$new" ]; do new=\$(for p in \$new; do pgrep -P "\$p"; done); all="\$all \$new"; done; '
      'kill -TERM \$all 2>/dev/null; i=0; while [ \$i -lt 10 ]; do left=; '
      'for p in \$all; do kill -0 "\$p" 2>/dev/null && left="\$left \$p"; done; '
      '[ -z "\$left" ] && break; sleep 0.5; i=\$((i+1)); done; echo "left:\$left"';

  /// How many processes [stopScript] left running.
  static int stillRunning(String out) {
    final line = out.split('\n').lastWhere((l) => l.startsWith('left:'), orElse: () => 'left:');
    return line.substring(5).trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).length;
  }

  /// [allSessionsScript]'s output, by session.
  static Map<String, List<AgentJob>> parseAll(String out) => {
        for (final c in out.split('@@jobs\t').skip(1))
          if (c.indexOf('\n') case final nl when nl > 0) c.substring(0, nl).split(':').first: parse(c.substring(nl + 1)),
      };

  /// [allSessionsScript]'s sessions with their folder, in scan order.
  static List<(String, String)> parseSessions(String out) => [
        for (final c in out.split('@@jobs\t').skip(1))
          if (c.split('\n').first case final head when head.contains(':'))
            (head.substring(0, head.indexOf(':')), head.substring(head.indexOf(':') + 1)),
      ];

  /// The shells and monitors an agent idle at its prompt still has running,
  /// so it spends no tokens while they finish. A [working] agent is working,
  /// even while it waits on a command of its own.
  static List<AgentJob> waitingOn(List<AgentJob> jobs, {required bool working}) => working
      ? const []
      : [
          for (final j in jobs)
            if (j.isShell && j.state != 'stopped' && j.state != 'exited') j
        ];

  static List<AgentJob> parse(String out) {
    final jobs = <int, List<String>>{};
    final output = <int, List<String>>{};
    final tails = <int, List<String>>{};
    for (final line in out.split('\n')) {
      final f = line.split('\t');
      if (f[0] == 'J' && f.length >= 7) jobs[int.tryParse(f[1]) ?? -1] = f;
      if (f[0] == 'O' && f.length >= 4) output[int.tryParse(f[1]) ?? -1] = f;
      if (f[0] == 'L' && f.length >= 3) (tails[int.tryParse(f[1]) ?? -1] ??= []).add(f.sublist(2).join('\t'));
    }
    return [
      for (final MapEntry(key: pid, value: f) in jobs.entries)
        if (pid > 0)
          AgentJob._(
            pid: pid,
            stat: f[2],
            elapsed: parseEtime(f[3]),
            cpu: double.tryParse(f[4]) ?? 0,
            children: int.tryParse(f[5]) ?? 0,
            raw: f.sublist(6).join('\t'),
            outputBytes: int.tryParse(output[pid]?[2] ?? ''),
            lastLine: output[pid]?.sublist(3).join('\t').trim(),
            output: tails[pid] ?? const [],
          ),
    ]..sort((a, b) => a.isShell == b.isShell ? a.elapsed.compareTo(b.elapsed) : (a.isShell ? -1 : 1));
  }

  AgentJob._({
    required this.pid,
    required this.stat,
    required this.elapsed,
    required this.cpu,
    required this.children,
    required String raw,
    this.outputBytes,
    String? lastLine,
    this.output = const [],
  })  : isShell = _shellCommand(raw) != null,
        command = _shellCommand(raw) ?? raw,
        lastLine = lastLine == null || lastLine.isEmpty ? null : lastLine;

  /// Claude Code runs each Bash call as `zsh -c source <snapshot> && … eval '<cmd>' < /dev/null && pwd -P >| …`;
  /// a single word goes unquoted (`eval /path/run.sh < /dev/null`).
  static String? _shellCommand(String raw) {
    if (!raw.contains('shell-snapshots/')) return null;
    final a = raw.indexOf(' eval ');
    if (a < 0) return null;
    final quoted = raw.startsWith("'", a + 6);
    final from = a + (quoted ? 7 : 6);
    final b = raw.lastIndexOf(quoted ? "' < /dev/null" : ' < /dev/null');
    final body = raw.substring(from, b > from ? b : raw.length);
    return body.replaceAll("'\\''", "'").replaceAll("'\"'\"'", "'").replaceAll(r'\012', '\n');
  }

  /// `ps` etime: `[[dd-]hh:]mm:ss`.
  static Duration parseEtime(String s) {
    final day = s.split('-');
    final parts = day.last.split(':').map((p) => int.tryParse(p) ?? 0).toList().reversed.toList();
    return Duration(
      days: day.length > 1 ? int.tryParse(day.first) ?? 0 : 0,
      hours: parts.length > 2 ? parts[2] : 0,
      minutes: parts.length > 1 ? parts[1] : 0,
      seconds: parts.isNotEmpty ? parts[0] : 0,
    );
  }
}

/// `$1` is the tmux session, `$2` how many output lines to send (default 1).
/// Per pane: walk past the login shell to the agent, print each child as a J
/// line (with its subtree's CPU and size), then an O line with the tail of its
/// stdout when that is a file, and with `$2` over 1, that many L lines of it.
const _script = r'''
panes=$(tmux list-panes -s -t "$1" -F '#{pane_pid}' 2>/dev/null) || exit 0
jobs=$(ps -axwwo pid=,ppid=,stat=,etime=,%cpu=,command= | awk -v panes="$panes" '
{ p=$1; pp[p]=$2; st[p]=$3; et[p]=$4; cpu[p]=$5; c=$0; sub(/^ *[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ /, "", c); cmd[p]=c; kids[$2]=kids[$2] " " p }
function shell(p) { return cmd[p] ~ /^(-|\/[^ ]*\/)?(ba|z|fi|da|k)?sh( -l| --login)?$/ }
function walk(p,   n, a, i) { n=split(kids[p], a, " "); for (i=1; i<=n; i++) { sub_cpu+=cpu[a[i]]; sub_n++; walk(a[i]) } }
END {
  n=split(panes, r, "\n")
  for (i=1; i<=n; i++) {
    a=r[i]
    while (shell(a) && split(kids[a], k, " ")==1) a=k[1]
    m=split(kids[a], j, " ")
    for (x=1; x<=m; x++) { p=j[x]; sub_cpu=cpu[p]; sub_n=0; walk(p)
      gsub(/[\t\n]/, " ", cmd[p])
      printf "J\t%s\t%s\t%s\t%.1f\t%d\t%s\n", p, st[p], et[p], sub_cpu, sub_n, substr(cmd[p], 1, 2000) }
  }
}')
[ -n "$jobs" ] || exit 0
printf '%s\n' "$jobs"
lsof -a -p "$(printf '%s\n' "$jobs" | cut -f2 | paste -sd, -)" -d 1 -Fpn 2>/dev/null | while read -r l; do
  case $l in
    p*) pid=${l#p} ;;
    n/*) f=${l#n}; [ -f "$f" ] && printf 'O\t%s\t%s\t%s\n' "$pid" "$(wc -c < "$f" | tr -d ' ')" \
      "$(tail -c 4000 "$f" | tr '\r\t' '\n ' | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-300)"
      [ -f "$f" ] && [ "${2:-1}" -gt 1 ] && tail -c 32000 "$f" | tr '\r\t' '\n ' | grep -v '^[[:space:]]*$' \
        | tail -n "$2" | cut -c1-300 | awk -v p="$pid" '{ printf "L\t%s\t%s\n", p, $0 }' ;;
  esac
done
true
''';
