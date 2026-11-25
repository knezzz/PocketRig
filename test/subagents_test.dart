import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/chat/transcript.dart';
import 'package:pocket_rig/data/subagents.dart';
import 'package:pocket_rig/models.dart';

void main() {
  test('the scan finds running subagents, not finished or quiet ones', () async {
    final home = await Directory.systemTemp.createTemp('pr-sub');
    addTearDown(() => home.delete(recursive: true));
    void agent(String session, String id, String meta, {bool old = false}) {
      final dir = Directory('${home.path}/projects/-w-app/$session/subagents')..createSync(recursive: true);
      final log = File('${dir.path}/agent-$id.jsonl')
        ..writeAsStringSync('{"type":"user","timestamp":"2026-11-04T10:00:00.000Z"}\n{"type":"assistant"}\n');
      File('${dir.path}/agent-$id.meta.json').writeAsStringSync(meta);
      if (old) log.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
    }

    agent('s1', 'a1', '{"agentType":"Explore","description":"Find the \\"router\\"\\tcode"}');
    agent('s1', 'a2', '{"agentType":"Explore","description":"done","finished":true}');
    agent('s2', 'a3', '{"agentType":"general-purpose","description":"stale"}', old: true);
    agent('s2', 'a4', '{"agentType":"x","stoppedByUser":true}');

    final r = await Process.run('/bin/sh', ['-c', Subagent.script()], environment: {'CLAUDE_CONFIG_DIR': home.path});
    final found = Subagent.parse(r.stdout as String);
    expect(found.map((s) => (s.sessionId, s.agentId)), [('s1', 'a1')]);
    expect(found.single.description, 'Find the "router"\tcode');
    expect(found.single.type, 'Explore');
    expect(found.single.path, '${home.path}/projects/-w-app/s1/subagents/agent-a1.jsonl');
    expect(found.single.started, DateTime.utc(2026, 11, 4, 10).toLocal());
    expect(DateTime.now().difference(found.single.lastWrite!).inMinutes, lessThan(2));
  });

  test('a seat is matched by its log name, else its resume token', () {
    Seat seat({String? tp, String? token}) => Seat(rigId: 'r', logicalId: 'x', transcriptPath: tp, resumeToken: token);
    expect(claudeSessionOf(seat(tp: '/h/.claude/projects/-w/abc-1.jsonl', token: 'zzz')), 'abc-1');
    expect(claudeSessionOf(seat(token: 'zzz')), 'zzz');
    expect(subagentsLabel([]), isNull);
  });

  test('sidechain lines show only in a subagent\'s own chat', () {
    const line = '{"type":"user","isSidechain":true,"uuid":"u1","message":{"role":"user","content":"Find the router"}}';
    expect((ChatTranscript()..add(line)).items, isEmpty);
    expect((ChatTranscript(sidechain: true)..add(line)).items, hasLength(1));
    expect(isSubagentLog('/h/.claude/projects/-w/s1/subagents/agent-a1.jsonl'), isTrue);
    expect(isSubagentLog('/h/.claude/projects/-w/s1.jsonl'), isFalse);
  });
}
