import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../api/openrig_client.dart';
import '../data/agent_jobs.dart';
import '../data/git_status.dart';
import '../data/projects.dart';
import '../data/rig_spec.dart';
import '../data/subagents.dart';
import '../models.dart';
import 'host_keys.dart';
import 'ssh_log.dart';

/// Opens an authenticated SSH connection to [host] over Tailscale.
///
/// The host key is pinned on first use and checked on every connect after
/// that ([HostKeyChangedException] when it differs). [onHostKey] sees the
/// key either way, so the host editor can show it. With [pin] off nothing
/// is saved (the editor's connection test).
Future<SSHClient> sshConnect(Host host, {bool pin = true, void Function(String type, String fingerprint)? onHostKey}) =>
    SshLog.instance.track(host, 'connect ${host.sshUser}@${host.address}:${host.sshPort}',
        () => _sshConnect(host, pin: pin, onHostKey: onHostKey));

Future<SSHClient> _sshConnect(Host host,
    {bool pin = true, void Function(String type, String fingerprint)? onHostKey}) async {
  final pem = host.privateKeyPem;
  if (pem == null) {
    throw OpenRigException('No SSH key saved for ${host.name}. Add one in Hosts.');
  }
  final socket = await sshSocket(host);
  String? seenType, seen;
  final client = SSHClient(
    socket,
    username: host.sshUser,
    identities: SSHKeyPair.fromPem(pem, host.keyPassphrase),
    onVerifyHostKey: (type, fingerprint) {
      seenType = type;
      seen = utf8.decode(fingerprint, allowMalformed: true);
      onHostKey?.call(type, seen!);
      return checkHostKey(host.hostKeyFingerprint, seen!) != HostKeyCheck.changed;
    },
  );
  try {
    await client.authenticated;
  } catch (e) {
    client.close();
    if (seen != null && checkHostKey(host.hostKeyFingerprint, seen!) == HostKeyCheck.changed) {
      throw HostKeyChangedException(host, seenType ?? '?', seen!);
    }
    rethrow;
  }
  if (pin && host.hostKeyFingerprint == null && seen != null) {
    host
      ..hostKeyFingerprint = seen
      ..hostKeyType = seenType;
    await persistHostKeys?.call();
  }
  return client;
}

/// Connects to the host's SSH port: [Host.address] (Tailscale) first, then
/// [Host.lanAddress] when that doesn't answer. The address that answered is
/// tried first for a minute, so a stalled tailnet costs one wait, not one per
/// connection.
@visibleForTesting
Future<SSHSocket> Function(String address, int port, Duration timeout) socketConnect =
    (address, port, timeout) => SSHSocket.connect(address, port, timeout: timeout);

final _lanSince = <String, DateTime>{};

/// True while [host]'s SSH goes over its local network address.
bool sshOverLan(Host host) => _lanSince.containsKey(host.id);

Future<SSHSocket> sshSocket(Host host) async {
  final lan = host.lanAddress?.trim();
  if (lan == null || lan.isEmpty || lan == host.address) {
    _lanSince.remove(host.id);
    return socketConnect(host.address, host.sshPort, const Duration(seconds: 8));
  }
  final since = _lanSince[host.id];
  final lanFirst = since != null && DateTime.now().difference(since) < const Duration(minutes: 1);
  final order = lanFirst ? [lan, host.address] : [host.address, lan];
  Object? first;
  for (final a in order) {
    try {
      final s = await socketConnect(a, host.sshPort, const Duration(seconds: 5));
      if (a == lan) {
        // Keep the original time while it's still LAN, so the tailnet is retried each minute.
        _lanSince[host.id] = (lanFirst ? since : null) ?? DateTime.now();
      } else {
        _lanSince.remove(host.id);
      }
      return s;
    } catch (e) {
      first ??= e;
    }
  }
  throw first!;
}

class _Pooled {
  _Pooled(this.key, this.connecting);
  final String key;
  final Future<SSHClient> connecting;
  SSHClient? client;
  int leases = 0;
  bool dead = false;
  Timer? idle;
  DateTime lastUsed = DateTime.now();
  Future<bool>? check;
}

/// One shared [SSHClient] per host for the main isolate, so opening a chat, a
/// file or a git status doesn't pay a TCP, key-exchange and auth handshake each
/// time. [lease] hands out the connection, [release] returns it; it closes
/// [idleAfter] after the last lease. A closed or failed connection is dropped,
/// so the next lease connects again.
///
/// shortcut: past [maxLeases] at once on a connection (sshd's MaxSessions is 10
/// by default) it opens another connection instead of making callers wait.
/// Upgrade to a waiting queue if hosts see too many parallel connections.
class SshPool {
  SshPool(this._connect,
      {this.idleAfter = const Duration(minutes: 2), this.maxLeases = 8, this.staleAfter = const Duration(seconds: 15), this.busyPing = const Duration(seconds: 15)});

  final Future<SSHClient> Function(Host host) _connect;
  final Duration staleAfter;

  /// How long [failed] waits for a ping: a transfer past the watchdog queues the ping behind its own data.
  final Duration busyPing;
  final Duration idleAfter;
  final int maxLeases;
  final _all = <_Pooled>[];

  /// A key that changes when the host's address, user or key does.
  static String keyOf(Host h) => '${h.id}|${h.address}|${h.sshPort}|${h.sshUser}|${h.privateKeyPem.hashCode}';

  Future<SSHClient> lease(Host host, {int retries = 1}) async {
    final key = keyOf(host);
    var e = _all.where((p) => p.key == key && !p.dead && p.leases < maxLeases).firstOrNull;
    if (e == null) {
      final p = e = _Pooled(key, _connect(host));
      _all.add(p);
      p.connecting.then((c) {
        p.client = c;
      }, onError: (Object _) {
        p.dead = true;
        _all.remove(p);
      });
    }
    // Time since anyone last leased or released it, even if a lease is still held (the daemon tunnel holds one).
    final stale = DateTime.now().difference(e.lastUsed) > staleAfter;
    e.lastUsed = DateTime.now();
    e.leases++;
    e.idle?.cancel();
    e.idle = null;
    try {
      final c = await e.connecting;
      // A dead TCP link (network change, NAT timeout) isn't `isClosed` and
      // keepalives never time out, so an idle client is pinged before reuse.
      if (!c.isClosed) {
        // Concurrent leases wait for the one check instead of skipping it.
        if (stale) {
          final p = e;
          p.check ??= _alive(c).whenComplete(() => p.check = null);
        }
        final check = e.check;
        if (check == null || await check) return c;
      }
    } catch (_) {
      e.leases--;
      rethrow;
    }
    // The server dropped it while idle: forget it and connect again.
    e.leases--;
    _drop(e);
    if (retries == 0) throw StateError('SSH connection closed while connecting');
    return lease(host, retries: retries - 1);
  }

  void release(SSHClient client) {
    final e = _all.where((p) => p.client == client).firstOrNull;
    if (e == null) {
      client.close();
      return;
    }
    if (e.leases > 0) e.leases--;
    e.lastUsed = DateTime.now();
    if (client.isClosed) {
      _drop(e);
    } else if (e.leases == 0) {
      e.idle = Timer(idleAfter, () => _drop(e));
    }
  }

  static Future<bool> _alive(SSHClient c, [Duration wait = const Duration(seconds: 3)]) async {
    try {
      await c.ping().timeout(wait);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Checks every pooled client (the app came back to the foreground).
  void checkAll() {
    for (final e in _all.toList()) {
      if (e.client case final c?) unawaited(failed(c));
    }
  }

  /// Closes connections nobody is using (the app went to the background).
  void closeIdle() {
    for (final e in _all.where((p) => p.leases == 0).toList()) {
      _drop(e);
    }
  }

  /// A call on [client] threw: if it no longer answers, drop it so the next lease reconnects.
  /// True when it was dropped.
  Future<bool> failed(SSHClient client) async {
    final e = _all.where((p) => p.client == client).firstOrNull;
    if (e == null || await _alive(client, busyPing)) return false;
    _drop(e);
    return true;
  }

  void _drop(_Pooled e) {
    e.dead = true;
    e.idle?.cancel();
    _all.remove(e);
    e.client?.close();
  }

  /// Connections open now (tests).
  @visibleForTesting
  int get open => _all.length;
}

/// The app's pool: everything on the main isolate shares it.
final sshPool = SshPool(sshConnect);

/// Runs [command] the way sshd would: `$SHELL -c`, stderr dropped.
Future<String> runLocal(String command, {void Function(String soFar)? onOutput}) async {
  final p = await Process.start(Platform.environment['SHELL'] ?? '/bin/zsh', ['-c', command]);
  unawaited(p.stderr.drain<void>());
  final all = StringBuffer();
  await for (final chunk in p.stdout.transform(const Utf8Decoder(allowMalformed: true))) {
    all.write(chunk);
    onOutput?.call(all.toString());
  }
  await p.exitCode;
  return all.toString();
}

/// One SSH connection for a batch of short, non-interactive commands.
/// What a path is on a host, see [SshExec.folderCheck].
enum FolderState { folder, file, missing }

class SshExec {
  SshExec._(this._client, this._host) : _fake = null;

  /// Runs over [client] (tests).
  @visibleForTesting
  SshExec.over(SSHClient client, Host host)
      : _client = client,
        _host = host,
        _fake = null;

  /// The pool this connection came from, and how long a call may run before the link is checked.
  @visibleForTesting
  static SshPool pool = sshPool;
  @visibleForTesting
  static Duration watchdog = const Duration(seconds: 20);

  /// This machine: commands run in a local shell, files are read directly.
  SshExec._local(Host host)
      : _client = null,
        _host = host,
        _fake = null;

  bool get _local => _client == null && _fake == null;

  /// A host that answers commands with [run] (tests and goldens).
  @visibleForTesting
  SshExec.fake(Future<String> Function(String command) run, {bool neverOpens = false})
      : _client = null,
        _host = null,
        _fake = run,
        _fakeNeverOpens = neverOpens;

  final SSHClient? _client;
  final Host? _host;
  final Future<String> Function(String command)? _fake;

  /// A fake whose command fails before its channel opens: [run]'s error is then not reported through `onStarted`.
  bool _fakeNeverOpens = false;

  /// Tests replace this to talk to a fake host instead of opening SSH.
  @visibleForTesting
  static Future<SshExec> Function(Host host)? debugConnect;

  static Future<SshExec> connect(Host host) async => debugConnect != null
      ? debugConnect!(host)
      : host.isLocal
          ? SshExec._local(host)
          : SshExec._(await pool.lease(host), host);

  /// Connects, runs [body], and closes the connection however it ends; a failed connect throws from here too.
  static Future<T> use<T>(Host host, Future<T> Function(SshExec ssh) body) async {
    final ssh = await connect(host);
    try {
      return await body(ssh);
    } finally {
      ssh.close();
    }
  }

  /// [onOutput] gets all of stdout so far, each time more arrives.
  ///
  /// [onStarted] is called once the command has been handed to the host (the exec channel is open): an error after that may
  /// have happened with the command already running, one before it certainly did not.
  Future<String> run(String command, {void Function(String soFar)? onOutput, void Function()? onStarted}) async {
    if (_fake != null) {
      if (!_fakeNeverOpens) onStarted?.call();
      final out = await _fake(command);
      onOutput?.call(out);
      return out;
    }
    return SshLog.instance.track(_host!, command, () async {
      return _watched(() => _run(command, onOutput, onStarted));
    }, show: (s) => s);
  }

  /// Runs [f] on this connection. A silently dead link makes a call hang rather
  /// than throw: still running after [watchdog], the link is checked, and a dead
  /// one is dropped and the call fails. Holds for exec and SFTP alike, leased or not.
  Future<T> _watched<T>(Future<T> Function() f) async {
    final c = _client;
    if (c == null) return f();
    final dead = Completer<T>();
    final watch = Timer(watchdog, () async {
      if (await pool.failed(c) && !dead.isCompleted) dead.completeError(_lost());
    });
    try {
      final r = await Future.any([f(), dead.future]);
      // dartssh2 ends a call on a closed client with its partial output, not an error.
      if (c.isClosed) throw _lost();
      return r;
    } catch (_) {
      unawaited(pool.failed(c));
      rethrow;
    } finally {
      watch.cancel();
    }
  }

  OpenRigException _lost() => OpenRigException('Lost the SSH connection to ${_host?.name ?? 'the host'}.');

  Future<String> _run(String command, void Function(String soFar)? onOutput, void Function()? onStarted) async {
    if (_local) {
      onStarted?.call();
      return runLocal(command, onOutput: onOutput);
    }
    if (onOutput != null || onStarted != null) {
      final session = await _client!.execute(command);
      onStarted?.call();
      unawaited(session.stderr.drain<void>());
      final all = StringBuffer();
      await for (final chunk in session.stdout.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true))) {
        all.write(chunk);
        onOutput?.call(all.toString());
      }
      return all.toString();
    }
    final out = await _client!.run(command, stderr: false);
    return utf8.decode(out, allowMalformed: true);
  }

  /// Runs [command] in the user's login shell, for PATH from the login files
  /// (Homebrew's git, gh and tmux on macOS). It isn't interactive, so anything
  /// added to PATH only in .zshrc is missing, so Homebrew's folders are
  /// appended as a fallback: path_helper keeps inherited entries, and Apple
  /// Silicon Homebrew often sets PATH only in .zshrc.
  Future<String> runLogin(String command, {void Function(String soFar)? onOutput, void Function()? onStarted}) => run(
      'PATH="\$PATH:/opt/homebrew/bin:/usr/local/bin" exec "\${SHELL:-/bin/sh}" -lc ${shQuote(command)}',
      onOutput: onOutput,
      onStarted: onStarted);

  /// Copies [bytes] into the host's upload folder as [name] over SFTP and
  /// returns its full path there, for the agent to read.
  Future<String> upload(String name, Uint8List bytes) async {
    const dir = r'"$HOME"/.cache/pocketrig/uploads';
    final abs = (await run('mkdir -p $dir && cd $dir && pwd')).trim();
    if (!abs.startsWith('/')) throw OpenRigException('Couldn\'t make the upload folder on ${_host?.name ?? 'the host'}.');
    final path = '$abs/$name';
    if (_fake != null) {
      await _fake('upload $path ${bytes.length}');
      return path;
    }
    if (_local) {
      await File(path).writeAsBytes(bytes);
      return path;
    }
    await _watched(() async {
    final sftp = await _client!.sftp();
    try {
      final f = await sftp.open(path,
          mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate);
      try {
        await f.writeBytes(bytes);
      } finally {
        await f.close();
      }
    } finally {
      sftp.close();
    }
    });
    return path;
  }

  /// Branch, changes and PR for [folder] in one round trip.
  Future<GitStatus> gitStatus(String folder) async => GitStatus.parse(await runLogin(GitStatus.script(shellDir(folder))));

  /// Processes the agents in tmux [session] started: shells, servers, MCP.
  Future<List<AgentJob>> agentJobs(String session, {int lines = 1}) async =>
      AgentJob.parse(await runLogin(AgentJob.script(session, lines: lines)));

  /// Ends tmux session [name] and everything in it. True when it's gone.
  Future<bool> killTmuxSession(String name) async {
    // `=` asks tmux for this exact name; quoted with it, since zsh expands a bare `=word`.
    final q = shQuote('=$name');
    final out = await runLogin('tmux kill-session -t $q 2>/dev/null; tmux has-session -t $q 2>/dev/null && echo alive || echo gone');
    return out.contains('gone');
  }

  /// Stops an agent's job and everything it started; how many processes are
  /// still running 5 s later.
  /// Under `sh`: the login shell may be zsh, which doesn't split `$all` into pids.
  Future<int> stopJob(int pid) async =>
      AgentJob.stillRunning(await run('sh -c ${shQuote(AgentJob.stopScript(pid))}'));

  /// Every running Claude Code subagent on the host.
  Future<List<Subagent>> subagents() async => Subagent.parse(await run('sh -c ${shQuote(Subagent.script())}'));

  /// RigSpec files under [projectPath]: YAML files with top-level `name:` and
  /// `pods:`. Skips dependency and build folders; capped so a huge tree
  /// can't hang the screen.
  ///
  /// Throws when it couldn't look: the folder can't be opened, or macOS kept
  /// SSH out of it (Documents, Desktop and Downloads need Full Disk Access
  /// for remote users) and nothing was found.
  Future<List<RigSpecFile>> findRigSpecs(String projectPath) async {
    final dir = shellDir(projectPath);
    final out = await run(findSpecsCommand(dir));
    final root = (await run('cd $dir 2>/dev/null && pwd')).trim();
    final lines = const LineSplitter().convert(out).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final specs = [
      for (final line in lines)
        if (!line.startsWith('pocketrig-')) RigSpecFile(path: line, projectPath: root.isEmpty ? projectPath : root),
    ]..sort((a, b) => a.relativePath.compareTo(b.relativePath));
    final shown = displayPath(projectPath);
    if (lines.contains('pocketrig-no-folder')) {
      throw OpenRigException('Couldn\'t open $shown on ${_host?.name ?? 'the host'}. It doesn\'t exist there, '
          'or macOS keeps SSH out of it. On the host: $_fullDiskAccess');
    }
    final denied =
        int.tryParse(lines.firstWhere((l) => l.startsWith('pocketrig-denied '), orElse: () => '').split(' ').last) ?? 0;
    if (specs.isEmpty && denied > 0) {
      throw OpenRigException(
          'macOS didn\'t let SSH read $denied folder${denied == 1 ? '' : 's'} in $shown, so rig specs '
          'there can\'t be found. On the host: $_fullDiskAccess');
    }
    return specs;
  }

  static const _fullDiskAccess =
      'System Settings → General → Sharing → Remote Login (i) → turn on "Allow full disk access for remote users".';

  /// The search, run from [dir]: specs, then `pocketrig-denied <n>` for the
  /// folders find wasn't allowed into, or `pocketrig-no-folder`.
  @visibleForTesting
  static String findSpecsCommand(String dir) => 'cd $dir 2>/dev/null || { echo pocketrig-no-folder; exit 0; }; '
      'PR_ERR="\${TMPDIR:-/tmp}/pocketrig-find-\$\$"; export PR_ERR; : > "\$PR_ERR"; $findSpecsScript; '
      'echo "pocketrig-denied \$(grep -c -E \'not permitted|Permission denied\' "\$PR_ERR")"; rm -f "\$PR_ERR"';

  /// Every YAML up to 5 folders deep that has top-level `name:` and `pods:`.
  /// Contents are checked before the cap: a project with hundreds of other
  /// YAML files (Maestro flows, CI, i18n) must not crowd out its rig specs.
  /// `grep -l` over batches keeps it to a few processes, not two per file.
  /// find's errors go to `$PR_ERR` when set, so blocked folders can be told
  /// apart from folders without specs.
  @visibleForTesting
  static const findSpecsScript =
      r'''find "$PWD" -maxdepth 5 \( -name node_modules -o -name .git -o -name build -o -name dist -o -name .dart_tool -o -name Pods -o -name .gradle -o -name .symlinks \) -prune -o -type f \( -name '*.yaml' -o -name '*.yml' \) -size -256k -exec grep -lE '^pods:' {} + 2>>"${PR_ERR:-/dev/null}" | while IFS= read -r f; do grep -qE '^name:' "$f" && printf '%s\n' "$f"; done | head -n 200''';

  /// The checked-out branch of [folder], or null outside a git checkout.
  Future<String?> branch(String folder) async {
    final b = (await run('cd ${shellDir(folder)} 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null')).trim();
    return b.isEmpty ? null : b;
  }

  /// [folder]'s git worktrees with what's not pushed, main checkout first;
  /// empty outside a git checkout.
  Future<List<Worktree>> worktrees(String folder) async => Worktree.parse(await run(Worktree.script(shellDir(folder))));

  /// The repo's local branch names (what `git worktree add -b` would collide with).
  Future<Set<String>> localBranches(String repo) async => {
        for (final l in (await run('cd ${shellDir(repo)} 2>/dev/null && git for-each-ref --format="%(refname:short)" refs/heads 2>/dev/null')).split('\n'))
          if (l.trim().isNotEmpty) l.trim()
      };

  /// The names already under `<repo>/.claude/worktrees` (git worktrees or stray folders): a new one may not reuse them.
  Future<Set<String>> worktreeFolders(String repo) async => {
        for (final l in (await run('cd ${shellDir(repo)} 2>/dev/null && ls -1 .claude/worktrees 2>/dev/null')).split('\n'))
          if (l.trim().isNotEmpty) l.trim()
      };

  /// A new worktree at `<repo>/.claude/worktrees/<name>` on a new branch [name]
  /// from the main checkout's HEAD. Returns its path; throws with git's message.
  Future<String> addWorktree(String repo, String name) async {
    final path = '$repo/.claude/worktrees/${name.replaceAll('/', '-')}';
    await _git(repo, 'worktree add -b ${shQuote(name)} ${shQuote(path)}');
    // Locally ignored (never committed), or the main checkout shows the folder as a change.
    await run('cd ${shellDir(repo)} && x="\$(git rev-parse --git-common-dir)/info/exclude" && mkdir -p "\${x%/*}" && '
        '{ grep -qxF /.claude/worktrees/ "\$x" 2>/dev/null || echo /.claude/worktrees/ >> "\$x"; }');
    return path;
  }

  /// Removes a worktree; git refuses when it has uncommitted changes unless [force]. The branch stays. [path] is quoted for
  /// the shell, and `--` ends git's options, so a name with spaces, quotes or a leading dash is one argument.
  Future<void> removeWorktree(String repo, String path, {bool force = false}) =>
      _git(repo, 'worktree remove ${force ? '--force ' : ''}-- ${shQuote(path)}');

  /// The uncommitted and untracked files of the worktree at [path] (`git status --porcelain`, minus the status codes). A
  /// folder with only untracked files shows as the folder.
  Future<List<String>> worktreeChanges(String path) async {
    final out = await run('cd ${shellDir(path)} 2>/dev/null && git status --porcelain 2>/dev/null');
    return [for (final l in out.split('\n')) if (l.length > 3) l.substring(3)];
  }

  /// run() doesn't check exit codes, so a marker tells success from git's error text.
  Future<void> _git(String repo, String args) async {
    const ok = '@@pocketrig-git-ok';
    final out = await run('cd ${shellDir(repo)} && git $args 2>&1 && echo $ok');
    if (!out.contains(ok)) throw OpenRigException(out.trim().split('\n').last);
  }

  /// [folder]'s GitHub repo URL and its latest pull requests, from `gh`
  /// (login shell, for Homebrew's PATH). Null when gh can't tell.
  Future<(String, List<PullRequest>)?> github(String folder) async {
    const mark = '@@pocketrig-prs';
    final out = await runLogin('cd ${shellDir(folder)} 2>/dev/null && command -v gh >/dev/null && '
        'gh repo view --json url -q .url 2>/dev/null && echo $mark && '
        'gh pr list --state all --limit 5 --json ${PullRequest.fields} 2>/dev/null; true');
    final at = out.indexOf(mark);
    if (at < 0) return null;
    return (out.substring(0, at).trim(), PullRequest.parseList(out.substring(at + mark.length)));
  }

  /// One pull request by its URL, from `gh` (login shell, for Homebrew's PATH). Null when gh can't tell.
  Future<PullRequest?> pullRequest(Uri url) async =>
      PullRequest.parse(await runLogin('command -v gh >/dev/null && '
          'gh pr view ${shQuote(url.toString())} --json ${PullRequest.fields} 2>/dev/null; true'));

  /// A text file, at most 256 KB.
  Future<String> readFile(String path) async {
    // stderr is dropped, so a failed read would look like an empty file. On
    // failure, read again for head's own reason ("No such file or directory",
    // "Operation not permitted").
    final out = await run('head -c 262144 -- QQ || { printf pocketrig-unreadable:; head -c 1 -- QQ 2>&1 >/dev/null; }'
        .replaceAll('QQ', shQuote(path)));
    if (out.startsWith('pocketrig-unreadable:')) {
      final why = out.substring('pocketrig-unreadable:'.length).split(':').last.trim();
      throw OpenRigException('Couldn\'t read $path on ${_host?.name ?? 'the host'}: '
          '${why.isEmpty ? 'unknown error' : why}.'
          '${why.contains('not permitted') ? ' macOS keeps SSH out of its folder. On the host: $_fullDiskAccess, '
              'then turn Remote Login off and on.' : ''}');
    }
    return out;
  }

  /// Which of [paths] (absolute or `~/`) this login can read as files:
  /// reading a byte also catches folders and macOS keeping SSH out.
  Future<Set<String>> readable(List<String> paths) async {
    if (paths.isEmpty) return {};
    final out = _fake != null
        ? await _fake('readable ${paths.join('\n')}')
        : await run([
            for (final (i, p) in paths.indexed) 'head -c 1 -- ${shellDir(p)} >/dev/null 2>&1 && echo $i;',
            'true',
          ].join(' '));
    return {
      for (final l in const LineSplitter().convert(out))
        if (int.tryParse(l.trim()) case final i? when i >= 0 && i < paths.length) paths[i],
    };
  }

  /// A file's bytes over SFTP (images and videos the agent made), at most
  /// [maxBytes].
  Future<Uint8List> download(String path, {int maxBytes = 100 << 20}) async {
    if (_fake != null) return base64Decode((await _fake('download $path')).trim());
    final shown = _host?.name ?? 'the host';
    if (_local) {
      final f = File(path);
      final size = await f.length();
      if (size > maxBytes) throw OpenRigException('$path is ${size >> 20} MB, too big to open.');
      return f.readAsBytes();
    }
    return _watched(() async {
    final sftp = await _client!.sftp();
    try {
      final f = await sftp.open(path);
      try {
        final size = (await f.stat()).size ?? 0;
        if (size > maxBytes) {
          throw OpenRigException('$path is ${size >> 20} MB, too big to open on the phone.');
        }
        return await f.readBytes();
      } finally {
        await f.close();
      }
    } on SftpStatusError catch (e) {
      final denied = e.code == SftpStatusCode.permissionDenied;
      throw OpenRigException('Couldn\'t read $path on $shown: ${e.message}.'
          '${denied ? ' macOS may keep SSH out of its folder. On the host: $_fullDiskAccess' : ''}');
    } finally {
      sftp.close();
    }
    });
  }

  /// Replaces [path] with [text] (a saved rig spec).
  Future<void> writeFile(String path, String text) => run('printf \'%s\' ${shQuote(text)} > ${shQuote(path)}');

  /// The absolute form of a folder path (expands `~/`).
  /// What [path] is on the host (`~` allowed): a folder (with its absolute path), a file, or nothing: one shell check.
  Future<(FolderState, String?)> folderCheck(String path) async {
    final d = shellDir(path);
    final out = (await run('if [ -d $d ]; then cd $d && pwd; elif [ -e $d ]; then echo @@pocketrig-file; '
            'else echo @@pocketrig-nodir; fi'))
        .trim();
    if (out.contains('@@pocketrig-file')) return (FolderState.file, null);
    if (out.isEmpty || out.contains('@@pocketrig-nodir')) return (FolderState.missing, null);
    return (FolderState.folder, out.split('\n').last.trim());
  }

  /// The folders inside [path] (`~` allowed), one call: its absolute path, then each folder with whether it is a git
  /// checkout. Hidden folders are left out. [FolderListing.state] says when [path] is missing, a file or unreadable.
  Future<FolderListing> listFolders(String path) async {
    final d = shellDir(path);
    final out = await run('d=$d; if [ -d "\$d" ]; then if cd "\$d" 2>/dev/null; then echo @@pocketrig-folders; pwd; '
        'for f in */; do [ -d "\$f" ] || continue; n=\${f%/}; if [ -e "\$f.git" ]; then echo "g \$n"; else echo "- \$n"; fi; done | head -n 500; '
        'else echo @@pocketrig-unreadable; fi; elif [ -e "\$d" ]; then echo @@pocketrig-file; else echo @@pocketrig-nodir; fi');
    return parseFolderListing(out);
  }

  Future<String> resolve(String path) async => (await run('cd ${shellDir(path)} && pwd')).trim();

  bool _released = false;

  /// Hands the connection back to the pool; it closes after it has been idle a while.
  void close() {
    if (_released) return;
    _released = true;
    if (_client case final c?) pool.release(c);
  }
}

/// How a folder listing ended: its folders, or why not.
enum ListingState { ok, missing, file, unreadable }

/// What [SshExec.listFolders] read: [path] (absolute) and its [folders] (name, is a git checkout).
class FolderListing {
  const FolderListing(this.state, {this.path, this.folders = const []});
  final ListingState state;
  final String? path;
  final List<(String, bool)> folders;
}

FolderListing parseFolderListing(String out) {
  if (out.contains('@@pocketrig-file')) return const FolderListing(ListingState.file);
  if (out.contains('@@pocketrig-nodir')) return const FolderListing(ListingState.missing);
  if (out.contains('@@pocketrig-unreadable')) return const FolderListing(ListingState.unreadable);
  final lines = out.split('\n').map((l) => l.trimRight()).where((l) => l.isNotEmpty).toList();
  final at = lines.indexOf('@@pocketrig-folders');
  if (at < 0 || at + 1 >= lines.length) return const FolderListing(ListingState.missing);
  return FolderListing(ListingState.ok, path: lines[at + 1], folders: [
    for (final l in lines.skip(at + 2))
      if (l.length > 2) (l.substring(2), l.startsWith('g ')),
  ]);
}
