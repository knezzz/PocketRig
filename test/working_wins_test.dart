import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/loose_agent_screen.dart' show looseStatus;

void main() {
  test('looseStatus: working wins over on-shell, so a working agent with something running reads working, as its icon is', () {
    final now = DateTime.now();
    final working = LooseAgent(id: 'w', activity: 'working', activeAt: now.subtract(const Duration(seconds: 5)), heardAt: now);
    expect(looseStatus(working, now, const [], 2), 'working', reason: 'subagents left running, still working');
    final idle = LooseAgent(id: 'i', activity: 'idle', activeAt: now.subtract(const Duration(minutes: 1)), heardAt: now);
    expect(looseStatus(idle, now, const [], 1), 'waiting on a subagent', reason: 'idle at its prompt: what it waits on');
  });
}
