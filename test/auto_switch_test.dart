import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/prompt_screen.dart' show dialogOnScreen;
import 'package:pocket_rig/terminal/transport.dart';

/// Runs [autoSwitchScript] against a stub `tmux` that shows `pane<N>` after
/// N Shift+Tabs (the last pane once it runs out).
Future<(String, int)> run(List<String> panes) async {
  final dir = await Directory.systemTemp.createTemp('autoswitch');
  addTearDown(() => dir.delete(recursive: true));
  for (var i = 0; i < panes.length; i++) {
    File('${dir.path}/pane$i').writeAsStringSync(panes[i]);
  }
  final stub = File('${dir.path}/tmux')
    ..writeAsStringSync('''#!/bin/sh
d=${dir.path}; n=\$(cat \$d/n 2>/dev/null || echo 0)
case "\$1" in
  has-session) exit 0;;
  send-keys) echo \$((n+1)) > \$d/n;;
  capture-pane) [ -f \$d/pane\$n ] && cat \$d/pane\$n || cat \$d/pane${panes.length - 1};;
esac
''');
  await Process.run('chmod', ['+x', stub.path]);
  final r = await Process.run(Platform.environment['SH'] ?? 'sh', ['-c', autoSwitchScript('dev@rig')],
      environment: {'PATH': '${dir.path}:${Platform.environment['PATH']}'});
  final n = File('${dir.path}/n');
  return ((r.stdout as String).trim(), n.existsSync() ? int.parse(n.readAsStringSync().trim()) : 0);
}

String screen(String footer, {String talk = 'done'}) => '$talk\n\n'
    '──────────── dev@rig ─\n❯ \n────────────────────\n  $footer\n\n';

void main() {
  test('presses Shift+Tab until the footer says auto mode on', () async {
    final (out, presses) = await run([
      screen('⏵⏵ accept edits on (shift+tab to cycle)', talk: 'I turned auto mode on earlier'),
      screen('⏸ plan mode on (shift+tab to cycle)'),
      screen('⏵⏵ auto mode on (shift+tab to cycle) · PR #50'),
    ]);
    expect((out, presses), ('POCKETRIG_AUTO', 2));
  });

  test('a footer with a tip line under it still counts', () async {
    final (out, presses) = await run(['${screen('⏵⏵ auto mode on · PR #2')}  new task? /clear\n']);
    expect((out, presses), ('POCKETRIG_AUTO', 0));
  });

  test('gives up after a full cycle without Auto', () async {
    final (out, presses) = await run([screen('⏵⏵ accept edits on')]);
    expect((out, presses), ('POCKETRIG_NOAUTO', 6));
  });

  test('never presses Shift+Tab into a permission menu', () async {
    final (out, presses) = await run(['Bash command\n  npm test\nDo you want to proceed?\n❯ 1. Yes\n  2. No\n']);
    expect((out, presses), ('POCKETRIG_PROMPT', 0));
  });

  // The real panes in test/fixtures/panes: the Auto switch must see a dialog exactly when the send guard's rule does, and
  // never press Shift+Tab into one (it would move or pick an option).
  final fixtures = Directory('test/fixtures/panes').listSync().whereType<File>().where((f) => f.path.endsWith('.txt')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in fixtures) {
    final name = f.uri.pathSegments.last;
    test('fixture $name: the Auto switch agrees with dialogOnScreen', () async {
      final text = f.readAsStringSync();
      final (out, presses) = await run([text]);
      if (dialogOnScreen(text)) {
        expect((out, presses), ('POCKETRIG_PROMPT', 0), reason: '$name shows a dialog: no key may be pressed');
      } else {
        expect(out, isNot('POCKETRIG_PROMPT'), reason: '$name shows none');
      }
    });
  }

  test('the fixtures include a question menu (no "Do you want") and it stops the switch', () async {
    final menu = File('test/fixtures/panes/question_option2.txt').readAsStringSync();
    expect(menu, isNot(contains('Do you want')));
    expect(dialogOnScreen(menu), isTrue);
    expect((await run([menu])).$1, 'POCKETRIG_PROMPT');
  });

  test('blank rows under the dialog, as a tall pane has, do not hide it', () async {
    final (out, presses) = await run(['Do you want to proceed?\n❯ 1. Yes\n  2. No\n${'\n' * 40}']);
    expect((out, presses), ('POCKETRIG_PROMPT', 0));
  });

  test('a numbered list in the agent\'s own reply is not a dialog', () async {
    final (out, _) = await run([screen('⏵⏵ auto mode on', talk: 'Plan:\n  1. Fix x\n  2. Ship it')]);
    expect(out, 'POCKETRIG_AUTO');
  });
}
