import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/terminal/transport.dart';

Seat _seat({String? attach}) => Seat.fromJson({
      'rigId': 'r',
      'logicalId': 'lead',
      'canonicalSessionName': 'lead@r',
      'runtime': 'claude-code',
      'sessionStatus': 'running',
      if (attach != null) 'attachmentType': 'tmux',
      if (attach != null) 'tmuxAttachCommand': attach,
    });

void main() {
  // Verified on this Mac with a scratch tmux socket: a client with no locale draws ⎿ ✻ ✔ as `_`; -u (or a UTF-8 LANG) draws them.
  test('a seat attaches with tmux -u, so a host whose SSH login shell has no locale still draws ⎿ ✻ ✔', () {
    expect(seatAttachCommand(_seat()), "exec tmux -u attach -t '=lead@r'");
  });

  test('the daemon\'s own attach command gets -u too, once', () {
    expect(tmuxUtf8('tmux attach-session -t lead@r'), 'tmux -u attach-session -t lead@r');
    expect(tmuxUtf8('tmux -u attach -t x'), 'tmux -u attach -t x');
    expect(tmuxUtf8('echo tmux'), 'echo tmux');
  });
}
