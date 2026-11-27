import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/agent_jobs.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/project_tally.dart' show looseState;

void main() {
  test('an agent whose tmux session is gone from the scan is stopped, not live; one in a listed session is not', () {
    final host = Host(id: 'h-gone', name: 'mini', address: 'mini', sshUser: 'me');
    final gone = LooseAgent(id: 'claude-app-aa11', runtime: 'claude-code', tmuxSession: 'claude-app-aa11', waiting: true);
    final live = LooseAgent(id: 'claude-app-bb22', runtime: 'claude-code', tmuxSession: 'claude-app-bb22');
    expect(looseGone(host, gone), isFalse, reason: 'not known before a scan');
    fleet.feedFor(host).jobs = <String, List<AgentJob>>{'claude-app-bb22': const [], 'claude-app-bb2': const []};
    expect(looseGone(host, gone), isTrue);
    expect(looseState(host, gone), SeatState.stopped, reason: 'a gone row does not ask for you');
    expect(looseGone(host, live), isFalse);
    expect(looseGone(host, LooseAgent(id: 'x', runtime: 'claude-code')), isFalse, reason: 'a terminal tab has no session to lose');
  });
}
