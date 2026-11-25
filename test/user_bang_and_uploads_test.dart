import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/chat/transcript.dart';

void main() {
  String user(String uuid, String text) => jsonEncode({
        'uuid': uuid,
        'type': 'user',
        'message': {'role': 'user', 'content': text},
      });

  test('a !command and its output become one Bash call', () {
    final t = ChatTranscript()
      ..add(user('a', '<bash-input>git push origin v1</bash-input>'))
      ..add(user('b', '<bash-stdout>* [new tag] v1 -&gt; v1</bash-stdout><bash-stderr></bash-stderr>'));
    final call = t.items.single as ToolCall;
    expect(call.name, 'Bash');
    expect(call.input['command'], 'git push origin v1');
    expect(call.result, '* [new tag] v1 -> v1');
    expect(call.isError, isFalse);
  });

  String only(String text) => switch ((ChatTranscript()..add(user('a', text))).items) {
        [UserMessage(:final text)] => 'user: $text',
        [NoteItem(:final text)] => 'note: $text',
        [] => 'nothing',
        final x => 'other: $x',
      };

  test('Claude Code tags in user lines', () {
    expect(only('<pasted_content id="8a71">\nline one\nline two\n</pasted_content id="8a71">'),
        'user: line one\nline two');
    expect(only('<artifact-view-context artifact="x">\n{"a":1}\n</artifact-view-context>\n\n1. No\n2. Yes'),
        'user: 1. No\n2. Yes');
    expect(only('<system-reminder>\nYou are in a worktree.\n</system-reminder>\nFix it'), 'user: Fix it');
    expect(only('<system-reminder>x</system-reminder>'), 'nothing');
    expect(
        only('<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n'
            '<summary>Background command "Run tests" completed (exit code 0)</summary>\n</task-notification>'),
        'note: Background command "Run tests" completed (exit code 0)');
    expect(only('<ci-monitor-event>"Auto-fix" is watching me/app PR #143 and saw…</ci-monitor-event>'),
        'note: CI update on PR #143');
    expect(only('<create-pr-command>\n## Overview\n…\n</create-pr-command>'), 'note: Create PR');
    expect(
        only('<command-message>review</command-message>\n<command-name>/review</command-name>\n'
            '<command-args>123</command-args>'),
        'note: /review 123');
    expect(only('<local-command-stdout>See ya!</local-command-stdout>'), 'note: See ya!');
  });

  test('attached uploads come out of the text', () {
    const p = '/Users/me/.cache/pocketrig/uploads/20261105-222050-shot.png';
    void check(String text, String rest, List<String> media) {
      final (r, m) = splitUploads(text);
      expect(r, rest);
      expect(m, media);
    }

    check('$p \n\nCan you fix this?', 'Can you fix this?', [p]);
    check('$p ', '', [p]);
    const pdf = '/Users/me/.cache/pocketrig/uploads/x.pdf';
    check('read $pdf', 'read $pdf', []);
  });
}
