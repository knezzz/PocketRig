import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/agent_jobs.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/ui/status_shape.dart';
import 'package:pocket_rig/ui/theme.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/terminal/transport.dart';

void main() {
  // Real output from a Claude Code seat running a background gradle build.
  const out = 'J\t25458\tS+\t04:20:23\t0.0\t0\t/Users/me/.cargo/bin/some-mcp --stdio\n'
      'J\t69650\tSs\t1-02:05:23\t12.5\t3\t/bin/zsh -c source /Users/me/.claude/shell-snapshots/snapshot-zsh-1.sh '
      "2>/dev/null || true && eval 'cd android && ./gradlew assembleDebug > log 2>&1; echo '\\''done'\\''' "
      '< /dev/null && pwd -P >| /tmp/claude-3997-cwd\n'
      'O\t69650\t88\tb729a81 Android widget: total fetch failure\n';

  test('parses shells first, with their command, state and last output line', () {
    final jobs = AgentJob.parse(out);
    expect(jobs.map((j) => j.pid), [69650, 25458]);
    final shell = jobs.first;
    expect(shell.isShell, isTrue);
    expect(shell.command, "cd android && ./gradlew assembleDebug > log 2>&1; echo 'done'");
    expect(shell.elapsed, const Duration(days: 1, hours: 2, minutes: 5, seconds: 23));
    expect(shell.children, 3);
    expect(shell.state, 'running');
    expect(shell.outputBytes, 88);
    expect(shell.lastLine, 'b729a81 Android widget: total fetch failure');

    final mcp = jobs.last;
    expect(mcp.isShell, isFalse);
    expect(mcp.command, '/Users/me/.cargo/bin/some-mcp --stdio');
    expect(mcp.state, 'waiting');
    expect(mcp.lastLine, isNull);
  });

  test('reads the output tail when more lines were asked for', () {
    final job = AgentJob.parse('${out}L\t69650\tBUILD SUCCESSFUL\nL\t69650\tdone\n').first;
    expect(job.output, ['BUILD SUCCESSFUL', 'done']);
    expect(AgentJob.parse(out).first.output, isEmpty);
    expect(AgentJob.script('s', lines: 20), startsWith("set -- 's' 20; "));
  });

  test('stops a job and everything under it', () {
    expect(AgentJob.stopScript(42), startsWith('all=42; new=42; '));
    expect(AgentJob.stopScript(42), contains('kill -TERM \$all'));
    expect(AgentJob.stillRunning('left:\n'), 0);
    expect(AgentJob.stillRunning('left: 42 43\n'), 2);
    expect(AgentJob.stillRunning('pocketrig-stop-moved\n'), -1, reason: 'refused: nothing was stopped');
  });

  test('stops under sh, since a zsh login shell would not split the pid list', () async {
    String? sent;
    final ssh = SshExec.fake((cmd) async {
      sent = cmd;
      return 'left: 7\n';
    });
    expect(await ssh.stopJob(42), 1);
    expect(sent, contains('all=42; new=42;'), reason: 'through the login shell, for Homebrew\'s tmux');
    expect(sent, contains('sh -c '));
    expect(sent, startsWith('PATH='));
  });

  test('kills exactly one tmux session, with the = quoted for zsh', () async {
    String? sent;
    final ssh = SshExec.fake((cmd) async {
      sent = cmd;
      return 'gone\n';
    });
    expect(await ssh.killTmuxSession('lead@my-rig'), isTrue);
    expect(sent, contains("kill-session -t '\\''=lead@my-rig'\\''"));
  });

  test('an idle agent waiting on subagents is waiting, not idle; they do spend tokens', () {
    final seat = Seat(rigId: 'r', logicalId: 'lead');
    expect(seat.state, SeatState.idle);
    seat.waitingSubagents = 2;
    expect(seat.state, SeatState.shell);
    expect(seat.jobsLine, 'waiting on subagents');
    expect(AgentJob.waitingLine(const [], 1), 'waiting on a subagent');
    final shells = AgentJob.parse(out).where((j) => j.isShell).toList();
    expect(AgentJob.waitingLine(shells, 0), endsWith(' · no tokens'));
    expect(AgentJob.waitingLine(shells, 2), endsWith(' · waiting on subagents'));
    expect(Seat(rigId: 'r', logicalId: 'x', needsInput: true)..waitingSubagents = 1,
        predicate<Seat>((s) => s.state == SeatState.needsYou), reason: 'needing you comes first');
  });

  test('terminal scrolling drives tmux copy mode on the exact session, quoted for zsh', () {
    expect(tmuxScrollCommand('lead@app', 5),
        "tmux copy-mode -e -t '=lead@app:' && tmux send-keys -t '=lead@app:' -X -N 5 scroll-up 2>/dev/null; "
        "tmux display -p -t '=lead@app:' '#{pane_in_mode}'");
    expect(tmuxScrollCommand('lead@app', -3), startsWith("tmux send-keys -t '=lead@app:' -X -N 3 scroll-down"));
    expect(tmuxCancelCopyMode('lead@app'), "tmux send-keys -t '=lead@app:' -X cancel 2>/dev/null; true");
  });

  test('nothing running, or no such tmux session', () {
    expect(AgentJob.parse(''), isEmpty);
  });

  test('quotes the session name', () {
    expect(AgentJob.script("it's@rig"), startsWith("set -- 'it'\\''s@rig' 1; "));
  });

  test('splits the all-sessions scan by tmux session', () {
    final all = AgentJob.parseAll('@@jobs\tdev@conveyor\n$out@@jobs\tqa@conveyor\n');
    expect(all.keys, ['dev@conveyor', 'qa@conveyor']);
    expect(all['dev@conveyor']!.length, 2);
    expect(all['qa@conveyor'], isEmpty);
  });

  // Shapes seen on a real host (Claude Code 2.1): a monitor (output to a socket, so no O
  // line), two Bash tasks writing to task files, and an unquoted single-word command.
  const snap = '/bin/zsh -c source /Users/me/.claude-work/shell-snapshots/s.sh 2>/dev/null || true && '
      "{ \\builtin unalias -- 'which'; } >/dev/null 2>&1 || true && eval ";
  const live = 'J\t30947\tSs\t05:50\t0.0\t1\t$snap\'until ! pgrep -f "flutter test"; do sleep 10; done\' < /dev/null && pwd -P >| /tmp/c\n'
      'J\t43640\tSs\t00:38\t3.0\t2\t$snap\'python3 - <<\'"\'"\'EOF\'"\'"\'\\012print(1)\\012EOF\' < /dev/null && pwd -P >| /tmp/c\n'
      'O\t43640\t0\t\n'
      'J\t7129\tSs\t17:22\t0.0\t1\t$snap/tmp/s/run-android.sh < /dev/null && pwd -P >| /tmp/c\n'
      'O\t7129\t512\tInstalling build/app.apk\n'
      'J\t15615\tS+\t01:13:31\t0.0\t0\t/Applications/Crawwwlers.app/Contents/MacOS/crawwwlers mcp\n';

  test('reads monitors and unquoted or zsh-quoted commands', () {
    final jobs = {for (final j in AgentJob.parse(live)) j.pid: j};
    expect(jobs[30947]!.isMonitor, isTrue);
    expect(jobs[30947]!.short, 'until ! pgrep -f "flutter test"; do sleep 10; done');
    expect(jobs[43640]!.isMonitor, isFalse);
    expect(jobs[43640]!.short, "python3 - <<'EOF'");
    expect(jobs[7129]!.isShell, isTrue);
    expect(jobs[7129]!.short, '/tmp/s/run-android.sh');
    expect(jobs[15615]!.isShell, isFalse);
    expect(AgentJob.parse("J\t1\tS\t00:01\t0\t0\t$snap'cd /a/b && flutter test' < /dev/null\n").single.short, 'flutter test');
    expect(AgentJob.parse("J\t1\tS\t00:01\t0\t0\t$snap'S=/tmp/x; cd /a && ./run.sh' < /dev/null\n").single.short, './run.sh');
  });

  test('only an agent idle at its prompt is on its shells; a working one is working', () {
    final jobs = AgentJob.parse(live);
    expect(AgentJob.waitingOn(jobs, working: true), isEmpty, reason: 'even with a command running for it');
    final idle = AgentJob.waitingOn(jobs, working: false);
    expect(AgentJob.describe(idle), '2 shells · 1 monitor');
    expect(AgentJob.counts(idle), ['2 shells', '1 monitor']);
    expect(AgentJob.describe([jobs.firstWhere((j) => j.pid == 30947)]),
        'monitor: until ! pgrep -f "flutter test"; do sleep 10; done');

    final seat = Seat(rigId: 'r', logicalId: 'qa')..jobs = idle;
    expect(seat.state, SeatState.shell);
    expect(seat.jobsLine, '2 shells · 1 monitor · no tokens');
    expect((Seat(rigId: 'r', logicalId: 'qa', needsInput: true)..jobs = idle).state, SeatState.needsYou);
    expect(Seat(rigId: 'r', logicalId: 'qa', activity: 'working').state, SeatState.working);
    expect((Seat(rigId: 'r', logicalId: 'qa', activity: 'working')..jobs = idle).state, SeatState.working,
        reason: 'blue (on shell) only while the agent itself is idle');

    // On a shell: the terminal turns blue, and the rig's active view lists it (an agent waiting on a shell is never folded away).
    const k = Tokens.dark;
    expect(Status.shell.edge(k), k.shell);
    expect(Status.shell.termBg(k), isNot(k.termBg));
    final f = Fleet();
    final quiet = Seat(rigId: 'r', logicalId: 'idle');
    expect(f.rigSeatsShown('r', [seat, quiet]), [seat], reason: 'on a shell: listed; idle: not');
    final working = Seat(rigId: 'r', logicalId: 'w', activity: 'working');
    expect(f.rigSeatsShown('r', [seat, quiet, working]), [seat, working]);
  });
}
