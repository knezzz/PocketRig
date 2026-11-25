import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart' show rootBundle;

import '../api/openrig_client.dart';
import '../models.dart';
import '../ssh/ssh_exec.dart';
import 'projects.dart';

/// What the app installs on a host, bundled from `host/watcher/`.
const watcherFiles = ['pocketrig-watcher.mjs', 'push.mjs', 'claude-hook.sh', 'install.sh'];

const _dir = r'"$HOME"/.config/pocketrig';

Future<Map<String, String>> loadWatcherFiles() async =>
    {for (final f in watcherFiles) f: await rootBundle.loadString('host/watcher/$f')};

/// Commands that write [text] to the setup folder, then move it into place so
/// a dropped connection never leaves half a script. Chunked on line boundaries
/// because one SSH command can only be so long.
List<String> uploadCommands(String name, String text, {int chunkSize = 16000}) {
  final tmp = '$_dir/$name.tmp';
  final chunks = <String>[];
  final b = StringBuffer();
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    b.write(lines[i]);
    if (i < lines.length - 1) b.write('\n');
    if (b.length >= chunkSize) {
      chunks.add(b.toString());
      b.clear();
    }
  }
  if (b.isNotEmpty) chunks.add(b.toString());
  return [
    'mkdir -p $_dir && rm -f $tmp',
    for (final c in chunks) "printf '%s' ${shQuote(c)} >> $tmp",
    'chmod 755 $tmp && mv -f $tmp $_dir/$name',
  ];
}

/// Sets `node` to a Node 22+, or fails. A login shell over SSH skips .zshrc,
/// which is where nvm and friends usually add themselves to PATH.
///
/// shortcut: only the usual install folders, widen this if an install reports
/// no-node or old-node.
const _fail = r'''fail() { echo "pocketrig-setup-error $1"; exit 0; }
find_node() {
  seen=
  for n in "$(command -v node 2>/dev/null)" "$HOME"/.local/node*/bin/node "$HOME"/.nvm/versions/node/*/bin/node \
      "$HOME"/.volta/bin/node /opt/homebrew/bin/node /usr/local/bin/node; do
    [ -x "$n" ] || continue
    seen=1
    "$n" -e 'process.exit(parseInt(process.versions.node) >= 22 ? 0 : 1)' 2>/dev/null && { node=$n; return 0; }
  done
  [ -n "$seen" ] && fail old-node
  fail no-node
}
''';

/// Runs before anything is uploaded: a host that can't run the watcher is left
/// exactly as it was.
const hostSetupPreflight = '''$_fail
command -v launchctl >/dev/null 2>&1 || fail not-macos
find_node
launchctl print "gui/\$(id -u)" >/dev/null 2>&1 || fail no-login
# Answers from the phone are typed into tmux; Homebrew installs it without a password.
command -v tmux >/dev/null 2>&1 || {
  command -v brew >/dev/null 2>&1 || fail no-tmux
  HOMEBREW_NO_AUTO_UPDATE=1 brew install tmux >/dev/null 2>&1 && command -v tmux >/dev/null 2>&1 || fail tmux-install
}
echo pocketrig-setup-ok
''';

/// Runs the uploaded installer, then checks for itself that the watcher answers
/// and the hooks landed.
String hostSetupInstall({required String topic, required String server, required String hostName}) => '''$_fail
d="\$HOME/.config/pocketrig"
find_node
out=\$(PATH="\${node%/*}:\$PATH" sh "\$d/install.sh" ${shQuote(topic)} ${shQuote(server)} ${shQuote(hostName)} 2>&1) || { printf '%s\\n' "\$out"; fail install; }
up=; i=0
while [ "\$i" -lt 20 ]; do
  code=\$(curl -s -o /dev/null -m 1 -w '%{http_code}' http://127.0.0.1:7434/hook 2>/dev/null)
  case "\$code" in ''|000) ;; *) up=1; break ;; esac
  i=\$((i + 1))
  sleep 0.5
done
[ -n "\$up" ] || fail no-watcher
grep -Fq "\$d/claude-hook.sh" "\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/settings.json" 2>/dev/null || fail no-hooks
echo pocketrig-setup-ok
''';

/// Throws [OpenRigException] with what went wrong unless [out] reports success.
void checkHostSetupOutput(String out) {
  if (out.contains('pocketrig-setup-ok')) return;
  final why = RegExp(r'pocketrig-setup-error (\S+)').firstMatch(out)?.group(1);
  final detail = out.replaceAll(RegExp(r'pocketrig-setup-error \S+'), '').trim();
  throw OpenRigException(switch (why) {
    'not-macos' => 'Setup from the app only supports macOS hosts so far. Nothing was changed.',
    'no-node' => 'Node isn\'t installed on this host. Nothing was changed.',
    'old-node' => 'The watcher needs Node 22 or newer. Nothing was changed.',
    'no-login' => 'launchd has no desktop session for this user. Log in at the Mac, then try again. Nothing was changed.',
    'no-tmux' => 'tmux isn\'t installed on this host, and there\'s no Homebrew to install it with. '
        'Install tmux at the Mac (brew install tmux), then try again. Nothing was changed.',
    'tmux-install' => 'Homebrew couldn\'t install tmux. Run brew install tmux at the Mac, then try again. '
        'Nothing was changed.',
    'install' => detail.isEmpty ? 'The installer failed.' : detail,
    'no-watcher' => 'Installed, but the watcher isn\'t answering. See ~/Library/Logs/pocketrig-watcher.log on the host.',
    'no-hooks' => 'The watcher is running, but the hooks aren\'t in Claude Code\'s settings.',
    _ => 'Setup gave no result. Check the host before trying again.',
  });
}

/// Installs or updates the watcher and Claude Code hooks on [host] over SSH.
Future<void> setUpHost(Host host, Map<String, String> files, {required String server}) async {
  final topic = host.ntfyTopic;
  if (topic == null) throw OpenRigException('Add an ntfy topic first.');
  await SshExec.use(host, (ssh) async {
    // `sh` because the login shell may not be POSIX; login so PATH finds node.
    Future<String> login(String script) => ssh.runLogin('sh -c ${shQuote(script)}');
    checkHostSetupOutput(await login(hostSetupPreflight));
    for (final e in files.entries) {
      for (final c in uploadCommands(e.key, e.value)) {
        await ssh.run(c);
      }
    }
    checkHostSetupOutput(await login(hostSetupInstall(topic: topic, server: server, hostName: host.name)));
  });
}

/// Stops and starts the OpenRig daemon on [host] over SSH. A daemon started
/// before Tailscale was up listens on loopback only; a restart binds the
/// tailnet too. Throws with rig's output when the start failed.
Future<void> restartDaemon(Host host) async {
  await SshExec.use(host, (ssh) async {
    // stop fails when nothing runs; that's fine. start exits nonzero when a listener is missing.
    final out = await ssh.runLogin('rig daemon stop 2>&1; rig daemon start 2>&1 && echo pocketrig-restart-ok');
    if (out.contains('pocketrig-restart-ok')) return;
    final tail = out.trim().split('\n').reversed.take(6).toList().reversed.join('\n');
    throw OpenRigException(tail.isEmpty ? 'The daemon didn\'t start, and rig printed nothing.' : tail);
  });
}

/// The OpenRig CLI on [host]: the version installed and the latest on npm
/// (either null when the host can't tell).
Future<(String?, String?)> openRigVersions(Host host) async {
  return SshExec.use(host, (ssh) async {
    return parseOpenRigVersions(await ssh.runLogin(
        'rig --version 2>/dev/null | head -n 1; echo @@pocketrig-latest; npm view @openrig/cli version 2>/dev/null; true'));
  });
}

/// `rig --version` ("0.7.6 (c00c6321)"), a marker, then `npm view`'s version.
(String?, String?) parseOpenRigVersions(String out) {
  final at = out.indexOf('@@pocketrig-latest');
  String? first(String s) => switch (s.trim().split(RegExp(r'\s+')).first) { '' => null, final v => v };
  return at < 0 ? (first(out), null) : (first(out.substring(0, at)), first(out.substring(at + 18)));
}

/// Updates the OpenRig CLI on [host] to the latest on npm, then restarts the
/// daemon so it runs the new code (agents keep running in tmux). Returns the
/// version now installed; throws with npm's or rig's output when a step failed.
Future<String> updateOpenRig(Host host) async {
  return SshExec.use(host, (ssh) async {
    final out = await ssh.runLogin(openRigUpdateScript);
    String tail() => out.trim().split('\n').reversed.take(6).toList().reversed.join('\n');
    if (!out.contains('pocketrig-install-ok')) {
      throw OpenRigException('npm couldn\'t install the update. Nothing was restarted.\n${tail()}');
    }
    final version = RegExp(r'pocketrig-version (\S+)').firstMatch(out)?.group(1) ?? '?';
    if (!out.contains('pocketrig-restart-ok')) {
      throw OpenRigException('Installed OpenRig $version, but the daemon didn\'t start again.\n${tail()}');
    }
    return version;
  });
}

/// npm install, then a daemon restart only when the install worked.
const openRigUpdateScript = 'npm install -g @openrig/cli@latest 2>&1 && echo pocketrig-install-ok || exit 0; '
    'rig daemon stop 2>&1; rig daemon start 2>&1 && echo pocketrig-restart-ok; '
    'echo "pocketrig-version \$(rig --version 2>/dev/null | head -n 1)"';

/// One line of the watcher check: what was checked, whether it passed, and
/// what to do when it didn't.
class HealthCheck {
  HealthCheck(this.label, this.ok, this.detail);
  final String label;
  final bool ok;
  final String detail;
}

class WatcherHealth {
  WatcherHealth(this.checks, this.log);
  final List<HealthCheck> checks;

  /// The last lines of ~/Library/Logs/pocketrig-watcher.log.
  final List<String> log;
  bool get ok => checks.every((c) => c.ok);
}

/// Read-only: launchd's view of the job, whether the watcher answers, the
/// installed files' hashes, the hooks and the topic, and the log's tail.
const watcherHealthScript = r'''d="$HOME/.config/pocketrig"
P="$HOME/Library/LaunchAgents/dev.pocketrig.watcher.plist"
command -v launchctl >/dev/null 2>&1 || { echo "pr-os other"; echo pr-done; exit 0; }
[ -f "$P" ] && echo "pr-plist yes" || echo "pr-plist no"
j=$(launchctl print "gui/$(id -u)/dev.pocketrig.watcher" 2>/dev/null)
echo "pr-state $(printf '%s\n' "$j" | sed -n 's/^[[:space:]]*state = //p' | head -n 1)"
echo "pr-lastexit $(printf '%s\n' "$j" | sed -n 's/^[[:space:]]*last exit code = //p' | head -n 1)"
code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' http://127.0.0.1:7434/hook 2>/dev/null)
echo "pr-http ${code:-000}"
for f in pocketrig-watcher.mjs push.mjs claude-hook.sh install.sh; do
  echo "pr-sha $f $(shasum -a 256 "$d/$f" 2>/dev/null | cut -d' ' -f1)"
done
grep -Fq "$d/claude-hook.sh" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null && echo "pr-hooks yes" || echo "pr-hooks no"
command -v tmux >/dev/null 2>&1 && echo "pr-tmux yes" || echo "pr-tmux no"
echo "pr-topic $(plutil -extract EnvironmentVariables.POCKETRIG_NTFY_TOPIC raw "$P" 2>/dev/null)"
s=$(plutil -extract EnvironmentVariables.POCKETRIG_NTFY_SERVER raw "$P" 2>/dev/null)
[ -n "$s" ] && echo "pr-ntfy $(curl -s -o /dev/null -m 6 -w '%{http_code}' "$s/v1/health" 2>/dev/null)"
L="$HOME/Library/Logs/pocketrig-watcher.log"
echo "pr-postfail $(tail -n 300 "$L" 2>/dev/null | grep -c 'ntfy unreachable')"
echo "pr-postfaillast $(tail -n 300 "$L" 2>/dev/null | grep 'ntfy unreachable' | tail -n 1 | cut -d' ' -f1)"
tail -n 5 "$HOME/Library/Logs/pocketrig-watcher.log" 2>/dev/null | sed 's/^/pr-log /'
echo pr-done
''';

/// Turns [watcherHealthScript]'s output into checks. [bundled] maps each
/// watcher file to the sha256 of the copy this app would install.
WatcherHealth parseWatcherHealth(String out, {required Map<String, String> bundled, String? topic}) {
  if (!out.contains('pr-done')) throw OpenRigException('The check gave no result: ${out.trim()}');
  final v = <String, String>{};
  final shas = <String, String>{};
  final log = <String>[];
  for (final line in out.split('\n')) {
    final m = RegExp(r'^pr-(\w+) ?(.*)$').firstMatch(line.trimRight());
    if (m == null) continue;
    final (key, rest) = (m.group(1)!, m.group(2)!);
    if (key == 'log') {
      log.add(rest);
    } else if (key == 'sha') {
      final parts = rest.split(' ');
      shas[parts.first] = parts.length > 1 ? parts[1] : '';
    } else {
      v[key] = rest.trim();
    }
  }
  if (v['os'] == 'other') {
    return WatcherHealth([HealthCheck('Host', false, 'The watcher check only supports macOS hosts so far.')], log);
  }
  const fix = 'Press Set up on this host.';
  final installed = v['plist'] == 'yes';
  final state = v['state'] ?? '';
  final lastExit = v['lastexit'] ?? '';
  final stale = [for (final e in bundled.entries) if (shas[e.key] != e.value) e.key];
  final missing = stale.where((f) => (shas[f] ?? '').isEmpty).toList();
  final installedTopic = v['topic'] ?? '';
  return WatcherHealth([
    HealthCheck('Installed', installed, installed ? 'launchd agent dev.pocketrig.watcher' : 'Not installed. $fix'),
    HealthCheck(
        'Running',
        state == 'running',
        state == 'running'
            ? 'launchd reports it running'
            : '${state.isEmpty ? 'Not loaded in launchd' : 'launchd says $state'}'
                '${lastExit.isEmpty || lastExit.startsWith('(') ? '' : ', last exit $lastExit'}. $fix'),
    HealthCheck('Answering', (v['http'] ?? '000') != '000',
        (v['http'] ?? '000') != '000' ? 'Listening on port 7434' : 'Nothing on port 7434. See the log below.'),
    HealthCheck(
        'Up to date',
        stale.isEmpty,
        stale.isEmpty
            ? 'Same version as this app'
            : missing.length == stale.length
                ? 'Files missing: ${stale.join(', ')}. $fix'
                : 'Older than this app (${stale.join(', ')}). $fix'),
    HealthCheck('Claude Code hooks', v['hooks'] == 'yes',
        v['hooks'] == 'yes' ? 'In ~/.claude/settings.json' : 'Not in Claude Code\'s settings. $fix'),
    // Older watcher scripts don't print the line; say nothing rather than fail.
    if (v.containsKey('tmux'))
      HealthCheck('tmux', v['tmux'] == 'yes',
          v['tmux'] == 'yes' ? 'Found, so answers can reach agents' : 'Not installed, so the phone can\'t answer agents. $fix'),
    if (v.containsKey('ntfy'))
      _ntfyCheck(v['ntfy']!, int.tryParse(v['postfail'] ?? '') ?? 0, DateTime.tryParse(v['postfaillast'] ?? '')),
    if (topic != null)
      HealthCheck(
          'Topic',
          installedTopic == topic,
          installedTopic == topic
              ? 'Posts to $topic'
              : installedTopic.isEmpty
                  ? 'No topic installed. $fix'
                  : 'Posts to $installedTopic, but this app listens on $topic. $fix'),
  ], log);
}

/// ntfy answers from the host now, and recent posts got through.
HealthCheck _ntfyCheck(String code, int failed, DateTime? last) {
  final up = code.startsWith('2');
  final when = last == null ? '' : ', last ${_ago(last)} ago';
  if (!up) return HealthCheck('Reaching ntfy', false, 'The host can\'t reach the ntfy server (HTTP ${code.isEmpty ? '—' : code}).');
  if (failed > 0) {
    return HealthCheck('Reaching ntfy', false,
        'Reachable now, but $failed notification${failed == 1 ? '' : 's'} failed to send recently$when.');
  }
  return HealthCheck('Reaching ntfy', true, 'Reachable, and no failed notifications in the log');
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  return d.inMinutes < 60 ? '${d.inMinutes}m' : d.inHours < 24 ? '${d.inHours}h' : '${d.inDays}d';
}

/// Runs the watcher check on [host] over SSH.
Future<WatcherHealth> checkWatcher(Host host, Map<String, String> files) async {
  return SshExec.use(host, (ssh) async {
    final out = await ssh.runLogin('sh -c ${shQuote(watcherHealthScript)}');
    return parseWatcherHealth(out,
        bundled: {for (final e in files.entries) e.key: sha256.convert(utf8.encode(e.value)).toString()},
        topic: host.ntfyTopic);
  });
}
