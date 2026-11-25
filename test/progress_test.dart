import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart';

// Shaped like OpenRig's GET /api/slices/:name and /api/progress/tree.
void main() {
  final rig = Rig(id: 'r1', name: 'factory', nodeCount: 2, runningCount: 2, attentionCount: 0, status: 'running');

  test('a slice reads its checks, story and the rigs it touches', () {
    final d = SliceDetail.fromJson({
      'name': '01-rings',
      'displayName': '01-rings',
      'missionId': 'usage-widget',
      'status': 'blocked',
      'qitemCount': 37,
      'lastActivityAt': '2026-11-02T10:18:01.545Z',
      'acceptance': {
        'items': [
          {'text': 'Unit test', 'done': true},
          {'text': 'Screenshot', 'done': false},
          {'text': '', 'done': true},
        ],
      },
      'story': {
        'events': [
          {'ts': '2026-11-02T10:18:01.192Z', 'kind': 'transition.done', 'actorSession': 'dev-qa@factory', 'summary': '→ done'},
        ],
      },
      'topology': {
        'affectedRigs': [
          {'rigId': 'other', 'rigName': 'factory'},
        ],
      },
    });
    expect(d.summary.status, 'blocked');
    expect(d.summary.qitemCount, 37);
    expect(d.checks, [('Unit test', true), ('Screenshot', false)]);
    expect(d.done, 1);
    expect(d.events.single.actor, 'dev-qa@factory');
    expect(d.touches(rig), isTrue, reason: 'matched by rig name');
    expect(SliceDetail.fromJson({'name': 'x'}).touches(rig), isFalse);
  });

  test('PROGRESS.md rows keep checkboxes and know their mission', () {
    final f = ProgressFile.fromJson({
      'relPath': 'missions/usage-widget/PROGRESS.md',
      'title': 'Progress — Usage Widget',
      'rows': [
        {'kind': 'heading', 'status': 'unknown', 'text': 'Acceptance', 'depth': 0},
        {'kind': 'checkbox', 'status': 'done', 'text': 'Scope complete', 'depth': 0},
        {'kind': 'checkbox', 'status': 'active', 'text': 'QA pass', 'depth': 1},
      ],
    });
    expect(f.missionId, 'usage-widget');
    expect(f.rows, [('Scope complete', 'done', 0), ('QA pass', 'active', 1)]);
    expect(ProgressFile.fromJson({'relPath': 'missions/m/slices/s/PROGRESS.md'}).missionId, isNull);
  });
}
