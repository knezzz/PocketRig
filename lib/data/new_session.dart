import 'dart:math';

import '../api/openrig_client.dart';
import '../models.dart';
import '../ssh/ssh_exec.dart';
import 'projects.dart';

/// What the app can start by hand on a host, outside any rig.
enum AgentRuntime {
  claude('claude-code', 'Claude Code', 'claude'),
  codex('codex', 'Codex', 'codex');

  const AgentRuntime(this.wire, this.label, this.binary);

  /// The daemon's runtime name (`runtimeHint`).
  final String wire;
  final String label;

  /// The command on the host.
  final String binary;

  /// Only Claude Code writes the session log the chat reads.
  bool get hasChat => this == AgentRuntime.claude;

  /// Where installers put it that a login shell over SSH may not have on PATH.
  List<String> get installFolders => switch (this) {
        AgentRuntime.claude => const [r'$HOME/.local/bin', r'$HOME/.claude/local', '/opt/homebrew/bin', '/usr/local/bin'],
        AgentRuntime.codex => const [r'$HOME/.local/bin', '/opt/homebrew/bin', '/usr/local/bin'],
      };
}

/// Claude Code's `--permission-mode` values, in the order the sheet shows them.
enum ClaudePermissionMode {
  ask('default', 'Ask'),
  acceptEdits('acceptEdits', 'Accept edits'),
  plan('plan', 'Plan'),
  bypass('bypassPermissions', 'Skip all');

  const ClaudePermissionMode(this.wire, this.label);
  final String wire;
  final String label;
}

/// A session to start: the runtime, where, and how.
class NewSessionSpec {
  NewSessionSpec({
    required this.runtime,
    required this.cwd,
    required this.name,
    String? sessionId,
    this.model,
    this.permissionMode = ClaudePermissionMode.ask,
    this.prompt,
  }) : sessionId = sessionId ?? newSessionId();

  final AgentRuntime runtime;

  /// The folder on the host, `~/…` allowed.
  final String cwd;

  /// The tmux session it runs in.
  final String name;

  /// Claude's session id, chosen here so the chat knows which log to follow
  /// before the file exists.
  final String sessionId;

  /// `--model`; null for the runtime's default.
  final String? model;
  final ClaudePermissionMode permissionMode;

  /// A first message, typed as the command's prompt argument.
  final String? prompt;

  /// The command line after the binary.
  List<String> get args => [
        if (runtime == AgentRuntime.claude) ...[
          '--session-id',
          sessionId,
          if (permissionMode != ClaudePermissionMode.ask) ...['--permission-mode', permissionMode.wire],
        ],
        if (model case final m? when m.trim().isNotEmpty) ...[runtime == AgentRuntime.claude ? '--model' : '-m', m.trim()],
        if (prompt case final p? when p.trim().isNotEmpty) p.trim(),
      ];

  /// The started session as the app lists it, until the scan and the hook
  /// report it themselves. [cwd] is the absolute folder the host reported.
  LooseAgent agent(String cwd, {DateTime? now}) => LooseAgent(
        id: name,
        claudeSessionId: runtime == AgentRuntime.claude ? sessionId : null,
        runtime: runtime.wire,
        cwd: cwd,
        tmuxSession: name,
        activeCommand: runtime.binary,
        activity: 'idle',
        since: now ?? DateTime.now(),
      );
}

/// A random UUID (version 4), the form Claude Code's `--session-id` takes.
String newSessionId([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// The tmux session a new agent gets: `claude-<folder>-<id start>`.
String newSessionName(AgentRuntime runtime, String cwd, String sessionId) {
  final folder = tmuxSafe(cwd.split('/').where((p) => p.isNotEmpty).lastOrNull ?? 'home');
  final tag = sessionId.length > 4 ? sessionId.substring(0, 4) : sessionId;
  return '${runtime.binary}-$folder-${tmuxSafe(tag)}';
}

/// Shell: sets `bin` to [runtime]'s absolute path, or fails `no-<binary>`.
/// Installers often add it to PATH in .zshrc, which a login shell over SSH
/// skips, so the usual install folders are tried too.
///
/// shortcut: only the usual install folders, widen this if an nvm-style
/// install reports no-claude.
String findBinaryScript(AgentRuntime runtime) {
  final b = runtime.binary;
  return '''
bin=\$(command -v $b)
case "\$bin" in
  /*) ;;
  *)
    bin=
    for c in ${runtime.installFolders.map((f) => '"$f/$b"').join(' ')}; do
      [ -x "\$c" ] && bin=\$c && break
    done
    [ -n "\$bin" ] || fail no-$b
    ;;
esac''';
}

/// Starts [spec] in a detached tmux session. Everything that can fail is
/// checked first, so nothing is left half started. Prints
/// `pocketrig-new-ok <absolute folder>` or `pocketrig-new-error <why>`.
///
/// The arguments are quoted for the shell tmux starts, so a prompt can hold
/// quotes, `$` or newlines.
String newSessionScript(NewSessionSpec spec, {int settleSeconds = 2}) => '''
name=${shQuote(spec.name)}
args=${shQuote(spec.args.map(shQuote).join(' '))}
fail() { echo "pocketrig-new-error \$1"; exit 0; }
command -v tmux >/dev/null 2>&1 || fail no-tmux
${findBinaryScript(spec.runtime)}
cd ${shellDir(spec.cwd)} 2>/dev/null || fail no-folder
dir=\$PWD
tmux has-session -t "=\$name" 2>/dev/null && fail name-taken
tmux new-session -d -s "\$name" -c "\$dir" "exec '\$bin' \$args" 2>/dev/null || fail start-failed
sleep $settleSeconds
tmux has-session -t "=\$name" 2>/dev/null || fail exited
echo "pocketrig-new-ok \$dir"
''';

/// Starts [spec] on [host] over SSH and returns the agent to open. Throws
/// with a sentence saying what happened.
Future<LooseAgent> startNewSession(Host host, NewSessionSpec spec) async {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(spec.name)) {
    throw OpenRigException('${spec.name} isn\'t a tmux session name: letters, digits, - and _ only.');
  }
  final ssh = await SshExec.connect(host);
  final String out;
  try {
    // `sh` because the login shell may be zsh, where an unmatched glob is an error.
    out = await ssh.runLogin('sh -c ${shQuote(newSessionScript(spec))}');
  } finally {
    ssh.close();
  }
  final ok = RegExp(r'pocketrig-new-ok (.*)').firstMatch(out);
  if (ok != null) {
    final dir = ok.group(1)!.trim();
    return spec.agent(dir.isEmpty ? spec.cwd : dir);
  }
  final why = RegExp(r'pocketrig-new-error (\S+)').firstMatch(out)?.group(1);
  final bin = spec.runtime.binary;
  throw OpenRigException(switch (why) {
    'no-tmux' => 'tmux isn\'t installed on ${host.name}. Nothing was started.',
    'no-claude' || 'no-codex' => 'Couldn\'t find $bin on ${host.name}. Nothing was started.',
    'no-folder' => 'The folder ${spec.cwd} doesn\'t exist on ${host.name}. Nothing was started.',
    'name-taken' => 'The tmux session ${spec.name} already exists. Pick another name.',
    'start-failed' => 'tmux couldn\'t start the session. On the host, run: cd ${shQuote(spec.cwd)} && $bin',
    'exited' => '$bin quit right after starting. Open a shell in ${spec.cwd} and run $bin there to see why.',
    _ => 'The start gave no result. Check ${host.name} before trying again.',
  });
}
