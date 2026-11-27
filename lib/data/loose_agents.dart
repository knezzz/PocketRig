import 'dart:convert';

import '../api/openrig_client.dart';
import '../models.dart';
import 'agent_jobs.dart';
import '../ssh/ssh_exec.dart';
import '../terminal/transport.dart';
import 'new_session.dart';
import 'projects.dart';
import 'subagents.dart';

/// Where the watcher's Claude hook keeps what it saw.
const looseFile = r'"$HOME"/.config/pocketrig/loose.json';

/// Hook entries from loose.json; empty when the watcher isn't installed.
List<LooseAgent> parseHookFile(String text) {
  try {
    final j = jsonDecode(text);
    if (j is! List) return const [];
    return j
        .whereType<Map>()
        .map((e) => LooseAgent.fromHook(e.cast<String, Object?>()))
        .whereType<LooseAgent>()
        .toList();
  } catch (_) {
    return const [];
  }
}

/// Scan rows and hook entries as one list, one row per agent.
///
/// Rig seats are dropped (their tmux session is in [managedSessions]): a
/// seat's Claude also fires the hook. Hook entries with no tmux session and
/// nothing to say for a long time are left out too.
List<LooseAgent> mergeLooseAgents(
  List<LooseAgent> scanned,
  List<LooseAgent> hooked,
  Set<String> managedSessions, {
  DateTime? now,
  Map<String, String> labels = const {},
}) {
  final byId = <String, LooseAgent>{};
  for (final a in scanned) {
    if (!managedSessions.contains(a.tmuxSession)) byId[a.id] = a;
  }
  for (final h in hooked) {
    if (h.tmuxSession != null && managedSessions.contains(h.tmuxSession)) continue;
    final existing = byId[h.id];
    byId[h.id] = existing == null ? h : existing.mergeHook(h);
  }
  for (final a in byId.values) {
    a.label = labels[a.id];
  }
  return byId.values.toList()
    ..sort((a, b) {
      final w = (b.waiting ? 1 : 0) - (a.waiting ? 1 : 0);
      return w != 0 ? w : a.name.compareTo(b.name);
    });
}

/// Both sources, best effort: a host without the watcher or an older daemon
/// just shows fewer agents. [scan] asks the daemon to look again first.
/// [onPartial] is called when a source failed, so a missing agent proves nothing.
/// [onSubagents] gets every running subagent on the host and [onJobs] every
/// tmux session's processes, from the same SSH call, and [onShells] the project shells among them. [onDiscovered] gets the
/// daemon's agents the moment its list is back, before the slower SSH read (the hook file, tmux's processes) has finished, so a
/// first load does not wait on it to show them.
Future<List<LooseAgent>> loadLooseAgents(Host host, OpenRigClient api, List<RigWithSeats> rigs,
    {bool scan = false,
    void Function()? onPartial,
    void Function(List<Subagent>)? onSubagents,
    void Function(Map<String, List<AgentJob>>)? onJobs,
    void Function(List<ProjectShell>)? onShells,
    void Function(List<LooseAgent>)? onDiscovered}) async {
  final managed = {
    for (final r in rigs)
      for (final s in r.seats)
        if (s.sessionName != null) s.sessionName!,
  };
  final results = await Future.wait([
    api.discovered(scan: scan).then((found) {
      onDiscovered?.call(mergeLooseAgents(found, const [], managed, labels: host.agentNames));
      return found;
    }).catchError((Object _) {
      onPartial?.call();
      return <LooseAgent>[];
    }),
    () async {
      SshExec? ssh;
      try {
        ssh = await SshExec.connect(host);
        const mark = '@@pocketrig-subagents', jobsMark = '@@pocketrig-jobs';
        var out = await ssh.run('cat $looseFile 2>/dev/null'
            '${onSubagents == null ? '' : '; echo; echo $mark; sh -c ${shQuote(Subagent.script())}'}'
            // A login shell for Homebrew's tmux, as SshExec.runLogin does.
            '${onJobs == null ? '' : '; echo; echo $jobsMark; PATH="\$PATH:/opt/homebrew/bin:/usr/local/bin" "\${SHELL:-/bin/sh}" -lc ${shQuote(AgentJob.allSessionsScript)}'}');
        final j = out.indexOf(jobsMark);
        if (j >= 0) {
          final sessions = out.substring(j + jobsMark.length);
          onJobs!(AgentJob.parseAll(sessions));
          onShells?.call(projectShells(AgentJob.parseSessions(sessions)));
          out = out.substring(0, j);
        }
        final at = out.indexOf(mark);
        if (at >= 0) onSubagents!(Subagent.parse(out.substring(at)));
        return parseHookFile((at < 0 ? out : out.substring(0, at)).trim());
      } catch (_) {
        onPartial?.call();
        return <LooseAgent>[];
      } finally {
        ssh?.close();
      }
    }(),
  ]);
  return mergeLooseAgents(results[0], results[1], managed, labels: host.agentNames);
}

/// Allow once ("1") or deny (Escape) at an agent's tmux pane, over SSH: the same exact-target, checked send as a seat's
/// ([pressSeatKeys]), at the agent's own pane when it has one.
Future<void> answerLooseAgent(Host host, LooseAgent a, {required bool allow}) async {
  if (a.tmuxSession == null) throw OpenRigException('${a.name} isn\'t in tmux, so it can only be answered at the Mac.');
  await pressSeatKeys(host, a.toSeat(), [allow ? '1' : 'Escape']);
}

/// The tmux session a restarted agent gets: `claude-<folder>-<id start>`.
String restartSessionName(String cwd, String sessionId) => newSessionName(AgentRuntime.claude, cwd, sessionId);

/// AppleScript: run command `c` in the tab on tty `t`, an error when there's none.
const _typeInTerminal = '''
on run {t, c}
  tell application "Terminal"
    repeat with w in windows
      repeat with b in tabs of w
        if tty of b is t then
          do script c in b
          return
        end if
      end repeat
    end repeat
  end tell
  error "no tab"
end run''';

const _typeInITerm = '''
on run {t, c}
  tell application "iTerm2"
    repeat with w in windows
      repeat with b in tabs of w
        repeat with s in sessions of b
          if tty of s is t then
            tell s to write text c
            return
          end if
        end repeat
      end repeat
    end repeat
  end tell
  error "no tab"
end run''';

/// Shell: sets `found` when `\$id` has a session file, `pid` when its process is alive.
const _findSessionProcess = r'''
for f in "$HOME"/.claude/sessions/*.json; do
  grep -Eq "\"sessionId\" *: *\"$id\"" "$f" 2>/dev/null || continue
  found=1
  p=$(basename "$f" .json)
  case "$p" in ''|*[!0-9]*) continue ;; esac
  kill -0 "$p" 2>/dev/null && { pid=$p; live=$((live + 1)); }
done''';

/// Shell helpers: `isclaude PID` (its executable is claude, or Claude Code's version-number title, or an interpreter running a
/// claude script: not any process with claude somewhere in its arguments) and `inpane PID "PANE_PIDS "` (the process, or one
/// of its ancestors, is one of those pane processes: it runs in that tmux session).
const _processChecks = r'''
isclaude() { set -- $(ps -o command= -p "$1" 2>/dev/null); a=${1##*/}
  case $a in claude|[0-9]*.[0-9]*.[0-9]*) return 0 ;; node|sh|bash) [ "${2##*/}" = claude ] && return 0 ;; esac; return 1; }
inpane() { q=$1; while [ -n "$q" ] && [ "$q" -gt 1 ] 2>/dev/null; do
  case " $2" in *" $q "*) return 0 ;; esac
  q=$(ps -o ppid= -p "$q" 2>/dev/null | tr -d ' '); done; return 1; }''';

/// Stops the Claude process behind [sessionId], then resumes it in a new
/// tmux session. Everything that can fail cheaply is checked before the stop,
/// and a process that won't exit is left alone, so two copies never share a
/// conversation. Prints `pocketrig-restart-ok` or `pocketrig-restart-error <why>`.
///
/// The terminal tab it ran in then attaches to the new session: `ok attached`,
/// or `ok attach-failed` when that couldn't be done. That never fails the
/// restart, and `osascript` is killed after [attachSeconds] because it blocks
/// for as long as macOS's Automation prompt stays unanswered.
///
/// shortcut: only Terminal and iTerm can be scripted, others report attach-failed.
///
/// shortcut: finds the process through Claude Code's internal
/// `~/.claude/sessions/<pid>.json`; `not-found` is the error if that changes.
String restartInTmuxScript({
  required String sessionId,
  required String cwd,
  required String name,
  int waitSeconds = 10,
  int settleSeconds = 2,
  int attachSeconds = 8,
}) =>
    '''
id=${shQuote(sessionId)}; dir=${shQuote(cwd)}; name=${shQuote(name)}
fail() { echo "pocketrig-restart-error \$1"; exit 0; }
command -v tmux >/dev/null 2>&1 || fail no-tmux
${findBinaryScript(AgentRuntime.claude)}
claude=\$bin
cd "\$dir" 2>/dev/null || fail no-folder
tmux has-session -t "=\$name" 2>/dev/null && fail name-taken
found=; pid=; tty=; live=0
$_processChecks
$_findSessionProcess
[ -n "\$found" ] || fail not-found
[ "\$live" -le 1 ] || fail ambiguous
if [ -n "\$pid" ]; then
  isclaude "\$pid" || fail not-claude
  # A process in a tmux pane has a session of its own: this restart is for terminal tabs.
  inpane "\$pid" "\$(tmux list-panes -a -F '#{pane_pid}' 2>/dev/null | tr '\\n' ' ')" && fail in-tmux
  tty=\$(ps -o tty= -p "\$pid" | tr -d ' ')
  echo pocketrig-restart-step stopping
  kill -TERM "\$pid" 2>/dev/null
  i=0
  while kill -0 "\$pid" 2>/dev/null; do
    [ "\$i" -ge ${waitSeconds * 2} ] && fail still-running
    i=\$((i + 1))
    sleep 0.5
  done
fi
echo pocketrig-restart-step starting
tmux new-session -d -s "\$name" -c "\$dir" "'\$claude' --resume \$id" 2>/dev/null || fail start-failed
sleep $settleSeconds
tmux has-session -t "=\$name" 2>/dev/null || fail start-failed
case "\$tty" in ''|*[!a-z0-9]*) echo pocketrig-restart-ok; exit 0 ;; esac
# Typing is only safe at a shell prompt, not into whatever else took over the tab.
ps -t "\$tty" -o stat=,comm= | grep '+' | grep -Evq '(^|[ /-])(zsh|bash|fish|sh)\$' && { echo pocketrig-restart-ok attach-failed; exit 0; }
echo pocketrig-restart-step attaching
type_in() {
  pgrep -xq "\$1" || return 1
  osascript -e "\$2" "/dev/\$tty" "tmux attach -t '=\$name'" >/dev/null 2>&1 &
  o=\$!
  ( sleep $attachSeconds; kill "\$o" ) >/dev/null 2>&1 &
  w=\$!
  wait "\$o"; r=\$?
  kill "\$w" 2>/dev/null
  return \$r
}
if type_in Terminal '$_typeInTerminal' || type_in iTerm2 '$_typeInITerm'; then
  echo pocketrig-restart-ok attached
else
  echo pocketrig-restart-ok attach-failed
fi
''';

/// Where a restart is, for the progress dialog.
enum RestartStep { connecting, stopping, starting, attaching }

/// Moves a plain-terminal Claude session into tmux. Returns the tmux session,
/// and whether its terminal tab was left behind instead of following it.
/// [onStep] hears each step as the script on the host reaches it.
Future<({String name, bool tabLeftBehind})> restartInTmux(Host host,
    {required String sessionId, required String cwd, void Function(RestartStep step)? onStep}) async {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(sessionId)) {
    throw OpenRigException('That doesn\'t look like a Claude session id.');
  }
  final name = restartSessionName(cwd, sessionId);
  onStep?.call(RestartStep.connecting);
  final ssh = await SshExec.connect(host);
  final String out;
  try {
    // `sh` because the login shell may be zsh, where an unmatched glob is an error.
    out = await ssh.runLogin(
        'sh -c ${shQuote(restartInTmuxScript(sessionId: sessionId, cwd: cwd, name: name))}',
        onOutput: (soFar) {
          final step = RegExp(r'pocketrig-restart-step (\w+)').allMatches(soFar).lastOrNull?.group(1);
          if (step != null) onStep?.call(RestartStep.values.byName(step));
        });
  } finally {
    ssh.close();
  }
  if (out.contains('pocketrig-restart-ok')) return (name: name, tabLeftBehind: out.contains('attach-failed'));
  final why = RegExp(r'pocketrig-restart-error (\S+)').firstMatch(out)?.group(1);
  throw OpenRigException(switch (why) {
    'no-tmux' => 'tmux isn\'t installed on this host. Nothing was stopped.',
    'no-claude' => 'Couldn\'t find claude on this host. Nothing was stopped.',
    'no-folder' => 'The agent\'s folder is gone. Nothing was stopped.',
    'name-taken' => 'The tmux session $name already exists. Nothing was stopped.',
    'not-found' => 'Couldn\'t find this session\'s process. Nothing was stopped.',
    'not-claude' => 'The process on record isn\'t Claude any more. Nothing was stopped.',
    'still-running' => 'The agent didn\'t stop, so it was left running in its terminal tab.',
    'start-failed' => 'The agent stopped, but tmux didn\'t start. On the host, run: '
        'cd ${shQuote(cwd)} && claude --resume $sessionId',
    _ => 'The restart gave no result. Check the agent at the Mac before retrying.',
  });
}

/// Ends an agent for good. In tmux it closes [pane], or the whole session [name]
/// when the pane isn't known; a pane that's no longer in that session is left
/// alone. The process behind [sessionId] gets TERM, then KILL after [waitSeconds], but only when it runs in that tmux
/// session (with a [name] given): a gone session kills nothing.
/// Prints `pocketrig-kill-ok` or `pocketrig-kill-error <why>`.
///
/// A killed process may never fire SessionEnd, and the watcher keeps a waiting
/// agent forever, so the script sends that event itself.
///
/// shortcut: uses the default watcher port unless the SSH login sets
/// POCKETRIG_ANSWER_PORT; elsewhere the row stays until the watcher prunes it.
String killAgentScript({String? sessionId, String? name, String? pane, int? since, int waitSeconds = 5}) => '''
id=${shQuote(sessionId ?? '')}; name=${shQuote(name ?? '')}; pane=${shQuote(pane ?? '')}; since=${since ?? 0}
fail() { echo "pocketrig-kill-error \$1"; exit 0; }
found=; pid=; live=0
$_processChecks
$_findSessionProcess
[ -n "\$name" ] || [ -n "\$found" ] || fail not-found
[ "\$live" -le 1 ] || fail ambiguous
if [ -n "\$pid" ] && ! isclaude "\$pid"; then
  [ -n "\$name" ] || fail not-claude
  pid=
fi
# A row with no tmux session is a terminal tab: a process that runs in a tmux pane is some session's, not this row's.
if [ -z "\$name" ] && [ -n "\$pid" ] && command -v tmux >/dev/null 2>&1; then
  inpane "\$pid" "\$(tmux list-panes -a -F '#{pane_pid}' 2>/dev/null | tr '\\n' ' ')" && fail in-tmux
fi
start=; [ -z "\$pid" ] || start=\$(ps -o lstart= -p "\$pid" 2>/dev/null)
if [ -n "\$name" ]; then
  command -v tmux >/dev/null 2>&1 || fail no-tmux
  if tmux has-session -t "=\$name" 2>/dev/null; then
    if [ -n "\$pid" ]; then
      # Claude runs elsewhere (the conversation was resumed, or a name like 0 was reused): this session is not its row's.
      inpane "\$pid" "\$(tmux list-panes -s -t "=\$name" -F '#{pane_pid}' 2>/dev/null | tr '\\n' ' ')" || fail session-reused
    elif [ -z "\$pane" ] && [ "\$since" -gt 0 ] 2>/dev/null; then
      # Nothing of the agent is alive: a session made after the row was first seen is another one.
      sc=\$(tmux display-message -p -t "=\$name:" '#{session_created}' 2>/dev/null)
      [ -z "\$sc" ] || [ "\$sc" -le \$((since + 5)) ] 2>/dev/null || fail session-reused
    fi
    if [ -z "\$pane" ]; then
      tmux kill-session -t "=\$name" 2>/dev/null || fail kill-failed
    else
      tmux list-panes -s -t "=\$name" -F '#{pane_id}' 2>/dev/null | grep -Fxq "\$pane" || fail pane-moved
      tmux kill-pane -t "\$pane" 2>/dev/null || fail kill-failed
    fi
  else
    # Its session is gone: nothing of it is left to stop, and a process holding the id is some other session's.
    pid=
  fi
fi
same() { [ "\$(ps -o lstart= -p "\$pid" 2>/dev/null)" = "\$start" ]; }
if [ -n "\$pid" ] && same; then
  kill -TERM "\$pid" 2>/dev/null
  i=0
  while kill -0 "\$pid" 2>/dev/null && same; do
    [ "\$i" -eq ${waitSeconds * 2} ] && kill -KILL "\$pid" 2>/dev/null
    [ "\$i" -ge ${waitSeconds * 2 + 4} ] && fail still-running
    i=\$((i + 1))
    sleep 0.5
  done
fi
if [ -n "\$id" ]; then
  printf 'header = "Authorization: Bearer %s"\\n' "\$(cat "\$HOME/.config/pocketrig/answer-token" 2>/dev/null)" |
  curl -s -m 2 -K - -X POST "http://127.0.0.1:\${POCKETRIG_ANSWER_PORT:-7434}/hook" \\
    -H 'Content-Type: application/json' \\
    -d "{\\"session_id\\":\\"\$id\\",\\"hook_event_name\\":\\"SessionEnd\\"}" >/dev/null 2>&1
fi
echo pocketrig-kill-ok
''';

/// Clears [sessionId]'s record from the watcher and stops nothing: what a row whose tmux session is gone offers.
String forgetAgentScript(String sessionId) => '''
id=${shQuote(sessionId)}
printf 'header = "Authorization: Bearer %s"\\n' "\$(cat "\$HOME/.config/pocketrig/answer-token" 2>/dev/null)" |
curl -s -m 2 -K - -X POST "http://127.0.0.1:\${POCKETRIG_ANSWER_PORT:-7434}/hook" \\
  -H 'Content-Type: application/json' \\
  -d "{\\"session_id\\":\\"\$id\\",\\"hook_event_name\\":\\"SessionEnd\\"}" >/dev/null 2>&1
echo pocketrig-kill-ok
''';

/// Removes a row whose tmux session is gone from the list. Never kills: nothing of it runs, and a process that holds its id
/// is some other session's. A row only the daemon's scan knows has no record here to clear.
Future<void> forgetLooseAgent(Host host, LooseAgent a) async {
  final id = a.claudeSessionId;
  if (id == null) return;
  if (!RegExp(r'^[A-Za-z0-9_-]+\$').hasMatch(id)) throw OpenRigException('That doesn\'t look like a Claude session id.');
  final ssh = await SshExec.connect(host);
  try {
    await ssh.runLogin('sh -c ${shQuote(forgetAgentScript(id))}');
  } finally {
    ssh.close();
  }
}

/// Ends [a] over SSH. Throws with a sentence saying what happened.
Future<void> killAgent(Host host, LooseAgent a) async {
  final id = a.claudeSessionId;
  if (id != null && !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
    throw OpenRigException('That doesn\'t look like a Claude session id.');
  }
  final ssh = await SshExec.connect(host);
  final String out;
  try {
    out = await ssh.runLogin('sh -c ${shQuote(killAgentScript(sessionId: id, name: a.tmuxSession, pane: a.tmuxPane, since: a.since == null ? null : a.since!.millisecondsSinceEpoch ~/ 1000))}');
  } finally {
    ssh.close();
  }
  if (out.contains('pocketrig-kill-ok')) return;
  final why = RegExp(r'pocketrig-kill-error (\S+)').firstMatch(out)?.group(1);
  throw OpenRigException(switch (why) {
    'no-tmux' => 'Couldn\'t find tmux on this host. Nothing was killed.',
    'not-found' => 'Couldn\'t find this session\'s process. Nothing was killed. If it\'s still running, stop it at the Mac.',
    'not-claude' => 'The process on record isn\'t Claude any more. Nothing was killed.',
    'pane-moved' => 'Its tmux pane has changed. Nothing was killed. Rescan and try again.',
    'session-reused' => 'That tmux session isn\'t this agent\'s any more (its name was reused). Nothing was killed. Rescan and try again.',
    'ambiguous' => 'More than one running Claude has this conversation. Nothing was killed. Stop the right one at the Mac.',
    'in-tmux' => 'That Claude runs in a tmux session, not in a terminal tab. Nothing was killed. Rescan and try again.',
    'kill-failed' => 'tmux couldn\'t close it. Check the agent at the Mac.',
    'still-running' => 'The agent didn\'t stop, even after a force kill. Check it at the Mac.',
    _ => 'The kill gave no result. Check the agent at the Mac.',
  });
}

/// Ends a project shell's tmux session over SSH, and everything running in it. Throws with a sentence.
Future<void> closeShell(Host host, ProjectShell s) async {
  final ssh = await SshExec.connect(host);
  final String out;
  try {
    out = await ssh.runLogin('tmux kill-session -t ${shQuote('=${s.name}')} && echo pocketrig-closed');
  } finally {
    ssh.close();
  }
  if (!out.contains('pocketrig-closed')) throw OpenRigException('Couldn\'t close ${s.name}. It may already be gone.');
}

/// One string field of Claude Code's session file for [sessionId], or null
/// when there is no such file or field. Throws when the host can't be reached.
///
/// shortcut: reads Claude Code's internal `~/.claude/sessions/<pid>.json`;
/// a renamed field just reads as null.
Future<String?> looseSessionField(Host host, String sessionId, String key) async {
  final ssh = await SshExec.connect(host);
  try {
    final out = await ssh.run('sh -c ${shQuote('''
for f in "\$HOME"/.claude/sessions/*.json; do
  grep -Fq ${shQuote('"sessionId":"$sessionId"')} "\$f" 2>/dev/null && sed -n 's/.*"$key":"\\([A-Za-z0-9_]*\\)".*/\\1/p' "\$f"
done
''')}');
    final value = out.trim().split('\n').last.trim();
    return value.isEmpty ? null : value;
  } catch (_) {
    return null;
  } finally {
    ssh.close();
  }
}

/// Whether the session is `busy`, `idle`, …, from Claude Code's session file.
/// Null when unknown: that only makes the restart warning more careful.
Future<String?> looseSessionStatus(Host host, String sessionId) => looseSessionField(host, sessionId, 'status');

/// The claude.ai page that drives this session, once `/remote-control` was
/// run in it. Null when Remote Control is off.
Future<Uri?> remoteControlUrl(Host host, String sessionId) async {
  final id = await looseSessionField(host, sessionId, 'bridgeSessionId');
  return id == null ? null : Uri.https('claude.ai', '/code/$id');
}
