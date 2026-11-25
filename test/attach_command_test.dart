import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/terminal/transport.dart';

void main() {
  test('only plain tmux attach lines from the daemon are run', () {
    expect(safeAttachCommand("tmux attach -t 'lead@conveyor'"), "tmux attach -t 'lead@conveyor'");
    expect(safeAttachCommand('tmux -L openrig attach-session -t =impl@app:'), isNotNull);
    expect(safeAttachCommand(null), isNull);
    for (final bad in [
      'tmux attach -t x; rm -rf ~',
      r'tmux attach -t $(id)',
      'tmux attach -t `id`',
      'tmux attach -t x | sh',
      'tmux attach -t x\nid',
      'tmux attach -t x > /tmp/y',
      'sh -c id',
    ]) {
      expect(safeAttachCommand(bad), isNull, reason: bad);
    }
  });
}
