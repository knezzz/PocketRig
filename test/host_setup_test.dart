import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/host_setup.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/keygen.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/hosts_screen.dart';

import 'golden/fixtures.dart';

void main() {
  watcherHealthTests();
  final host = Host(id: 'h', name: 'mini', address: 'mini', sshUser: 'me', ntfyTopic: 'topic-1', privateKeyPem: 'k');

  group('setup on a real shell', () {
    late Directory home;
    late File log;

    void tool(String name, String body) {
      final f = File('${home.path}/bin/$name')..writeAsStringSync('#!/bin/sh\n$body\n');
      Process.runSync('chmod', ['+x', f.path]);
    }

    /// Commands really run, against a temporary home with fake tools.
    SshExec fakeHost() => SshExec.fake((cmd) async {
          File(log.path).writeAsStringSync('$cmd\n', mode: FileMode.append);
          final r = await Process.run('/bin/sh', ['-c', cmd], environment: {
            'HOME': home.path,
            // A real login shell would reset PATH and reach the machine's own launchctl.
            'SHELL': '${home.path}/bin/loginsh',
            'PATH': '${home.path}/bin:/usr/bin:/bin',
          });
          return '${r.stdout}';
        });

    setUp(() {
      home = Directory.systemTemp.createTempSync('pocketrig-setup');
      Directory('${home.path}/bin').createSync();
      Directory('${home.path}/.claude').createSync();
      log = File('${home.path}/commands.log')..createSync();
      // Resets PATH like a real login shell, so Homebrew's folders on this machine stay out.
      tool('loginsh', 'shift; PATH="\$HOME/bin:/usr/bin:/bin" exec /bin/sh -c "\$1"');
      tool('launchctl', 'exit 0');
      tool('tmux', 'exit 0');
      tool('node', 'exit 0');
      tool('curl', 'printf 404');
      SshExec.debugConnect = (h) async => fakeHost();
    });

    tearDown(() {
      SshExec.debugConnect = null;
      home.deleteSync(recursive: true);
    });

    /// An installer standing in for install.sh: records its arguments and adds the hook.
    String installer() => r'''#!/bin/sh
printf '%s\n' "$@" > "$HOME/install.args"
printf '%s' "$HOME/.config/pocketrig/claude-hook.sh" > "$HOME/.claude/settings.json"
''';

    test('uploads byte for byte, runs the installer, and checks the result', () async {
      // Long enough to need several chunks, with characters a shell cares about.
      final big = List.generate(4000, (i) => "line $i: it's \$HOME › `x` \"q\" \\n").join('\n');
      await setUpHost(host, {'pocketrig-watcher.mjs': '$big\n', 'claude-hook.sh': '#!/bin/sh\n', 'install.sh': installer()},
          server: 'https://ntfy.sh');
      expect(File('${home.path}/.config/pocketrig/pocketrig-watcher.mjs').readAsStringSync(), '$big\n');
      expect(File('${home.path}/install.args').readAsLinesSync(), ['topic-1', 'https://ntfy.sh', 'mini']);
      expect(Directory('${home.path}/.config/pocketrig').listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
      expect(uploadCommands('pocketrig-watcher.mjs', big).length, greaterThan(3), reason: 'chunked');
    });

    /// A fake node at [dir] under home that passes the version check or doesn't.
    void nodeAt(String dir, {required bool ok}) {
      Directory('${home.path}/$dir').createSync(recursive: true);
      final f = File('${home.path}/$dir/node')..writeAsStringSync('#!/bin/sh\nexit ${ok ? 0 : 1}\n');
      Process.runSync('chmod', ['+x', f.path]);
    }

    /// An installer that records which node it finds on PATH.
    String nodeSpy() => '${installer()}command -v node > "\$HOME/install.node"\n';

    test('finds a node that only .zshrc would put on PATH, and hands it to the installer', () async {
      File('${home.path}/bin/node').deleteSync();
      nodeAt('.nvm/versions/node/v22.1.0/bin', ok: true);
      await setUpHost(host, {'install.sh': nodeSpy()}, server: 'https://ntfy.sh');
      expect(File('${home.path}/install.node').readAsStringSync().trim(),
          '${home.path}/.nvm/versions/node/v22.1.0/bin/node');
    });

    test('skips an old node on PATH when a newer one is installed', () async {
      tool('node', 'exit 1');
      nodeAt('.local/node22/bin', ok: true);
      await setUpHost(host, {'install.sh': nodeSpy()}, server: 'https://ntfy.sh');
      expect(File('${home.path}/install.node').readAsStringSync().trim(), '${home.path}/.local/node22/bin/node');
    });

    test('only an old node: says so and uploads nothing', () async {
      tool('node', 'exit 1');
      await expectLater(
        setUpHost(host, {'install.sh': installer()}, server: 'https://ntfy.sh'),
        throwsA(isA<OpenRigException>().having((e) => e.message, 'message', contains('Node 22 or newer'))),
      );
      expect(Directory('${home.path}/.config').existsSync(), isFalse);
    }, skip: ['/opt/homebrew/bin/node', '/usr/local/bin/node'].any((p) => File(p).existsSync())
        ? 'this machine has a node in a searched folder'
        : null);

    test('a host that fails the preflight gets nothing uploaded', () async {
      tool('launchctl', 'exit 1');
      await expectLater(
        setUpHost(host, {'install.sh': installer()}, server: 'https://ntfy.sh'),
        throwsA(isA<OpenRigException>().having((e) => e.message, 'message', contains('Log in at the Mac'))),
      );
      expect(Directory('${home.path}/.config').existsSync(), isFalse);
    });

    group('no tmux', () {
      setUp(() => File('${home.path}/bin/tmux').deleteSync());

      test('installs it with Homebrew', () async {
        tool('brew', 'printf \'%s\\n\' "\$*" > "\$HOME/brew.args"; printf \'#!/bin/sh\\n\' > "\$HOME/bin/tmux"; chmod +x "\$HOME/bin/tmux"');
        await setUpHost(host, {'install.sh': installer()}, server: 'https://ntfy.sh');
        expect(File('${home.path}/brew.args').readAsStringSync().trim(), 'install tmux');
      });

      test('without Homebrew: says so and uploads nothing', () async {
        await expectLater(
          setUpHost(host, {'install.sh': installer()}, server: 'https://ntfy.sh'),
          throwsA(isA<OpenRigException>().having((e) => e.message, 'message', contains('brew install tmux'))),
        );
        expect(Directory('${home.path}/.config').existsSync(), isFalse);
      });
    }, skip: File('/usr/bin/tmux').existsSync() ? 'this machine has tmux in /usr/bin' : null);

    test('an installer failure comes back with its own message', () async {
      await expectLater(
        setUpHost(host, {'install.sh': '#!/bin/sh\necho "launchd wouldn\'t start the watcher" >&2\nexit 1\n'},
            server: 'https://ntfy.sh'),
        throwsA(isA<OpenRigException>().having((e) => e.message, 'message', contains('wouldn\'t start the watcher'))),
      );
    });

    test('hooks that did not land are reported', () async {
      await expectLater(
        setUpHost(host, {'install.sh': '#!/bin/sh\nexit 0\n'}, server: 'https://ntfy.sh'),
        throwsA(isA<OpenRigException>().having((e) => e.message, 'message', contains('hooks aren'))),
      );
    });
  });

  test('the bundled files are the repo\'s watcher', () {
    for (final f in watcherFiles) {
      expect(File('host/watcher/$f').existsSync(), isTrue, reason: f);
    }
  });

  test('restartDaemon stops then starts, and surfaces rig\'s output on failure', () async {
    final commands = <String>[];
    var reply = 'stopped\nDaemon started\npocketrig-restart-ok\n';
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          commands.add(cmd);
          return reply;
        });
    addTearDown(() => SshExec.debugConnect = null);

    await restartDaemon(host);
    expect(commands.single, contains('rig daemon stop'));
    expect(commands.single, contains('rig daemon start'));

    reply = 'required listener missing: <tailscale interface>\n';
    expect(
        () => restartDaemon(host),
        throwsA(isA<OpenRigException>()
            .having((e) => e.toString(), 'message', contains('required listener missing'))));
  });

  testWidgets('Set up on this host saves the host, runs setup, and shows the result', (tester) async {
    final store = await installFakes();
    final commands = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          commands.add(cmd);
          return 'pocketrig-setup-ok\n';
        });
    addTearDown(() => SshExec.debugConnect = null);
    final existing = Host(
      id: 'h1',
      name: 'mini',
      address: 'mini.ts.net',
      sshUser: 'me',
      ntfyTopic: 'topic-1',
      privateKeyPem: generateEd25519(comment: 't').privatePem,
    );
    await tester.binding.setSurfaceSize(const Size(390, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    HostEditor.checkOnOpen = false;
    addTearDown(() => HostEditor.checkOnOpen = true);
    await tester.pumpWidget(AppScope(store: store, child: MaterialApp(home: HostEditor(host: existing))));
    await tester.pump();

    await tester.scrollUntilVisible(find.text('Set up on this host'), 300, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('Set up on this host')); // built in the cache area isn't on screen yet
    await tester.pump();
    await tester.tap(find.text('Set up on this host'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.textContaining('✓ The watcher is running'), findsOneWidget);
    expect(store.hosts.any((h) => h.id == 'h1'), isTrue, reason: 'saved first, so a pinned key isn\'t lost');
    expect(commands.first, contains('watcher.json'));
    expect(commands.any((c) => c.contains('install.sh.tmp')), isTrue, reason: 'the real assets are bundled');
    expect(commands.last, contains('install.sh'));
  });
}

// Real output of watcherHealthScript on a Mac (one stale file, failed posts in the log).
const _realHealth = '''pr-plist yes
pr-state running
pr-lastexit (never exited)
pr-http 404
pr-sha pocketrig-watcher.mjs 349b88e7
pr-sha claude-hook.sh c5e8103b
pr-sha install.sh 9a7a4095
pr-hooks yes
pr-topic pocketrig-example
pr-ntfy 200
pr-postfail 36
pr-postfaillast 2026-11-02T11:14:40.012Z
pr-log 2026-11-02T11:04:22.558Z waiting: dev-android@pocketrig-factory permission_prompt
pr-log 2026-11-02T11:04:22.812Z ntfy unreachable: fetch failed
pr-done
''';

void watcherHealthTests() {
  const bundled = {'pocketrig-watcher.mjs': 'e7849ca4', 'claude-hook.sh': 'c5e8103b', 'install.sh': '9a7a4095'};
  WatcherHealth parse(String out, {String? topic = 'pocketrig-example'}) =>
      parseWatcherHealth(out, bundled: bundled, topic: topic);
  HealthCheck check(WatcherHealth h, String label) => h.checks.firstWhere((c) => c.label == label);

  test('watcher check: running and answering, but stale and dropping posts', () {
    final h = parse(_realHealth);
    expect(check(h, 'Installed').ok, isTrue);
    expect(check(h, 'Running').ok, isTrue);
    expect(check(h, 'Answering').ok, isTrue, reason: '404 from /hook still means it is listening');
    expect(check(h, 'Up to date').ok, isFalse);
    expect(check(h, 'Up to date').detail, contains('pocketrig-watcher.mjs'));
    expect(check(h, 'Claude Code hooks').ok, isTrue);
    expect(check(h, 'Topic').ok, isTrue);
    expect(check(h, 'Reaching ntfy').ok, isFalse);
    expect(check(h, 'Reaching ntfy').detail, contains('36 notifications failed'));
    expect(h.log, hasLength(2));
    expect(h.ok, isFalse);
  });

  test('watcher check: healthy, not installed, wrong topic, other OS', () {
    final good = _realHealth
        .replaceFirst('349b88e7', 'e7849ca4')
        .replaceFirst('pr-postfail 36', 'pr-postfail 0')
        .replaceFirst(RegExp(r'pr-postfaillast .*\n'), 'pr-postfaillast \n');
    expect(parse(good).ok, isTrue);
    expect(parse(good.replaceFirst('pr-hooks yes\n', 'pr-hooks yes\npr-tmux yes\n')).ok, isTrue);
    final noTmux = parse(good.replaceFirst('pr-hooks yes\n', 'pr-hooks yes\npr-tmux no\n'));
    expect(check(noTmux, 'tmux').ok, isFalse);
    expect(noTmux.ok, isFalse);

    final none = parse('pr-plist no\npr-state \npr-lastexit \npr-http 000\npr-sha pocketrig-watcher.mjs \n'
        'pr-sha claude-hook.sh \npr-sha install.sh \npr-hooks no\npr-topic \npr-postfail 0\npr-postfaillast \npr-done\n');
    expect(check(none, 'Installed').detail, contains('Set up on this host'));
    expect(check(none, 'Running').detail, startsWith('Not loaded'));
    expect(check(none, 'Up to date').detail, startsWith('Files missing'));
    expect(check(none, 'Topic').detail, startsWith('No topic installed'));

    expect(check(parse(good, topic: 'other'), 'Topic').detail, contains('this app listens on other'));
    expect(parse('pr-os other\npr-done\n').checks.single.label, 'Host');
    expect(() => parse('Permission denied'), throwsA(isA<OpenRigException>()));
  });
}
