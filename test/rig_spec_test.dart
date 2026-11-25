import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/rig_spec.dart';

// Trimmed copy of OpenRig's built-in `pm` RigSpec (specs/rigs/focused/pm).
const pmSpec = '''
version: "0.2"
name: pm
summary: >
  Product management rig with a PM lead.

pods:
  - id: pm
    label: Product Management
    members:
      - id: lead
        agent_ref: "local:../../../agents/product-management/pm"
        runtime: claude-code
        cwd: "."
      - id: researcher
        agent_ref: "local:../../../agents/research/analyst"
        runtime: codex
    edges:
      - kind: delegates_to
        from: lead
        to: researcher

  - id: dev
    label: Development Support
    members:
      - id: build
        runtime: claude-code
    edges: []

edges:
  - kind: delegates_to
    from: pm.lead
    to: dev.build
''';

void main() {
  test('parses pods, members and both edge levels', () {
    final s = RigSpecSummary.parse(pmSpec);
    expect(s.error, isNull);
    expect(s.name, 'pm');
    expect(s.version, '0.2');
    expect(s.summary, 'Product management rig with a PM lead.');
    expect(s.pods.map((p) => p.id), ['pm', 'dev']);
    expect(s.seatCount, 3);
    expect(s.runtimes, {'claude-code', 'codex'});
    expect(s.pods.first.members.first.runtimeBadge, 'CC');
    expect(s.edges.map((e) => '${e.from}>${e.to}'), ['pm.lead>pm.researcher', 'pm.lead>dev.build']);
    expect(s.oneLine, '2 pods · 3 seats · claude + codex');
  });

  test('broken YAML reports an error instead of throwing', () {
    final s = RigSpecSummary.parse('pods: [unclosed');
    expect(s.error, isNotNull);
    expect(s.oneLine, 'invalid YAML');
  });

  test('launch results keep stages and errors from plan and failure bodies', () {
    final planned = LaunchResult.fromJson({
      'status': 'planned',
      'stages': [
        {'stage': 'resolve_spec', 'status': 'ok', 'detail': {'message': 'pm v0.2'}},
        {'stage': 'import_rig', 'status': 'ok', 'detail': null},
      ],
      'errors': [],
    });
    expect(planned.ok, isTrue);
    expect(planned.stages.first, ('resolve_spec', 'ok', 'pm v0.2'));

    final failed = LaunchResult.fromJson({'error': 'sourceRef is required'});
    expect(failed.ok, isFalse);
    expect(failed.errors, ['sourceRef is required']);
  });

  test('relative path is shown against the project folder', () {
    final f = RigSpecFile(path: '/w/app/rigs/a/rig.yaml', projectPath: '/w/app');
    expect(f.relativePath, 'rigs/a/rig.yaml');
    expect(f.worktree, isNull);
    expect(f.checkoutPath, 'rigs/a/rig.yaml');
  });

  test('a worktree\'s copy of a spec has the same checkout path', () {
    final f = RigSpecFile(path: '/w/app/.claude/worktrees/fix/rigs/a/rig.yaml', projectPath: '/w/app');
    expect(f.worktree, 'fix');
    expect(f.checkoutPath, 'rigs/a/rig.yaml');
    expect(RigSpecFile(path: '/w/app/.worktrees/two/rig.yaml', projectPath: '/w/app').checkoutPath, 'rig.yaml');
    // Opened on a worktree itself, its specs are that project's own.
    final own = RigSpecFile(path: '/w/.worktrees/two/rig.yaml', projectPath: '/w/.worktrees/two');
    expect(own.worktree, isNull);
  });
}
