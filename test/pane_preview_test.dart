import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/chat/pane_preview.dart';

// The panes are written in Claude Code's TUI format (with invented content).
String pane(String name) => File('test/fixtures/panes/$name.txt').readAsStringSync();

void main() {
  test('a reply being written shows its text without the pane chrome', () {
    final t = parsePanePreview(pane('mid_reply'))!;
    expect(
        t,
        'Now the tests: a retry test on the fake client, and one that checks it gives up after three tries instead of looping.\n'
        '\n'
        'The retry waits 200 ms between tries, so the tests use a fake clock.');
  });

  test('wrapped lines join; list items stay apart; the reply shows while hooks run', () {
    expect(
        parsePanePreview(pane('hooks_after_reply')),
        'Done. Two changes:\n'
        '\n'
        '- Retry: upload.dart retries a failed send three times, 200 ms apart, then rethrows the last error.\n'
        '- Test: upload_test.dart covers success on the second try and giving up after the third, with a fake clock.\n'
        '- Not run: the whole suite; only upload_test.dart.');
  });

  test('nothing while a tool runs, when idle, or at a permission menu', () {
    expect(parsePanePreview(pane('tool_running')), isNull);
    expect(parsePanePreview(pane('idle')), isNull);
    expect(parsePanePreview(pane('permission')), isNull);
    expect(parsePanePreview(pane('tool_with_tip')), isNull, reason: 'a tool call is the last block, a tip under the status');
  });

  test('a tip under the status line does not hide the reply', () {
    expect(parsePanePreview(pane('reply_with_tip')), 'Fine, that is done. Next up is the second slice.');
  });

  test('nothing when the pane is not recognised', () {
    expect(parsePanePreview(''), isNull);
    expect(parsePanePreview('\$ ls\nfoo\n\$ '), isNull);
  });
}
